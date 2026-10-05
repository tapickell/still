defmodule Still.AgentConnectionManager.App do
  @moduledoc "The controller's view of one application on an agent — the agent's reported snapshot, plus `health` derived from HealthMonitor transitions."

  defstruct [
    :application_name,
    :type,
    :active_slot,
    :active_port,
    :current_version,
    :previous_version,
    :current_release_id,
    :previous_release_id,
    :current_revision_id,
    :previous_revision_id,
    :last_health_check_at,
    :pid,
    :active_state,
    :active_enter_at,
    :health
  ]

  @doc "Builds an entry from an agent-reported snapshot, dropping any unknown keys."
  def new(attrs) when is_map(attrs), do: struct(__MODULE__, attrs)
end
