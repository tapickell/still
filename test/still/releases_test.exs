defmodule Still.ReleasesTest do
  use Still.DataCase, async: false

  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  alias Still.Applications
  alias Still.ArtifactStore
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Releases
  alias Still.Releases.Release
  alias Still.Releases.Revision
  alias Still.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:still, :artifacts_dir)
    Application.put_env(:still, :artifacts_dir, Path.join(dir, "artifacts"))
    on_exit(fn -> Application.put_env(:still, :artifacts_dir, previous) end)

    app =
      application_fixture(%{
        artifact_source: %{type: :local_file},
        env_vars: %{"TOKEN" => "private-value"}
      })

    application_server_fixture(app, server_fixture())
    %{app: app, tar: tarball(dir, "first", "hello")}
  end

  test "binds verified bytes and a redacted immutable configuration snapshot", %{
    app: app,
    tar: tar
  } do
    hook_fixture(app, %{event: :release, script: "echo release"})
    deployment = deployment(app, tar)
    assert {:ok, prepared} = Releases.prepare(app, deployment)
    assert prepared.release.version == "1.0.0"
    assert prepared.release.size == File.stat!(tar).size
    assert prepared.release.format == "tar_gzip"
    assert prepared.revision.configuration["env_vars"]["TOKEN"] == "private-value"
    assert prepared.revision.configuration["hooks"]["release"]["script"] == "echo release"
    refute Map.has_key?(prepared.revision.configuration, "maintenance")
    refute Map.has_key?(prepared.revision.configuration, "domain")
    refute inspect(prepared.revision) =~ "private-value"
    refute inspect(Audit.snapshot(prepared.revision)) =~ "private-value"
    refute inspect(Audit.snapshot(deployment)) =~ "private-value"
    refute inspect(StillWeb.DeploymentJSON.render_created(deployment)) =~ "private-value"
    assert Repo.get!(Still.Deployments.Deployment, deployment.id).process_snapshot == nil
  end

  test "reuses exact bytes and configuration even from a different source URL", %{
    app: app,
    tar: tar,
    tmp_dir: dir
  } do
    assert {:ok, first} = Releases.prepare(app, deployment(app, tar))
    copied = Path.join(dir, "another-url.tar.gz")
    File.cp!(tar, copied)
    assert {:ok, second} = Releases.prepare(app, deployment(app, copied))
    assert second.release_id == first.release_id
    assert second.revision_id == first.revision_id
    assert Repo.aggregate(Release, :count) == 1
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "same version with different bytes fails and preserves the original object", %{
    app: app,
    tar: tar,
    tmp_dir: dir
  } do
    assert {:ok, first} = Releases.prepare(app, deployment(app, tar))
    original_path = ArtifactStore.artifact_path(app.name, first.release.digest)
    original = File.read!(original_path)
    other = tarball(dir, "second", "changed")
    failed = deployment(app, other)
    assert {:error, :version_content_conflict} = Releases.prepare(app, failed)
    assert Repo.get!(Still.Deployments.Deployment, failed.id).release_id == nil
    assert File.read!(original_path) == original
    assert Repo.aggregate(Release, :count) == 1
  end

  test "configuration is captured on acceptance, not after a slow download", %{app: app, tar: tar} do
    pending = deployment(app, tar)

    {:ok, edited} =
      Applications.update_application(Actor.system(), app, %{env_vars: %{"TOKEN" => "changed"}})

    assert {:ok, first} = Releases.prepare(edited, pending)
    assert first.revision.configuration["env_vars"]["TOKEN"] == "private-value"
    assert {:ok, second} = Releases.prepare(edited, deployment(edited, tar))
    assert second.release_id == first.release_id
    refute second.revision_id == first.revision_id
    assert Releases.process_fields(second.revision).env_vars == %{"TOKEN" => "changed"}
  end

  test "pinned restart and rollback do not fetch the original URL", %{app: app, tar: tar} do
    assert {:ok, first} = Releases.prepare(app, deployment(app, tar))
    File.rm!(tar)

    {:ok, changed} =
      Applications.update_application(Actor.system(), app, %{env_vars: %{"TOKEN" => "new"}})

    restart = deployment(changed, tar, %{release_id: first.release_id, source: "restart"})
    assert {:ok, restarted} = Releases.prepare(changed, restart)
    assert restarted.release_id == first.release_id
    refute restarted.revision_id == first.revision_id

    rollback =
      deployment(changed, tar, %{
        release_id: first.release_id,
        revision_id: first.revision_id,
        source: "rollback"
      })

    assert {:ok, rolled_back} = Releases.prepare(changed, rollback)
    assert rolled_back.revision_id == first.revision_id
    assert Releases.process_fields(rolled_back.revision).env_vars == %{"TOKEN" => "private-value"}
  end

  test "missing or corrupted retained bytes fail rather than refetching a mutable source", %{
    app: app,
    tar: tar
  } do
    assert {:ok, first} = Releases.prepare(app, deployment(app, tar))
    path = ArtifactStore.artifact_path(app.name, first.release.digest)
    File.write!(path, "corrupted")
    pinned = deployment(app, tar, %{release_id: first.release_id})
    assert {:error, :artifact_mismatch} = Releases.prepare(app, pinned)
    File.rm!(path)
    assert {:error, :enoent} = Releases.prepare(app, pinned)
    assert File.exists?(tar)
  end

  test "failed staging creates no release or revision", %{app: app, tar: tar} do
    File.write!(tar, "broken tar")
    assert {:error, _} = Releases.prepare(app, deployment(app, tar))
    assert Repo.aggregate(Release, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
  end

  test "cannot attach a release owned by another application", %{app: app, tar: tar} do
    {:ok, first} = Releases.prepare(app, deployment(app, tar))
    other = application_fixture(%{artifact_source: %{type: :local_file}})
    application_server_fixture(other, server_fixture())
    pending = deployment(other, tar, %{release_id: first.release_id})
    assert {:error, :unknown_release} = Releases.prepare(other, pending)
  end

  test "rejects inconsistent internal version and revision references", %{
    app: app,
    tar: tar,
    tmp_dir: dir
  } do
    {:ok, first} = Releases.prepare(app, deployment(app, tar))
    mismatched = deployment(app, tar, %{version: "wrong", release_id: first.release_id})
    assert {:error, :release_version_mismatch} = Releases.prepare(app, mismatched)
    second_tar = tarball(dir, "v2", "v2")
    {:ok, second} = Releases.prepare(app, deployment(app, second_tar, %{version: "2.0.0"}))

    mismatched =
      deployment(app, tar, %{release_id: first.release_id, revision_id: second.revision_id})

    assert {:error, :unknown_revision} = Releases.prepare(app, mismatched)
  end

  test "deleting the application still deletes related database rows", %{app: app, tar: tar} do
    assert {:ok, _} = Releases.prepare(app, deployment(app, tar))
    assert {:ok, _} = Applications.delete_application(Actor.system(), app)
    assert Repo.aggregate(Release, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
  end

  test "rollback chooses a distinct exact revision, ignoring an unchanged restart", %{
    app: app,
    tar: tar,
    tmp_dir: dir
  } do
    {:ok, first} = Releases.prepare(app, deployment(app, tar))
    Deployments.complete_deployment!(first)
    second_tar = tarball(dir, "v2", "v2")
    {:ok, second} = Releases.prepare(app, deployment(app, second_tar, %{version: "2.0.0"}))
    Deployments.complete_deployment!(second)

    restart =
      deployment(app, second_tar, %{
        version: "2.0.0",
        release_id: second.release_id,
        source: "restart"
      })

    {:ok, restart} = Releases.prepare(app, restart)
    Deployments.complete_deployment!(restart)
    assert Deployments.get_rollback_target(app).revision_id == first.revision_id
  end

  defp deployment(app, path, attrs \\ %{}) do
    {:ok, deployment} =
      Deployments.create_deployment(
        Actor.system(),
        app,
        Map.merge(%{version: "1.0.0", artifact_url: path, initiated_by: "test"}, attrs)
      )

    deployment
  end

  defp tarball(dir, name, body) do
    path = Path.join(dir, name <> ".tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"index.html", body}], [:compressed])
    path
  end
end
