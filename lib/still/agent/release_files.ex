defmodule Still.Agent.ReleaseFiles do
  @moduledoc "Publishes verified release directories without modifying existing releases."

  alias Still.Artifact.Archive

  @marker ".still-artifact.json"

  @doc "Verifies downloaded bytes and atomically installs them, or verifies an existing release marker."
  @spec install(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def install(tarball, destination, spec)
      when is_binary(tarball) and is_binary(destination) and is_map(spec) do
    with {:ok, metadata} <- Archive.metadata(tarball),
         :ok <- verify_expected(metadata, spec) do
      case File.lstat(destination) do
        {:ok, %{type: :directory}} -> verify_marker(destination, metadata)
        {:ok, _} -> {:error, :unsafe_release_destination}
        {:error, :enoent} -> publish(tarball, destination, metadata)
        {:error, _} = error -> error
      end
    end
  end

  @doc "Confirms an exact on-disk release before a restart or rollback; no fetching or rewriting."
  @spec verify(String.t(), map()) :: :ok | {:error, term()}
  def verify(destination, %{artifact_digest: digest, artifact_size: size})
      when is_binary(destination) and is_binary(digest) and is_integer(size) do
    verify_marker(destination, %{digest: digest, size: size})
  end

  def verify(_destination, _spec), do: {:error, :missing_artifact_identity}

  defp verify_expected(metadata, spec) do
    case {Map.get(spec, :artifact_digest), Map.get(spec, :artifact_size)} do
      {nil, nil} ->
        if Map.get(spec, :release_id), do: {:error, :missing_artifact_identity}, else: :ok

      {digest, size} when digest == metadata.digest and size == metadata.size ->
        :ok

      _ ->
        {:error, :artifact_mismatch}
    end
  end

  defp publish(tarball, destination, metadata) do
    temporary = destination <> ".tmp-" <> Ecto.UUID.generate()
    File.mkdir_p!(Path.dirname(destination))

    try do
      with :ok <- Archive.extract(tarball, temporary),
           :ok <- File.write(Path.join(temporary, @marker), Jason.encode!(metadata), [:exclusive]) do
        File.rename(temporary, destination)
      end
    after
      File.rm_rf(temporary)
    end
  end

  defp verify_marker(destination, %{digest: digest, size: size}) do
    with {:ok, %{type: :directory}} <- File.lstat(destination),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(destination, @marker)),
         {:ok, body} <- File.read(Path.join(destination, @marker)),
         {:ok, %{"digest" => ^digest, "size" => ^size}} <- Jason.decode(body) do
      :ok
    else
      _ -> {:error, :unverified_existing_release}
    end
  end
end
