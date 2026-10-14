defmodule Alplus.Monitoring.MonitorMetrics do
  @moduledoc """
  Tenant-scoped latency and response metrics for one Monitor detail page.

  This is a read model, not a second Monitor resource. Ash still owns the
  Monitor and MonitorCheck records. PostgreSQL owns the bounded aggregates so
  the page never loads a long check history into BEAM.

  The direct SQL calls are intentional. PostgreSQL's ordered-set aggregates,
  grouped percentile buckets, and response composition cannot be expressed as
  a bounded Ash read without fetching every check. Every query repeats the
  organization, project, monitor, and membership predicates. See
  `docs/DIRECT-ECTO-ESCAPE-HATCHES.md`.
  """

  alias Alplus.Billing.Package
  alias Alplus.Repo
  alias Alplus.Scope

  @windows ~w(24h 7d 30d 90d)
  @max_buckets 96
  @default_threshold_source :not_configured

  @histogram_bins [
    %{key: :under_50, lower: 0, upper: 50, label: "0 to 49 ms"},
    %{key: :from_50_to_99, lower: 50, upper: 100, label: "50 to 99 ms"},
    %{key: :from_100_to_249, lower: 100, upper: 250, label: "100 to 249 ms"},
    %{key: :from_250_to_499, lower: 250, upper: 500, label: "250 to 499 ms"},
    %{key: :from_500_to_999, lower: 500, upper: 1_000, label: "500 to 999 ms"},
    %{key: :from_1000_to_2499, lower: 1_000, upper: 2_500, label: "1,000 to 2,499 ms"},
    %{key: :from_2500_to_4999, lower: 2_500, upper: 5_000, label: "2,500 to 4,999 ms"},
    %{key: :from_5000_to_9999, lower: 5_000, upper: 10_000, label: "5,000 to 9,999 ms"},
    %{key: :over_10000, lower: 10_000, upper: nil, label: "10,000 ms and over"}
  ]

  @type metric_state :: :ready | :partial | :anomaly | :empty | :error
  @type latency_state :: :ready | :insufficient | :missing

  @type t :: %__MODULE__{
          monitor_id: String.t(),
          org_id: String.t(),
          project_id: String.t(),
          window: String.t(),
          range: map(),
          state: metric_state(),
          latency_state: latency_state(),
          threshold_ms: pos_integer() | nil,
          threshold_source: atom(),
          sample_count: non_neg_integer(),
          latency_count: non_neg_integer(),
          missing_latency_count: non_neg_integer(),
          missing_bucket_count: non_neg_integer(),
          min_latency_ms: number() | nil,
          max_latency_ms: number() | nil,
          percentiles: %{p50: number() | nil, p95: number() | nil, p99: number() | nil},
          latency_buckets: [map()],
          percentile_series: [map()],
          percentile_paths: %{p50: String.t(), p95: String.t(), p99: String.t()},
          histogram: [map()],
          histogram_markers: [map()],
          response_composition: map(),
          annotations: [map()],
          error: term() | nil
        }

  defstruct [
    :monitor_id,
    :org_id,
    :project_id,
    :window,
    :range,
    :state,
    :latency_state,
    :threshold_ms,
    :threshold_source,
    :sample_count,
    :latency_count,
    :missing_latency_count,
    :missing_bucket_count,
    :min_latency_ms,
    :max_latency_ms,
    :percentiles,
    :latency_buckets,
    :percentile_series,
    :percentile_paths,
    :histogram,
    :histogram_markers,
    :response_composition,
    :annotations,
    :error
  ]

  @doc "Returns the supported Monitor detail windows in ascending range order."
  @spec windows() :: [String.t()]
  def windows, do: @windows

  @doc "Returns the fixed histogram definitions used by the read model."
  @spec histogram_bins() :: [map()]
  def histogram_bins, do: @histogram_bins

  @doc "Returns exact PostgreSQL-compatible continuous percentile math."
  @spec percentile([number()], float()) :: float()
  def percentile([], _probability), do: nil

  def percentile(values, probability)
      when is_list(values) and is_number(probability) and probability >= 0 and probability <= 1 do
    sorted = Enum.sort(values)
    last_index = length(sorted) - 1
    position = last_index * probability
    lower_index = trunc(Float.floor(position))
    upper_index = trunc(Float.ceil(position))
    lower = Enum.at(sorted, lower_index)
    upper = Enum.at(sorted, upper_index)

    lower + (upper - lower) * (position - lower_index)
  end

  def percentile(_values, _probability),
    do: raise(ArgumentError, "percentile probability must be between 0 and 1")

  @doc "Calculates p50, p95, and p99 from latency values without dropping outliers."
  @spec percentiles([number()]) :: %{p50: float() | nil, p95: float() | nil, p99: float() | nil}
  def percentiles(values) when is_list(values) do
    %{
      p50: percentile(values, 0.50),
      p95: percentile(values, 0.95),
      p99: percentile(values, 0.99)
    }
  end

  @doc "Builds exact histogram counts from latency values using the stable bins."
  @spec histogram_counts([number()]) :: [map()]
  def histogram_counts(values) when is_list(values) do
    counts = Enum.frequencies_by(values, &histogram_index/1)
    max_count = Enum.max([Map.values(counts) |> Enum.max(fn -> 0 end), 1])

    Enum.map(Enum.with_index(@histogram_bins), fn {bin, index} ->
      count = Map.get(counts, index, 0)
      histogram_item(bin, count, max_count)
    end)
  end

  @doc "Returns effective range bounds after applying the plan retention limit."
  @spec window_bounds(String.t(), pos_integer(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def window_bounds(window, retention_days, %DateTime{} = now)
      when window in @windows and is_integer(retention_days) and retention_days > 0,
      do: window_bounds(window, retention_days, now, nil)

  def window_bounds(_window, _retention_days, _now), do: {:error, :invalid_window}

  @doc "Returns effective bounds using the monitor interval for stable buckets."
  @spec window_bounds(String.t(), pos_integer(), DateTime.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, term()}
  def window_bounds(window, retention_days, %DateTime{} = now, interval_seconds)
      when window in @windows and is_integer(retention_days) and retention_days > 0 do
    requested_start = DateTime.add(now, -window_seconds(window), :second)
    retention_start = DateTime.add(now, -retention_days * 86_400, :second)
    start_at = max_datetime(requested_start, retention_start)
    bucket_seconds = bucket_seconds(DateTime.diff(now, start_at, :second), interval_seconds)
    aligned_start = align_start(start_at, bucket_seconds)
    aligned_end = align_end(now, bucket_seconds)

    {:ok,
     range_map(
       requested_start,
       now,
       start_at,
       now,
       aligned_start,
       aligned_end,
       bucket_seconds,
       retention_days
     )}
  end

  def window_bounds(_window, _retention_days, _now, _interval), do: {:error, :invalid_window}

  @doc "Returns the configured response threshold without inventing one in a component."
  @spec threshold_for(map() | nil) :: {:ok, {pos_integer() | nil, atom()}} | {:error, term()}
  def threshold_for(nil), do: {:ok, {nil, @default_threshold_source}}

  def threshold_for(config) when is_map(config) do
    threshold = Map.get(config, :response_time_threshold_ms)

    cond do
      is_nil(threshold) ->
        {:ok, {nil, @default_threshold_source}}

      is_integer(threshold) and threshold in 100..60_000 ->
        {:ok, {threshold, :monitor_configuration}}

      true ->
        {:error, :invalid_response_threshold}
    end
  end

  def threshold_for(_config), do: {:error, :invalid_response_threshold}

  @doc "Reads all Monitor metrics for one already-authorized Monitor."
  @spec load(map(), map() | nil, Scope.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def load(monitor, config, %Scope{} = scope, window, options \\ [])
      when is_map(monitor) and window in @windows and is_list(options) do
    with :ok <- validate_scope(monitor, scope),
         {:ok, retention_days} <- retention_days(scope, options),
         {:ok, {threshold_ms, threshold_source}} <- threshold_for(config),
         {:ok, now} <- option_now(options),
         {:ok, range} <- window_bounds(window, retention_days, now, interval_seconds(config)),
         {:ok, summary} <- summary(monitor, scope, range),
         {:ok, grouped_buckets} <- latency_bucket_rows(monitor, scope, range, threshold_ms),
         {:ok, composition} <- response_composition(monitor, scope, range),
         {:ok, histogram} <- latency_histogram(monitor, scope, range, summary.latency_count) do
      annotations = bound_annotations(Keyword.get(options, :annotations, []), range)

      {:ok,
       build_metrics(
         monitor,
         window,
         range,
         threshold_ms,
         threshold_source,
         summary,
         grouped_buckets,
         histogram,
         composition,
         annotations
       )}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {:database, error}}
  end

  @doc "Raises when `load/5` cannot read the scoped metrics."
  @spec load!(map(), map() | nil, Scope.t(), String.t(), keyword()) :: t()
  def load!(monitor, config, %Scope{} = scope, window, options \\ []) do
    case load(monitor, config, scope, window, options) do
      {:ok, metrics} -> metrics
      {:error, reason} -> raise ArgumentError, "monitor metrics unavailable: #{inspect(reason)}"
    end
  end

  @doc "Returns an error-shaped metrics value for a chart-level failure state."
  @spec error(String.t(), term()) :: %__MODULE__{
          state: :error,
          error: %{message: String.t(), reason: term()}
        }
  def error(message, reason) do
    %__MODULE__{
      state: :error,
      latency_state: :missing,
      percentiles: %{p50: nil, p95: nil, p99: nil},
      latency_buckets: [],
      percentile_series: [],
      percentile_paths: %{p50: "", p95: "", p99: ""},
      histogram: [],
      histogram_markers: [],
      response_composition: %{state: :error, total: nil, items: []},
      annotations: [],
      error: %{message: message, reason: reason}
    }
  end

  defp validate_scope(monitor, %Scope{org_id: org_id, project_id: project_id, user_id: user_id})
       when is_binary(org_id) and is_binary(project_id) and is_binary(user_id) do
    if Map.get(monitor, :org_id) == org_id and Map.get(monitor, :project_id) == project_id do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp validate_scope(_monitor, _scope), do: {:error, :invalid_scope}

  defp retention_days(%Scope{}, options) do
    case Keyword.get(options, :retention_days) do
      days when is_integer(days) and days > 0 ->
        {:ok, days}

      nil ->
        {:ok, Package.limit(:detailed_uptime_retention_days)}

      _ ->
        {:error, :invalid_retention_days}
    end
  end

  defp option_now(options) do
    case Keyword.get(options, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, now}
      _ -> {:error, :invalid_now}
    end
  end

  defp interval_seconds(config) when is_map(config) do
    case Map.get(config, :interval_seconds) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp interval_seconds(_config), do: nil

  defp summary(monitor, scope, range) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT count(*)::bigint,
               count(latency_ms)::bigint,
               count(*) FILTER (WHERE latency_ms IS NULL)::bigint,
               min(latency_ms),
               max(latency_ms),
               percentile_cont(0.50) WITHIN GROUP (ORDER BY latency_ms)
                 FILTER (WHERE latency_ms IS NOT NULL),
               percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)
                 FILTER (WHERE latency_ms IS NOT NULL),
               percentile_cont(0.99) WITHIN GROUP (ORDER BY latency_ms)
                 FILTER (WHERE latency_ms IS NOT NULL)
        FROM monitor_checks AS checks
        WHERE checks.org_id = $1
          AND checks.project_id = $2
          AND checks.monitor_id = $3
          AND checks.checked_at >= $4::timestamp
          AND checks.checked_at < $5::timestamp
          AND EXISTS (
            SELECT 1 FROM monitors
            WHERE monitors.id = checks.monitor_id
              AND monitors.org_id = $1
              AND monitors.project_id = $2
          )
          AND EXISTS (
            SELECT 1 FROM memberships
            WHERE memberships.org_id = $1
              AND memberships.user_id = $6
          )
        """,
        summary_params(monitor, scope, range)
      )

    {:ok,
     %{
       sample_count: integer_value(Enum.at(row, 0)),
       latency_count: integer_value(Enum.at(row, 1)),
       missing_latency_count: integer_value(Enum.at(row, 2)),
       min_latency_ms: number_value(Enum.at(row, 3)),
       max_latency_ms: number_value(Enum.at(row, 4)),
       percentiles: %{
         p50: number_value(Enum.at(row, 5)),
         p95: number_value(Enum.at(row, 6)),
         p99: number_value(Enum.at(row, 7))
       }
     }}
  end

  defp latency_bucket_rows(monitor, scope, range, threshold_ms) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT date_bin(make_interval(secs => $6), checks.checked_at, TIMESTAMP 'epoch') AS bucket_start,
               count(*)::bigint,
               count(checks.latency_ms)::bigint,
               count(*) FILTER (WHERE checks.latency_ms IS NULL)::bigint,
               min(checks.latency_ms),
               max(checks.latency_ms),
               percentile_cont(0.50) WITHIN GROUP (ORDER BY checks.latency_ms)
                 FILTER (WHERE checks.latency_ms IS NOT NULL),
               percentile_cont(0.95) WITHIN GROUP (ORDER BY checks.latency_ms)
                 FILTER (WHERE checks.latency_ms IS NOT NULL),
               percentile_cont(0.99) WITHIN GROUP (ORDER BY checks.latency_ms)
                 FILTER (WHERE checks.latency_ms IS NOT NULL),
               count(*) FILTER (
                 WHERE checks.latency_ms IS NOT NULL
                   AND $7::bigint IS NOT NULL
                   AND checks.latency_ms > $7
               )::bigint
        FROM monitor_checks AS checks
        WHERE checks.org_id = $1
          AND checks.project_id = $2
          AND checks.monitor_id = $3
          AND checks.checked_at >= $4::timestamp
          AND checks.checked_at < $5::timestamp
          AND EXISTS (
            SELECT 1 FROM monitors
            WHERE monitors.id = checks.monitor_id
              AND monitors.org_id = $1
              AND monitors.project_id = $2
          )
          AND EXISTS (
            SELECT 1 FROM memberships
            WHERE memberships.org_id = $1
              AND memberships.user_id = $8
          )
        GROUP BY date_bin(make_interval(secs => $6), checks.checked_at, TIMESTAMP 'epoch')
        ORDER BY bucket_start
        """,
        bucket_params(monitor, scope, range, threshold_ms)
      )

    # Threshold crossing is a configured value. The query receives it after
    # the threshold is validated, so no component has to infer slow state.
    {:ok, rows}
  end

  defp latency_histogram(monitor, scope, range, latency_count) do
    if latency_count == 0 do
      {:ok, []}
    else
      %{rows: rows} =
        Repo.query!(
          """
          SELECT CASE
                   WHEN latency_ms < 50 THEN 0
                   WHEN latency_ms < 100 THEN 1
                   WHEN latency_ms < 250 THEN 2
                   WHEN latency_ms < 500 THEN 3
                   WHEN latency_ms < 1000 THEN 4
                   WHEN latency_ms < 2500 THEN 5
                   WHEN latency_ms < 5000 THEN 6
                   WHEN latency_ms < 10000 THEN 7
                   ELSE 8
                 END AS bucket_index,
                 count(*)::bigint
          FROM monitor_checks AS checks
          WHERE checks.org_id = $1
            AND checks.project_id = $2
            AND checks.monitor_id = $3
            AND checks.checked_at >= $4::timestamp
            AND checks.checked_at < $5::timestamp
            AND checks.latency_ms IS NOT NULL
            AND EXISTS (
              SELECT 1 FROM monitors
              WHERE monitors.id = checks.monitor_id
                AND monitors.org_id = $1
                AND monitors.project_id = $2
            )
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1
                AND memberships.user_id = $6
            )
          GROUP BY bucket_index
          ORDER BY bucket_index
          """,
          summary_params(monitor, scope, range)
        )

      counts = Map.new(rows, fn [index, count] -> {index, integer_value(count)} end)
      max_count = Enum.max([Map.values(counts) |> Enum.max(fn -> 0 end), 1])

      {:ok,
       Enum.map(Enum.with_index(@histogram_bins), fn {bin, index} ->
         histogram_item(bin, Map.get(counts, index, 0), max_count)
       end)}
    end
  end

  defp response_composition(%{type: type}, _scope, _range) when type not in ["http", "keyword"],
    do: {:ok, %{state: :not_applicable, total: 0, items: []}}

  defp response_composition(monitor, scope, range) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT count(*)::bigint,
               count(*) FILTER (WHERE status_code BETWEEN 100 AND 199)::bigint,
               count(*) FILTER (WHERE status_code BETWEEN 200 AND 299)::bigint,
               count(*) FILTER (WHERE status_code BETWEEN 300 AND 399)::bigint,
               count(*) FILTER (WHERE status_code BETWEEN 400 AND 499)::bigint,
               count(*) FILTER (WHERE status_code BETWEEN 500 AND 599)::bigint,
               count(*) FILTER (WHERE status_code IS NULL AND lower(coalesce(error_class, '')) = ANY($6::text[]))::bigint,
               count(*) FILTER (WHERE status_code IS NULL AND lower(coalesce(error_class, '')) = ANY($7::text[]))::bigint,
               count(*) FILTER (WHERE status_code IS NULL AND error_class IS NOT NULL AND lower(error_class) <> ALL($8::text[]) )::bigint,
               count(*) FILTER (WHERE status_code IS NULL AND error_class IS NULL)::bigint
        FROM monitor_checks AS checks
        WHERE checks.org_id = $1
          AND checks.project_id = $2
          AND checks.monitor_id = $3
          AND checks.checked_at >= $4::timestamp
          AND checks.checked_at < $5::timestamp
          AND EXISTS (
            SELECT 1 FROM monitors
            WHERE monitors.id = checks.monitor_id
              AND monitors.org_id = $1
              AND monitors.project_id = $2
          )
          AND EXISTS (
            SELECT 1 FROM memberships
            WHERE memberships.org_id = $1
              AND memberships.user_id = $9
          )
        """,
        composition_params(monitor, scope, range)
      )

    [
      total,
      one_xx,
      two_xx,
      three_xx,
      four_xx,
      five_xx,
      timeouts,
      transports,
      other_errors,
      no_response
    ] =
      Enum.map(row, &integer_value/1)

    items =
      if total == 0 do
        []
      else
        [
          composition_item("1xx", "1xx responses", one_xx, total, "neutral"),
          composition_item("2xx", "2xx responses", two_xx, total, "live"),
          composition_item("3xx", "3xx responses", three_xx, total, "live"),
          composition_item("4xx", "4xx responses", four_xx, total, "late"),
          composition_item("5xx", "5xx responses", five_xx, total, "error"),
          composition_item("timeout", "Timeouts", timeouts, total, "error"),
          composition_item("transport", "Transport errors", transports, total, "error"),
          composition_item("other_error", "Other errors", other_errors, total, "late"),
          composition_item("no_response", "No response class", no_response, total, "neutral")
        ]
      end

    {:ok, %{state: if(total == 0, do: :empty, else: :ready), total: total, items: items}}
  end

  defp build_metrics(
         monitor,
         window,
         range,
         threshold_ms,
         threshold_source,
         summary,
         grouped_rows,
         histogram,
         composition,
         annotations
       ) do
    buckets =
      build_latency_buckets(
        grouped_rows,
        range,
        threshold_ms,
        summary.max_latency_ms
      )

    percentile_paths = %{
      p50: percentile_path(buckets, :p50_ms, summary.max_latency_ms),
      p95: percentile_path(buckets, :p95_ms, summary.max_latency_ms),
      p99: percentile_path(buckets, :p99_ms, summary.max_latency_ms)
    }

    missing_bucket_count = Enum.count(buckets, &(&1.sample_count == 0))
    latency_state = latency_state(summary.sample_count, summary.latency_count)
    outlier? = Enum.any?(histogram, &(&1.key == :over_10000 and &1.count > 0))

    state =
      cond do
        summary.sample_count == 0 -> :empty
        outlier? -> :anomaly
        latency_state in [:missing, :insufficient] or missing_bucket_count > 0 -> :partial
        true -> :ready
      end

    %__MODULE__{
      monitor_id: monitor.id,
      org_id: monitor.org_id,
      project_id: monitor.project_id,
      window: window,
      range: range,
      state: state,
      latency_state: latency_state,
      threshold_ms: threshold_ms,
      threshold_source: threshold_source,
      sample_count: summary.sample_count,
      latency_count: summary.latency_count,
      missing_latency_count: summary.missing_latency_count,
      missing_bucket_count: missing_bucket_count,
      min_latency_ms: summary.min_latency_ms,
      max_latency_ms: summary.max_latency_ms,
      percentiles: summary.percentiles,
      latency_buckets: buckets,
      percentile_series: buckets,
      percentile_paths: percentile_paths,
      histogram: histogram,
      histogram_markers: percentile_markers(summary.percentiles),
      response_composition: composition,
      annotations: annotations,
      error: nil
    }
  end

  defp build_latency_buckets(rows, range, threshold_ms, max_latency_ms) do
    by_start =
      rows
      |> Enum.map(&bucket_row/1)
      |> Map.new(&{DateTime.to_unix(&1.start_at), &1})

    bucket_count = range.bucket_count
    scale_max = max(number_value(max_latency_ms) || 0, 1)

    Enum.map(0..(bucket_count - 1), fn index ->
      start_at = DateTime.add(range.aligned_start, index * range.bucket_seconds, :second)
      end_at = DateTime.add(start_at, range.bucket_seconds, :second)
      raw = Map.get(by_start, DateTime.to_unix(start_at), empty_bucket_row(start_at, end_at))
      decorate_bucket(raw, end_at, threshold_ms, scale_max)
    end)
  end

  defp bucket_row([
         start_at,
         sample_count,
         latency_count,
         missing_latency_count,
         min_latency,
         max_latency,
         p50,
         p95,
         p99,
         slow_count
       ]) do
    %{
      start_at: normalize_datetime(start_at),
      sample_count: integer_value(sample_count),
      latency_count: integer_value(latency_count),
      missing_latency_count: integer_value(missing_latency_count),
      min_latency_ms: number_value(min_latency),
      max_latency_ms: number_value(max_latency),
      p50_ms: number_value(p50),
      p95_ms: number_value(p95),
      p99_ms: number_value(p99),
      slow_count: integer_value(slow_count)
    }
  end

  defp empty_bucket_row(start_at, end_at) do
    %{
      start_at: start_at,
      end_at: end_at,
      sample_count: 0,
      latency_count: 0,
      missing_latency_count: 0,
      min_latency_ms: nil,
      max_latency_ms: nil,
      p50_ms: nil,
      p95_ms: nil,
      p99_ms: nil,
      slow_count: 0
    }
  end

  defp decorate_bucket(bucket, end_at, threshold_ms, scale_max) do
    value = bucket.p50_ms
    slow? = is_integer(threshold_ms) and bucket.slow_count > 0
    state = bucket_state(bucket, threshold_ms, slow?)
    height = if is_number(value), do: max(value / scale_max * 100, 4), else: nil
    label = bucket_label(bucket, state)

    %{
      id: "latency-#{DateTime.to_unix(bucket.start_at)}",
      start_at: bucket.start_at,
      end_at: end_at,
      sample_count: bucket.sample_count,
      latency_count: bucket.latency_count,
      missing_latency_count: bucket.missing_latency_count,
      min_latency_ms: bucket.min_latency_ms,
      max_latency_ms: bucket.max_latency_ms,
      p50_ms: value,
      p95_ms: bucket.p95_ms,
      p99_ms: bucket.p99_ms,
      slow_count: bucket.slow_count,
      state: state,
      tone: if(state == :slow, do: "late", else: "live"),
      value: value,
      height: height,
      label: label,
      tooltip: bucket_tooltip(bucket, state),
      aria_label: bucket_tooltip(bucket, state),
      table_cells: [
        format_datetime(bucket.start_at),
        format_datetime(end_at),
        Integer.to_string(bucket.sample_count),
        format_number(value, "ms"),
        format_number(bucket.p95_ms, "ms"),
        state_label(state)
      ]
    }
  end

  defp bucket_state(%{sample_count: 0}, _threshold_ms, _slow?), do: :missing
  defp bucket_state(%{latency_count: 0}, _threshold_ms, _slow?), do: :no_latency
  defp bucket_state(_bucket, _threshold_ms, true), do: :slow
  defp bucket_state(_bucket, _threshold_ms, false), do: :ready

  defp bucket_label(%{sample_count: 0}, _state), do: "No samples"
  defp bucket_label(%{latency_count: 0}, _state), do: "No latency"
  defp bucket_label(_bucket, :slow), do: "Slow"
  defp bucket_label(_bucket, _state), do: "Response"

  defp bucket_tooltip(bucket, state) do
    values =
      [
        format_datetime(bucket.start_at),
        "#{bucket.sample_count} samples",
        "p50 #{format_number(bucket.p50_ms, "ms")}",
        "p95 #{format_number(bucket.p95_ms, "ms")}",
        state_label(state)
      ]

    Enum.join(values, ", ")
  end

  defp histogram_item(bin, count, max_count) do
    value = if count > 0, do: count, else: nil
    height = if count > 0, do: max(count / max_count * 100, 4), else: nil

    %{
      id: "latency-histogram-#{bin.key}",
      key: bin.key,
      label: bin.label,
      count: count,
      value: value,
      height: height,
      tone: if(bin.key == :over_10000 and count > 0, do: "error", else: "live"),
      tooltip: "#{bin.label}, #{count} samples",
      aria_label: "#{bin.label}, #{count} samples",
      table_cells: [bin.label, Integer.to_string(count)]
    }
  end

  defp composition_item(key, label, count, total, tone) do
    %{
      id: "response-composition-#{key}",
      key: key,
      label: label,
      count: count,
      value: count,
      width: if(total > 0, do: count / total * 100, else: nil),
      tone: tone,
      tooltip: "#{label}, #{count} of #{total} samples",
      aria_label: "#{label}, #{count} of #{total} samples",
      table_cells: [label, Integer.to_string(count), "#{format_ratio(count, total)}%"]
    }
  end

  defp percentile_markers(percentiles) do
    [
      {:p50, Map.get(percentiles, :p50)},
      {:p95, Map.get(percentiles, :p95)},
      {:p99, Map.get(percentiles, :p99)}
    ]
    |> Enum.map(fn {key, value} ->
      %{id: "latency-marker-#{key}", key: key, label: Atom.to_string(key), value: value}
    end)
    |> Enum.reject(&is_nil(&1.value))
  end

  defp latency_state(0, _latency_count), do: :missing
  defp latency_state(_sample_count, 0), do: :missing
  defp latency_state(_sample_count, 1), do: :insufficient
  defp latency_state(_sample_count, _latency_count), do: :ready

  defp bound_annotations(annotations, range) when is_list(annotations) do
    Enum.filter(annotations, fn annotation ->
      case annotation_datetime(annotation) do
        %DateTime{} = at ->
          DateTime.compare(at, range.start_at) != :lt and
            DateTime.compare(at, range.end_at) == :lt

        nil ->
          # Callers may provide already-bounded annotations without a
          # timestamp. Keep those labels separate from series data.
          true
      end
    end)
  end

  defp bound_annotations(_annotations, _range), do: []

  defp annotation_datetime(annotation) when is_map(annotation) do
    annotation
    |> Map.get(
      :at,
      Map.get(
        annotation,
        :started_at,
        Map.get(annotation, "at", Map.get(annotation, "started_at"))
      )
    )
    |> normalize_annotation_datetime()
  end

  defp annotation_datetime(_annotation), do: nil

  defp normalize_annotation_datetime(%DateTime{} = at), do: at

  defp normalize_annotation_datetime(%NaiveDateTime{} = at),
    do: DateTime.from_naive!(at, "Etc/UTC")

  defp normalize_annotation_datetime(_at), do: nil

  defp range_map(
         requested_start,
         requested_end,
         start_at,
         end_at,
         aligned_start,
         aligned_end,
         bucket_seconds,
         retention_days
       ) do
    bucket_count = max(div(DateTime.diff(aligned_end, aligned_start, :second), bucket_seconds), 1)

    %{
      requested_start: requested_start,
      requested_end: requested_end,
      start_at: start_at,
      end_at: end_at,
      aligned_start: aligned_start,
      aligned_end: aligned_end,
      start: DateTime.to_iso8601(start_at),
      end: DateTime.to_iso8601(end_at),
      bucket_seconds: bucket_seconds,
      bucket_count: bucket_count,
      retention_days: retention_days,
      truncated?: DateTime.compare(start_at, requested_start) == :gt
    }
  end

  defp bucket_seconds(window_seconds, interval_seconds) do
    target = max(ceil_div(max(window_seconds, 1), @max_buckets), 1)

    case interval_seconds do
      interval when is_integer(interval) and interval > 0 -> ceil_to_multiple(target, interval)
      _ -> target
    end
  end

  defp align_start(datetime, interval_seconds) do
    unix = DateTime.to_unix(datetime)
    DateTime.from_unix!(unix - rem(unix, interval_seconds))
  end

  defp align_end(datetime, interval_seconds) do
    aligned = align_start(datetime, interval_seconds)

    if DateTime.compare(aligned, datetime) == :lt,
      do: DateTime.add(aligned, interval_seconds, :second),
      else: aligned
  end

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp summary_params(monitor, scope, range) do
    [scope.org_id, scope.project_id, monitor.id, range.start_at, range.end_at, scope.user_id]
  end

  defp bucket_params(monitor, scope, range, threshold_ms) do
    [
      scope.org_id,
      scope.project_id,
      monitor.id,
      range.start_at,
      range.end_at,
      range.bucket_seconds,
      threshold_ms,
      scope.user_id
    ]
  end

  defp composition_params(monitor, scope, range) do
    timeout_classes = ~w(timeout timed_out heartbeat_hung heartbeat_fail)

    transport_classes =
      ~w(network_error connection_refused dns_error doh_error invalid_url too_many_redirects)

    known_error_classes = timeout_classes ++ transport_classes

    [
      scope.org_id,
      scope.project_id,
      monitor.id,
      range.start_at,
      range.end_at,
      timeout_classes,
      transport_classes,
      known_error_classes,
      scope.user_id
    ]
  end

  defp histogram_index(value) when value < 50, do: 0
  defp histogram_index(value) when value < 100, do: 1
  defp histogram_index(value) when value < 250, do: 2
  defp histogram_index(value) when value < 500, do: 3
  defp histogram_index(value) when value < 1_000, do: 4
  defp histogram_index(value) when value < 2_500, do: 5
  defp histogram_index(value) when value < 5_000, do: 6
  defp histogram_index(value) when value < 10_000, do: 7
  defp histogram_index(_value), do: 8

  defp normalize_datetime(%DateTime{} = value), do: value
  defp normalize_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp integer_value(nil), do: 0
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value), do: trunc(value)

  defp number_value(nil), do: nil
  defp number_value(value) when is_integer(value), do: value
  defp number_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp number_value(value) when is_float(value), do: value
  defp number_value(value), do: value |> to_string() |> String.to_float()

  defp format_number(nil, _unit), do: "No value"
  defp format_number(value, unit), do: "#{format_float(value)} #{unit}"

  defp format_float(value) when is_integer(value), do: Integer.to_string(value)
  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_float(value), do: to_string(value)

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp format_ratio(_count, 0), do: 0
  defp format_ratio(count, total), do: Float.round(count / total * 100, 2)

  defp percentile_path(buckets, field, max_latency) do
    scale_max = max(number_value(max_latency) || 0, 1)
    point_count = length(buckets)

    buckets
    |> Enum.with_index()
    |> Enum.reduce({[], false}, fn {bucket, index}, {segments, open?} ->
      value = Map.get(bucket, field)

      if is_number(value) do
        x = if point_count <= 1, do: 0.0, else: index / (point_count - 1) * 100
        y = 40 - value / scale_max * 38
        command = if open?, do: "L", else: "M"
        {["#{command}#{format_coordinate(x)},#{format_coordinate(y)}" | segments], true}
      else
        {segments, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  defp format_coordinate(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp state_label(:ready), do: "Ready"
  defp state_label(:slow), do: "Slow"
  defp state_label(:missing), do: "No samples"
  defp state_label(:no_latency), do: "No latency"

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
  defp ceil_to_multiple(value, multiple), do: ceil_div(value, multiple) * multiple

  defp window_seconds("24h"), do: 86_400
  defp window_seconds("7d"), do: 604_800
  defp window_seconds("30d"), do: 2_592_000
  defp window_seconds("90d"), do: 7_776_000
end
