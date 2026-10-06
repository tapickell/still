defmodule Still.Repo.Migrations.CreateOperations do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :operation_kind, :string, null: false, default: "deploy"
      add :durable_operations, :boolean, null: false, default: false
    end

    create table(:operations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :deployment_id, references(:deployments, type: :binary_id), null: false
      add :step_id, references(:deployment_steps, type: :binary_id), null: false
      add :application_id, references(:applications, type: :binary_id), null: false
      add :server_id, references(:servers, type: :binary_id), null: false
      add :generation, :integer, null: false
      add :request, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :sequence, :integer, null: false, default: 0
      add :phase, :string
      add :error, :text
      timestamps()
    end

    create unique_index(:operations, [:step_id])
    create unique_index(:operations, [:application_id, :server_id, :generation])
  end
end
