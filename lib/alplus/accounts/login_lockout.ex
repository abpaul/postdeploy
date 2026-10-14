defmodule Alplus.Accounts.LoginLockout do
  @moduledoc """
  Locks a sign-in identity (email or IP) after too many failed password
  attempts in a rolling window.

  Counters live in an ETS table owned by this GenServer (ARCHITECTURE.md
  §6: create a process for live, in-memory state; keep durable state in
  Postgres). Writes go through the GenServer so increments never race;
  reads hit the ETS table directly for speed.

  Every function takes `now` explicitly so tests can use a fixed clock
  instead of sleeping through the 15-minute window.
  """

  use GenServer

  @table __MODULE__
  @max_attempts 10
  @window_seconds 15 * 60
  @sweep_interval_ms 5 * 60 * 1000

  @type key :: {:email, String.t()} | {:ip, String.t()}

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns `true` if `key` has hit the failure threshold within the window."
  @spec locked?(key, DateTime.t()) :: boolean()
  def locked?(key, now \\ DateTime.utc_now()) do
    count(key, now) >= @max_attempts
  end

  @doc "Records a failed attempt for `key`."
  @spec record_failure(key, DateTime.t()) :: :ok
  def record_failure(key, now \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:record_failure, key, now})
  end

  @doc "Clears the failure counter for `key` (call on a successful sign-in)."
  @spec clear(key) :: :ok
  def clear(key) do
    GenServer.call(__MODULE__, {:clear, key})
  end

  @doc false
  @spec count(key, DateTime.t()) :: non_neg_integer()
  def count(key, now \\ DateTime.utc_now()) do
    ensure_table!()

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] -> Enum.count(timestamps, &within_window?(&1, now))
      [] -> 0
    end
  end

  # GenServer callbacks

  @doc """
  Deletes every key whose timestamps all fall outside the window.

  Keys come from attacker-controlled input: any email string, any source IP.
  Without a sweep the table grows without bound, so a rotating-IP attack
  becomes a memory-exhaustion attack. The periodic tick calls this; tests
  call it directly with a fixed clock.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:sweep, now})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:record_failure, key, now}, _from, state) do
    existing =
      case :ets.lookup(@table, key) do
        [{^key, timestamps}] -> timestamps
        [] -> []
      end

    pruned = Enum.filter(existing, &within_window?(&1, now))
    :ets.insert(@table, {key, [now | pruned]})
    {:reply, :ok, state}
  end

  def handle_call({:clear, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  def handle_call({:sweep, now}, _from, state) do
    {:reply, do_sweep(now), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(DateTime.utc_now())
    schedule_sweep()
    {:noreply, state}
  end

  defp do_sweep(now) do
    :ets.foldl(
      fn {key, timestamps}, deleted ->
        case Enum.filter(timestamps, &within_window?(&1, now)) do
          [] ->
            :ets.delete(@table, key)
            deleted + 1

          kept ->
            :ets.insert(@table, {key, kept})
            deleted
        end
      end,
      0,
      @table
    )
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp within_window?(timestamp, now) do
    DateTime.diff(now, timestamp, :second) < @window_seconds
  end

  # The application supervisor starts exactly one of these; this guards
  # against calling `count/2` before that process has booted.
  defp ensure_table! do
    if :ets.whereis(@table) == :undefined do
      raise "#{inspect(__MODULE__)} is not started; add it to the supervision tree"
    end

    :ok
  end
end
