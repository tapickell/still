defmodule Still.Protocol.OperationRequest do
  @moduledoc "Version 1 asynchronous operation envelope. IDs are stable across retries."
  @enforce_keys [:id, :generation, :kind, :spec]
  defstruct [:id, :generation, :kind, :spec, protocol: 1]
  @type t :: %__MODULE__{}
  alias Still.Artifact.Archive

  @doc "Validates the version, identity and data-only payload before any side effect."
  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(
        %__MODULE__{protocol: 1, generation: generation, kind: kind, spec: spec, id: id} = request
      )
      when is_integer(generation) and generation > 0 and kind in [:deploy, :rollback, :restart] and
             is_map(spec) do
    if valid_identifiers?(id, spec) and data?(request) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  def validate(_request), do: {:error, :unsupported_operation_protocol}

  defp valid_identifiers?(id, spec) do
    Enum.all?([id, Map.get(spec, :release_id)], &match?({:ok, _}, Ecto.UUID.cast(&1))) and
      Enum.all?(
        [Map.get(spec, :application), Map.get(spec, :version)],
        &Archive.safe_component?/1
      ) and
      Map.get(spec, :type) in [:static_site, :elixir_release, :process]
  end

  defp data?(term) when is_map(term),
    do: Enum.all?(Map.to_list(term), fn {k, v} -> data?(k) and data?(v) end)

  defp data?(term) when is_list(term), do: Enum.all?(term, &data?/1)
  defp data?(term), do: is_binary(term) or is_atom(term) or is_number(term)
end
