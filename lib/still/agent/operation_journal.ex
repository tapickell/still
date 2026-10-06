defmodule Still.Agent.OperationJournal do
  @moduledoc "Private, synced operation records. Corrupt records block admission rather than disappearing."
  alias Still.Artifact.Archive
  alias Still.Protocol.OperationRequest

  @doc "Reads committed records; a single unreadable record makes recovery fail closed."
  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    case File.ls(directory()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".etf"))
        |> Enum.reduce_while({:ok, []}, &read_next/2)

      {:error, :enoent} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  defp read_next(name, {:ok, records}) do
    case read(Path.rootname(name)) do
      {:ok, record} -> {:cont, {:ok, [record | records]}}
      {:error, reason} -> {:halt, {:error, {name, reason}}}
    end
  end

  @doc "Safe-decodes and checks a journal's identity and payload fingerprint."
  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(id) when is_binary(id) do
    # Populate the fixed protocol vocabulary before safe decoding on cold boot.
    Code.ensure_loaded!(Still.Protocol.DeployRequest)
    Code.ensure_loaded!(Still.Applications.Hook)

    with :ok <- valid_id(id), {:ok, bytes} <- File.read(path(id)) do
      decode_record(:erlang.binary_to_term(bytes, [:safe]), id)
    end
  rescue
    ArgumentError -> {:error, :invalid_journal}
  end

  defp decode_record({:still_operation, checksum, bytes}, id) when is_binary(bytes) do
    if :crypto.hash(:sha256, bytes) == checksum,
      do: validate_record(:erlang.binary_to_term(bytes, [:safe]), id),
      else: {:error, :invalid_journal}
  end

  defp decode_record(_record, _id), do: {:error, :invalid_journal}

  defp validate_record(
         %{
           format: 1,
           id: id,
           request: %OperationRequest{id: id} = request,
           generation: generation,
           fingerprint: digest,
           sequence: sequence,
           status: status,
           completed: completed,
           context: context,
           phase: phase
         } = record,
         id
       )
       when is_integer(sequence) and sequence > 0 and is_list(completed) and
              status in [:accepted, :running, :unknown, :succeeded, :failed] and is_atom(phase) do
    valid = valid_snapshot?(generation, digest, request, context)

    if valid, do: {:ok, record}, else: {:error, :invalid_journal}
  end

  defp validate_record(_record, _id), do: {:error, :invalid_journal}

  defp valid_snapshot?(generation, digest, request, context) do
    generation == request.generation and digest == fingerprint(request) and
      OperationRequest.validate(request) == :ok and (is_nil(context) or is_map(context))
  end

  @doc "Syncs bytes and directory entries before acknowledging an atomic journal replacement."
  @spec write(map()) :: :ok | {:error, term()}
  def write(%{id: id} = record) do
    with :ok <- valid_id(id),
         :ok <- File.mkdir_p(directory()),
         :ok <- File.chmod(directory(), 0o700) do
      bytes = :erlang.term_to_binary(record)
      envelope = :erlang.term_to_binary({:still_operation, :crypto.hash(:sha256, bytes), bytes})
      publish(path(id), envelope)
    end
  end

  defp publish(destination, bytes) do
    temporary = destination <> ".tmp-" <> Ecto.UUID.generate()

    try do
      with :ok <- synced_write(temporary, bytes),
           :ok <- File.rename(temporary, destination),
           :ok <- sync_directory(directory()) do
        sync_directory(Path.dirname(directory()))
      end
    after
      File.rm(temporary)
    end
  end

  defp synced_write(path, bytes) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- :file.write(io, bytes), do: :file.sync(io)
      after
        :file.close(io)
      end
    end
  end

  @doc "Syncs a directory after a state-file rename."
  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  def sync_directory(path) when is_binary(path) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(io)
      after
        :file.close(io)
      end
    end
  end

  @doc "Returns public progress, never the request, context, commands, or environment."
  @spec report(map()) :: map()
  def report(record) when is_map(record) do
    record
    |> Map.take([:id, :generation, :sequence, :status, :phase, :completed, :version, :error])
    |> Map.merge(Map.take(record.request.spec, [:release_id, :revision_id]))
  end

  @doc "Fingerprints a command deterministically, including its generation and complete payload."
  @spec fingerprint(map()) :: String.t()
  def fingerprint(request) when is_map(request) do
    request
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp directory, do: Path.join(Application.fetch_env!(:still, :applications_dir), ".operations")
  defp path(id), do: Path.join(directory(), id <> ".etf")

  defp valid_id(id) do
    if Archive.safe_component?(id) and match?({:ok, _}, Ecto.UUID.cast(id)),
      do: :ok,
      else: {:error, :invalid_operation_id}
  end
end
