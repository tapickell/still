defmodule Still.Artifact.ArchiveTest do
  use ExUnit.Case, async: true

  alias Still.Artifact.Archive

  @moduletag :tmp_dir

  test "hashes bytes, verifies identity, and extracts executable files", %{tmp_dir: dir} do
    executable = Path.join(dir, "start")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)
    tar = Path.join(dir, "app.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"bin/start", String.to_charlist(executable)}],
        [:compressed]
      )

    assert {:ok, %{digest: digest, size: size} = metadata} = Archive.metadata(tar)
    assert digest == Base.encode16(:crypto.hash(:sha256, File.read!(tar)), case: :lower)
    assert size == File.stat!(tar).size
    assert :ok = Archive.verify(tar, metadata)

    assert {:error, :artifact_mismatch} =
             Archive.verify(tar, %{metadata | digest: String.duplicate("0", 64)})

    assert :ok = Archive.validate(tar)
    assert :ok = Archive.extract(tar, Path.join(dir, "release"))
    assert Bitwise.band(File.stat!(Path.join(dir, "release/bin/start")).mode, 0o777) == 0o755
  end

  test "rejects traversal, absolute paths, duplicate normalized names, and reserved marker files",
       %{tmp_dir: dir} do
    for {name, entries} <- [
          {"traversal", [{~c"../outside", "bad"}]},
          {"absolute", [{~c"/outside", "bad"}]},
          {"duplicate", [{~c"index.html", "one"}, {~c"./index.html", "two"}]},
          {"marker", [{~c".still-artifact.json", "bad"}]}
        ] do
      tar = Path.join(dir, name <> ".tar.gz")
      :ok = :erl_tar.create(String.to_charlist(tar), entries, [:compressed])
      assert {:error, _} = Archive.validate(tar)
      refute File.exists?(Path.join(dir, "outside"))
    end
  end

  test "rejects an escaping symlink and accepts a contained relative symlink", %{tmp_dir: dir} do
    link = Path.join(dir, "link")
    File.ln_s!("../../outside", link)
    tar = Path.join(dir, "bad-link.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"link", String.to_charlist(link)}], [
        :compressed
      ])

    assert {:error, _} = Archive.validate(tar)

    File.rm!(link)
    File.ln_s!("target", link)
    tar = Path.join(dir, "good-link.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"target", "hello"}, {~c"link", String.to_charlist(link)}],
        [:compressed]
      )

    assert :ok = Archive.validate(tar)
    dest = Path.join(dir, "good-link")
    assert :ok = Archive.extract(tar, dest)
    assert File.read!(Path.join(dest, "link")) == "hello"
  end

  test "rejects symlink-followed-by-child escape without touching external files", %{tmp_dir: dir} do
    outside = Path.join(dir, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "sentinel"), "original")
    link = Path.join(dir, "link")
    File.ln_s!(outside, link)
    tar = Path.join(dir, "escape.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"link", String.to_charlist(link)}, {~c"link/sentinel", "changed"}],
        [:compressed]
      )

    assert {:error, _} = Archive.validate(tar)
    assert File.read!(Path.join(outside, "sentinel")) == "original"
  end

  test "rejects corrupt archives and does not extract over an existing directory", %{tmp_dir: dir} do
    tar = Path.join(dir, "bad.tar.gz")
    File.write!(tar, "not a tarball")
    assert {:error, _} = Archive.validate(tar)
    :ok = :erl_tar.create(String.to_charlist(tar), [{~c"index.html", "hello"}], [:compressed])
    assert {:error, :eexist} = Archive.extract(tar, dir)
    refute File.exists?(Path.join(dir, "index.html"))
  end

  test "rejects privilege bits in archive files", %{tmp_dir: dir} do
    source = Path.join(dir, "privileged")
    File.write!(source, "bad")
    File.chmod!(source, 0o4755)
    tar = Path.join(dir, "privileged.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"privileged", String.to_charlist(source)}], [
        :compressed
      ])

    assert {:error, :unsafe_archive_entry} = Archive.validate(tar)
  end

  test "safe components do not admit path syntax" do
    for value <- [nil, "", ".", "..", "../a", "a/b", "/tmp", "a\\b", "a\0b", "-flag"] do
      refute Archive.safe_component?(value)
    end

    assert Archive.safe_component?("1.0.0+build-2")
  end

  test "rejects empty input and empty archives", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.tar.gz")
    File.write!(path, "")
    assert {:error, :invalid_artifact_size_or_type} = Archive.metadata(path)
    assert {:error, :invalid_artifact_size_or_type} = Archive.metadata(dir)
    :ok = :erl_tar.create(String.to_charlist(path), [], [:compressed])
    assert {:error, :empty_archive} = Archive.validate(path)
  end
end
