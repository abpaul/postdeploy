defmodule Alplus.Measure.VisitorState do
  @moduledoc false
  use GenServer

  @ttl_ms :timer.minutes(30)
  @cleanup_interval_ms :timer.minutes(1)
  @default_max_entries 250_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def update(key, now, fun), do: GenServer.call(__MODULE__, {:update, key, now, fun})

  @doc "Updates visit state without running persistence work in this process."
  def transition(key, now, hit), do: GenServer.call(__MODULE__, {:transition, key, now, hit})

  @doc false
  def transition(server, key, now, hit), do: GenServer.call(server, {:transition, key, now, hit})

  @doc false
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :private, read_concurrency: true])
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, %{table: table, max_entries: max_entries}}
  end

  @impl true
  def handle_call({:update, key, now, fun}, _from, state) do
    current = current_state(state.table, key, now)
    {result, next_state} = fun.(current)
    store(state, key, now, next_state)
    {:reply, result, state}
  end

  def handle_call({:transition, key, now, hit}, _from, state) do
    visitor_state = current_state(state.table, key, now)
    {deltas, next_state} = Alplus.Measure.Hit.deltas(visitor_state, hit, now)
    store(state, key, now, next_state)
    {:reply, deltas, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      entries: :ets.info(state.table, :size),
      memory_bytes: :ets.info(state.table, :memory) * :erlang.system_info(:wordsize),
      max_entries: state.max_entries
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    delete_expired(state.table, System.system_time(:millisecond))
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end

  defp current_state(table, key, now) do
    case :ets.lookup(table, key) do
      [{^key, expires_at, state}] when expires_at > now -> state
      _ -> nil
    end
  end

  defp store(state, key, now, next_state) do
    new_key? = not :ets.member(state.table, key)

    if not new_key? or :ets.info(state.table, :size) < state.max_entries do
      true = :ets.insert(state.table, {key, now + @ttl_ms, next_state})
    else
      :telemetry.execute(
        [:alplus, :ingest, :visitor_state, :dropped],
        %{count: 1},
        %{reason: :capacity}
      )
    end
  end

  defp delete_expired(table, now) do
    :ets.select_delete(table, [{{:"$1", :"$2", :"$3"}, [{:"=<", :"$2", now}], [true]}])
  end
end
