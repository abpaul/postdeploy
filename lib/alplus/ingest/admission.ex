defmodule Alplus.Ingest.Admission do
  @moduledoc """
  Bounded admission control for public telemetry writes.

  Each product has a separate global lane. Each authenticated Source also has
  a smaller lane. The counters use atomics, so overload rejection cannot build
  a GenServer mailbox. Phoenix endpoint telemetry releases every lease, even
  when a controller raises before it sends a response.
  """

  use GenServer

  @handler_id "alplus-ingest-admission-release"
  @table __MODULE__
  @process_key {__MODULE__, :leases}
  @global_limits %{
    errors: 16,
    sessions: 8,
    measure: 16,
    heartbeat: 8,
    artifacts: 2,
    product_events: 16
  }
  @tenant_limits %{
    errors: 2,
    sessions: 2,
    measure: 2,
    heartbeat: 2,
    artifacts: 1,
    product_events: 2
  }

  @type lane :: :errors | :sessions | :measure | :heartbeat | :artifacts | :product_events
  @type scope :: :global | {:tenant, String.t()}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec acquire(lane(), scope()) :: :ok | {:error, :overloaded}
  def acquire(lane, scope) when is_map_key(@global_limits, lane) do
    key = counter_key(lane, scope)
    limit = limit(lane, scope)
    counter = counter(key)

    if :atomics.add_get(counter, 1, 1) <= limit do
      Process.put(@process_key, [key | Process.get(@process_key, [])])
      emit(:accepted, lane, scope, current(counter))
      :ok
    else
      :atomics.sub(counter, 1, 1)
      emit(:rejected, lane, scope, current(counter))
      {:error, :overloaded}
    end
  end

  @spec release_all() :: :ok
  def release_all do
    @process_key
    |> Process.delete()
    |> List.wrap()
    |> Enum.each(fn key ->
      counter = counter(key)
      _remaining = :atomics.sub(counter, 1, 1)
    end)

    :ok
  end

  @spec snapshot() :: %{optional(term()) => non_neg_integer()}
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {key, counter} -> {key, current(counter)} end)
  end

  @doc false
  def handle_endpoint_event([:phoenix, :endpoint, :stop], _measurements, metadata, _config) do
    release_all()

    status =
      case metadata do
        %{conn: %{status: status}} when is_integer(status) -> status_class(status)
        _metadata -> :unknown
      end

    :telemetry.execute([:alplus, :http, :response], %{count: 1}, %{status_class: status})
  end

  def handle_endpoint_event([:phoenix, :endpoint, :exception], _measurements, _metadata, _config) do
    release_all()
    :telemetry.execute([:alplus, :http, :response], %{count: 1}, %{status_class: :server_error})
  end

  @impl GenServer
  def init(:ok) do
    counters =
      for lane <- Map.keys(@global_limits), into: %{} do
        {{lane, :global}, new_counter()}
      end

    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, Map.to_list(counters))

    :telemetry.attach_many(
      @handler_id,
      [[:phoenix, :endpoint, :stop], [:phoenix, :endpoint, :exception]],
      &__MODULE__.handle_endpoint_event/4,
      nil
    )

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  defp counter_key(lane, :global), do: {lane, :global}
  defp counter_key(lane, {:tenant, source_id}), do: {lane, {:tenant, source_id}}

  defp limit(lane, :global), do: Map.fetch!(@global_limits, lane)
  defp limit(lane, {:tenant, _source_id}), do: Map.fetch!(@tenant_limits, lane)

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, counter}] ->
        counter

      [] ->
        GenServer.call(__MODULE__, {:counter, key})
    end
  end

  @impl GenServer
  def handle_call({:counter, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, counter}] ->
        {:reply, counter, state}

      [] ->
        counter = new_counter()
        true = :ets.insert(@table, {key, counter})
        {:reply, counter, state}
    end
  end

  defp new_counter do
    counter = :atomics.new(1, signed: false)
    :atomics.put(counter, 1, 0)
    counter
  end

  defp current(counter), do: :atomics.get(counter, 1)

  defp emit(decision, lane, scope, concurrent) do
    :telemetry.execute(
      [:alplus, :ingest, :admission, decision],
      %{count: 1, concurrent: concurrent},
      %{lane: lane, scope: scope_type(scope)}
    )
  end

  defp scope_type(:global), do: :global
  defp scope_type({:tenant, _source_id}), do: :tenant

  defp status_class(status) when status in 100..199, do: :informational
  defp status_class(status) when status in 200..299, do: :success
  defp status_class(status) when status in 300..399, do: :redirect
  defp status_class(status) when status in 400..499, do: :client_error
  defp status_class(status) when status in 500..599, do: :server_error
  defp status_class(_status), do: :unknown
end
