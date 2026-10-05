defmodule Still.Agent.ApplicationState do
  @moduledoc """
  Persistent per-application state for an agent server. Mirrors the shape of
  `state.json` files written under `<applications_dir>/<application_name>/`.
  """

  @derive Jason.Encoder
  defstruct type: nil,
            active_slot: nil,
            active_port: nil,
            current_version: nil,
            previous_version: nil,
            current_release_id: nil,
            previous_release_id: nil,
            current_revision_id: nil,
            previous_revision_id: nil,
            operation_id: nil,
            generation: nil,
            last_health_check_at: nil
end
