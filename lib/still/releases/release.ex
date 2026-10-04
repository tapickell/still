defmodule Still.Releases.Release do
  @moduledoc "An immutable, verified artifact. Version labels are unique within an application."
  use Still.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "releases" do
    field :version, :string
    field :digest, :string
    field :size, :integer
    field :format, :string, default: "tar_gzip"
    belongs_to :application, Still.Applications.Application
    timestamps()
  end

  @doc "Builds an insert-only changeset for verified artifact metadata."
  @spec creation_changeset(map()) :: Ecto.Changeset.t()
  def creation_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:application_id, :version, :digest, :size])
    |> validate_required([:application_id, :version, :digest, :size])
    |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:size, greater_than: 0)
    |> unique_constraint([:application_id, :version])
    |> assoc_constraint(:application)
  end
end
