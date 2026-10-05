defmodule Still.Integration.ImmutableReleaseTest do
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.Agent.StatePersistence
  alias Still.Artifact.Archive
  alias Still.Artifact.Provider.LocalFile

  test "same-release redeploy and corrupt input preserve live static files", %{
    applications_dir: dir,
    caddy: caddy
  } do
    start_supervised!(DeploymentManager)
    spec = spec(dir, "1.0.0", "A")
    assert {:ok, "1.0.0"} = DeploymentManager.deploy(spec)
    assert body(caddy.http_port, 200) == "A"
    release_dir = Path.join([dir, spec.application, "releases", spec.release_id])
    File.write!(Path.join(release_dir, "sentinel"), "keep")
    assert {:ok, "1.0.0"} = DeploymentManager.deploy(spec)
    assert File.read!(Path.join(release_dir, "sentinel")) == "keep"
    assert body(caddy.http_port, 200) == "A"

    File.write!(spec.artifact_url, "corrupt")

    assert {:error, %{step: :unpacking, reason: :artifact_mismatch}} =
             DeploymentManager.deploy(spec)

    assert body(caddy.http_port, 200) == "A"
    assert File.read!(Path.join(release_dir, "sentinel")) == "keep"
  end

  test "exact rollback preserves maintenance and restores the selected bytes", %{
    applications_dir: dir,
    caddy: caddy
  } do
    start_supervised!(DeploymentManager)
    a = spec(dir, "1.0.0", "A")
    b = spec(dir, "2.0.0", "B")
    assert {:ok, "1.0.0"} = DeploymentManager.deploy(a)
    assert {:ok, "2.0.0"} = DeploymentManager.deploy(b)
    assert body(caddy.http_port, 200) == "B"
    parked = Map.merge(a, %{maintenance: true, maintenance_message: "parked"})
    assert {:ok, "1.0.0"} = DeploymentManager.rollback(parked)
    assert body(caddy.http_port, 503) == "parked"
    assert {:ok, state} = StatePersistence.read(a.application)
    assert state.current_release_id == a.release_id
    assert {:ok, :reconciled} = DeploymentManager.reconcile_route(a)
    assert body(caddy.http_port, 200) == "A"
  end

  defp spec(dir, version, content) do
    path = Path.join(dir, "#{version}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"index.html", content}], [:compressed])
    {:ok, metadata} = Archive.metadata(path)

    %{
      application: "immutable-site",
      type: :static_site,
      version: version,
      release_id: Ecto.UUID.generate(),
      revision_id: Ecto.UUID.generate(),
      artifact_url: path,
      artifact_provider: LocalFile,
      artifact_digest: metadata.digest,
      artifact_size: metadata.size,
      domain: "localhost",
      env_vars: %{},
      health_check: nil,
      hooks: %{},
      port_blue: nil,
      port_green: nil
    }
  end

  defp body(port, expected_status) do
    response = Req.get!("http://localhost:#{port}/", retry: false)
    assert response.status == expected_status
    response.body
  end
end
