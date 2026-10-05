defmodule Still.Artifact.Archive do
  @moduledoc "Verified tar.gz handling in private staging directories, never over a live release."

  @type metadata :: %{digest: String.t(), size: pos_integer()}

  @doc "Hashes an artifact with bounded read buffers and checks its compressed size."
  @spec metadata(String.t()) :: {:ok, metadata()} | {:error, term()}
  def metadata(path) when is_binary(path) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size > 0 and size <= limit(:artifact_max_bytes, 536_870_912) do
      digest =
        path
        |> File.stream!(65_536)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, %{digest: digest, size: size}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_artifact_size_or_type}
    end
  end

  @doc "Checks artifact bytes against the controller's exact digest and size."
  @spec verify(String.t(), metadata()) :: :ok | {:error, term()}
  def verify(path, %{digest: digest, size: size}) when is_binary(path) do
    case metadata(path) do
      {:ok, %{digest: ^digest, size: ^size}} -> :ok
      {:ok, _} -> {:error, :artifact_mismatch}
      {:error, _} = error -> error
    end
  end

  @doc "Fully validates an archive in a disposable sibling directory, including link targets."
  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(path) when is_binary(path) do
    dir = path <> ".validate-" <> Ecto.UUID.generate()

    try do
      extract(path, dir)
    after
      File.rm_rf(dir)
    end
  end

  @doc "Extracts only into a new directory. Rejects unsafe names, special files and oversized archives."
  @spec extract(String.t(), String.t()) :: :ok | {:error, term()}
  def extract(path, destination) when is_binary(path) and is_binary(destination) do
    with :ok <- gzip_header(path),
         {:ok, entries} <- :erl_tar.table(String.to_charlist(path), [:compressed, :verbose]),
         :ok <- validate_entries(entries),
         :ok <- File.mkdir(destination) do
      # erl_tar resolves each path against cwd and rejects escaping symbolic links.
      # Unlike shelling out to tar, no archive-supplied owner is applied.
      :erl_tar.extract(String.to_charlist(path), [
        :compressed,
        {:cwd, String.to_charlist(destination)}
      ])
    end
  end

  @doc "Accepts a single safe path component for legacy version paths and application names."
  @spec safe_component?(term()) :: boolean()
  def safe_component?(value) when is_binary(value) do
    byte_size(value) in 1..255 and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._+-]*\z/, value)
  end

  def safe_component?(_value), do: false

  defp gzip_header(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 2)) do
      {:ok, <<0x1F, 0x8B>>} -> :ok
      {:ok, _} -> {:error, :invalid_archive_format}
      {:error, _} = error -> error
    end
  end

  defp validate_entries(entries) do
    names =
      Enum.map(entries, fn {name, _, _, _, _, _, _} ->
        Path.expand(to_string(name), "/archive")
      end)

    size = Enum.reduce(entries, 0, fn {_, _, size, _, _, _, _}, acc -> acc + size end)

    cond do
      entries == [] ->
        {:error, :empty_archive}

      length(entries) > limit(:artifact_max_entries, 100_000) ->
        {:error, :too_many_archive_entries}

      size > limit(:artifact_max_expanded_bytes, 2_147_483_648) ->
        {:error, :archive_too_large}

      length(Enum.uniq(names)) != length(names) ->
        {:error, :duplicate_archive_path}

      not Enum.all?(entries, &safe_entry?/1) ->
        {:error, :unsafe_archive_entry}

      true ->
        :ok
    end
  end

  defp safe_entry?({name, type, size, _mtime, mode, _uid, _gid}) do
    path = to_string(name)

    type in [:regular, :directory, :symlink] and size >= 0 and
      Bitwise.band(mode, 0o6000) == 0 and Path.type(path) == :relative and
      not String.contains?(path, ["\\", "\0"]) and
      ".." not in Path.split(path) and
      Path.basename(path) != ".still-artifact.json"
  end

  defp limit(key, default), do: Application.get_env(:still, key, default)
end
