defmodule Still.Orchestrator do
  @moduledoc """
  Rolling deployment coordinator.

  Accepts deployment requests, validates preconditions (servers assigned, enough
  agents connected), creates the database records, and spawns a background task
  that submits persisted operations server-by-server and observes their progress.
  Known failure halts the rollout; transport uncertainty preserves the lock and
  pending intent. Private task supervision ties observers to this coordinator's
  lifetime, while agent work is independent of a controller restart.

  Only one deployment per application may be in progress at a time — a second
  request for the same application returns `{:error, :deployment_in_progress}`.

  The actual agent call is injectable via the `:agent_caller` start option so
  tests can stub it without real Erlang distribution. An optional `:notifier`
  pid receives `{:deployment_complete, deployment_id, status}` when the
  background task finishes — used by tests to avoid `Process.sleep`.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Applications.Application
  alias Still.Applications.ApplicationServer
  alias Still.ArtifactStore
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Deployments.FailureReason
  alias Still.Operations
  alias Still.Protocol.DeployRequest
  alias Still.Releases
  alias Still.Repo

  # Each coordinator owns its task supervisor. Replacing the coordinator also
  # replaces its observers, rather than leaving duplicate polling tasks alive.

  @doc """
  Starts the Orchestrator GenServer.

  Options:
    * `:agent_caller` — 2-arity fn `(node, %DeployRequest{}) -> {:ok, version} | {:error, reason}`
      used for `trigger_deployment/2`
    * `:rollback_agent_caller` — 2-arity fn with the same shape, used for
      `trigger_rollback/2`. The agent interprets the same struct as a rollback.
    * `:restart_agent_caller` — 2-arity fn with the same shape, used for
      `trigger_restart/2`. The agent interprets the same struct as a restart.
    * `:artifact_stager` — 2-arity fn `(application, deployment) -> {:ok, deployment} | {:error, reason}`
      that stages the artifact on the controller before fanning out to agents.
      Defaults to `&default_artifact_stager/2` which downloads via the
      application's artifact provider and binds immutable release/revision records.
      Tests may return `:ok` to leave the deployment unchanged.
    * `:notifier` — pid to receive `{:deployment_complete, id, :completed | :failed}`
      after either a deploy or a rollback finishes.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a deployment. Returns `{:ok, %Deployment{}}` immediately — the
  rolling sequence runs in a background task.
  """
  def trigger_deployment(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    GenServer.call(__MODULE__, {:trigger_deployment, actor, application, attrs})
  end

  @doc """
  Triggers a rollback. Creates a new deployment row that records the
  rollback target (the previous successful version), then calls each
  agent's `{:rollback, spec}` handler server-by-server. Returns
  `{:ok, %Deployment{}}` on accept, `{:error, :no_rollback_target}` if
  there is no prior successful deployment to roll back to, or any of the
  same preconditions as `trigger_deployment/2`.
  """
  def trigger_rollback(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    GenServer.call(__MODULE__, {:trigger_rollback, actor, application, attrs})
  end

  @doc """
  Triggers a restart. Creates a new deployment row pinned to the application's
  current live version, then calls each agent's `{:restart, spec}` handler
  server-by-server — re-booting that version into the standby slot, health-
  checking it, then cutting traffic over. Returns `{:ok, %Deployment{}}` on
  accept, `{:error, :not_deployed}` when the application has never deployed
  successfully, `{:error, :unsupported_for_type}` for a static site, or any of
  the same preconditions as `trigger_deployment/2`.
  """
  def trigger_restart(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    GenServer.call(__MODULE__, {:trigger_restart, actor, application, attrs})
  end

  @doc """
  Updates an application's mutable fields, then reconciles the serving Caddy
  route on each hosting agent when `domain` or `path_prefix` changed.

  Route reconciliation is best-effort and runs in the background:
  disconnected agents are skipped and pick up the change on their next
  deploy. Returns `{:ok, %Application{}}` or the changeset error.
  """
  def update_application(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    with {:ok, updated} <- Applications.update_application(actor, application, attrs) do
      if routing_changed?(application, updated), do: reconcile_app_routes(updated)
      {:ok, updated}
    end
  end

  @doc """
  Pushes a route-only reconcile to every agent hosting a live deployment of
  `application`, rebuilding its `still_app_*` route from the current
  domain/path_prefix and active slot. Returns `:ok` immediately; the
  fan-out runs in the background. No-op when the orchestrator worker isn't
  running (e.g. tests that exercise the controller without it).
  """
  def reconcile_app_routes(%Application{} = application) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:reconcile_routes, application})
    else
      :ok
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    unless Keyword.get(opts, :skip_orphan_recovery, false) do
      recover_orphans()
    end

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    durable =
      Keyword.get(
        opts,
        :durable_operations,
        not Enum.any?(
          [:agent_caller, :rollback_agent_caller, :restart_agent_caller],
          &Keyword.has_key?(opts, &1)
        )
      )

    if durable, do: send(self(), :resume_pending)

    {:ok,
     %{
       in_progress: MapSet.new(),
       tasks: %{},
       task_supervisor: task_supervisor,
       durable: durable,
       agent_caller: Keyword.get(opts, :agent_caller, &default_agent_caller/2),
       rollback_agent_caller:
         Keyword.get(opts, :rollback_agent_caller, &default_rollback_caller/2),
       restart_agent_caller: Keyword.get(opts, :restart_agent_caller, &default_restart_caller/2),
       route_caller: Keyword.get(opts, :route_caller, &default_route_caller/2),
       artifact_stager: Keyword.get(opts, :artifact_stager, &default_artifact_stager/2),
       notifier: Keyword.get(opts, :notifier)
     }}
  end

  defp recover_orphans do
    case Deployments.mark_orphaned_as_failed!("controller_restart") do
      {0, 0} ->
        :ok

      {deployments, steps} ->
        Logger.warning(
          "recovered #{deployments} orphaned deployment(s) and #{steps} step(s) " <>
            "left in_progress from a previous controller run"
        )
    end
  end

  @impl true
  def handle_call({:trigger_deployment, actor, application, attrs}, _from, state)
      when is_map(state) do
    attrs = Map.put(attrs, :durable_operations, state.durable)

    if application_busy?(state, application) do
      {:reply, {:error, :deployment_in_progress}, state}
    else
      case validate_and_create(actor, application, attrs) do
        {:ok, deployment, servers} ->
          state = %{state | in_progress: MapSet.put(state.in_progress, application.name)}

          ref =
            spawn_rolling_task(
              deployment,
              application,
              servers,
              state.agent_caller,
              state.artifact_stager,
              state.notifier,
              state.task_supervisor
            )

          state = put_in(state.tasks[ref], application.name)

          {:reply, {:ok, deployment}, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:trigger_rollback, actor, application, attrs}, _from, state)
      when is_map(state) do
    attrs = Map.put(attrs, :durable_operations, state.durable)

    if application_busy?(state, application) do
      {:reply, {:error, :deployment_in_progress}, state}
    else
      case validate_and_create_rollback(actor, application, attrs) do
        {:ok, deployment, servers} ->
          state = %{state | in_progress: MapSet.put(state.in_progress, application.name)}

          ref =
            spawn_rolling_task(
              deployment,
              application,
              servers,
              state.rollback_agent_caller,
              state.artifact_stager,
              state.notifier,
              state.task_supervisor
            )

          state = put_in(state.tasks[ref], application.name)

          {:reply, {:ok, deployment}, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:trigger_restart, actor, application, attrs}, _from, state)
      when is_map(state) do
    attrs = Map.put(attrs, :durable_operations, state.durable)

    if application_busy?(state, application) do
      {:reply, {:error, :deployment_in_progress}, state}
    else
      case validate_and_create_restart(actor, application, attrs) do
        {:ok, deployment, servers} ->
          state = %{state | in_progress: MapSet.put(state.in_progress, application.name)}

          ref =
            spawn_rolling_task(
              deployment,
              application,
              servers,
              state.restart_agent_caller,
              state.artifact_stager,
              state.notifier,
              state.task_supervisor
            )

          state = put_in(state.tasks[ref], application.name)

          {:reply, {:ok, deployment}, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:reconcile_routes, application}, _from, state) when is_map(state) do
    start_route_task(state, application)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:deployment_finished, app_name}, state) when is_map(state) do
    {:noreply, %{state | in_progress: MapSet.delete(state.in_progress, app_name)}}
  end

  def handle_cast({:operation_report, server_id, report}, state) when is_map(state) do
    Operations.observe(server_id, report)
    {:noreply, state}
  end

  def handle_cast({:refresh_routes, before}, state) when is_map(state) do
    current = Applications.get_application_by_name(before.name)
    if current && routing_changed?(before, current), do: start_route_task(state, current)
    {:noreply, state}
  end

  @impl true
  def handle_info(:resume_pending, state) do
    pending =
      Repo.all(
        from d in Still.Deployments.Deployment,
          where: d.durable_operations and d.status in [:pending, :in_progress],
          preload: [:application]
      )

    state =
      Enum.reduce(pending, state, fn deployment, acc ->
        app = deployment.application

        if MapSet.member?(acc.in_progress, app.name) do
          acc
        else
          caller =
            case deployment.operation_kind do
              :rollback -> acc.rollback_agent_caller
              :restart -> acc.restart_agent_caller
              :deploy -> acc.agent_caller
            end

          ref =
            spawn_rolling_task(
              deployment,
              app,
              Applications.list_application_servers(app),
              caller,
              acc.artifact_stager,
              acc.notifier,
              acc.task_supervisor
            )

          %{
            acc
            | in_progress: MapSet.put(acc.in_progress, app.name),
              tasks: Map.put(acc.tasks, ref, app.name)
          }
        end
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_map(state) do
    {app, tasks} = Map.pop(state.tasks, ref)

    in_progress =
      if app && app not in Map.values(tasks),
        do: MapSet.delete(state.in_progress, app),
        else: state.in_progress

    if app && state.durable, do: Process.send_after(self(), :resume_pending, 1_000)
    {:noreply, %{state | tasks: tasks, in_progress: in_progress}}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.task_supervisor), do: Supervisor.stop(state.task_supervisor)
    :ok
  end

  defp application_busy?(state, application) do
    MapSet.member?(state.in_progress, application.name) or
      Repo.exists?(
        from d in Still.Deployments.Deployment,
          where:
            d.application_id == ^application.id and
              d.durable_operations and d.status in [:pending, :in_progress]
      )
  end

  defp routing_changed?(before, updated) do
    before.domain != updated.domain or before.path_prefix != updated.path_prefix or
      before.maintenance != updated.maintenance or
      before.maintenance_message != updated.maintenance_message
  end

  # Fans the route-only spec out to each hosting agent, skipping servers
  # whose agent isn't currently connected.
  defp start_route_task(state, application) do
    servers = Applications.list_application_servers(application)

    Task.Supervisor.start_child(state.task_supervisor, fn ->
      reconcile_routes(application, state.route_caller, servers)
    end)
  end

  defp reconcile_routes(application, route_caller, servers) do
    spec = route_spec(application)

    Enum.each(servers, fn application_server ->
      case AgentConnectionManager.get_agent_state(application_server.server_id) do
        %{node: node} -> route_caller.(node, spec)
        nil -> :ok
      end
    end)
  end

  defp route_spec(application) do
    %{
      application: application.name,
      type: application.type,
      domain: application.domain,
      path_prefix: application.path_prefix,
      maintenance: application.maintenance,
      maintenance_message: application.maintenance_message
    }
  end

  defp validate_and_create(actor, application, attrs) do
    Applications.with_assignment_lock(application.id, fn ->
      servers = Applications.list_application_servers(application)
      check_preconditions_and_create(actor, application, servers, attrs)
    end)
  end

  defp validate_and_create_rollback(actor, application, attrs) do
    case Deployments.get_rollback_target(application) do
      nil ->
        {:error, :no_rollback_target}

      %{version: version, artifact_url: artifact_url} = target ->
        attrs =
          attrs
          |> Map.put_new(:source, "rollback")
          |> Map.merge(%{
            version: version,
            artifact_url: artifact_url,
            release_id: target.release_id,
            revision_id: target.revision_id,
            operation_kind: :rollback
          })

        validate_and_create(actor, application, attrs)
    end
  end

  # Static sites have no process to re-boot, so reject before creating a row or
  # calling any agent (the agent's restart step provider would have no list to
  # run). The current live version's row supplies a real version/artifact_url to
  # stamp the restart record with; the agent re-boots its own on-disk current.
  defp validate_and_create_restart(_actor, %Application{type: :static_site}, _attrs) do
    {:error, :unsupported_for_type}
  end

  defp validate_and_create_restart(actor, application, attrs) do
    case Deployments.get_current_deployment(application) do
      nil ->
        {:error, :not_deployed}

      %{version: version, artifact_url: artifact_url} = target ->
        attrs =
          attrs
          |> Map.put_new(:source, "restart")
          |> Map.merge(%{
            version: version,
            artifact_url: artifact_url,
            release_id: target.release_id,
            operation_kind: :restart
          })

        validate_and_create(actor, application, attrs)
    end
  end

  defp check_preconditions_and_create(_actor, _application, [], _attrs) do
    {:error, :no_servers_assigned}
  end

  defp check_preconditions_and_create(actor, application, servers, attrs) do
    connected = Enum.count(servers, &AgentConnectionManager.connected?(&1.server_id))

    if connected < application.min_healthy do
      {:error, :insufficient_healthy_agents}
    else
      case Deployments.create_deployment(actor, application, attrs) do
        {:ok, deployment} -> {:ok, deployment, servers}
        {:error, _} = error -> error
      end
    end
  end

  defp spawn_rolling_task(
         deployment,
         application,
         servers,
         agent_caller,
         artifact_stager,
         notifier,
         task_supervisor
       ) do
    orchestrator = self()

    {:ok, pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        status =
          run_deploy_safely(deployment, application, servers, agent_caller, artifact_stager)

        GenServer.cast(orchestrator, {:deployment_finished, application.name})
        if notifier, do: send(notifier, {:deployment_complete, deployment.id, status})
      end)

    Process.monitor(pid)
  end

  # The deploy task is unlinked (it runs under the private task supervisor), but an
  # unhandled crash mid-deploy — a `!` Repo call on a locked DB, an :exit from a
  # remote GenServer.call to a node that just died — would still skip the
  # `deployment_finished` cast and leave the app wedged in_progress. Convert any
  # crash into an outcome so the cast and notifier always run. Durable work
  # remains nonterminal on observer failure and is resumed from persisted intent.
  defp run_deploy_safely(deployment, application, servers, agent_caller, artifact_stager) do
    execute_rolling_deploy(deployment, application, servers, agent_caller, artifact_stager)
  rescue
    exception -> fail_crashed(deployment, application, Exception.message(exception))
  catch
    kind, reason -> fail_crashed(deployment, application, "#{kind} #{inspect(reason)}")
  end

  defp fail_crashed(deployment, application, message) do
    Logger.error("deployment #{deployment.id} (#{application.name}) crashed: #{message}")

    if deployment.durable_operations do
      # Remote work may already be running. Leave durable intent nonterminal and
      # restart observation; the database gate prevents new conflicting work.
      deployment
      |> Ecto.Changeset.change(error: "observation interrupted: " <> message)
      |> Repo.update!()

      Process.send_after(__MODULE__, :resume_pending, 2_000)
      :unknown
    else
      failed = Deployments.fail_deployment!(deployment, message)
      record_terminal_audit(application, failed, :failed, message)
      broadcast_update(application, deployment, %{status: :failed, error: message})
      :failed
    end
  end

  defp execute_rolling_deploy(deployment, application, servers, agent_caller, artifact_stager) do
    deployment = Deployments.start_deployment!(deployment)

    # six:ignore:start
    result =
      with {:ok, prepared} <- prepare_or_resume(application, deployment, artifact_stager) do
        run_rollout(prepared, application, servers, agent_caller)
      end

    # six:ignore:stop

    case result do
      :ok ->
        completed = Deployments.complete_deployment!(deployment)
        record_terminal_audit(application, completed, :completed, nil)
        broadcast_update(application, deployment, %{status: :completed})
        maybe_refresh_routes(application, deployment)
        :completed

      {:error, reason} ->
        error = format_reason(reason)

        Logger.warning(
          "deployment #{deployment.id} (#{application.name} #{deployment.version}) failed: #{error}"
        )

        failed = Deployments.fail_deployment!(deployment, error)
        record_terminal_audit(application, failed, :failed, error)
        broadcast_update(application, deployment, %{status: :failed, error: error})
        maybe_refresh_routes(application, deployment)
        :failed
    end
  end

  # Audits a deploy's terminal transition. The actor is :system because
  # the orchestrator's background task — not the user who initiated —
  # decided the outcome. The deployment row's `subject_id` ties this
  # event to the earlier `:deploy_initiated` actor for a full timeline.
  defp record_terminal_audit(application, deployment, status, error) do
    type =
      case {status, deployment.source} do
        {:completed, "rollback"} -> :rollback_completed
        {:completed, "restart"} -> :restart_completed
        {:completed, _} -> :deploy_completed
        {:failed, "rollback"} -> :rollback_failed
        {:failed, "restart"} -> :restart_failed
        {:failed, _} -> :deploy_failed
      end

    {:ok, _} =
      Audit.record(Actor.system(),
        type: type,
        subject_type: :deployment,
        subject_id: deployment.id,
        payload:
          Map.reject(
            %{
              deployment_id: deployment.id,
              application_id: application.id,
              application_name: application.name,
              version: deployment.version,
              error: error
            },
            fn {_k, v} -> is_nil(v) end
          )
      )

    :ok
  end

  defp stage_artifact(application, deployment, artifact_stager) do
    case artifact_stager.(application, deployment) do
      :ok ->
        {:ok, deployment}

      {:ok, prepared} ->
        {:ok, prepared}

      {:error, reason} = err ->
        Logger.warning(
          "artifact staging failed for deployment #{deployment.id} " <>
            "(#{application.name} #{deployment.version}, url=#{deployment.artifact_url}): " <>
            format_reason(reason)
        )

        err
    end
  end

  defp format_reason(reason), do: FailureReason.headline(reason)

  defp maybe_refresh_routes(_before, %{durable_operations: false}), do: :ok

  defp maybe_refresh_routes(before, _deployment) do
    # Route repair is best-effort and cannot change an already-settled outcome.
    GenServer.cast(__MODULE__, {:refresh_routes, before})
  end

  defp prepare_or_resume(application, deployment, stager) do
    if deployment.durable_operations and Operations.for_deployment(deployment.id) != [] do
      {:ok, deployment}
    else
      stage_artifact(application, deployment, stager)
    end
  end

  defp execute_durable(deployment, application, servers) do
    if Operations.for_deployment(deployment.id) == [] do
      {:ok, _} = Repo.transaction(fn -> prepare_operations(deployment, application, servers) end)
    end

    deployment.id
    |> Operations.for_deployment()
    |> Enum.reduce_while(:ok, fn operation, :ok ->
      await_operation(operation, deployment, application)
    end)
  end

  defp run_rollout(%{durable_operations: true} = deployment, app, servers, _caller),
    do: execute_durable(deployment, app, servers)

  defp run_rollout(deployment, app, servers, caller) do
    Enum.reduce_while(servers, :ok, fn assignment, :ok ->
      deploy_to_server(deployment, app, assignment, caller)
    end)
  end

  defp prepare_operations(deployment, app, servers) do
    servers
    |> Enum.with_index()
    |> Enum.each(fn {assignment, position} ->
      step = Deployments.get_step_for_server!(deployment.id, assignment.server_id)
      spec = build_deploy_request(app, deployment, assignment)
      hooks = Map.filter(spec.hooks, &hook_on_host?(&1, position, length(servers)))
      Operations.ensure(deployment, step, %{spec | hooks: hooks}, position)
    end)
  end

  defp hook_on_host?({event, %{scope: :per_rollout}}, position, count)
       when event in [:post_deploy, :post_rollback],
       do: position == count - 1

  defp hook_on_host?({_event, %{scope: :per_rollout}}, position, _count), do: position == 0
  defp hook_on_host?(_hook, _position, _count), do: true

  defp await_operation(operation, deployment, app) do
    step = Deployments.get_deployment_step!(operation.step_id)

    if step.status == :completed do
      {:cont, :ok}
    else
      finish_operation(operation, deployment, app, Deployments.start_deployment_step!(step))
    end
  end

  defp finish_operation(operation, deployment, app, step) do
    assignment =
      Repo.get_by(ApplicationServer, application_id: app.id, server_id: operation.server_id)

    case Operations.await(operation) do
      {:ok, _} ->
        complete_step(deployment, app, assignment || %{server_id: operation.server_id}, step)

      {:error, reason} ->
        fail_step(deployment, app, %{server_id: operation.server_id}, step, reason)
    end
  end

  defp deploy_to_server(deployment, application, application_server, agent_caller) do
    step = Deployments.get_step_for_server!(deployment.id, application_server.server_id)

    if step.status == :completed do
      {:cont, :ok}
    else
      dispatch_step(deployment, application, application_server, agent_caller, step)
    end
  end

  defp dispatch_step(deployment, application, application_server, agent_caller, step) do
    spec = build_deploy_request(application, deployment, application_server)

    case AgentConnectionManager.get_agent_state(application_server.server_id) do
      nil ->
        fail_step(deployment, application, application_server, step, :agent_disconnected)

      %{node: node} = report ->
        step = Deployments.start_deployment_step!(step)

        result =
          if deployment.release_id &&
               :immutable_releases not in Map.get(report, :capabilities, []) do
            {:error, :agent_upgrade_required}
          else
            agent_caller.(node, spec)
          end

        case result do
          {:ok, version}
          when not is_nil(deployment.release_id) and version != deployment.version ->
            fail_step(deployment, application, application_server, step, :agent_version_mismatch)

          {:ok, _version} ->
            complete_step(deployment, application, application_server, step)

          {:error, reason} ->
            fail_step(deployment, application, application_server, step, reason)
        end
    end
  end

  defp complete_step(deployment, application, application_server, step) do
    Deployments.complete_deployment_step!(step)

    # Stamp desired_version per-server, on success only. Setting it fleet-wide up
    # front made servers that failed (or were never reached) keep desired=new
    # while running old — permanent phantom "drift" the reconciliation loop logs
    # forever on an otherwise-healthy fleet.
    if match?(%ApplicationServer{}, application_server) do
      _ = Applications.set_desired_version(application_server, deployment.version)
    end

    broadcast_update(application, deployment, %{
      server_id: application_server.server_id,
      step_status: :completed
    })

    {:cont, :ok}
  end

  defp fail_step(deployment, application, application_server, step, reason) do
    error = format_reason(reason)

    Logger.warning(
      "deployment #{deployment.id} step on server #{application_server.server_id} " <>
        "(#{application.name} #{deployment.version}) failed: #{error}"
    )

    Deployments.fail_deployment_step!(step, error)

    broadcast_update(application, deployment, %{
      server_id: application_server.server_id,
      step_status: :failed,
      error: error
    })

    {:halt, {:error, error}}
  end

  # Wraps Still.Events.deployment_updated with the fields every push
  # needs (deployment_id, progress, eta_at) so the dashboard can update
  # a progress bar without refetching.
  defp broadcast_update(application, deployment, extra) when is_map(extra) do
    %{progress: progress, eta_at: eta_at} =
      Deployments.progress_and_eta_for(deployment.id)

    payload =
      Map.merge(extra, %{
        deployment_id: deployment.id,
        progress: progress,
        eta_at: eta_at
      })

    Still.Events.deployment_updated(application.name, payload)
  end

  defp build_deploy_request(application, deployment, application_server) do
    # Process settings are snapshotted, but routing remains live. Refresh it
    # after staging and between hosts instead of restoring a revision's routes.
    application = Applications.get_application_by_name!(application.name)

    spec = %DeployRequest{
      application: application.name,
      type: application.type,
      version: deployment.version,
      artifact_url: ArtifactStore.artifact_url(application.name, deployment.version),
      deployment_id: deployment.id,
      domain: application.domain,
      path_prefix: application.path_prefix,
      maintenance: application.maintenance,
      maintenance_message: application.maintenance_message,
      env_vars: application.env_vars,
      exec_command: application.exec_command,
      exec_start_pre: application.exec_start_pre,
      exec_stop: application.exec_stop,
      health_check: application.health_check,
      hooks: hooks_for(application),
      port_blue: application_server.port_blue,
      port_green: application_server.port_green
    }

    if deployment.release_id do
      deployment = Releases.load(deployment)

      spec
      |> Map.merge(Releases.process_fields(deployment.revision))
      |> Map.merge(%{
        release_id: deployment.release_id,
        revision_id: deployment.revision_id,
        artifact_digest: deployment.release.digest,
        artifact_size: deployment.release.size,
        artifact_url: ArtifactStore.artifact_url(application.name, deployment.release.digest)
      })
    else
      spec
    end
  end

  # Turn the application's hook rows into the map the agent's
  # DeploymentManager consumes: `%{pre_deploy: %{script: ..., timeout_ms: ...}, ...}`.
  # Keyed by event atom so the agent can look up hooks by the step name
  # it's running without scanning a list.
  defp hooks_for(application) do
    application
    |> Applications.list_hooks_for()
    |> Map.new(fn hook ->
      {hook.event, %{script: hook.script, timeout_ms: hook.timeout_ms}}
    end)
  end

  # six:ignore:start
  defp default_artifact_stager(application, deployment) do
    if deployment.operation_kind in [:rollback, :restart] and is_nil(deployment.release_id) do
      {:error, :legacy_release_unverified}
    else
      Releases.prepare(application, deployment)
    end
  end

  defp default_agent_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:deploy, spec},
      120_000
    )
  end

  defp default_rollback_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:rollback, spec},
      120_000
    )
  end

  defp default_restart_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:restart, spec},
      120_000
    )
  end

  defp default_route_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:reconcile_route, spec},
      30_000
    )
  end

  # six:ignore:stop
end
