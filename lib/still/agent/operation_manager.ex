defmodule Still.Agent.OperationManager do
  @moduledoc "Durable asynchronous admission and per-application supervised execution."
  use GenServer

  alias Still.Agent.DeploymentManager
  alias Still.Agent.NodeConnector
  alias Still.Agent.OperationJournal
  alias Still.Protocol.OperationRequest

  @terminal [:succeeded, :failed]
  @confirmable [:pre_deploy, :release, :post_deploy, :pre_rollback, :post_rollback, :starting]

  @doc "Starts admission and re-observation of incomplete journaled operations."
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Accepts an operation after its journal has been synced."
  def submit(%OperationRequest{} = request), do: GenServer.call(__MODULE__, {:submit, request})

  @doc "Queries durable progress without waiting for workload execution."
  def status(id) when is_binary(id), do: GenServer.call(__MODULE__, {:status, id})

  @doc "Returns redacted nonterminal progress for reconnect announcements."
  def reports, do: GenServer.call(__MODULE__, :reports)

  @doc "Re-observes a paused operation after host repair; never replays an ambiguous hook."
  def recover(id) when is_binary(id), do: GenServer.call(__MODULE__, {:recover, id, nil})

  @doc "Operator attestation that an interrupted side effect completed; inspect the host first."
  def confirm_phase(id, phase) when is_binary(id) and is_atom(phase),
    do: GenServer.call(__MODULE__, {:recover, id, phase})

  @doc "Serializes a legacy mutation with durable workers for the same application on this node."
  def locked(application, fun) when is_binary(application) and is_function(fun, 0),
    do: :global.trans({{__MODULE__, application}, self()}, fun, [node()])

  @doc "Whether durable nonterminal work reserves an application."
  def busy?(application) when is_binary(application) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:busy, application}),
      else: journal_blocks?(application, :active)
  end

  @doc "Legacy deploy commands are fenced out permanently once this application has durable history."
  def legacy_allowed?(application) when is_binary(application) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:legacy_allowed, application}),
      else: not journal_blocks?(application, :history)
  end

  defp journal_blocks?(app, mode) do
    case OperationJournal.list() do
      {:ok, records} ->
        Enum.any?(records, fn record ->
          record.request.spec.application == app and
            (mode == :history or record.status not in @terminal)
        end)

      {:error, _} ->
        true
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    {records, fault} = load_records()
    send(self(), :recover)

    {:ok,
     %{
       records: records,
       workers: %{},
       supervisor: supervisor,
       fault: fault,
       executor: Keyword.get(opts, :executor, &DeploymentManager.execute_operation/2)
     }}
  end

  defp load_records do
    case OperationJournal.list() do
      {:ok, records} -> {Map.new(records, &{&1.id, &1}), nil}
      {:error, reason} -> {%{}, reason}
    end
  end

  @impl true
  def handle_call({:submit, request}, _from, state) when is_map(state) do
    with :ok <- OperationRequest.validate(request), :ok <- admission(request, state) do
      accept(request, state)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:status, id}, _from, state) when is_map(state),
    do: {:reply, public_status(state.records[id], state.fault), state}

  def handle_call(:reports, _from, state) when is_map(state) do
    reports =
      state.records
      |> Map.values()
      |> Enum.reject(&(&1.status in @terminal))
      |> Enum.map(&OperationJournal.report/1)

    {:reply, reports, state}
  end

  def handle_call({:busy, app}, _from, state) when is_map(state),
    do: {:reply, state.fault != nil or active?(state, app), state}

  def handle_call({:legacy_allowed, app}, _from, state) when is_map(state) do
    history? =
      Enum.any?(state.records, fn {_, record} -> record.request.spec.application == app end)

    {:reply, is_nil(state.fault) and not history?, state}
  end

  def handle_call({:recover, id, phase}, {caller, _}, state) when is_map(state) do
    case recoverable(state, id, phase) do
      :ok ->
        record =
          confirm(state.records[id], phase, caller) |> advance(%{status: :accepted, error: nil})

        accept_record(record, state)

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:checkpoint, id, patch}, {pid, _}, state) when is_map(state) do
    if worker?(state, id, pid) and state.records[id].status not in @terminal do
      record =
        advance(
          state.records[id],
          Map.take(patch, [:status, :phase, :completed, :context, :version, :error])
        )

      case store(state, record) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, %{state | fault: reason}}
      end
    else
      {:reply, {:error, :stale_worker}, state}
    end
  end

  defp accept(request, state) do
    case state.records[request.id] do
      nil ->
        record = %{
          format: 1,
          id: request.id,
          generation: request.generation,
          request: request,
          fingerprint: OperationJournal.fingerprint(request),
          sequence: 1,
          status: :accepted,
          phase: nil,
          completed: [],
          context: nil,
          version: request.spec.version,
          error: nil
        }

        accept_record(record, state)

      record ->
        {:reply, {:ok, OperationJournal.report(record)}, state}
    end
  end

  defp accept_record(record, state) do
    case store(state, record) do
      {:ok, updated} -> {:reply, {:ok, OperationJournal.report(record)}, launch(updated, record)}
      {:error, reason} -> {:reply, {:error, reason}, %{state | fault: reason}}
    end
  end

  defp public_status(%{status: status} = record, _) when status in @terminal,
    do: {:ok, OperationJournal.report(record)}

  defp public_status(_, fault) when not is_nil(fault), do: {:error, :journal_unavailable}
  defp public_status(nil, _), do: {:error, :not_found}
  defp public_status(record, _), do: {:ok, OperationJournal.report(record)}

  defp recoverable(%{fault: fault}, _, _) when not is_nil(fault),
    do: {:error, :journal_unavailable}

  defp recoverable(state, id, phase) do
    record = state.records[id]

    cond do
      is_nil(record) -> {:error, :not_found}
      record.status != :unknown or worker?(state, id) -> {:error, :not_paused}
      is_nil(phase) -> :ok
      phase in @confirmable and phase == record.phase -> :ok
      true -> {:error, :invalid_confirmation}
    end
  end

  defp confirm(record, nil, _caller), do: record

  defp confirm(record, phase, caller) do
    confirmation = %{
      phase: phase,
      at: DateTime.to_iso8601(DateTime.utc_now()),
      node: to_string(node(caller))
    }

    record
    |> Map.merge(%{phase: nil, completed: Enum.uniq(record.completed ++ [phase])})
    |> Map.update(:operator_confirmations, [confirmation], &[confirmation | &1])
  end

  @impl true
  def handle_info(:recover, state) when is_map(state) do
    active = state.records |> Map.values() |> Enum.reject(&(&1.status in @terminal))

    conflicts? =
      active
      |> Enum.frequencies_by(& &1.request.spec.application)
      |> Enum.any?(fn {_, n} -> n > 1 end)

    if conflicts? or state.fault != nil do
      {:noreply, %{state | fault: state.fault || :conflicting_journals}}
    else
      {:noreply, Enum.reduce(active, state, &launch(&2, &1))}
    end
  end

  def handle_info({ref, _result}, state) when is_reference(ref) and is_map(state) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{id: id}, workers} ->
        {:noreply, worker_down(%{state | workers: workers}, state.records[id])}
    end
  end

  def handle_info({:recover_one, id}, state) when is_map(state) do
    record = state.records[id]

    if record && record.status == :unknown && is_nil(state.fault) && not worker?(state, id),
      do: {:noreply, launch(state, record)},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_map(state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{id: id}, workers} ->
        {:noreply, worker_down(%{state | workers: workers}, state.records[id])}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor)
    :ok
  end

  defp worker_down(state, %{status: status}) when status in @terminal, do: state

  defp worker_down(state, record) do
    retry? = not Map.get(record, :recovery_attempted, false)

    updated =
      record
      |> Map.put(:recovery_attempted, true)
      |> advance(%{
        status: :unknown,
        error: record.error || "worker exited; observing host before recovery"
      })

    case store(state, updated) do
      {:ok, state} ->
        if retry?, do: send(self(), {:recover_one, record.id})
        state

      {:error, reason} ->
        %{state | fault: reason}
    end
  end

  defp admission(_request, %{fault: fault}) when not is_nil(fault),
    do: {:error, :journal_unavailable}

  defp admission(request, state) do
    existing = state.records[request.id]
    app = request.spec.application

    highest =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.request.spec.application == app))
      |> Enum.map(& &1.generation)
      |> Enum.max(fn -> 0 end)

    cond do
      existing && existing.fingerprint != OperationJournal.fingerprint(request) ->
        {:error, :operation_conflict}

      existing != nil ->
        :ok

      active?(state, app) ->
        {:error, :operation_in_progress}

      request.generation <= highest ->
        {:error, :stale_generation}

      true ->
        :ok
    end
  end

  defp active?(state, app),
    do:
      Enum.any?(state.records, fn {_, r} ->
        r.request.spec.application == app and r.status not in @terminal
      end)

  defp worker?(state, id, pid \\ nil),
    do: Enum.any?(state.workers, fn {_, w} -> w.id == id and (is_nil(pid) or w.pid == pid) end)

  defp advance(record, patch), do: record |> Map.merge(patch) |> Map.update!(:sequence, &(&1 + 1))

  defp store(state, record) do
    with :ok <- OperationJournal.write(record) do
      notify(record)
      {:ok, put_in(state.records[record.id], record)}
    end
  end

  defp launch(state, record) do
    manager = self()
    executor = state.executor

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        locked(record.request.spec.application, fn ->
          executor.(record, &checkpoint(manager, record.id, &1))
        end)
      end)

    put_in(state.workers[task.ref], %{id: record.id, pid: task.pid})
  end

  defp checkpoint(manager, id, patch) do
    case GenServer.call(manager, {:checkpoint, id, patch}, :infinity) do
      :ok -> :ok
      {:error, reason} -> exit(reason)
    end
  end

  defp notify(record) do
    if Process.whereis(NodeConnector),
      do: GenServer.cast(NodeConnector, {:report_operation, OperationJournal.report(record)})
  end
end
