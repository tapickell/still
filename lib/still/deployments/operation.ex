defmodule Still.Deployments.Operation do
  @moduledoc "Persisted per-host intent and ordered, redacted agent observations."
  use Still.Schema
  @type t :: %__MODULE__{}

  schema "operations" do
    belongs_to :deployment, Still.Deployments.Deployment
    belongs_to :step, Still.Deployments.DeploymentStep
    belongs_to :application, Still.Applications.Application
    belongs_to :server, Still.Fleet.Server
    field :generation, :integer
    field :position, :integer, default: 0
    field :request, :binary, redact: true

    field :status, Ecto.Enum,
      values: [:pending, :accepted, :running, :unknown, :succeeded, :failed],
      default: :pending

    field :sequence, :integer, default: 0
    field :phase, :string
    field :error, :string
    timestamps()
  end
end
