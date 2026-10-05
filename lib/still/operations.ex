defmodule Still.Operations do
  @moduledoc "Durable intent before dispatch, monotonic reports, and bounded RPC observation."
  import Ecto.Query, only: [from: 2]

  alias Still.Agent.OperationManager
  alias Still.AgentConnectionManager
  alias Still.Deployments.Operation
  alias Still.Protocol.OperationRequest
  alias Still.Repo

  @doc "Creates exactly one persisted command per deployment step before contacting its agent."
  @spec ensure(map(), map(), map(), non_neg_integer()) :: Operation.t()
  def ensure(deployment, step, spec, position \\ 0)
      when is_map(deployment) and is_map(step) and is_map(spec) do
    {:ok, operation} =
      Repo.transaction(fn ->
        Repo.get_by(Operation, step_id: step.id) ||
          insert_operation(deployment, step, spec, position)
      end)

    operation
  end

  defp insert_operation(deployment, step, spec, position) do
    generation =
      Repo.one(
        from o in Operation,
          where:
            o.application_id == ^deployment.application_id and o.server_id == ^step.server_id,
          select: max(o.generation)
      ) || 0

    id = Ecto.UUID.generate()

    request = %OperationRequest{
      id: id,
      generation: generation + 1,
      kind: deployment.operation_kind,
      spec: spec
    }

    Repo.insert!(%Operation{
      id: id,
      deployment_id: deployment.id,
      step_id: step.id,
      application_id: deployment.application_id,
      server_id: step.server_id,
      generation: generation + 1,
      request: :erlang.term_to_binary(request),
      position: position
    })
  end

  @doc "Applies only newer reports matching this server, operation, and generation."
  @spec observe(String.t(), map()) :: :ok
  def observe(
        server_id,
        %{id: id, generation: generation, sequence: sequence, status: status} = report
      )
      when is_integer(sequence) and sequence > 0 and
             status in [:accepted, :running, :unknown, :succeeded, :failed] do
    if valid_report?(server_id, id, generation, report),
      do: apply_report(server_id, report),
      else: :ok
  end

  def observe(_server_id, _report), do: :ok

  defp valid_report?(server_id, id, generation, report)
       when is_integer(generation) and generation > 0 do
    Enum.all?([id, server_id], &match?({:ok, _}, Ecto.UUID.cast(&1))) and
      (is_nil(report[:error]) or is_binary(report[:error])) and
      (is_atom(report[:phase]) or is_binary(report[:phase]))
  end

  defp valid_report?(_server, _id, _generation, _report), do: false

  defp apply_report(server_id, %{id: id, generation: generation, sequence: sequence} = report) do
    report = verify_terminal_report(report)
    status = report.status

    report_query(id, server_id, generation, sequence)
    |> Repo.update_all(
      set: [
        status: status,
        sequence: sequence,
        phase: report[:phase] && to_string(report.phase),
        error: report[:error],
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  defp report_query(id, server_id, generation, sequence) do
    from(o in Operation,
      where: o.id == ^id and o.server_id == ^server_id and o.generation == ^generation,
      where: o.sequence < ^sequence or (o.sequence == ^sequence and o.status == :unknown),
      where: o.status not in [:succeeded, :failed]
    )
  end

  defp verify_terminal_report(%{status: :succeeded, id: id} = report) do
    case Repo.get(Operation, id) do
      nil ->
        report

      operation ->
        request = :erlang.binary_to_term(operation.request, [:safe])

        if report[:version] == request.spec.version and
             report[:release_id] == request.spec.release_id do
          report
        else
          %{report | status: :unknown} |> Map.put(:error, "agent terminal identity mismatch")
        end
    end
  end

  defp verify_terminal_report(report), do: report

  @doc "Waits by querying fast status RPCs, not by holding a deployment RPC open. Unknown work stays locked."
  @spec await(Operation.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def await(%Operation{} = operation, opts \\ []) do
    call = Keyword.get(opts, :caller, &remote_call/2)
    interval = Keyword.get(opts, :interval_ms, 1_000)
    poll(operation.id, call, interval)
  end

  defp poll(id, call, interval) do
    operation = Repo.get!(Operation, id)
    request = :erlang.binary_to_term(operation.request, [:safe])

    case operation.status do
      :succeeded ->
        {:ok, request.spec.version}

      :failed ->
        {:error, operation.error}

      _ ->
        contact(operation, request, call)

        Process.sleep(interval)

        poll(id, call, interval)
    end
  end

  defp contact(operation, request, call) do
    case AgentConnectionManager.get_agent_state(operation.server_id) do
      nil ->
        unknown(operation, "agent disconnected")

      %{node: node} = report ->
        if :durable_operations_v1 in Map.get(report, :capabilities, []),
          do: observe_remote(operation, request, node, call),
          else: unknown(operation, "agent upgrade required for durable operations")
    end
  end

  defp observe_remote(operation, request, node, call) do
    result = safe_call(call, node, {:status, operation.id})

    case result do
      {:ok, report} ->
        observe(operation.server_id, report)

      {:error, :not_found} when operation.sequence == 0 ->
        unknown(operation, "awaiting durable acceptance")

        case safe_call(call, node, {:submit, request}) do
          {:ok, report} -> observe(operation.server_id, report)
          {:error, reason} -> unknown(operation, inspect(reason))
        end

      {:error, :not_found} ->
        unknown(operation, "agent journal missing; refusing to replay observed work")

      {:error, reason} ->
        unknown(operation, inspect(reason))
    end
  end

  defp unknown(operation, error) do
    from(o in Operation,
      where:
        o.id == ^operation.id and o.sequence == ^operation.sequence and
          o.status not in [:succeeded, :failed]
    )
    |> Repo.update_all(set: [status: :unknown, error: error, updated_at: DateTime.utc_now()])

    :ok
  end

  defp safe_call(call, node, message) do
    call.(node, message)
  catch
    :exit, _ -> {:error, :connection_or_rpc_timeout}
  end

  defp remote_call(node, message), do: GenServer.call({OperationManager, node}, message, 5_000)

  @doc "Lists public operation progress for a deployment, omitting private command payloads."
  def list(deployment_id) when is_binary(deployment_id) do
    Repo.all(
      from o in Operation, where: o.deployment_id == ^deployment_id, order_by: o.inserted_at
    )
    |> Enum.map(&Map.take(&1, [:id, :server_id, :generation, :status, :sequence, :phase, :error]))
  end

  @doc "Returns persisted rollout order and private requests for controller recovery."
  def for_deployment(deployment_id) when is_binary(deployment_id) do
    Repo.all(
      from o in Operation,
        where: o.deployment_id == ^deployment_id,
        order_by: [asc: o.position, asc: o.id]
    )
  end

  @doc "Whether durable history still refers to a resource (requires coordinated decommission, not CRUD deletion)."
  def references?(field, id) when field in [:application_id, :server_id] and is_binary(id) do
    Repo.exists?(from o in Operation, where: field(o, ^field) == ^id)
  end
end
