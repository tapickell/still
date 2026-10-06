defmodule Still.Agent.CaddyConcurrencyTest do
  use ExUnit.Case, async: false
  alias Still.Agent.CaddyManager

  test "read-modify-write transactions cannot discard another application's config" do
    Req.Test.set_req_test_to_shared()
    store = start_supervised!({Agent, fn -> %{} end})

    Req.Test.stub(CaddyManager, fn conn ->
      if conn.method == "POST" do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(store, fn _ -> Jason.decode!(body) end)
        Req.Test.json(conn, %{})
      else
        Req.Test.json(conn, Agent.get(store, & &1))
      end
    end)

    owner = self()

    first =
      Task.async(fn ->
        CaddyManager.update(fn config ->
          send(owner, {:first_read, self()})

          receive do
            :continue -> {:ok, Map.put(config, "first-app", true)}
          end
        end)
      end)

    assert_receive {:first_read, pid}

    second =
      Task.async(fn ->
        CaddyManager.update(fn config ->
          send(owner, :second_read)
          {:ok, Map.put(config, "second-app", true)}
        end)
      end)

    refute_receive :second_read
    send(pid, :continue)
    assert :ok = Task.await(first)
    assert :ok = Task.await(second)
    assert Agent.get(store, & &1) == %{"first-app" => true, "second-app" => true}
    assert {:error, :rejected} = CaddyManager.update(fn _ -> {:error, :rejected} end)
    assert Agent.get(store, & &1) == %{"first-app" => true, "second-app" => true}
  end
end
