defmodule Still.Agent.OperationExecutorTest do
  use ExUnit.Case, async: false
  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.StatePersistence
  alias Still.Artifact.Archive
  alias Still.Artifact.Provider.LocalFile
  alias Still.Protocol.OperationRequest
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    old = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, dir)
    on_exit(fn -> Application.put_env(:still, :applications_dir, old) end)
    Req.Test.set_req_test_to_shared()
    config = %{"apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => []}}}}}
    store = start_supervised!({Agent, fn -> config end})

    Req.Test.stub(CaddyManager, fn conn ->
      if conn.method == "POST" do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(store, fn _ -> Jason.decode!(body) end)
        Req.Test.json(conn, %{})
      else
        Req.Test.json(conn, Agent.get(store, & &1))
      end
    end)

    tar = Path.join(dir, "artifact.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(tar), [{~c"index.html", "hello"}], [:compressed])
    {:ok, metadata} = Archive.metadata(tar)

    request = %OperationRequest{
      id: Ecto.UUID.generate(),
      generation: 1,
      kind: :deploy,
      spec: %{
        application: "executor",
        type: :static_site,
        version: "1",
        release_id: Ecto.UUID.generate(),
        revision_id: Ecto.UUID.generate(),
        artifact_url: tar,
        artifact_provider: LocalFile,
        artifact_digest: metadata.digest,
        artifact_size: metadata.size,
        domain: "executor.test",
        hooks: %{},
        env_vars: %{},
        health_check: nil,
        port_blue: nil,
        port_green: nil
      }
    }

    record = %{
      request: request,
      context: nil,
      completed: [],
      phase: nil,
      status: :accepted,
      error: nil
    }

    journal = start_supervised!(Supervisor.child_spec({Agent, fn -> record end}, id: :journal))
    %{record: record, journal: journal, store: store}
  end

  test "recovers an interrupted no-op hook and an interrupted state-file commit", ctx do
    assert catch_throw(
             DeploymentManager.execute_operation(ctx.record, fn patch ->
               Agent.update(ctx.journal, &Map.merge(&1, patch))
               if patch[:phase] == :pre_deploy, do: throw(:interrupted)
             end)
           ) == :interrupted

    record = Agent.get(ctx.journal, & &1)
    completed = execute(ctx, record)
    assert completed.status == :succeeded

    interrupted = %{
      completed
      | status: :running,
        phase: :cleanup,
        completed: Enum.reject(completed.completed, &(&1 in [:cleanup, :post_deploy]))
    }

    assert execute(ctx, interrupted).status == :succeeded
    assert {:ok, state} = StatePersistence.read("executor")
    assert state.previous_version == nil
    assert execute(ctx, %{completed | status: :running}).status == :succeeded
    Agent.update(ctx.store, &put_in(&1, ["apps", "http", "servers", "still", "routes"], []))
    assert execute(ctx, %{completed | status: :running}).status == :unknown
  end

  test "ordinary failures are terminal but an uncertain switch retains the operation", ctx do
    record = ctx.record
    missing = put_in(record.request.spec.artifact_url, "/missing-artifact")
    failed = execute(ctx, missing)
    assert failed.status == :failed
    assert failed.phase == :downloading
    assert failed.error =~ "local copy failed"
    invalid = put_in(record.request.kind, :rollback)
    assert execute(ctx, invalid).status == :failed
    Agent.update(ctx.store, fn _ -> %{} end)
    uncertain = execute(ctx, ctx.record)
    assert uncertain.status == :unknown
    assert uncertain.phase == :switching
  end

  defp execute(ctx, record) do
    Agent.update(ctx.journal, fn _ -> record end)

    DeploymentManager.execute_operation(record, fn patch ->
      Agent.update(ctx.journal, &Map.merge(&1, patch))
    end)

    Agent.get(ctx.journal, & &1)
  end
end
