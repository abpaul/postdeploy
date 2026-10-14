defmodule Alplus.Ingest.OperationalMonitor do
  @moduledoc "Low-cardinality self-monitoring and rate-limited overload alerts."

  use GenServer

  require Logger

  @table __MODULE__
  @interval_ms 10_000
  @handler_id "alplus-ingest-operational-monitor"
  @max_sources_per_window 1_000
  @memory_warning_bytes 1_500_000_000
  @process_warning_count 100_000
  @notification_backlog_limit 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec outcome(atom(), String.t() | nil, non_neg_integer(), non_neg_integer(), atom()) :: :ok
  def outcome(lane, source_id, accepted, rejected, status) do
    :telemetry.execute(
      [:alplus, :ingest, :outcome],
      %{accepted: accepted, rejected: rejected, count: 1},
      %{lane: lane, source_id: source_id, status: status}
    )

    :ok
  end

  @spec reserve_notification() :: :ok | {:error, :backlog_full}
  def reserve_notification do
    depth = :ets.update_counter(@table, :notification_backlog, {2, 1})

    if depth <= @notification_backlog_limit do
      :ok
    else
      _depth = :ets.update_counter(@table, :notification_backlog, {2, -1})
      {:error, :backlog_full}
    end
  rescue
    ArgumentError -> {:error, :backlog_full}
  end

  @spec release_notification() :: :ok
  def release_notification do
    _depth =
      :ets.update_counter(
        @table,
        :notification_backlog,
        {2, -1, 0, 0},
        {:notification_backlog, 0}
      )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> count_event(event, measurements, metadata)
    end
  end

  @impl GenServer
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    true = :ets.insert(table, {:notification_backlog, 0})

    :telemetry.attach_many(
      @handler_id,
      [
        [:alplus, :ingest, :admission, :rejected],
        [:alplus, :ingest, :analytics_engine, :dropped],
        [:alplus, :ingest, :visitor_state, :dropped],
        [:alplus, :ingest, :notification, :suppressed],
        [:alplus, :ingest, :outcome],
        [:alplus, :http, :response],
        [:alplus, :repo, :query]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, schedule(%{})}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    sample = sample()

    :telemetry.execute(
      [:alplus, :ingest, :runtime],
      Map.drop(sample, [:rejected, :analytics_dropped, :top_sources]),
      %{}
    )

    cond do
      alert?(sample) ->
        Logger.warning("ingest_overload " <> inspect(sample, limit: 30, printable_limit: 2_000))

      sample.accepted > 0 or sample.rejected_events > 0 ->
        Logger.info("ingest_activity " <> inspect(sample, limit: 30, printable_limit: 2_000))

      true ->
        :ok
    end

    {:noreply, schedule(state)}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  defp count_event([:alplus, :ingest, :admission, :rejected], measurements, _metadata) do
    increment(:rejected, measurements.count)
  end

  defp count_event([:alplus, :ingest, :analytics_engine, :dropped], measurements, _metadata) do
    increment(:analytics_dropped, measurements.count)
  end

  defp count_event([:alplus, :ingest, :visitor_state, :dropped], measurements, _metadata) do
    increment(:visitor_state_dropped, measurements.count)
  end

  defp count_event([:alplus, :ingest, :notification, :suppressed], measurements, _metadata) do
    increment(:notifications_suppressed, measurements.count)
  end

  defp count_event([:alplus, :ingest, :outcome], measurements, metadata) do
    increment({:outcome, :accepted}, measurements.accepted)
    increment({:outcome, :rejected}, measurements.rejected)
    count_source(metadata.source_id, metadata.lane, measurements.accepted + measurements.rejected)
  end

  defp count_event(
         [:alplus, :http, :response],
         measurements,
         %{status_class: :server_error}
       ) do
    increment(:http_5xx, measurements.count)
  end

  defp count_event([:alplus, :http, :response], _measurements, _metadata), do: :ok

  defp count_event([:alplus, :repo, :query], measurements, _metadata) do
    queue_time = Map.get(measurements, :queue_time, 0)
    increment(:db_queue_time, queue_time)
  end

  defp increment(key, value), do: :ets.update_counter(@table, key, {2, value}, {key, 0})

  defp sample do
    memory = :erlang.memory(:total)
    run_queue = :erlang.statistics(:run_queue)
    mailboxes = mailbox_lengths()
    visitor_state = visitor_state_stats()
    notification_backlog = notification_backlog()
    top_sources = take_top_sources()

    %{
      memory_bytes: memory,
      process_count: :erlang.system_info(:process_count),
      run_queue: run_queue,
      visitor_state_mailbox: Map.get(mailboxes, Alplus.Measure.VisitorState, 0),
      visitor_state_entries: visitor_state.entries,
      visitor_state_memory_bytes: visitor_state.memory_bytes,
      visitor_state_available: visitor_state.available,
      analytics_batcher_mailbox: Map.get(mailboxes, Alplus.Measure.AnalyticsEngine.Batcher, 0),
      analytics_buffer_depth: Alplus.Measure.AnalyticsEngine.Batcher.depth(),
      admission_concurrent: Alplus.Ingest.Admission.snapshot() |> Map.values() |> Enum.sum(),
      rejected: take_counter(:rejected),
      accepted: take_counter({:outcome, :accepted}),
      rejected_events: take_counter({:outcome, :rejected}),
      analytics_dropped: take_counter(:analytics_dropped),
      visitor_state_dropped: take_counter(:visitor_state_dropped),
      notifications_suppressed: take_counter(:notifications_suppressed),
      http_5xx: take_counter(:http_5xx),
      notification_backlog: notification_backlog,
      db_queue_time_native: take_counter(:db_queue_time),
      top_sources: top_sources
    }
  end

  defp count_source(nil, _lane, _count), do: :ok
  defp count_source(_source_id, _lane, 0), do: :ok

  defp count_source(source_id, lane, count) do
    key = {:source, lane, source_id}

    try do
      increment(key, count)
    rescue
      ArgumentError ->
        if :ets.info(@table, :size) < @max_sources_per_window do
          if :ets.insert_new(@table, {key, count}), do: :ok, else: increment(key, count)
        end
    end
  end

  defp take_top_sources do
    sources =
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn
        {{:source, _lane, _source_id}, _count} -> true
        _entry -> false
      end)

    Enum.each(sources, fn {key, _count} -> :ets.delete(@table, key) end)
    emit_tenant_rates(sources)

    sources
    |> Enum.sort_by(fn {_key, count} -> -count end)
    |> Enum.take(5)
    |> Enum.map(fn {{:source, lane, source_id}, count} ->
      %{lane: lane, source_id: source_id, events_per_10_seconds: count}
    end)
  end

  defp emit_tenant_rates(sources) do
    sources
    |> Enum.group_by(fn {{:source, lane, _source_id}, _count} -> lane end)
    |> Enum.each(fn {lane, lane_sources} ->
      {{:source, ^lane, source_id}, count} = Enum.max_by(lane_sources, &elem(&1, 1))

      :telemetry.execute(
        [:alplus, :ingest, :tenant_rate],
        %{events_per_window: count},
        %{lane: lane, source_id: source_id, window_seconds: div(@interval_ms, 1_000)}
      )
    end)
  end

  defp mailbox_lengths do
    [Alplus.Measure.VisitorState, Alplus.Measure.AnalyticsEngine.Batcher]
    |> Map.new(fn name ->
      length =
        case Process.whereis(name) do
          nil ->
            0

          pid ->
            case Process.info(pid, :message_queue_len) do
              {:message_queue_len, length} -> length
              nil -> 0
            end
        end

      {name, length}
    end)
  end

  defp take_counter(key) do
    case :ets.take(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp alert?(sample) do
    sample.rejected > 0 or sample.analytics_dropped > 0 or
      sample.visitor_state_dropped > 0 or sample.http_5xx > 0 or
      sample.notifications_suppressed > 0 or
      sample.memory_bytes >= @memory_warning_bytes or
      sample.process_count >= @process_warning_count or
      sample.run_queue >= :erlang.system_info(:schedulers_online) * 4 or
      sample.notification_backlog >= @notification_backlog_limit or
      sample.analytics_buffer_depth >= 800 or sample.visitor_state_mailbox >= 32 or
      sample.visitor_state_entries >= 225_000 or sample.visitor_state_available == 0 or
      sample.analytics_batcher_mailbox >= 100
  end

  defp visitor_state_stats do
    stats = Alplus.Measure.VisitorState.stats()
    Map.put(stats, :available, 1)
  catch
    :exit, _reason -> %{entries: 0, memory_bytes: 0, available: 0}
  end

  defp notification_backlog do
    result =
      Alplus.Repo.query(
        """
        SELECT count(*)
        FROM (
          SELECT 1 FROM oban_jobs
          WHERE queue = 'notify' AND state IN ('available', 'scheduled', 'retryable', 'executing')
          LIMIT $1
        ) pending
        """,
        [@notification_backlog_limit + 1],
        timeout: 1_000
      )

    depth =
      case result do
        {:ok, %{rows: [[depth]]}} -> depth
        {:error, _reason} -> @notification_backlog_limit
      end

    true = :ets.insert(@table, {:notification_backlog, depth})
    depth
  end

  defp schedule(state) do
    Process.send_after(self(), :sample, @interval_ms)
    state
  end
end
