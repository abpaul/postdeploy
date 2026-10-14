defmodule Alplus.Monitoring.UptimeTracer.Checks do
  @moduledoc """
  Database I/O and tenant scope validation for `Alplus.Monitoring.UptimeTracer`.

  Everything here either crosses the PostgreSQL boundary (`aggregate_checks!/5,6`)
  or guards records the tracer's pure fold is about to consume (`validate_scope!/2`
  and the private validators `trace/5` calls). Keeping both out of the fold means
  the fold stays a plain function of already-authorized, already-shaped data.
  """

  alias Alplus.Repo

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
  def aggregate_checks!(_org_id, _project_id, [], _window_start, _window_end, _scope), do: %{}

  def aggregate_checks!(org_id, project_id, monitor_intervals, window_start, window_end, scope)
      when is_binary(org_id) and is_binary(project_id) and is_list(monitor_intervals) do
    monitor_ids = Enum.map(monitor_intervals, &elem(&1, 0))
    base_intervals = Enum.map(monitor_intervals, &elem(&1, 1))
    display_intervals = Enum.map(monitor_intervals, &elem(&1, 2))

    # Raw Ecto/Postgrex: aggregates check-interval-aligned buckets in the
    # database (date_bin over hundreds of thousands of checks). Ash cannot
    # express this grouped, tenant-and-membership-filtered window function.
    %{rows: rows} =
      Repo.query!(
        """
        WITH monitor_intervals AS (
          SELECT monitor_id, base_interval_seconds, display_interval_seconds
          FROM unnest($3::text[], $4::bigint[], $5::bigint[])
            AS wanted(monitor_id, base_interval_seconds, display_interval_seconds)
        ), check_slots AS (
          SELECT
            checks.monitor_id,
            intervals.base_interval_seconds,
            intervals.display_interval_seconds,
            date_bin(
              make_interval(secs => intervals.base_interval_seconds),
              checks.checked_at,
              TIMESTAMP 'epoch'
            ) AS slot_start,
            checks.status,
            checks.error_class,
            checks.detail
          FROM monitor_checks AS checks
          JOIN monitor_intervals AS intervals ON intervals.monitor_id = checks.monitor_id
          WHERE checks.org_id = $1
            AND checks.project_id = $2
            AND checks.monitor_id = ANY($3::text[])
            AND checks.checked_at >= $6::timestamp
            AND checks.checked_at < $7::timestamp
            AND EXISTS (
              SELECT 1
              FROM monitors
              WHERE monitors.id = checks.monitor_id
                AND monitors.org_id = $1
                AND monitors.project_id = $2
            )
            AND (
              $8::text IS NULL OR EXISTS (
                SELECT 1
                FROM memberships
                WHERE memberships.org_id = checks.org_id
                  AND memberships.user_id = $8::text
              )
            )
        ), slot_evidence AS (
          SELECT
            monitor_id,
            base_interval_seconds,
            display_interval_seconds,
            date_bin(
              make_interval(secs => display_interval_seconds),
              slot_start,
              TIMESTAMP 'epoch'
            ) AS bucket_start,
            slot_start,
            count(*)::bigint AS check_count,
            bool_or(
              lower(coalesce(error_class, '')) IN ('anomaly', 'outlier') OR
                coalesce(detail ->> 'anomaly', 'false') IN ('true', '1')
            ) AS has_anomaly,
            bool_or(status = 'down') AS has_down,
            bool_or(status = 'degraded') AS has_slow,
            bool_or(status = 'up') AS has_up
          FROM check_slots
          GROUP BY monitor_id, base_interval_seconds, display_interval_seconds,
            bucket_start, slot_start
        ), grouped AS (
          SELECT
            monitor_id,
            base_interval_seconds,
            display_interval_seconds,
            bucket_start,
            (display_interval_seconds / base_interval_seconds)::bigint AS expected_interval_count,
            count(*)::bigint AS covered_interval_count,
            sum(check_count)::bigint AS check_count,
            count(*) FILTER (WHERE has_anomaly)::bigint AS anomaly_interval_count,
            count(*) FILTER (WHERE has_down AND NOT has_anomaly)::bigint AS down_interval_count,
            count(*) FILTER (WHERE has_slow AND NOT has_down AND NOT has_anomaly)::bigint AS slow_interval_count,
            count(*) FILTER (WHERE has_up AND NOT has_slow AND NOT has_down AND NOT has_anomaly)::bigint AS up_interval_count
          FROM slot_evidence
          GROUP BY monitor_id, base_interval_seconds, display_interval_seconds, bucket_start
        )
        SELECT
          monitor_id,
          base_interval_seconds,
          display_interval_seconds,
          bucket_start,
          check_count,
          expected_interval_count,
          covered_interval_count,
          GREATEST(expected_interval_count - covered_interval_count, 0)::bigint AS missing_interval_count,
          anomaly_interval_count,
          down_interval_count,
          slow_interval_count,
          up_interval_count,
          CASE
            WHEN anomaly_interval_count > 0 THEN 'anomaly'
            WHEN down_interval_count > 0 THEN 'down'
            WHEN slow_interval_count > 0 THEN 'slow'
            WHEN covered_interval_count < expected_interval_count AND up_interval_count > 0 THEN 'partial'
            WHEN up_interval_count > 0 THEN 'up'
            ELSE 'missing'
          END AS state
        FROM grouped
        ORDER BY monitor_id, bucket_start
        """,
        [
          org_id,
          project_id,
          monitor_ids,
          base_intervals,
          display_intervals,
          window_start,
          window_end,
          scope_user_id(scope)
        ]
      )

    intervals_by_monitor =
      Map.new(monitor_intervals, fn {monitor_id, base, display} ->
        {monitor_id, %{base_interval_seconds: base, display_interval_seconds: display}}
      end)

    rows
    |> Enum.map(fn [
                     monitor_id,
                     base_interval,
                     display_interval,
                     bucket_start,
                     check_count,
                     expected_interval_count,
                     covered_interval_count,
                     missing_interval_count,
                     anomaly_interval_count,
                     down_interval_count,
                     slow_interval_count,
                     up_interval_count,
                     state
                   ] ->
      # A raw Repo.query! returns a NaiveDateTime for a timestamp column, not
      # a DateTime. Coerce at this boundary; the fold only ever sees DateTime.
      bucket_start = normalize_datetime!(bucket_start)
      state = aggregate_state(state)
      intervals = Map.get(intervals_by_monitor, monitor_id, %{})

      %{
        org_id: org_id,
        project_id: project_id,
        monitor_id: monitor_id,
        start_at: bucket_start,
        end_at: DateTime.add(bucket_start, display_interval, :second),
        state: state,
        check_count: check_count,
        base_interval_seconds: base_interval,
        interval_seconds: Map.get(intervals, :display_interval_seconds, display_interval),
        expected_interval_count: expected_interval_count,
        covered_interval_count: covered_interval_count,
        missing_interval_count: missing_interval_count,
        state_counts: %{
          anomaly: anomaly_interval_count,
          down: down_interval_count,
          slow: slow_interval_count,
          up: up_interval_count
        }
      }
    end)
    |> Enum.group_by(& &1.monitor_id)
  end

  def aggregate_checks!(org_id, project_id, monitor_intervals, window_start, window_end),
    do: aggregate_checks!(org_id, project_id, monitor_intervals, window_start, window_end, nil)

  defp scope_user_id(%{user_id: user_id}), do: user_id
  defp scope_user_id(_scope), do: nil

  defp normalize_datetime!(%DateTime{} = datetime), do: datetime

  defp normalize_datetime!(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp normalize_datetime!(value),
    do:
      raise(
        ArgumentError,
        "uptime aggregate returned an invalid bucket timestamp: #{inspect(value)}"
      )

  defp aggregate_state("up"), do: :up
  defp aggregate_state("down"), do: :down
  defp aggregate_state("slow"), do: :slow
  defp aggregate_state("anomaly"), do: :anomaly
  defp aggregate_state("partial"), do: :partial
  defp aggregate_state("missing"), do: :missing

  @doc "Rejects evidence whose tenant or monitor identity differs from `scope`."
  @spec validate_scope!([map()], map()) :: :ok
  def validate_scope!(records, scope) when is_list(records) and is_map(scope) do
    validate_records!(records, [], [], scope)
    :ok
  end

  @doc false
  # Guards the checks/incidents/pauses lists `trace/5` is about to fold.
  # `nil` scope only asserts the shapes are lists; a scope also rejects any
  # record whose org/project/monitor id disagrees with the caller's tenant.
  @spec validate_records!([map()], [map()], [map()], map() | nil) :: :ok
  def validate_records!(checks, incidents, pauses, nil)
      when is_list(checks) and is_list(incidents) and is_list(pauses),
      do: :ok

  def validate_records!(_checks, _incidents, _pauses, nil),
    do: raise(ArgumentError, "uptime evidence must be lists")

  def validate_records!(checks, incidents, pauses, scope) when is_map(scope) do
    validate_scope_records!(checks, scope)
    validate_scope_records!(incidents, scope)
    validate_scope_records!(pauses, scope)
    :ok
  end

  defp validate_scope_records!(records, scope) when is_list(records) do
    Enum.each(records, fn record ->
      Enum.each([:org_id, :project_id, :monitor_id], fn field ->
        expected = Map.get(scope, field)
        actual = value(record, field)

        if not is_nil(actual) and not is_nil(expected) and actual != expected do
          raise ArgumentError,
                "uptime evidence #{field} does not match the requested monitor scope"
        end
      end)
    end)
  end

  @doc false
  # Guards the pre-aggregated bucket rows `trace/5` accepts from
  # `aggregate_checks!/5,6`: same tenant scope check, plus the shape every
  # bucket must carry to fold correctly.
  @spec validate_bucket_evidence!([map()], map() | nil) :: :ok
  def validate_bucket_evidence!(evidence, scope) when is_list(evidence) do
    if is_map(scope), do: validate_scope_records!(evidence, scope)

    Enum.each(evidence, fn row ->
      unless is_map(row) and is_integer(Map.get(row, :check_count)) and
               Map.has_key?(row, :start_at) do
        raise ArgumentError, "uptime bucket evidence must include start_at and check_count"
      end
    end)

    :ok
  end

  def validate_bucket_evidence!(_evidence, _scope),
    do: raise(ArgumentError, "uptime bucket evidence must be a list")

  defp value(record, field) when is_map(record), do: Map.get(record, field)
  defp value(_record, _field), do: nil
end
