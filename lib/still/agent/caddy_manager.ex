defmodule Still.Agent.CaddyManager do
  @moduledoc """
  Wraps the local Caddy admin API. The agent uses this to manage routing,
  upstream switching, and TLS for the apps running on its server.

  Stateless — every operation is a single round trip to `localhost:2019`.
  Higher-level operations (add an application, switch the active blue/green
  slot, etc.) are composed from these primitives.
  """

  @doc """
  Fetches the current Caddy configuration as a decoded map.

  Returns `{:ok, config}` on success or `{:error, reason}` if the admin API
  is unreachable or returns a non-2xx status.
  """
  def get_config do
    case Req.get(req(), url: "/config/") do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:caddy_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Atomically replaces the entire Caddy configuration.

  Caddy validates the new config and swaps it in one step — there is no
  partial-write window. Returns `:ok` on success or `{:error, reason}` if
  validation fails or the admin API is unreachable.
  """
  def load_config(config) when is_map(config) do
    synchronize(fn -> do_load_config(config) end)
  end

  @doc "Serializes a complete read/modify/write transaction for this node's Caddy endpoint."
  @spec synchronize((-> result)) :: result when result: var
  def synchronize(fun) when is_function(fun, 0) do
    :global.trans({{__MODULE__, caddy_admin_url()}, self()}, fun, [node()])
  end

  @doc "Atomically transforms the latest config relative to every other Still writer on this node."
  @spec update((map() -> {:ok, map()} | {:error, term()})) :: :ok | {:error, term()}
  def update(transform) when is_function(transform, 1) do
    synchronize(fn ->
      with {:ok, config} <- get_config(),
           {:ok, updated} <- transform.(config),
           do: do_load_config(updated)
    end)
  end

  defp do_load_config(config) do
    case Req.post(req(), url: "/load", json: config) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:caddy_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req do
    Req.new([base_url: caddy_admin_url()] ++ caddy_req_options())
  end

  defp caddy_admin_url do
    Application.fetch_env!(:still, :caddy_admin_url)
  end

  defp caddy_req_options do
    Application.get_env(:still, :caddy_req_options, [])
  end
end
