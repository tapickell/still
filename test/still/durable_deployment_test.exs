defmodule Still.DurableDeploymentTest do
  use Still.DataCase, async: false
  import Still.ApplicationsFixtures
  import Still.FleetFixtures
  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.OperationManager
  alias Still.Agent.StatePersistence
  alias Still.AgentConnectionManager
  alias Still.Artifact.Provider.URL
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Operations
  alias Still.Orchestrator
  alias Still.Releases

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    for {key, value} <- [
          applications_dir: Path.join(dir, "apps"),
          artifacts_dir: Path.join(dir, "artifacts")
        ] do
      old = Application.get_env(:still, key)
      Application.put_env(:still, key, value)
      on_exit(fn -> Application.put_env(:still, key, old) end)
    end

    Req.Test.set_req_test_to_shared()

    app =
      application_fixture(%{
        type: :static_site,
        exec_command: nil,
        health_check: nil,
        artifact_source: %{type: :local_file}
      })

    server = server_fixture()
    application_server_fixture(app, server)
    start_supervised!(AgentConnectionManager)

    AgentConnectionManager.agent_connected(%{
      server_id: server.id,
      node: node(),
      connected_at: DateTime.utc_now(),
      applications: [],
      capabilities: [:immutable_releases, :durable_operations_v1]
    })

    :sys.get_state(AgentConnectionManager)

    config = %{"apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => []}}}}}
    store = start_supervised!({Agent, fn -> %{config: config, writes: 0} end})

    Req.Test.stub(CaddyManager, fn conn ->
      if conn.method == "POST" do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(store, &%{config: Jason.decode!(body), writes: &1.writes + 1})
        Req.Test.json(conn, %{})
      else
        Req.Test.json(conn, Agent.get(store, & &1.config))
      end
    end)

    Req.Test.stub(URL, fn conn ->
      path = String.replace_prefix(conn.request_path, "/artifacts/", "")
      Plug.Conn.send_resp(conn, 200, File.read!(Path.join([dir, "artifacts", path])))
    end)

    tar = Path.join(dir, "app.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(tar), [{~c"index.html", "hello"}], [:compressed])
    %{app: app, server: server, tar: tar, store: store}
  end

  test "controller restart observes the same accepted operation instead of restarting its workload",
       ctx do
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         send(owner, {:accepted, record.id, self()})

         receive do
           :proceed -> DeploymentManager.execute_operation(record, save)
         end
       end}
    )

    start_supervised!({Orchestrator, notifier: self()})
    deployment = deploy(ctx)
    assert_receive {:accepted, id, worker}, 5_000
    assert [%{id: ^id}] = Operations.list(deployment.id)
    Still.IntegrationCase.wait_until!(fn -> hd(Operations.list(deployment.id)).sequence > 0 end)
    stop_supervised(Orchestrator)
    assert Process.alive?(worker)
    start_supervised!({Orchestrator, notifier: self()})

    assert {:error, :deployment_in_progress} =
             Orchestrator.trigger_deployment(Actor.system(), ctx.app, attrs(ctx))

    send(worker, :proceed)
    assert_receive {:deployment_complete, completed_id, :completed}, 5_000
    assert completed_id == deployment.id
    refute_receive {:accepted, _, _}
    assert [%{id: ^id, status: :succeeded}] = Operations.list(deployment.id)
    assert {:ok, state} = StatePersistence.read(ctx.app.name)
    assert state.operation_id == id
  end

  test "agent restart after traffic switches recovers state without a second switch", ctx do
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         DeploymentManager.execute_operation(record, fn patch ->
           if patch[:phase] == nil and :switching in Map.get(patch, :completed, []) do
             send(owner, {:switched, record.id, self()})

             receive do
               :never -> :ok
             end
           end

           save.(patch)
         end)
       end}
    )

    start_supervised!({Orchestrator, notifier: self()})
    deployment = deploy(ctx)
    assert_receive {:switched, id, _}, 5_000
    assert Agent.get(ctx.store, & &1.writes) == 1
    stop_supervised(OperationManager)
    start_supervised!(OperationManager)
    assert_receive {:deployment_complete, completed_id, :completed}, 5_000
    assert completed_id == deployment.id
    assert Agent.get(ctx.store, & &1.writes) == 1
    assert {:ok, state} = StatePersistence.read(ctx.app.name)
    assert state.operation_id == id
    assert state.current_release_id == Deployments.get_deployment!(deployment.id).release_id
  end

  test "rollout hook scope and target order are frozen before first dispatch", ctx do
    second = server_fixture()
    application_server_fixture(ctx.app, second)
    hook_fixture(ctx.app, %{event: :pre_deploy, scope: :per_rollout, script: "pre"})
    hook_fixture(ctx.app, %{event: :post_deploy, scope: :per_rollout, script: "post"})
    hook_fixture(ctx.app, %{event: :pre_rollback, script: "true"})
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn _, _ ->
         send(owner, :accepted)

         receive do
           :never -> :ok
         end
       end}
    )

    # Both are eligible; only the first starts in this test.
    AgentConnectionManager.agent_connected(%{
      server_id: second.id,
      node: node(),
      connected_at: DateTime.utc_now(),
      applications: [],
      capabilities: [:durable_operations_v1]
    })

    :sys.get_state(AgentConnectionManager)
    start_supervised!({Orchestrator, notifier: self()})
    deployment = deploy(ctx)
    assert_receive :accepted, 5_000
    [first, last] = Operations.for_deployment(deployment.id)
    a = :erlang.binary_to_term(first.request, [:safe])
    b = :erlang.binary_to_term(last.request, [:safe])
    assert Map.has_key?(a.spec.hooks, :pre_deploy)
    refute Map.has_key?(a.spec.hooks, :post_deploy)
    refute Map.has_key?(b.spec.hooks, :pre_deploy)
    assert Map.has_key?(b.spec.hooks, :post_deploy)
    assert Map.has_key?(a.spec.hooks, :pre_rollback)
    assert Map.has_key?(b.spec.hooks, :pre_rollback)
  end

  defp attrs(ctx), do: %{version: "1.0", artifact_url: ctx.tar, initiated_by: "test"}

  defp deploy(ctx) do
    {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), ctx.app, attrs(ctx))
    deployment
  end

  test "restart and rollback intent retain their operation kind through controller startup",
       ctx do
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         send(owner, {:kind, record.request.kind})
         save.(%{status: :succeeded})
       end}
    )

    for kind <- [:restart, :rollback] do
      app = application_fixture(%{artifact_source: %{type: :local_file}})
      application_server_fixture(app, ctx.server)
      {:ok, baseline} = Deployments.create_deployment(Actor.system(), app, attrs(ctx))
      {:ok, baseline} = Releases.prepare(app, baseline)
      Deployments.complete_deployment!(baseline)

      {:ok, pending} =
        Deployments.create_deployment(
          Actor.system(),
          app,
          Map.merge(attrs(ctx), %{
            release_id: baseline.release_id,
            revision_id: baseline.revision_id,
            durable_operations: true,
            operation_kind: kind,
            source: "not-used-to-infer-kind"
          })
        )

      controller =
        start_supervised!(%{
          id: {Orchestrator, kind},
          start: {Orchestrator, :start_link, [[notifier: self()]]},
          restart: :temporary
        })

      assert_receive {:kind, ^kind}, 5_000
      assert_receive {:deployment_complete, id, :completed}, 5_000
      assert id == pending.id
      assert :ok = GenServer.stop(controller)
    end
  end

  @tag :capture_log
  test "unexpected staging exceptions preserve intent for re-observation", ctx do
    counter = :atomics.new(1, [])

    start_supervised!(
      {OperationManager, executor: fn _, save -> save.(%{status: :succeeded}) end}
    )

    start_supervised!(
      {Orchestrator,
       notifier: self(),
       artifact_stager: fn app, deployment ->
         if :atomics.add_get(counter, 1, 1) == 1, do: raise("transient staging fault")
         Releases.prepare(app, deployment)
       end}
    )

    deployment = deploy(ctx)
    assert_receive {:deployment_complete, id, :unknown}, 5_000
    assert id == deployment.id
    assert Deployments.get_deployment!(id).status == :in_progress
    original_started_at = Deployments.get_deployment!(id).started_at
    assert_receive {:deployment_complete, ^id, :completed}, 5_000
    assert length(Operations.for_deployment(id)) == 1
    finished = Deployments.get_deployment!(id)
    assert finished.started_at == original_started_at
    assert finished.error == nil
  end

  test "known agent failure settles the rollout and malformed monitor messages are harmless",
       ctx do
    start_supervised!(
      {OperationManager,
       executor: fn _, save -> save.(%{status: :failed, error: "known failure"}) end}
    )

    start_supervised!({Orchestrator, notifier: self()})
    deployment = deploy(ctx)

    ExUnit.CaptureLog.capture_log(fn ->
      assert_receive {:deployment_complete, id, :failed}, 5_000
      assert id == deployment.id
    end)

    assert Deployments.get_deployment!(deployment.id).status == :failed
    send(Process.whereis(Orchestrator), {:DOWN, make_ref(), :process, self(), :late})
    assert :sys.get_state(Orchestrator).in_progress == MapSet.new()
  end

  test "routing edits made during execution are refreshed after the operation settles", ctx do
    owner = self()
    start_supervised!(DeploymentManager)

    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         send(owner, {:waiting_for_config, self()})

         receive do
           :continue -> DeploymentManager.execute_operation(record, save)
         end
       end}
    )

    start_supervised!({Orchestrator, notifier: self()})
    deployment = deploy(ctx)
    assert_receive {:waiting_for_config, worker}, 5_000

    assert {:ok, _} =
             Orchestrator.update_application(Actor.system(), ctx.app, %{maintenance: true})

    send(worker, :continue)
    assert_receive {:deployment_complete, id, :completed}, 5_000
    assert id == deployment.id

    Still.IntegrationCase.wait_until!(fn ->
      routes =
        Agent.get(ctx.store, &get_in(&1.config, ["apps", "http", "servers", "still", "routes"]))

      Enum.any?(routes, fn route ->
        route["@id"] == "still_app_#{ctx.app.name}" and
          match?([%{"handler" => "static_response", "status_code" => 503}], route["handle"])
      end)
    end)
  end
end
