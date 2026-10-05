defmodule Still.Protocol.DeployRequest do
  @moduledoc "Controller → Agent: trigger a deploy on this server."

  @enforce_keys [
    :application,
    :type,
    :version,
    :artifact_url,
    :domain,
    :env_vars,
    :health_check,
    :hooks,
    :port_blue,
    :port_green
  ]

  defstruct [
    :application,
    :type,
    :version,
    :artifact_url,
    :deployment_id,
    :release_id,
    :revision_id,
    :artifact_digest,
    :artifact_size,
    :domain,
    :path_prefix,
    :maintenance,
    :maintenance_message,
    :env_vars,
    :exec_command,
    :exec_start_pre,
    :exec_stop,
    :exec_console,
    :user,
    :drain_ms,
    :stop_timeout_ms,
    :health_check,
    :hooks,
    :port_blue,
    :port_green
  ]
end
