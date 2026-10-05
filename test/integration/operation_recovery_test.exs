defmodule Still.Integration.OperationRecoveryTest do
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.Agent.OperationManager
  alias Still.Agent.StatePersistence
  alias Still.Artifact.Archive
  alias Still.Artifact.Provider.LocalFile
  alias Still.Protocol.OperationRequest

  test "interrupted real hook is not repeated; explicit confirmation resumes the same operation",
       %{applications_dir: dir, caddy: caddy} do
    owner = self()
    marker = Path.join(dir, "hook-counter")
    req = request(dir, %{pre_deploy: %{script: "printf x >> '#{marker}'", timeout_ms: 5000}})

    start_supervised!(
      {OperationManager,
       executor: fn record, save ->
         DeploymentManager.execute_operation(record, fn patch ->
           if :pre_deploy in Map.get(patch, :completed, []) and is_nil(patch[:phase]) do
             send(owner, :hook_ran)

             receive do
               :never -> :ok
             end
           end

           save.(patch)
         end)
       end}
    )

    assert {:ok, _} = OperationManager.submit(req)
    assert_receive :hook_ran, 5_000
    assert File.read!(marker) == "x"
    stop_supervised(OperationManager)
    start_supervised!(OperationManager)

    wait_until!(fn ->
      match?({:ok, %{status: :unknown}}, OperationManager.status(req.id)) and
        :sys.get_state(OperationManager).workers == %{}
    end)

    assert File.read!(marker) == "x"
    assert {:ok, _} = OperationManager.confirm_phase(req.id, :pre_deploy)
    wait_until!(fn -> match?({:ok, %{status: :succeeded}}, OperationManager.status(req.id)) end)
    assert File.read!(marker) == "x"
    assert fetch_body(caddy, req) == "operation-fixture"
  end

  test "completed journal survives a cold peer BEAM restart without replay", %{
    applications_dir: dir,
    caddy: caddy
  } do
    req = request(dir, %{})
    peer = start_agent_peer!(%{applications_dir: dir, caddy: caddy})
    assert {:ok, _} = :erpc.call(peer.node, OperationManager, :submit, [req])

    wait_until!(fn ->
      match?(
        {:ok, %{status: :succeeded}},
        :erpc.call(peer.node, OperationManager, :status, [req.id])
      )
    end)

    stop_agent_peer!(peer)
    peer = start_agent_peer!(%{applications_dir: dir, caddy: caddy})
    on_exit(fn -> stop_agent_peer!(peer) end)
    assert {:ok, %{status: :succeeded}} = :erpc.call(peer.node, OperationManager, :submit, [req])
    assert {:ok, state} = StatePersistence.read(req.spec.application)
    assert state.operation_id == req.id
    assert fetch_body(caddy, req) == "operation-fixture"
  end

  defp request(dir, hooks) do
    app = "op-#{System.unique_integer([:positive])}"
    tar = Path.join(dir, "#{Ecto.UUID.generate()}.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"index.html", "operation-fixture"}], [
        :compressed
      ])

    {:ok, metadata} = Archive.metadata(tar)

    %OperationRequest{
      id: Ecto.UUID.generate(),
      generation: 1,
      kind: :deploy,
      spec: %{
        application: app,
        type: :static_site,
        version: "1.0",
        release_id: Ecto.UUID.generate(),
        revision_id: Ecto.UUID.generate(),
        artifact_url: tar,
        artifact_provider: LocalFile,
        artifact_digest: metadata.digest,
        artifact_size: metadata.size,
        domain: "#{app}.test",
        env_vars: %{},
        health_check: nil,
        hooks: hooks,
        port_blue: nil,
        port_green: nil
      }
    }
  end

  defp fetch_body(caddy, req) do
    response =
      Req.get!("http://localhost:#{caddy.http_port}/", headers: [{"host", req.spec.domain}])

    assert response.status == 200
    response.body
  end
end
