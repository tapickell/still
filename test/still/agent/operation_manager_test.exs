defmodule Still.Agent.OperationManagerTest do
  use ExUnit.Case, async: false
  alias Still.Agent.DeploymentManager
  alias Still.Agent.NodeConnector
  alias Still.Agent.OperationJournal
  alias Still.Agent.OperationManager
  alias Still.Protocol.OperationRequest

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    old = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, dir)
    on_exit(fn -> Application.put_env(:still, :applications_dir, old) end)
    :ok
  end

  test "acceptance is durable, duplicates do not execute twice, and other applications are independent",
       %{tmp_dir: dir} do
    owner = self()

    executor = fn record, checkpoint ->
      checkpoint.(%{status: :running, phase: :downloading})
      send(owner, {:executing, record.id, self()})

      receive do
        :finish -> checkpoint.(%{status: :succeeded, phase: nil})
      end
    end

    start_supervised!({OperationManager, executor: executor})
    a = request("alpha")
    b = request("beta")
    assert {:ok, _} = OperationManager.submit(a)
    assert_receive {:executing, id, worker}, 1_000
    assert id == a.id
    assert {:ok, record} = OperationJournal.read(id)
    assert record.request == a

    assert Bitwise.band(File.stat!(Path.join([dir, ".operations", id <> ".etf"])).mode, 0o777) ==
             0o600

    assert {:ok, report} = OperationManager.submit(a)
    refute Map.has_key?(report, :request)
    refute inspect(report) =~ "secret-value"

    assert {:error, :operation_in_progress} =
             OperationManager.submit(%{a | id: Ecto.UUID.generate(), generation: 2})

    assert {:error, :operation_conflict} = OperationManager.submit(%{a | generation: 2})
    assert {:ok, _} = OperationManager.submit(b)
    assert_receive {:executing, beta_id, other}, 1_000
    assert beta_id == b.id
    send(other, :finish)
    send(worker, :finish)

    Still.IntegrationCase.wait_until!(fn ->
      match?({:ok, %{status: :succeeded}}, OperationManager.status(id))
    end)

    assert {:ok, %{status: :succeeded}} = OperationManager.submit(a)
    refute OperationManager.legacy_allowed?(a.spec.application)
    assert OperationManager.legacy_allowed?("unused")

    assert {:reply, {:error, :durable_protocol_required}, _} =
             DeploymentManager.handle_call({:deploy, a.spec}, self(), %{})

    refute_receive {:executing, ^id, _}
    assert {:error, :stale_generation} = OperationManager.submit(%{a | id: Ecto.UUID.generate()})
    assert {:error, :not_found} = OperationManager.status(Ecto.UUID.generate())
  end

  test "manager restart retains outcomes and generation fencing" do
    start_supervised!(
      {OperationManager, executor: fn _, save -> save.(%{status: :succeeded}) end}
    )

    request = request("finished")
    assert {:ok, _} = OperationManager.submit(request)

    Still.IntegrationCase.wait_until!(fn ->
      match?({:ok, %{status: :succeeded}}, OperationManager.status(request.id))
    end)

    stop_supervised(OperationManager)
    refute OperationManager.legacy_allowed?(request.spec.application)
    refute OperationManager.busy?(request.spec.application)

    start_supervised!(
      {OperationManager, executor: fn _, _ -> flunk("must not replay completed work") end}
    )

    assert {:ok, %{status: :succeeded}} = OperationManager.submit(request)

    assert {:error, :stale_generation} =
             OperationManager.submit(%{request | id: Ecto.UUID.generate()})
  end

  test "unreadable journals fail closed instead of forgetting prior work", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".operations"))
    File.write!(Path.join([dir, ".operations", Ecto.UUID.generate() <> ".etf"]), "broken")
    start_supervised!({OperationManager, executor: fn _, _ -> flunk("must not execute") end})
    assert {:error, :journal_unavailable} = OperationManager.submit(request("blocked"))
    assert OperationManager.busy?("blocked")
    assert {:error, :journal_unavailable} = OperationManager.status(Ecto.UUID.generate())
    assert {:error, :journal_unavailable} = OperationManager.recover(Ecto.UUID.generate())
    stop_supervised(OperationManager)
    assert OperationManager.busy?("blocked")
    refute OperationManager.legacy_allowed?("blocked")
  end

  test "supervised workers stop with the manager and interrupted hooks remain paused" do
    owner = self()

    executor = fn record, save ->
      save.(%{
        status: :running,
        phase: :release,
        context: %{spec: record.request.spec},
        completed: [:unpacking]
      })

      send(owner, {:blocked, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({OperationManager, executor: executor})
    request = request("interrupted")
    assert {:ok, _} = OperationManager.submit(request)
    assert_receive {:blocked, worker}
    ref = Process.monitor(worker)
    stop_supervised(OperationManager)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    start_supervised!(OperationManager)

    Still.IntegrationCase.wait_until!(fn ->
      match?({:ok, %{status: :unknown}}, OperationManager.status(request.id))
    end)

    assert {:ok, %{phase: :release, status: :unknown}} = OperationManager.status(request.id)

    assert {:error, :operation_in_progress} =
             OperationManager.submit(%{request | id: Ecto.UUID.generate(), generation: 2})

    assert {:error, :invalid_confirmation} = OperationManager.confirm_phase(request.id, :starting)

    assert {:reply, {:error, :operation_in_progress}, _} =
             DeploymentManager.handle_call({:deploy, request.spec}, self(), %{})
  end

  test "rejects executable payloads and unsupported protocol versions" do
    start_supervised!(OperationManager)
    request = request("invalid")

    assert {:error, :unsupported_operation_protocol} =
             OperationManager.submit(%{request | protocol: 99})

    assert {:error, :invalid_operation} =
             OperationManager.submit(%{
               request
               | spec: Map.put(request.spec, :callback, fn -> :bad end)
             })
  end

  defp request(app) do
    %OperationRequest{
      id: Ecto.UUID.generate(),
      generation: 1,
      kind: :deploy,
      spec: %{
        application: app,
        version: "1.0",
        type: :static_site,
        release_id: Ecto.UUID.generate(),
        hooks: %{release: %{script: "do not rerun", timeout_ms: 1000}},
        env_vars: %{"TOKEN" => "secret-value"}
      }
    }
  end

  test "manual recovery preserves locks and confirmations are journaled before resumption" do
    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         if :release in record.completed do
           save.(%{status: :succeeded})
         else
           save.(%{
             status: :unknown,
             phase: :release,
             context: %{spec: record.request.spec},
             error: "ambiguous hook"
           })
         end
       end}
    )

    req = request("paused")
    assert {:error, :not_found} = OperationManager.recover(req.id)
    assert {:ok, _} = OperationManager.submit(req)
    wait_paused(req.id)
    assert [%{id: id, status: :unknown}] = OperationManager.reports()
    assert id == req.id
    assert {:ok, _} = OperationManager.recover(req.id)
    wait_paused(req.id)
    assert {:ok, _} = OperationManager.confirm_phase(req.id, :release)

    Still.IntegrationCase.wait_until!(fn ->
      match?({:ok, %{status: :succeeded}}, OperationManager.status(req.id))
    end)

    assert {:error, :not_paused} = OperationManager.recover(req.id)
    assert [] = OperationManager.reports()

    assert {:error, :stale_worker} =
             GenServer.call(OperationManager, {:checkpoint, req.id, %{status: :running}})

    send(Process.whereis(OperationManager), {make_ref(), :late_reply})
    send(Process.whereis(OperationManager), {:DOWN, make_ref(), :process, self(), :late_exit})
    assert {:ok, %{status: :succeeded}} = OperationManager.status(req.id)
  end

  test "journal write failure during acceptance cannot start an executor", %{tmp_dir: dir} do
    start_supervised!({OperationManager, executor: fn _, _ -> flunk("uncommitted work ran") end})
    File.write!(Path.join(dir, ".operations"), "not a directory")
    assert {:error, _} = OperationManager.submit(request("io-failure"))
    assert {:error, :journal_unavailable} = OperationManager.status(Ecto.UUID.generate())
  end

  test "checkpoint write failure stops the worker and leaves admission blocked", %{tmp_dir: dir} do
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn _, save ->
         send(owner, {:ready, self()})

         receive do
           :continue -> save.(%{status: :running})
         end
       end}
    )

    assert {:ok, _} = OperationManager.submit(request("checkpoint-failure"))
    assert_receive {:ready, worker}
    path = Path.join(dir, ".operations")
    File.rename!(path, path <> ".backup")
    File.write!(path, "blocked")
    ref = Process.monitor(worker)

    ExUnit.CaptureLog.capture_log(fn ->
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
      :sys.get_state(OperationManager)
    end)

    assert OperationManager.busy?("another-app")
  end

  test "data-only lists are valid but stale worker messages cannot checkpoint" do
    start_supervised!(
      {OperationManager,
       executor: fn _, save -> save.(%{status: :failed, error: "known failure"}) end}
    )

    req = request("data")
    req = %{req | spec: Map.put(req.spec, :extra, ["safe", 1])}
    assert {:ok, _} = OperationManager.submit(req)

    Still.IntegrationCase.wait_until!(fn ->
      match?({:ok, %{status: :failed}}, OperationManager.status(req.id))
    end)

    assert {:ok, %{status: :failed}} = OperationManager.submit(req)
  end

  defp wait_paused(id) do
    Still.IntegrationCase.wait_until!(fn ->
      match?({:ok, %{status: :unknown}}, OperationManager.status(id)) and
        :sys.get_state(OperationManager).workers == %{}
    end)
  end

  test "progress notifications and reconnect announcements contain only public state" do
    Process.register(self(), NodeConnector)
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn _, save ->
         save.(%{status: :running})
         send(owner, :running)

         receive do
           :never -> :ok
         end
       end}
    )

    req = request("announced")
    assert {:ok, _} = OperationManager.submit(req)
    assert_receive :running
    assert_receive {:"$gen_cast", {:report_operation, report}}
    assert report.id == req.id
    refute inspect(report) =~ "secret-value"
    announcement = NodeConnector.build_report(Ecto.UUID.generate())
    assert [%{id: id}] = announcement.operations
    assert id == req.id
  end

  test "explicit manager shutdown waits for its supervised workers" do
    owner = self()

    executor = fn _, _ ->
      send(owner, {:worker, self()})

      receive do
        :never -> :ok
      end
    end

    manager =
      start_supervised!(%{
        id: OperationManager,
        start: {OperationManager, :start_link, [[executor: executor]]},
        restart: :temporary
      })

    req = request("shutdown")
    assert {:ok, _} = OperationManager.submit(req)
    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    assert :ok = GenServer.stop(manager)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert OperationManager.busy?("shutdown")
  end

  test "a legacy command waiting for a lock cannot slip past newly accepted durable intent" do
    owner = self()
    req = request("legacy-race")

    start_supervised!(
      {OperationManager, executor: fn _, save -> save.(%{status: :failed, error: "settled"}) end}
    )

    holder =
      Task.async(fn ->
        OperationManager.locked(req.spec.application, fn ->
          send(owner, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked

    legacy =
      Task.async(fn ->
        receive do
          :attempt -> :ok
        end

        DeploymentManager.handle_call({:deploy, req.spec}, self(), %{
          step_provider: fn _ -> flunk("stale legacy command ran") end
        })
      end)

    :erlang.trace_pattern({OperationManager, :locked, 2}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({OperationManager, :locked, 2}, false, [:local]) end)
    :erlang.trace(legacy.pid, true, [:call, {:tracer, self()}])
    send(legacy.pid, :attempt)
    legacy_pid = legacy.pid
    assert_receive {:trace, ^legacy_pid, :call, {OperationManager, :locked, _}}, 1_000
    assert {:ok, _} = OperationManager.submit(req)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert {:reply, {:error, reason}, _} = Task.await(legacy)
    assert reason in [:operation_in_progress, :durable_protocol_required]
  end
end
