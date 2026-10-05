defmodule Still.Integration.OperationProcessRecoveryTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.DeploymentManager
  alias Still.Agent.OperationManager
  alias Still.Agent.StatePersistence
  alias Still.Agent.Systemd
  alias Still.Artifact.Archive
  alias Still.Artifact.Provider.LocalFile
  alias Still.IntegrationFixtures
  alias Still.Protocol.OperationRequest

  setup do
    app = "still-op-recovery-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup_systemd_units(app) end)
    source = IntegrationFixtures.path(:release_a)
    {:ok, metadata} = Archive.metadata(source)

    req = %OperationRequest{
      id: Ecto.UUID.generate(),
      generation: 1,
      kind: :deploy,
      spec: %{
        application: app,
        type: :elixir_release,
        version: "1.0",
        release_id: Ecto.UUID.generate(),
        revision_id: Ecto.UUID.generate(),
        artifact_url: source,
        artifact_provider: LocalFile,
        artifact_digest: metadata.digest,
        artifact_size: metadata.size,
        domain: "#{app}.test",
        env_vars: %{},
        exec_command: "bin/elixir_release start",
        hooks: %{},
        health_check: %{path: "/health", interval_ms: 250, deadline_ms: 30_000},
        port_blue: free_port(),
        port_green: free_port()
      }
    }

    %{request: req}
  end

  test "switch recovery observes systemd and preserves the running PID", %{
    request: req,
    caddy: caddy
  } do
    block_after(:switching)
    assert {:ok, _} = OperationManager.submit(req)
    assert_receive :effect_completed, 40_000
    %{pid: pid} = Systemd.info_for(req.spec.application, :blue)
    assert is_integer(pid)
    stop_supervised(OperationManager)
    start_supervised!(OperationManager)
    wait_until!(fn -> match?({:ok, %{status: :succeeded}}, OperationManager.status(req.id)) end)
    assert Systemd.info_for(req.spec.application, :blue).pid == pid
    assert fetch_body(caddy, req) =~ "vA"
    assert {:ok, state} = StatePersistence.read(req.spec.application)
    assert state.operation_id == req.id
  end

  test "an interrupted start is paused, not repeated, until operator confirmation", %{
    request: req,
    caddy: caddy
  } do
    block_after(:starting)
    assert {:ok, _} = OperationManager.submit(req)
    assert_receive :effect_completed, 40_000
    stop_supervised(OperationManager)
    start_supervised!(OperationManager)

    wait_until!(fn ->
      match?({:ok, %{status: :unknown}}, OperationManager.status(req.id)) and
        :sys.get_state(OperationManager).workers == %{}
    end)

    wait_until!(fn ->
      case Req.get("http://localhost:#{req.spec.port_blue}/health", retry: false) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end)

    pid = Systemd.info_for(req.spec.application, :blue).pid
    assert {:ok, _} = OperationManager.confirm_phase(req.id, :starting)
    wait_until!(fn -> match?({:ok, %{status: :succeeded}}, OperationManager.status(req.id)) end)
    assert Systemd.info_for(req.spec.application, :blue).pid == pid
    assert fetch_body(caddy, req) =~ "vA"
  end

  defp block_after(phase) do
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         DeploymentManager.execute_operation(record, fn patch ->
           if phase in Map.get(patch, :completed, []) and is_nil(patch[:phase]) do
             send(owner, :effect_completed)

             receive do
               :never -> :ok
             end
           end

           save.(patch)
         end)
       end}
    )
  end

  test "durable restart and rollback preserve exact revision identities", %{
    request: req,
    caddy: caddy
  } do
    start_supervised!(OperationManager)
    assert {:ok, _} = OperationManager.submit(req)
    await_success(req)

    restarted = %{
      req
      | id: Ecto.UUID.generate(),
        generation: 2,
        kind: :restart,
        spec: %{req.spec | revision_id: Ecto.UUID.generate(), env_vars: %{"CHANGED" => "yes"}}
    }

    assert {:ok, _} = OperationManager.submit(restarted)
    await_success(restarted)
    assert {:ok, state} = StatePersistence.read(req.spec.application)
    assert state.current_revision_id == restarted.spec.revision_id
    rollback = %{req | id: Ecto.UUID.generate(), generation: 3, kind: :rollback}
    assert {:ok, _} = OperationManager.submit(rollback)
    await_success(rollback)
    assert {:ok, state} = StatePersistence.read(req.spec.application)
    assert state.current_revision_id == req.spec.revision_id
    assert state.generation == 3
    assert fetch_body(caddy, req) =~ "vA"
  end

  test "recovery does not restart a stopped target whose start was already recorded", %{
    request: req
  } do
    block_after(:health_checking)
    assert {:ok, _} = OperationManager.submit(req)
    assert_receive :effect_completed, 40_000
    stop_supervised(OperationManager)
    {_, 0} = System.cmd("systemctl", ["stop", "#{req.spec.application}@blue"])
    start_supervised!(OperationManager)
    wait_until!(fn -> match?({:ok, %{status: :unknown}}, OperationManager.status(req.id)) end)
    refute Systemd.info_for(req.spec.application, :blue).active_state == "active"
  end

  test "confirming a start cannot bypass a failing readiness probe", %{request: req} do
    req = %{
      req
      | spec: %{
          req.spec
          | health_check: %{req.spec.health_check | path: "/not-a-health-endpoint"}
        }
    }

    block_after(:starting)
    assert {:ok, _} = OperationManager.submit(req)
    assert_receive :effect_completed, 40_000
    stop_supervised(OperationManager)
    start_supervised!(OperationManager)

    wait_until!(fn ->
      match?({:ok, %{status: :unknown}}, OperationManager.status(req.id)) and
        :sys.get_state(OperationManager).workers == %{}
    end)

    # Wait for real startup so the bad configured path yields HTTP 404, rather
    # than mistaking connection-refused during boot for the intended failure.
    wait_until!(fn ->
      case Req.get("http://localhost:#{req.spec.port_blue}/health", retry: false) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end)

    assert {:ok, _} = OperationManager.confirm_phase(req.id, :starting)

    wait_until!(fn ->
      match?({:ok, %{status: :unknown}}, OperationManager.status(req.id)) and
        :sys.get_state(OperationManager).workers == %{}
    end)

    assert Systemd.info_for(req.spec.application, :blue).active_state == "active"
    assert {:ok, %{error: error}} = OperationManager.status(req.id)
    assert error =~ "target_not_ready"
  end

  defp await_success(req) do
    wait_until!(
      fn -> match?({:ok, %{status: :succeeded}}, OperationManager.status(req.id)) end,
      40_000
    )
  end

  defp fetch_body(caddy, req) do
    response =
      Req.get!("http://localhost:#{caddy.http_port}/", headers: [{"host", req.spec.domain}])

    assert response.status == 200
    response.body
  end
end
