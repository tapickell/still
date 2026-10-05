defmodule Still.Repo.Migrations.CreateImmutableReleases do
  use Ecto.Migration

  def change do
    create table(:releases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id, references(:applications, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version, :string, null: false
      add :digest, :string, null: false
      add :size, :bigint, null: false
      add :format, :string, null: false, default: "tar_gzip"
      timestamps()
    end

    create unique_index(:releases, [:application_id, :version])

    create table(:application_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id, references(:applications, type: :binary_id, on_delete: :delete_all),
        null: false

      add :release_id, references(:releases, type: :binary_id, on_delete: :delete_all),
        null: false

      add :configuration, :map, null: false
      timestamps()
    end

    create index(:application_revisions, [:release_id])

    alter table(:deployments) do
      add :process_snapshot, :map
      add :release_id, references(:releases, type: :binary_id, on_delete: :nilify_all)

      add :revision_id,
          references(:application_revisions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:deployments, [:release_id])
    create index(:deployments, [:revision_id])
  end
end
