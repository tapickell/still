defmodule Still.ImmutableDeploymentTest do
  use Still.DataCase, async: false

  import ExUnit.CaptureLog
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  alias Still.Agent.ApplicationState
  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.StatePersistence
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.ArtifactStore
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Orchestrator

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    for {key, folder} <- [artifacts_dir: "artifacts", applications_dir: "applications"] do
      original = Application.get_env(:still, key)
      Application.put_env(:still, key, Path.join(dir, folder))
      on_exit(fn -> Application.put_env(:still, key, original) end)
    end

    app =
      application_fixture(%{
        type: :static_site,
        exec_command: nil,
        health_check: nil,
        artifact_source: %{type: :local_file}
      })

    server = server_fixture()
    application_server_fixture(app, server)
    start_supervised!(AgentConnectionManager)

    AgentConnectionManager.agent_connected(%{
      server_id: server.id,
      node: :fake@host,
      connected_at: DateTime.utc_now(),
      capabilities: [:immutable_releases],
      applications: []
    })

    :sys.get_state(AgentConnectionManager)

    owner = self()
    config = %{"apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => []}}}}}

    Req.Test.stub(CaddyManager, fn conn ->
      if conn.method == "POST" do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:route_written, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      else
        Req.Test.json(conn, config)
      end
    end)

    {:ok, agent_state} = DeploymentManager.init([])

    caller = fn operation ->
      fn _node, spec ->
        Req.Test.allow(CaddyManager, owner, self())
        send(owner, {:request, operation, spec})

        spec =
          Map.merge(spec, %{
            artifact_provider: Still.Artifact.Provider.LocalFile,
            artifact_url: ArtifactStore.artifact_path(spec.application, spec.artifact_digest)
          })

        {:reply, result, _} =
          DeploymentManager.handle_call({operation, spec}, self(), agent_state)

        result
      end
    end

    start_supervised!(
      {Orchestrator,
       notifier: self(), agent_caller: caller.(:deploy), rollback_agent_caller: caller.(:rollback)}
    )

    %{app: app, server: server}
  end

  test "real staging and extraction reuse immutable files and roll back an exact revision", %{
    app: app,
    tmp_dir: dir
  } do
    a = tarball(dir, "a", "A")
    first = deploy(app, "1.0.0", a)
    assert_receive {:request, :deploy, spec_a}
    assert spec_a.release_id == first.release_id
    assert spec_a.revision_id == first.revision_id
    assert {:ok, %ApplicationState{current_release_id: id}} = StatePersistence.read(app.name)
    assert id == first.release_id
    release = Path.join([dir, "applications", app.name, "releases", id])
    File.write!(Path.join(release, "sentinel"), "keep")

    repeated = deploy(app, "1.0.0", a)
    assert repeated.release_id == first.release_id
    assert File.read!(Path.join(release, "sentinel")) == "keep"
    assert File.read!(Path.join(release, "index.html")) == "A"

    b = tarball(dir, "b", "B")
    second = deploy(app, "2.0.0", b)
    refute second.release_id == first.release_id
    # A host's local previous version is not authoritative for fleet rollback.
    {:ok, before_rollback} = StatePersistence.read(app.name)

    StatePersistence.write(app.name, %{
      before_rollback
      | previous_version: "unrelated",
        previous_release_id: Ecto.UUID.generate()
    })

    File.rm!(a)
    File.rm!(b)

    {:ok, parked} =
      Applications.update_application(Actor.system(), app, %{
        maintenance: true,
        maintenance_message: "offline"
      })

    {:ok, rollback} =
      Orchestrator.trigger_rollback(Actor.system(), parked, %{initiated_by: "test"})

    assert_receive {:deployment_complete, rollback_id, :completed}, 5_000
    assert rollback_id == rollback.id
    assert_receive {:request, :rollback, rollback_spec}
    assert rollback_spec.release_id == first.release_id
    assert rollback_spec.revision_id == first.revision_id
    assert rollback_spec.maintenance
    assert {:ok, state} = StatePersistence.read(app.name)
    assert state.current_release_id == first.release_id
    assert state.current_revision_id == first.revision_id
    active = Path.join([dir, "applications", app.name, "current_#{state.active_slot}"])
    assert File.read!(Path.join(active, "index.html")) == "A"
    assert File.exists?(Path.join(release, "sentinel"))
  end

  test "conflicting content fails before dispatch and leaves the active release unchanged", %{
    app: app,
    tmp_dir: dir
  } do
    first = deploy(app, "1.0.0", tarball(dir, "a", "A"))
    assert_receive {:request, :deploy, _}

    capture_log(fn ->
      {:ok, failed} =
        Orchestrator.trigger_deployment(Actor.system(), app, %{
          version: "1.0.0",
          artifact_url: tarball(dir, "b", "B"),
          initiated_by: "test"
        })

      assert_receive {:deployment_complete, _, :failed}, 5_000
      assert Deployments.get_deployment!(failed.id).error =~ "version_content_conflict"
    end)

    refute_receive {:request, :deploy, _}
    assert {:ok, state} = StatePersistence.read(app.name)
    assert state.current_release_id == first.release_id

    assert File.read!(Path.join([dir, "applications", app.name, "current_blue", "index.html"])) ==
             "A"
  end

  test "agents without immutable-release support are rejected before dispatch", %{
    app: app,
    server: server,
    tmp_dir: dir
  } do
    AgentConnectionManager.agent_connected(%{
      server_id: server.id,
      node: :old@host,
      connected_at: DateTime.utc_now(),
      applications: []
    })

    :sys.get_state(AgentConnectionManager)

    capture_log(fn ->
      {:ok, failed} =
        Orchestrator.trigger_deployment(Actor.system(), app, %{
          version: "1.0.0",
          artifact_url: tarball(dir, "a", "A"),
          initiated_by: "test"
        })

      assert_receive {:deployment_complete, _, :failed}, 5_000
      assert Deployments.get_deployment!(failed.id).error =~ "agent_upgrade_required"
    end)

    refute_receive {:request, _, _}
  end

  test "new deployments preserve legacy version directories and state remains readable", %{
    app: app,
    tmp_dir: dir
  } do
    legacy = Path.join([dir, "applications", app.name, "releases", "old-version"])
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, "index.html"), "legacy")
    File.ln_s!(legacy, Path.join([dir, "applications", app.name, "current_blue"]))
    state_path = Path.join([dir, "applications", app.name, "state.json"])

    File.write!(
      state_path,
      Jason.encode!(%{
        type: "static_site",
        active_slot: "blue",
        current_version: "old-version",
        previous_version: nil
      })
    )

    assert {:ok, %ApplicationState{current_release_id: nil}} = StatePersistence.read(app.name)
    deployed = deploy(app, "1.0.0", tarball(dir, "a", "A"))
    assert {:ok, state} = StatePersistence.read(app.name)
    assert state.active_slot == "green"
    assert state.current_release_id == deployed.release_id
    assert state.previous_release_id == nil
    assert state.previous_version == "old-version"
    assert File.read!(Path.join(legacy, "index.html")) == "legacy"
  end

  defp deploy(app, version, path) do
    {:ok, deployment} =
      Orchestrator.trigger_deployment(Actor.system(), app, %{
        version: version,
        artifact_url: path,
        initiated_by: "test"
      })

    assert_receive {:deployment_complete, id, :completed}, 5_000
    assert id == deployment.id
    Deployments.get_deployment!(id)
  end

  test "a wrong reported version is not acknowledged as the exact release", %{
    app: app,
    tmp_dir: dir
  } do
    stop_supervised(Orchestrator)

    start_supervised!(
      {Orchestrator, notifier: self(), agent_caller: fn _, _ -> {:ok, "wrong-version"} end}
    )

    capture_log(fn ->
      {:ok, failed} =
        Orchestrator.trigger_deployment(Actor.system(), app, %{
          version: "1.0.0",
          artifact_url: tarball(dir, "a", "A"),
          initiated_by: "test"
        })

      assert_receive {:deployment_complete, _, :failed}, 5_000
      assert Deployments.get_deployment!(failed.id).error =~ "agent_version_mismatch"
    end)
  end

  test "free-form source labels do not change the operation kind", %{app: app, tmp_dir: dir} do
    {:ok, pending} =
      Orchestrator.trigger_deployment(Actor.system(), app, %{
        version: "1.0.0",
        artifact_url: tarball(dir, "a", "A"),
        initiated_by: "test",
        source: "restart"
      })

    assert_receive {:deployment_complete, id, :completed}, 5_000
    assert id == pending.id
    assert_receive {:request, :deploy, _}
  end

  test "legacy rollback fails closed without inventing an artifact identity", %{app: app} do
    for version <- ["old-a", "old-b"] do
      {:ok, legacy} =
        Deployments.create_deployment(Actor.system(), app, %{
          version: version,
          artifact_url: "/missing-legacy-source",
          initiated_by: "test"
        })

      completed = Deployments.complete_deployment!(legacy)
      assert completed.release_id == nil
      assert completed.revision_id == nil
    end

    capture_log(fn ->
      {:ok, rollback} =
        Orchestrator.trigger_rollback(Actor.system(), app, %{initiated_by: "test"})

      assert_receive {:deployment_complete, id, :failed}, 5_000
      assert id == rollback.id
      assert Deployments.get_deployment!(id).error =~ "legacy_release_unverified"
    end)

    refute_receive {:request, _, _}
  end

  defp tarball(dir, name, body) do
    path = Path.join(dir, name <> ".tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"index.html", body}], [:compressed])
    path
  end
end
