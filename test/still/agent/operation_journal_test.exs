defmodule Still.Agent.OperationJournalTest do
  use ExUnit.Case, async: false
  alias Still.Agent.OperationJournal
  alias Still.Protocol.OperationRequest
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    old = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, dir)
    on_exit(fn -> Application.put_env(:still, :applications_dir, old) end)
    :ok
  end

  test "traversal IDs are rejected and malformed committed envelopes fail closed", %{tmp_dir: dir} do
    assert {:error, :invalid_operation_id} = OperationJournal.read("../outside")
    assert {:error, :invalid_operation_id} = OperationJournal.write(%{id: "../outside"})
    path = Path.join(dir, ".operations")
    File.mkdir_p!(path)
    id = Ecto.UUID.generate()
    file = Path.join(path, id <> ".etf")
    File.write!(file, :erlang.term_to_binary(%{}))
    assert {:error, :invalid_journal} = OperationJournal.read(id)
    bytes = :erlang.term_to_binary(%{format: 99})

    File.write!(
      file,
      :erlang.term_to_binary({:still_operation, :crypto.hash(:sha256, bytes), bytes})
    )

    assert {:error, :invalid_journal} = OperationJournal.read(id)
    File.write!(file, :erlang.term_to_binary({:still_operation, "bad checksum", bytes}))
    assert {:error, :invalid_journal} = OperationJournal.read(id)
  end

  test "partial temporary writes are ignored, but an invalid committed record blocks the list", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, ".operations")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "partial.etf.tmp-123"), "unfinished")
    assert {:ok, []} = OperationJournal.list()
    File.write!(Path.join(path, "not-an-id.etf"), "corrupt")
    assert {:error, _} = OperationJournal.list()
  end

  test "directory IO failures are returned rather than interpreted as an empty history", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, ".operations"), "not a directory")
    assert {:error, :enotdir} = OperationJournal.list()
    assert {:error, _} = OperationJournal.write(%{id: Ecto.UUID.generate()})
  end

  test "checksums cover the entire record and request fingerprints cover all parameters" do
    request = %OperationRequest{
      id: Ecto.UUID.generate(),
      generation: 1,
      kind: :deploy,
      spec: %{
        application: "app",
        version: "1",
        type: :static_site,
        release_id: Ecto.UUID.generate(),
        env_vars: %{}
      }
    }

    record = %{
      format: 1,
      id: request.id,
      generation: 1,
      sequence: 1,
      request: request,
      fingerprint: OperationJournal.fingerprint(request),
      status: :accepted,
      phase: nil,
      context: nil,
      completed: [],
      version: "1",
      error: nil
    }

    assert :ok = OperationJournal.write(record)
    assert {:ok, ^record} = OperationJournal.read(request.id)
    assert :ok = OperationJournal.write(%{record | fingerprint: "incorrect"})
    assert {:error, :invalid_journal} = OperationJournal.read(request.id)
  end
end
