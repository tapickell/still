defmodule Still.Releases do
  @moduledoc "Immutable artifact identity and private process-configuration snapshots."

  import Ecto.Query, only: [from: 2]

  alias Still.Applications
  alias Still.Applications.Application
  alias Still.Applications.Hook
  alias Still.Artifact.Archive
  alias Still.ArtifactStore
  alias Still.Deployments.Deployment
  alias Still.Releases.Release
  alias Still.Releases.Revision
  alias Still.Repo

  @configuration_fields [
    :type,
    :env_vars,
    :exec_command,
    :exec_start_pre,
    :exec_stop,
    :exec_console
  ]

  @doc "Captures process configuration, excluding live routing/maintenance and deployment provenance."
  @spec snapshot(Application.t()) :: map()
  def snapshot(%Application{} = application) do
    config = Map.take(application, @configuration_fields)

    health_check =
      application.health_check &&
        Map.take(application.health_check, [:path, :interval_ms, :deadline_ms])

    hooks =
      application
      |> Applications.list_hooks_for()
      |> Map.new(fn hook -> {hook.event, Map.take(hook, [:script, :timeout_ms])} end)

    config
    |> Map.merge(%{health_check: health_check, hooks: hooks})
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @doc "Stages exact bytes and binds a deployment to its immutable release and configuration snapshot."
  @spec prepare(Application.t(), Deployment.t()) :: {:ok, Deployment.t()} | {:error, term()}
  def prepare(%Application{} = application, %Deployment{} = deployment) do
    if deployment.release_id do
      prepare_existing(application, deployment)
    else
      with {:ok, path} <-
             ArtifactStore.stage(application.name, deployment.version,
               source_type: application.artifact_source.type,
               spec: %{artifact_url: deployment.artifact_url}
             ),
           {:ok, metadata} <- Archive.metadata(path) do
        bind(application, deployment, metadata)
      end
    end
  end

  defp bind(application, deployment, metadata) do
    Repo.transaction(fn ->
      release = find_or_insert_release(application, deployment.version, metadata)
      config = deployment.process_snapshot || snapshot(application)
      revision = insert_revision(application.id, release.id, config)
      attach(deployment, release, revision)
    end)
  end

  defp find_or_insert_release(application, version, metadata) do
    attrs = Map.merge(metadata, %{application_id: application.id, version: version})

    # The unique index also arbitrates callers outside the single orchestrator.
    {:ok, _} =
      Repo.insert(Release.creation_changeset(attrs),
        on_conflict: :nothing,
        conflict_target: [:application_id, :version]
      )

    release = Repo.get_by!(Release, application_id: application.id, version: version)

    if release.digest != metadata.digest or release.size != metadata.size do
      Repo.rollback(:version_content_conflict)
    end

    release
  end

  defp prepare_existing(application, deployment) do
    release = Repo.get_by(Release, id: deployment.release_id, application_id: application.id)

    with %Release{version: version} when version == deployment.version <- release,
         :ok <-
           Archive.verify(ArtifactStore.artifact_path(application.name, release.digest), release) do
      Repo.transaction(fn ->
        revision = existing_or_new_revision(application, deployment, release)
        attach(deployment, release, revision)
      end)
    else
      nil -> {:error, :unknown_release}
      %Release{} -> {:error, :release_version_mismatch}
      {:error, _} = error -> error
    end
  end

  defp existing_or_new_revision(application, %{revision_id: nil} = deployment, release) do
    insert_revision(
      application.id,
      release.id,
      deployment.process_snapshot || snapshot(application)
    )
  end

  defp existing_or_new_revision(application, deployment, release) do
    Repo.get_by(Revision,
      id: deployment.revision_id,
      application_id: application.id,
      release_id: release.id
    ) || Repo.rollback(:unknown_revision)
  end

  defp insert_revision(application_id, release_id, configuration) do
    existing =
      Repo.all(
        from r in Revision,
          where: r.application_id == ^application_id and r.release_id == ^release_id
      )
      |> Enum.find(&(&1.configuration == configuration))

    existing ||
      %{application_id: application_id, release_id: release_id, configuration: configuration}
      |> Revision.creation_changeset()
      |> Repo.insert!()
  end

  defp attach(deployment, release, revision) do
    deployment
    |> Ecto.Changeset.change(
      release_id: release.id,
      revision_id: revision.id,
      process_snapshot: nil
    )
    |> Repo.update!()
    |> Map.put(:release, release)
    |> Map.put(:revision, revision)
  end

  @doc "Loads a deployment's immutable references without exposing configuration through serializers."
  @spec load(Deployment.t()) :: Deployment.t()
  def load(%Deployment{} = deployment), do: Repo.preload(deployment, [:release, :revision])

  @doc "Returns the preceding completed distinct revision, ignoring repeated restarts of the current revision."
  @spec previous_completed(Application.t(), Deployment.t()) :: Deployment.t() | nil
  def previous_completed(%Application{} = application, %Deployment{} = current) do
    Repo.one(
      from d in Deployment,
        where:
          d.application_id == ^application.id and d.status == :completed and d.id != ^current.id,
        where: not is_nil(d.revision_id) and d.revision_id != ^current.revision_id,
        order_by: [desc: d.completed_at],
        limit: 1
    )
  end

  @doc "Decodes a stored revision into the fixed set of process fields accepted by an agent."
  @spec process_fields(Revision.t()) :: map()
  def process_fields(%Revision{configuration: config}) do
    fields = Map.new(@configuration_fields, &{&1, config[Atom.to_string(&1)]})
    health = config["health_check"]

    health =
      health &&
        %{
          path: health["path"],
          interval_ms: health["interval_ms"],
          deadline_ms: health["deadline_ms"]
        }

    hooks = Map.new(Hook.events(), &{&1, config["hooks"][Atom.to_string(&1)]})

    hooks =
      for {event, hook} <- hooks,
          hook != nil,
          into: %{},
          do: {event, %{script: hook["script"], timeout_ms: hook["timeout_ms"]}}

    fields
    |> Map.put(:type, Enum.find(Application.types(), &(Atom.to_string(&1) == config["type"])))
    |> Map.merge(%{health_check: health, hooks: hooks})
  end
end
