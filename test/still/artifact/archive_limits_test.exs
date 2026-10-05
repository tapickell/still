defmodule Still.Artifact.ArchiveLimitsTest do
  use ExUnit.Case, async: false

  alias Still.Artifact.Archive

  @moduletag :tmp_dir

  setup do
    for key <- [:artifact_max_bytes, :artifact_max_entries, :artifact_max_expanded_bytes] do
      original = Application.get_env(:still, key)

      on_exit(fn ->
        if original,
          do: Application.put_env(:still, key, original),
          else: Application.delete_env(:still, key)
      end)
    end

    :ok
  end

  test "enforces compressed, expanded and entry-count limits", %{tmp_dir: dir} do
    tar = Path.join(dir, "archive.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"a", "hello"}, {~c"b", "world"}], [:compressed])

    Application.put_env(:still, :artifact_max_bytes, 1)
    assert {:error, :invalid_artifact_size_or_type} = Archive.metadata(tar)
    Application.put_env(:still, :artifact_max_entries, 1)
    assert {:error, :too_many_archive_entries} = Archive.validate(tar)
    Application.put_env(:still, :artifact_max_entries, 2)
    Application.put_env(:still, :artifact_max_expanded_bytes, 9)
    assert {:error, :archive_too_large} = Archive.validate(tar)
    Application.put_env(:still, :artifact_max_expanded_bytes, 10)
    assert :ok = Archive.validate(tar)
  end

  test "reports missing archives and refuses raw tar disguised as tar.gz", %{tmp_dir: dir} do
    path = Path.join(dir, "missing.tar.gz")
    assert {:error, :enoent} = Archive.validate(path)
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"a", "hello"}], [])
    assert {:error, :invalid_archive_format} = Archive.validate(path)
  end
end
