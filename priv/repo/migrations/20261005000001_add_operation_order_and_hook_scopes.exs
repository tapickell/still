defmodule Still.Repo.Migrations.AddOperationOrderAndHookScopes do
  use Ecto.Migration

  def change do
    alter table(:operations) do
      add :position, :integer, null: false, default: 0
    end

    alter table(:hooks) do
      add :scope, :string, null: false, default: "per_replica"
    end
  end
end
