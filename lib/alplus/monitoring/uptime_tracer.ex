defmodule Alplus.Monitoring.UptimeTracer do
  @moduledoc """
  Shapes scoped monitor evidence into interval-aligned uptime buckets.

  The tracer owns time boundaries and state classification. It does not
  interpolate missing checks, calculate an SLO, or calculate a percentile.
  Each bucket is a direct view of the checks, incidents, and pause intervals
  that overlap it. A table row is emitted from the same bucket as the compact
  display data, so the two views cannot drift.

  `trace/5` accepts already-authorized records. Pass `scope:` when the caller
  wants this boundary to reject records from another monitor, project, or
  organization. Database reads remain in the monitor activity boundary, where
  the project actor and explicit tenant filters are available.

  `trace/5` and its private helpers are a pure fold: same inputs, same trace,
  no I/O. `aggregate_checks!/5,6` and the scope validation both cross a
  boundary the fold does not, so they live in
  `Alplus.Monitoring.UptimeTracer.Checks` and are re-exported here.
  """

  alias Alplus.Monitoring.UptimeTracer.Checks

  @typedoc "The state represented by one check interval."
  @type bucket_state ::
          :up | :down | :slow | :missing | :paused | :anomaly | :partial

  @typedoc "The state of the complete trace."
  @type trace_state :: :ready | :partial | :anomaly | :empty | :error

  @type t :: %{
          kind: :ticks,
          state: trace_state(),
          buckets: [map()],
          table_rows: [map()],
          counts: map(),
          coverage_ratio: float() | nil,
          base_interval_seconds: pos_integer() | nil,
          interval_seconds: pos_integer() | nil,
          range: map() | nil,
          legend: [map()],
          summary: String.t(),
          description: String.t()
        }

  @legend_order [:up, :down, :slow, :paused, :missing, :partial, :anomaly]
  @max_bucket_count 1_440

  @doc "Returns the explicit empty trace used when a panel has no evidence."
  @spec empty() :: t()
  def empty do
    %{
      kind: :ticks,
      state: :empty,
      buckets: [],
      table_rows: [],
      counts: %{},
      coverage_ratio: nil,
      base_interval_seconds: nil,
      interval_seconds: nil,
      range: nil,
      legend: [],
      summary: "No uptime evidence yet",
      description: "No uptime evidence is available for this range."
    }
  end

  @doc """
  Returns a check-interval-aligned display interval bounded to 1,440 buckets.

  A larger interval is an exact grouping of the monitor interval. It does not
  interpolate checks or hide a state inside a bucket.
  """
  @spec display_interval_seconds(DateTime.t(), DateTime.t(), pos_integer() | nil) ::
          pos_integer() | nil
  def display_interval_seconds(%DateTime{} = window_start, %DateTime{} = window_end, interval)
      when is_integer(interval) and interval > 0 do
    bounded_interval_seconds(window_start, window_end, interval)
  end

  def display_interval_seconds(_window_start, _window_end, _interval), do: nil

  @doc """
  Returns the exact UTC bucket grid for a dashboard period.

  The current UTC hour is included in `24h`. Calendar periods include today.
  The returned end is exclusive.
  """
  @spec timeline_bounds(String.t(), DateTime.t()) ::
          {DateTime.t(), DateTime.t(), pos_integer(), pos_integer()}
  def timeline_bounds(window, now \\ DateTime.utc_now())

  def timeline_bounds("24h", %DateTime{} = now) do
    current_hour = %{now | minute: 0, second: 0, microsecond: {0, 0}}
    {DateTime.add(current_hour, -23, :hour), DateTime.add(current_hour, 1, :hour), 3_600, 24}
  end

  def timeline_bounds(window, %DateTime{} = now) when window in ["7d", "30d"] do
    days = if(window == "7d", do: 7, else: 30)
    today = DateTime.to_date(now)
    start_at = today |> Date.add(-(days - 1)) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    end_at = today |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    {start_at, end_at, 86_400, days}
  end

  def timeline_bounds("90d", %DateTime{} = now) do
    today = DateTime.to_date(now)
    start_at = today |> Date.add(-89) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    end_at = today |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    {start_at, end_at, 86_400, 90}
  end

  @doc """
  Aggregates all checks into bounded, aligned evidence rows in PostgreSQL.

  The query returns one row per monitor and display interval, not one row per
  check. It preserves the count and the complete state precedence signals.
  """
  @spec aggregate_checks!(
          String.t(),
          String.t(),
          [{String.t(), pos_integer(), pos_integer()}],
          DateTime.t(),
          DateTime.t(),
          map() | nil
        ) :: %{String.t() => [map()]}
  defdelegate aggregate_checks!(
                org_id,
                project_id,
                monitor_intervals,
                window_start,
                window_end,
                scope
              ),
              to: Checks

  @spec aggregate_checks!(
          String.t(),
          String.t(),
          [{String.t(), pos_integer(), pos_integer()}],
          DateTime.t(),
          DateTime.t()
        ) :: %{String.t() => [map()]}
  defdelegate aggregate_checks!(org_id, project_id, monitor_intervals, window_start, window_end),
    to: Checks

  @doc """
  Builds interval-aligned buckets from monitor evidence.

  The first bucket starts at the UTC Unix interval boundary at or before the
  requested start. The last bucket ends at the boundary at or after the
  requested end. This keeps adjacent ranges on the same check grid.

  Supported options are `:incidents`, `:pauses`, `:scope`,
  `:bucket_evidence`, `:base_interval_seconds`, `:now`, and
  `:missing_is_failure`.

  A bucket with no checks is `:missing`, never `:down`, even while an
  incident is open: absence of evidence is not evidence of failure. The one
  exception is `missing_is_failure: true`, which a heartbeat monitor passes,
  because for a heartbeat the missing ping *is* the evaluated failure once an
  incident marks the deadline as passed. `:now` clips the bucket in progress
  so its expected interval count and its label say "so far", not "missing". `:bucket_evidence`
  contains the bounded rows returned by `aggregate_checks!/5`; its effective
  display interval is the fourth argument and its base monitor interval is
  passed in the options. Incident and pause records use
  `started_at`/`resolved_at` and `paused_at`/`resumed_at`.
  """
  @spec trace([map()], DateTime.t(), DateTime.t(), pos_integer() | nil, keyword()) :: t()
  def trace(checks, window_start, window_end, interval_seconds, options \\ [])
      when is_list(checks) and is_list(options) do
    incidents = Keyword.get(options, :incidents, [])
    pauses = Keyword.get(options, :pauses, [])
    bucket_evidence = Keyword.get(options, :bucket_evidence, [])
    scope = Keyword.get(options, :scope)
    base_interval_seconds = Keyword.get(options, :base_interval_seconds, interval_seconds)
    now = Keyword.get(options, :now)
    missing_is_failure = Keyword.get(options, :missing_is_failure, false)

    Checks.validate_records!(checks, incidents, pauses, scope)
    Checks.validate_bucket_evidence!(bucket_evidence, scope)

    with {:ok, start_at} <- utc_datetime(window_start),
         {:ok, end_at} <- utc_datetime(window_end),
         :ok <- validate_window(start_at, end_at),
         {:ok, interval} <- validate_interval(interval_seconds),
         {:ok, base_interval} <- validate_interval(base_interval_seconds),
         :ok <- validate_interval_relationship(base_interval, interval) do
      interval = bounded_interval_seconds(start_at, end_at, interval)
      checks = Enum.filter(checks, &within_window?(&1, :checked_at, start_at, end_at))

      incidents =
        Enum.filter(incidents, &overlaps_window?(&1, :started_at, :resolved_at, start_at, end_at))

      pauses =
        Enum.filter(pauses, &overlaps_window?(&1, :paused_at, :resumed_at, start_at, end_at))

      if checks == [] and bucket_evidence == [] and incidents == [] and pauses == [] do
        empty_with_range(start_at, end_at, base_interval, interval)
      else
        build_trace(
          checks,
          incidents,
          pauses,
          bucket_evidence,
          start_at,
          end_at,
          base_interval,
          interval,
          %{now: now, missing_is_failure: missing_is_failure}
        )
      end
    else
      {:error, message} -> error_trace(message)
    end
  end

  @doc "Rejects evidence whose tenant or monitor identity differs from `scope`."
  @spec validate_scope!([map()], map()) :: :ok
  defdelegate validate_scope!(records, scope), to: Checks

  defp build_trace(
         checks,
         incidents,
         pauses,
         bucket_evidence,
         start_at,
         end_at,
         base_interval,
         interval,
         rules
       ) do
    aligned_start = align_start(start_at, interval)
    aligned_end = align_end(end_at, interval)
    # The bucket in progress only expects the intervals that have passed.
    evidence_end = clip_end(end_at, rules.now)
    # Raw Postgrex timestamps can retain a microsecond precision tuple while
    # grid-aligned tracer boundaries come from Unix seconds. Unix keys make
    # the same interval canonical across both representations.
    evidence_by_start = Map.new(bucket_evidence, &{DateTime.to_unix(&1.start_at), &1})

    buckets =
      aligned_start
      |> bucket_starts(aligned_end, interval)
      |> Enum.map(fn bucket_start ->
        bucket_end = DateTime.add(bucket_start, interval, :second)

        in_progress? = in_progress?(bucket_start, bucket_end, rules.now)

        case Map.get(evidence_by_start, DateTime.to_unix(bucket_start)) do
          nil ->
            bucket_checks = checks_in_bucket(checks, bucket_start, bucket_end)

            state =
              bucket_state(bucket_checks, incidents, pauses, bucket_start, bucket_end, rules)

            expected_interval_count =
              expected_interval_count(
                bucket_start,
                bucket_end,
                start_at,
                evidence_end,
                base_interval
              )

            bucket(
              bucket_start,
              bucket_end,
              state,
              bucket_checks,
              nil,
              %{
                expected_interval_count: expected_interval_count,
                covered_interval_count: if(bucket_checks == [], do: 0, else: 1),
                missing_interval_count:
                  if(bucket_checks == [], do: expected_interval_count, else: 0),
                base_interval_seconds: base_interval,
                interval_seconds: interval,
                state_counts: state_counts_for_checks(bucket_checks),
                in_progress?: in_progress?
              }
            )

          evidence ->
            evidence =
              normalize_evidence(
                evidence,
                bucket_start,
                bucket_end,
                start_at,
                evidence_end,
                base_interval
              )

            state =
              aggregate_bucket_state(
                evidence,
                incidents,
                pauses,
                bucket_start,
                bucket_end,
                rules
              )

            bucket(
              bucket_start,
              bucket_end,
              state,
              [],
              evidence.check_count,
              Map.put(evidence, :in_progress?, in_progress?)
            )
        end
      end)

    counts = Enum.frequencies_by(buckets, & &1.state)
    missing_count = Map.get(counts, :missing, 0)
    anomaly_count = Map.get(counts, :anomaly, 0)
    total = length(buckets)
    missing_intervals = Enum.sum(Enum.map(buckets, & &1.missing_interval_count))
    expected_intervals = Enum.sum(Enum.map(buckets, & &1.expected_interval_count))
    covered_intervals = Enum.sum(Enum.map(buckets, & &1.covered_interval_count))

    %{
      kind: :ticks,
      state: trace_state(anomaly_count, missing_count, missing_intervals),
      buckets: buckets,
      table_rows: Enum.map(buckets, &table_row/1),
      counts: counts,
      coverage_ratio:
        if(expected_intervals == 0, do: nil, else: covered_intervals / expected_intervals),
      base_interval_seconds: base_interval,
      interval_seconds: interval,
      range: range(start_at, end_at, aligned_start, aligned_end, base_interval, interval),
      legend: legend(counts),
      summary: summary(counts, total, missing_intervals, expected_intervals),
      description:
        "Uptime buckets from #{format_datetime(aligned_start)} to #{format_datetime(aligned_end)}. Each bucket is #{format_duration(interval)} wide and aggregates checks on the #{format_duration(base_interval)} monitor interval grid. Missing intervals are separate from down intervals."
    }
  end

  defp bucket(start_at, end_at, state, checks, check_count, metadata) do
    check_count = check_count || length(checks)
    expected_interval_count = Map.get(metadata, :expected_interval_count, 1)

    covered_interval_count =
      Map.get(metadata, :covered_interval_count, if(check_count > 0, do: 1, else: 0))

    missing_interval_count =
      Map.get(
        metadata,
        :missing_interval_count,
        max(expected_interval_count - covered_interval_count, 0)
      )

    interval = Map.get(metadata, :interval_seconds, DateTime.diff(end_at, start_at, :second))
    base_interval = Map.get(metadata, :base_interval_seconds, interval)
    state_counts = Map.get(metadata, :state_counts, state_counts_for_checks(checks))
    partial? = (covered_interval_count > 0 and missing_interval_count > 0) or state == :partial
    in_progress? = Map.get(metadata, :in_progress?, false)
    state_label = state_label(state)
    interval_label = "#{format_datetime(start_at)} to #{format_datetime(end_at)}"

    width_label = format_duration(interval)

    coverage_label =
      "#{covered_interval_count} of #{expected_interval_count} monitor intervals covered"

    missing_label =
      if missing_interval_count > 0, do: ", #{missing_interval_count} missing", else: ""

    progress_label = if in_progress?, do: ", in progress", else: ""

    value_label = "#{state_label}, #{check_count} checks, #{width_label} bucket#{progress_label}"

    table_cells = [
      format_datetime(start_at),
      format_datetime(end_at),
      state_label,
      Integer.to_string(check_count),
      width_label,
      coverage_label,
      Integer.to_string(missing_interval_count)
    ]

    %{
      start_at: start_at,
      end_at: end_at,
      state: state,
      kind: state,
      tone: tone(state),
      value: value_label,
      label: state_label,
      aria_label: "#{interval_label}, #{value_label}, #{coverage_label}#{missing_label}",
      tooltip: "#{interval_label}, #{value_label}, #{coverage_label}#{missing_label}",
      check_count: check_count,
      checks: checks,
      base_interval_seconds: base_interval,
      interval_seconds: interval,
      expected_interval_count: expected_interval_count,
      covered_interval_count: covered_interval_count,
      missing_interval_count: missing_interval_count,
      partial?: partial?,
      in_progress?: in_progress?,
      state_counts: state_counts,
      table_cells: table_cells
    }
  end

  defp clip_end(end_at, %DateTime{} = now), do: min_datetime(end_at, now)
  defp clip_end(end_at, _now), do: end_at

  defp in_progress?(bucket_start, bucket_end, %DateTime{} = now) do
    DateTime.compare(now, bucket_start) != :lt and DateTime.compare(now, bucket_end) == :lt
  end

  defp in_progress?(_bucket_start, _bucket_end, _now), do: false

  defp table_row(bucket) do
    %{
      id: "#{DateTime.to_unix(bucket.start_at)}",
      cells: bucket.table_cells,
      state: bucket.state
    }
  end

  defp bucket_state(checks, incidents, pauses, bucket_start, bucket_end, rules) do
    cond do
      Enum.any?(pauses, &overlaps?(&1, :paused_at, :resumed_at, bucket_start, bucket_end)) ->
        :paused

      Enum.any?(checks, &check_anomaly?/1) ->
        :anomaly

      Enum.any?(checks, &(normalise_status(&1) == "down")) ->
        :down

      # An open incident proves failure only where something was observed, or
      # where the missing observation is itself the failure (a heartbeat).
      (checks != [] or rules.missing_is_failure) and
          Enum.any?(
            incidents,
            &overlaps?(&1, :started_at, :resolved_at, bucket_start, bucket_end)
          ) ->
        :down

      Enum.any?(checks, &(normalise_status(&1) == "degraded")) ->
        :slow

      Enum.any?(checks, &(normalise_status(&1) == "up")) ->
        :up

      true ->
        :missing
    end
  end

  defp normalize_evidence(
         evidence,
         bucket_start,
         bucket_end,
         window_start,
         window_end,
         base_interval
       ) do
    expected =
      expected_interval_count(bucket_start, bucket_end, window_start, window_end, base_interval)

    covered = Map.get(evidence, :covered_interval_count, 0)
    missing = max(expected - covered, 0)

    evidence
    |> Map.put(:expected_interval_count, expected)
    |> Map.put(:missing_interval_count, missing)
  end

  defp expected_interval_count(bucket_start, bucket_end, window_start, window_end, base_interval) do
    effective_start = max_datetime(bucket_start, window_start)
    effective_end = min_datetime(bucket_end, window_end)

    if DateTime.compare(effective_start, effective_end) == :lt do
      base_microseconds = base_interval * 1_000_000

      first_slot =
        Integer.floor_div(DateTime.to_unix(effective_start, :microsecond), base_microseconds)

      last_slot =
        Integer.floor_div(DateTime.to_unix(effective_end, :microsecond) - 1, base_microseconds)

      max(last_slot - first_slot + 1, 0)
    else
      0
    end
  end

  defp aggregate_evidence_state(evidence) do
    state_counts = Map.get(evidence, :state_counts, %{})

    if map_size(state_counts) == 0 do
      Map.get(evidence, :state, :missing)
    else
      missing = Map.get(evidence, :missing_interval_count, 0)
      up = Map.get(state_counts, :up, 0)

      cond do
        Map.get(state_counts, :anomaly, 0) > 0 -> :anomaly
        Map.get(state_counts, :down, 0) > 0 -> :down
        Map.get(state_counts, :slow, 0) > 0 -> :slow
        missing > 0 and up > 0 -> :partial
        up > 0 -> :up
        true -> :missing
      end
    end
  end

  defp aggregate_bucket_state(evidence, incidents, pauses, bucket_start, bucket_end, rules) do
    evidence_state = aggregate_evidence_state(evidence)
    observed? = Map.get(evidence, :check_count, 0) > 0

    cond do
      Enum.any?(pauses, &overlaps?(&1, :paused_at, :resumed_at, bucket_start, bucket_end)) ->
        :paused

      evidence_state == :anomaly ->
        :anomaly

      evidence_state == :down ->
        :down

      (observed? or rules.missing_is_failure) and
          Enum.any?(
            incidents,
            &overlaps?(&1, :started_at, :resolved_at, bucket_start, bucket_end)
          ) ->
        :down

      evidence_state == :slow ->
        :slow

      evidence_state == :partial ->
        :partial

      evidence_state == :up ->
        :up

      true ->
        :missing
    end
  end

  defp checks_in_bucket(checks, bucket_start, bucket_end) do
    Enum.filter(checks, fn check ->
      case datetime_value(check, :checked_at) do
        nil ->
          false

        checked_at ->
          DateTime.compare(checked_at, bucket_start) != :lt and
            DateTime.compare(checked_at, bucket_end) == :lt
      end
    end)
  end

  defp within_window?(record, field, start_at, end_at) do
    case datetime_value(record, field) do
      nil -> false
      value -> DateTime.compare(value, start_at) != :lt and DateTime.compare(value, end_at) == :lt
    end
  end

  defp overlaps_window?(record, start_field, end_field, start_at, end_at),
    do: overlaps?(record, start_field, end_field, start_at, end_at)

  defp overlaps?(record, start_field, end_field, window_start, window_end) do
    with started_at when not is_nil(started_at) <- datetime_value(record, start_field) do
      resolved_at = datetime_value(record, end_field) || window_end

      DateTime.compare(started_at, window_end) == :lt and
        DateTime.compare(resolved_at, window_start) == :gt
    else
      _ -> false
    end
  end

  defp check_anomaly?(check) do
    error_class = check |> value(:error_class) |> to_string_or_empty() |> String.downcase()
    detail = value(check, :detail) || %{}

    error_class in ["anomaly", "outlier"] or
      truthy?(Map.get(detail, :anomaly) || Map.get(detail, "anomaly"))
  end

  defp validate_window(start_at, end_at) do
    if DateTime.compare(start_at, end_at) == :lt,
      do: :ok,
      else: {:error, "The uptime range is invalid."}
  end

  defp validate_interval(interval) when is_integer(interval) and interval > 0, do: {:ok, interval}
  defp validate_interval(_), do: {:error, "The monitor check interval is unavailable."}

  defp validate_interval_relationship(base_interval, display_interval)
       when rem(display_interval, base_interval) == 0,
       do: :ok

  defp validate_interval_relationship(_base_interval, _display_interval),
    do: {:error, "The uptime display interval must be a multiple of the monitor interval."}

  defp utc_datetime(%DateTime{} = value), do: {:ok, value}
  defp utc_datetime(%NaiveDateTime{} = value), do: {:ok, DateTime.from_naive!(value, "Etc/UTC")}
  defp utc_datetime(_), do: {:error, "The uptime range is unavailable."}

  defp empty_with_range(start_at, end_at, base_interval, interval) do
    aligned_start = align_start(start_at, interval)
    aligned_end = align_end(end_at, interval)

    %{
      empty()
      | base_interval_seconds: base_interval,
        interval_seconds: interval,
        range: range(start_at, end_at, aligned_start, aligned_end, base_interval, interval),
        description:
          "No uptime evidence is available from #{format_datetime(start_at)} to #{format_datetime(end_at)}. Display buckets are #{format_duration(interval)} wide on the #{format_duration(base_interval)} monitor interval grid."
    }
  end

  defp error_trace(summary) do
    %{empty() | state: :error, summary: summary, description: summary}
  end

  defp trace_state(anomaly_count, _missing_count, _missing_intervals) when anomaly_count > 0,
    do: :anomaly

  defp trace_state(_anomaly_count, missing_count, missing_intervals)
       when missing_count > 0 or missing_intervals > 0,
       do: :partial

  defp trace_state(_anomaly_count, _missing_count, _missing_intervals), do: :ready

  defp summary(counts, total, missing_intervals, expected_intervals) do
    cond do
      Map.get(counts, :anomaly, 0) > 0 ->
        "Anomalous evidence in #{counts.anomaly} of #{total} intervals"

      missing_intervals > 0 ->
        "Partial coverage, #{missing_intervals} of #{expected_intervals} monitor intervals missing"

      Map.get(counts, :down, 0) > 0 ->
        "Down in #{counts.down} of #{total} intervals"

      Map.get(counts, :slow, 0) > 0 ->
        "Slow in #{counts.slow} of #{total} intervals"

      Map.get(counts, :paused, 0) > 0 ->
        "Paused in #{counts.paused} of #{total} intervals"

      true ->
        "Up in all #{total} intervals"
    end
  end

  defp legend(counts) do
    Enum.flat_map(@legend_order, fn state ->
      case Map.get(counts, state, 0) do
        0 -> []
        count -> [%{label: state_label(state), state: state, tone: tone(state), count: count}]
      end
    end)
  end

  defp range(start_at, end_at, aligned_start, aligned_end, base_interval, interval) do
    %{
      start: format_datetime(start_at),
      end: format_datetime(end_at),
      aligned_start: format_datetime(aligned_start),
      aligned_end: format_datetime(aligned_end),
      base_interval_seconds: base_interval,
      interval_seconds: interval,
      bucket_width: format_duration(interval),
      monitor_interval: format_duration(base_interval)
    }
  end

  defp bucket_starts(start_at, end_at, interval) do
    Stream.iterate(start_at, &DateTime.add(&1, interval, :second))
    |> Enum.take_while(&(DateTime.compare(&1, end_at) == :lt))
  end

  defp align_start(datetime, interval) do
    datetime
    |> DateTime.to_unix()
    |> Integer.floor_div(interval)
    |> Kernel.*(interval)
    |> DateTime.from_unix!()
  end

  defp align_end(datetime, interval) do
    unix = DateTime.to_unix(datetime)
    aligned = Integer.floor_div(unix, interval) * interval

    if aligned == unix,
      do: DateTime.from_unix!(aligned),
      else: DateTime.from_unix!(aligned + interval)
  end

  defp bounded_interval_seconds(start_at, end_at, interval)
       when is_integer(interval) and interval > 0 do
    minimum_interval =
      div(
        aligned_span_seconds(start_at, end_at, interval) + @max_bucket_count - 1,
        @max_bucket_count
      )

    max(interval, div(minimum_interval + interval - 1, interval) * interval)
  end

  defp aligned_span_seconds(start_at, end_at, interval) do
    aligned_start = align_start(start_at, interval)
    aligned_end = align_end(end_at, interval)

    max(DateTime.diff(aligned_end, aligned_start, :second), 1)
  end

  defp datetime_value(record, field) do
    case value(record, field) do
      %DateTime{} = datetime -> datetime
      %NaiveDateTime{} = datetime -> DateTime.from_naive!(datetime, "Etc/UTC")
      _ -> nil
    end
  end

  defp state_counts_for_checks(checks) do
    Enum.reduce(checks, %{up: 0, down: 0, slow: 0, anomaly: 0}, fn check, counts ->
      state =
        cond do
          check_anomaly?(check) -> :anomaly
          normalise_status(check) == "down" -> :down
          normalise_status(check) == "degraded" -> :slow
          normalise_status(check) == "up" -> :up
          true -> nil
        end

      if state, do: Map.update!(counts, state, &(&1 + 1)), else: counts
    end)
  end

  defp value(record, field) when is_map(record), do: Map.get(record, field)
  defp value(_record, _field), do: nil

  defp normalise_status(record),
    do: record |> value(:status) |> to_string_or_empty() |> String.downcase()

  defp truthy?(value), do: value in [true, 1, "true", "1"]

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_or_empty(value), do: inspect(value)

  defp state_label(:up), do: "Up"
  defp state_label(:down), do: "Down"
  defp state_label(:slow), do: "Slow"
  defp state_label(:missing), do: "Missing"
  defp state_label(:paused), do: "Paused"
  defp state_label(:anomaly), do: "Anomaly"
  defp state_label(:partial), do: "Partial"

  defp tone(:up), do: "live"
  defp tone(:down), do: "error"
  defp tone(:slow), do: "late"
  defp tone(:missing), do: "neutral"
  defp tone(:paused), do: "paused"
  defp tone(:anomaly), do: "error"
  defp tone(:partial), do: "late"

  defp format_duration(seconds) when is_integer(seconds) and rem(seconds, 86_400) == 0,
    do: pluralize(div(seconds, 86_400), "day")

  defp format_duration(seconds) when is_integer(seconds) and rem(seconds, 3_600) == 0,
    do: pluralize(div(seconds, 3_600), "hour")

  defp format_duration(seconds) when is_integer(seconds) and rem(seconds, 60) == 0,
    do: pluralize(div(seconds, 60), "minute")

  defp format_duration(seconds) when is_integer(seconds), do: pluralize(seconds, "second")
  defp format_duration(_seconds), do: "unknown duration"

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(number, word), do: "#{number} #{word}s"

  defp min_datetime(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
