defmodule Still.Releases.Revision do
  @moduledoc "Immutable process configuration for a release; never includes live routing policy."
  use Still.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "application_revisions" do
    field :configuration, :map, redact: true
    belongs_to :application, Still.Applications.Application
    belongs_to :release, Still.Releases.Release
    timestamps()
  end

  @doc "Builds an insert-only revision changeset. Configuration is redacted from inspection/audits."
  @spec creation_changeset(map()) :: Ecto.Changeset.t()
  def creation_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:application_id, :release_id, :configuration])
    |> validate_required([:application_id, :release_id, :configuration])
    |> assoc_constraint(:application)
    |> assoc_constraint(:release)
  end
end
