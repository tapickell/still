defmodule Still.Agent.ReleaseFilesTest do
  use ExUnit.Case, async: true

  alias Still.Agent.ReleaseFiles
  alias Still.Artifact.Archive

  @moduletag :tmp_dir

  test "publishes an immutable release and reuses it without replacing active files", %{
    tmp_dir: dir
  } do
    tar = tarball(dir, "first", "hello")
    {:ok, metadata} = Archive.metadata(tar)
    spec = %{artifact_digest: metadata.digest, artifact_size: metadata.size}
    dest = Path.join(dir, "releases/" <> Ecto.UUID.generate())
    assert :ok = ReleaseFiles.install(tar, dest, spec)
    File.ln_s!(dest, Path.join(dir, "current_blue"))
    File.write!(Path.join(dest, "sentinel"), "do not remove")
    assert :ok = ReleaseFiles.install(tar, dest, spec)
    assert :ok = ReleaseFiles.verify(dest, spec)
    assert File.read!(Path.join(dir, "current_blue/index.html")) == "hello"
    assert File.read!(Path.join(dest, "sentinel")) == "do not remove"

    changed = tarball(dir, "changed", "different")
    assert {:error, :artifact_mismatch} = ReleaseFiles.install(changed, dest, spec)
    assert {:error, :unverified_existing_release} = ReleaseFiles.install(changed, dest, %{})
    assert File.read!(Path.join(dest, "index.html")) == "hello"
  end

  test "never modifies a legacy directory that has no verification marker", %{tmp_dir: dir} do
    tar = tarball(dir, "new", "new")
    dest = Path.join(dir, "releases/legacy")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "index.html"), "legacy")
    assert {:error, :unverified_existing_release} = ReleaseFiles.install(tar, dest, %{})
    assert File.read!(Path.join(dest, "index.html")) == "legacy"
  end

  test "refuses symlink destinations and cleans failed extraction without publishing", %{
    tmp_dir: dir
  } do
    tar = tarball(dir, "new", "new")
    destination = Path.join(dir, "alias")
    File.ln_s!(dir, destination)
    assert {:error, :unsafe_release_destination} = ReleaseFiles.install(tar, destination, %{})

    bad = Path.join(dir, "bad.tar.gz")
    File.write!(bad, "corrupt")
    dest = Path.join(dir, "releases/failed")
    assert {:error, _} = ReleaseFiles.install(bad, dest, %{})
    refute File.exists?(dest)
    assert File.ls!(Path.dirname(dest)) == []
  end

  defp tarball(dir, name, body) do
    path = Path.join(dir, name <> ".tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"index.html", body}], [:compressed])
    path
  end

  test "propagates destination IO errors and refuses incomplete exact identities", %{tmp_dir: dir} do
    tar = tarball(dir, "new", "hello")
    parent = Path.join(dir, "not-a-directory")
    File.write!(parent, "file")
    assert {:error, :enotdir} = ReleaseFiles.install(tar, Path.join(parent, "child"), %{})
    assert {:error, :missing_artifact_identity} = ReleaseFiles.verify(dir, %{})

    assert {:error, :missing_artifact_identity} =
             ReleaseFiles.install(tar, Path.join(dir, "release"), %{
               release_id: Ecto.UUID.generate()
             })
  end
end
