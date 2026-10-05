defmodule Still.OperationsTest do
  use Still.DataCase, async: false
  import Still.ApplicationsFixtures
  import Still.FleetFixtures
  alias Still.Agent.OperationManager
  alias Still.AgentConnectionManager
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Deployments.Operation
  alias Still.Operations
  alias Still.Repo

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    old = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, dir)
    on_exit(fn -> Application.put_env(:still, :applications_dir, old) end)
    app = application_fixture()
    server = server_fixture()
    application_server_fixture(app, server)

    {:ok, deployment} =
      Deployments.create_deployment(Actor.system(), app, %{
        version: "1.0",
        artifact_url: "https://example.test/a",
        initiated_by: "test"
      })

    step = Deployments.get_step_for_server!(deployment.id, server.id)

    spec = %{
      application: app.name,
      version: "1.0",
      type: :static_site,
      release_id: Ecto.UUID.generate(),
      env_vars: %{"SECRET" => "private"}
    }

    operation = Operations.ensure(deployment, step, spec)
    %{operation: operation, deployment: deployment, step: step, server: server, spec: spec}
  end

  test "intent is stable and private; reports are server/generation/sequence fenced", ctx do
    assert Operations.ensure(ctx.deployment, ctx.step, %{ctx.spec | version: "changed"}).id ==
             ctx.operation.id

    refute inspect(ctx.operation) =~ "private"

    report = %{
      id: ctx.operation.id,
      generation: ctx.operation.generation,
      sequence: 3,
      status: :running,
      version: "1.0",
      release_id: ctx.spec.release_id,
      phase: :starting
    }

    Operations.observe(ctx.server.id, report)
    Operations.observe(ctx.server.id, %{report | sequence: 2, status: :failed})
    Operations.observe(Ecto.UUID.generate(), %{report | sequence: 4, status: :failed})
    Operations.observe(ctx.server.id, %{report | generation: 9, sequence: 4, status: :failed})
    assert Repo.get!(Operation, ctx.operation.id).status == :running
    Operations.observe(ctx.server.id, %{report | sequence: 5, status: :succeeded})
    Operations.observe(ctx.server.id, %{report | sequence: 6, status: :unknown})
    assert Repo.get!(Operation, ctx.operation.id).status == :succeeded
    refute inspect(Operations.list(ctx.deployment.id)) =~ "private"
  end

  test "lost acceptance replies are recovered by querying the same operation, not re-executing",
       ctx do
    start_supervised!(AgentConnectionManager)

    AgentConnectionManager.agent_connected(%{
      server_id: ctx.server.id,
      node: node(),
      connected_at: DateTime.utc_now(),
      applications: [],
      capabilities: [:durable_operations_v1]
    })

    :sys.get_state(AgentConnectionManager)
    owner = self()

    start_supervised!(
      {OperationManager,
       executor: fn record, checkpoint ->
         send(owner, {:executed, record.id})
         checkpoint.(%{status: :succeeded})
       end}
    )

    caller = fn _, message ->
      case message do
        {:submit, request} ->
          assert {:ok, _} = OperationManager.submit(request)
          exit(:timeout)

        {:status, id} ->
          OperationManager.status(id)
      end
    end

    assert {:ok, "1.0"} = Operations.await(ctx.operation, caller: caller, interval_ms: 1)
    assert_receive {:executed, id}
    assert id == ctx.operation.id
    refute_receive {:executed, _}
  end

  test "transport uncertainty can be cleared by the same current report; bad terminal identity stays unknown",
       ctx do
    report = %{
      id: ctx.operation.id,
      generation: ctx.operation.generation,
      sequence: 3,
      status: :running,
      phase: :downloading,
      version: "1.0",
      release_id: ctx.spec.release_id
    }

    Operations.observe(ctx.server.id, report)
    ctx.operation |> Repo.reload!() |> Ecto.Changeset.change(status: :unknown) |> Repo.update!()
    Operations.observe(ctx.server.id, report)
    assert Repo.get!(Operation, ctx.operation.id).status == :running

    Operations.observe(ctx.server.id, %{
      report
      | sequence: 4,
        status: :succeeded,
        version: "wrong"
    })

    assert Repo.get!(Operation, ctx.operation.id).status == :unknown
    Operations.observe(ctx.server.id, %{report | sequence: 5, status: :failed})
    assert {:error, _} = Operations.await(ctx.operation)
    assert :ok = Operations.observe(ctx.server.id, %{})
    assert :ok = Operations.observe(ctx.server.id, %{report | generation: -1})

    assert :ok =
             Operations.observe(ctx.server.id, %{
               report
               | id: Ecto.UUID.generate(),
                 status: :succeeded
             })
  end

  test "missing journals after observed acceptance are not resubmitted", ctx do
    start_supervised!(AgentConnectionManager)

    AgentConnectionManager.agent_connected(%{
      server_id: ctx.server.id,
      node: node(),
      connected_at: DateTime.utc_now(),
      applications: [],
      capabilities: [:durable_operations_v1]
    })

    :sys.get_state(AgentConnectionManager)

    Operations.observe(ctx.server.id, %{
      id: ctx.operation.id,
      generation: 1,
      sequence: 1,
      status: :accepted
    })

    owner = self()

    task =
      Task.async(fn ->
        Operations.await(ctx.operation,
          interval_ms: 1,
          caller: fn _, message ->
            send(owner, {:polled, message})
            {:error, :not_found}
          end
        )
      end)

    assert_receive {:polled, {:status, _}}

    Still.IntegrationCase.wait_until!(fn ->
      Repo.get!(Operation, ctx.operation.id).status == :unknown
    end)

    refute_receive {:polled, {:submit, _}}

    Operations.observe(ctx.server.id, %{
      id: ctx.operation.id,
      generation: 1,
      sequence: 2,
      status: :failed,
      error: "operator diagnosis"
    })

    assert {:error, "operator diagnosis"} = Task.await(task)
  end

  test "disconnected and old agents leave durable intent unknown, not failed", ctx do
    start_supervised!(AgentConnectionManager)
    task = Task.async(fn -> Operations.await(ctx.operation, interval_ms: 5) end)

    Still.IntegrationCase.wait_until!(fn ->
      Repo.get!(Operation, ctx.operation.id).status == :unknown
    end)

    AgentConnectionManager.agent_connected(%{
      server_id: ctx.server.id,
      node: node(),
      connected_at: DateTime.utc_now(),
      applications: []
    })

    :sys.get_state(AgentConnectionManager)

    Still.IntegrationCase.wait_until!(fn ->
      Repo.get!(Operation, ctx.operation.id).error =~ "upgrade required"
    end)

    Operations.observe(ctx.server.id, %{
      id: ctx.operation.id,
      generation: 1,
      sequence: 2,
      status: :failed,
      error: "known rejection"
    })

    assert {:error, "known rejection"} = Task.await(task)
  end

  test "retained history protects assignments and is safe to expose through the deployment API",
       ctx do
    [assignment] =
      Still.Applications.list_application_servers(%Still.Applications.Application{
        id: ctx.deployment.application_id
      })

    assert {:error, :operation_history_retained} =
             Still.Applications.unassign_server(Actor.system(), assignment)

    assert {:error, :operation_history_retained} =
             Still.Fleet.delete_server(Actor.system(), ctx.server)

    assert {:error, :operation_history_retained} =
             Still.Applications.delete_application(
               Actor.system(),
               %Still.Applications.Application{id: ctx.deployment.application_id}
             )

    payload =
      ctx.deployment.id |> Deployments.get_deployment!() |> StillWeb.DeploymentJSON.render_one()

    assert [%{id: id}] = payload.data.operations
    assert id == ctx.operation.id
    refute inspect(payload) =~ "private"

    conn =
      Plug.Test.conn(:delete, "/")
      |> StillWeb.FallbackController.call({:error, :operation_history_retained})

    assert conn.status == 409
  end

  test "status RPC failure remains unknown until a subsequent authoritative outcome", ctx do
    start_supervised!(AgentConnectionManager)

    AgentConnectionManager.agent_connected(%{
      server_id: ctx.server.id,
      node: node(),
      connected_at: DateTime.utc_now(),
      applications: [],
      capabilities: [:durable_operations_v1]
    })

    :sys.get_state(AgentConnectionManager)
    calls = :atomics.new(1, [])

    caller = fn _, {:status, id} ->
      if :atomics.add_get(calls, 1, 1) == 1 do
        exit(:timeout)
      else
        assert Repo.get!(Operation, id).status == :unknown
        {:ok, %{id: id, generation: 1, sequence: 1, status: :failed, error: "confirmed failure"}}
      end
    end

    assert {:error, "confirmed failure"} =
             Operations.await(ctx.operation, caller: caller, interval_ms: 1)
  end
end
