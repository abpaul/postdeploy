defmodule Alplus.Observe.DeploymentCorrelation do
  @moduledoc """
  Compares one stored Observe release with the evidence around its deployment.

  A release is the only deployment marker. Monitor checks, Measure rollups,
  and error events are read only when their organization, project, and
  environment match that release. Measure Sources remain separate rows even
  when they share an environment.

  This module is a bounded read model. It uses direct SQL because ordered
  percentiles and conditional aggregates are not useful Ash collection reads.
  Every statement repeats the tenant and membership predicates. The caller
  receives explicit evidence and comparison states instead of inferred zeros.
  """

  alias Alplus.Repo
  alias Alplus.Scope

  @windows %{
    "1h" => 3_600,
    "6h" => 21_600,
    "24h" => 86_400,
    "7d" => 604_800,
    "30d" => 2_592_000,
    "90d" => 7_776_000
  }
  @default_window "24h"
  @max_window_seconds 90 * 86_400
  @max_resources 100
  @max_releases 100
  @minimum_latency_samples 2

  @type state :: :ready | :partial | :insufficient | :unavailable | :ambiguous | :confounded
  @type direction :: :better | :worse | :neutral | :unavailable

  @doc "Returns the supported before and after window labels."
  @spec windows() :: %{String.t() => pos_integer()}
  def windows, do: @windows

  @doc "Returns the default before and after window label."
  def default_window, do: @default_window

  @doc "Compares a release with project-scoped Monitor, Measure, and Observe evidence."
  @spec correlate(map(), Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def correlate(release, scope, options \\ [])

  def correlate(%{id: release_id}, %Scope{} = scope, options)
      when is_binary(release_id) and is_list(options) do
    with {:ok, release} <- fetch_release(scope, release_id),
         {:ok, window} <- build_window(release.released_at, options),
         {:ok, resources} <- matching_resources(scope, release.environment),
         {:ok, errors} <- error_comparison(scope, release, window),
         {:ok, monitors} <-
           monitor_comparisons(scope, resources.monitors, release.environment, window),
         {:ok, measure_sources} <-
           measure_comparisons(scope, resources.measure_sources, release.environment, window) do
      {:ok,
       build_result(
         release,
         window,
         resources,
         errors,
         monitors,
         measure_sources
       )}
    end
  end

  def correlate(_release, _scope, _options), do: {:error, :invalid_release}

  @doc "Returns release markers for a matching project environment."
  @spec markers(Scope.t(), String.t() | nil, keyword()) :: [map()]
  def markers(%Scope{} = scope, environment, options \\ []) when is_list(options) do
    if is_nil(environment) do
      []
    else
      {since, until} = marker_bounds(options)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT r.id, r.version, r.commit_sha, r.released_at
          FROM releases AS r
          WHERE r.org_id = $1
            AND r.project_id = $2
            AND r.environment IS NOT DISTINCT FROM $3
            AND r.released_at >= $4
            AND r.released_at < $5
            AND EXISTS (
              SELECT 1 FROM sources AS source
              WHERE source.id = r.source_id
                AND source.org_id = r.org_id
                AND source.project_id = r.project_id
                AND source.type = 'observe'
                AND source.environment = r.environment
            )
            AND EXISTS (
              SELECT 1 FROM memberships AS m
              WHERE m.org_id = $1 AND m.user_id = $6
            )
          ORDER BY r.released_at ASC, r.id ASC
          LIMIT $7
          """,
          [
            scope.org_id,
            scope.project_id,
            environment,
            since,
            until,
            scope.user_id,
            @max_releases
          ]
        )

      Enum.map(rows, fn [id, version, commit_sha, released_at] ->
        deployed_at = normalize_datetime(released_at)

        %{
          id: id,
          version: version,
          commit_sha: commit_sha,
          released_at: deployed_at,
          deployed_at: deployed_at,
          at: deployed_at
        }
      end)
    end
  end

  @doc "Calculates a metric delta without hiding a missing sample."
  @spec metric(term(), term(), :lower_is_better | :higher_is_better | :descriptive) :: map()
  def metric(before, after_value, direction \\ :descriptive) do
    state = metric_state(before, after_value)
    delta = if state == :ready, do: after_value - before
    delta_percent = percentage_change(before, after_value)

    %{
      before: before,
      after: after_value,
      delta: delta,
      delta_percent: delta_percent,
      direction: classify_direction(delta, state, direction),
      state: state
    }
  end

  defp fetch_release(scope, release_id) do
    case Repo.query(
           """
           SELECT r.id, r.org_id, r.project_id, r.source_id, r.environment,
                  r.version, r.commit_sha, r.released_at,
                  s.id, s.type, s.environment
           FROM releases AS r
           LEFT JOIN sources AS s ON s.id = r.source_id
             AND s.org_id = r.org_id AND s.project_id = r.project_id
           WHERE r.id = $1
             AND r.org_id = $2
             AND r.project_id = $3
             AND EXISTS (
               SELECT 1 FROM memberships AS m
               WHERE m.org_id = $2 AND m.user_id = $4
             )
           LIMIT 1
           """,
           [release_id, scope.org_id, scope.project_id, scope.user_id]
         ) do
      {:ok,
       %{
         rows: [
           [
             id,
             org_id,
             project_id,
             source_id,
             environment,
             version,
             commit_sha,
             at,
             source_row_id,
             source_type,
             source_environment
           ]
         ]
       }} ->
        {:ok,
         %{
           id: id,
           org_id: org_id,
           project_id: project_id,
           source_id: source_id,
           environment: environment,
           version: version,
           commit_sha: commit_sha,
           released_at: normalize_datetime(at),
           source_valid?: source_row_id != nil and source_type == "observe",
           environment_valid?:
             not is_nil(environment) and
               source_row_id != nil and source_environment == environment
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp matching_resources(scope, environment) do
    monitors =
      Repo.query!(
        """
        SELECT m.id, m.name, m.environment, m.status
        FROM monitors AS m
        WHERE m.org_id = $1
          AND m.project_id = $2
          AND m.status = 'active'
          AND m.environment IS NOT DISTINCT FROM $3
          AND EXISTS (
            SELECT 1 FROM memberships AS membership
            WHERE membership.org_id = $1 AND membership.user_id = $4
          )
        ORDER BY m.name ASC, m.id ASC
        LIMIT $5
        """,
        [scope.org_id, scope.project_id, environment, scope.user_id, @max_resources]
      ).rows
      |> Enum.map(&resource_row(&1, :monitor))

    measure_sources =
      Repo.query!(
        """
        SELECT s.id, s.name, s.environment, s.status
        FROM sources AS s
        WHERE s.org_id = $1
          AND s.project_id = $2
          AND s.type = 'measure'
          AND s.status = 'active'
          AND s.environment IS NOT DISTINCT FROM $3
          AND EXISTS (
            SELECT 1 FROM memberships AS membership
            WHERE membership.org_id = $1 AND membership.user_id = $4
          )
        ORDER BY s.name ASC, s.id ASC
        LIMIT $5
        """,
        [scope.org_id, scope.project_id, environment, scope.user_id, @max_resources]
      ).rows
      |> Enum.map(&resource_row(&1, :measure_source))

    {:ok, %{monitors: monitors, measure_sources: measure_sources}}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:database, error}}
  end

  defp error_comparison(scope, release, window) do
    if not release.source_valid? or not release.environment_valid? do
      {:ok, unavailable_error(release.source_id)}
    else
      %{rows: [row]} =
        Repo.query!(
          """
          SELECT
            count(*) FILTER (
              WHERE e.received_at >= $4 AND e.received_at < $5
            )::bigint,
            count(*) FILTER (
              WHERE e.received_at >= $5 AND e.received_at < $6
            )::bigint,
            count(DISTINCT date_trunc('hour', e.received_at)) FILTER (
              WHERE e.received_at >= $4 AND e.received_at < $5
            )::bigint,
            count(DISTINCT date_trunc('hour', e.received_at)) FILTER (
              WHERE e.received_at >= $5 AND e.received_at < $6
            )::bigint
          FROM error_events AS e
          WHERE e.org_id = $1
            AND e.project_id = $2
            AND e.source_id = $3
            AND e.environment IS NOT DISTINCT FROM $7
            AND e.received_at >= $4
            AND e.received_at < $6
            AND EXISTS (
              SELECT 1 FROM memberships AS m
              WHERE m.org_id = $1 AND m.user_id = $8
            )
          """,
          [
            scope.org_id,
            scope.project_id,
            release.source_id,
            window.before_start,
            window.release_at,
            window.after_end,
            release.environment,
            scope.user_id
          ]
        )

      [before_count, after_count, before_buckets, after_buckets] = Enum.map(row, &integer_value/1)

      before = evidence(before_count, before_buckets, window.window_seconds)
      after_value = evidence(after_count, after_buckets, window.window_seconds)

      state = evidence_metric_state(window, before, after_value)

      {:ok,
       %{
         key: :errors,
         label: "Error volume",
         metric: mask_metric(metric(before_count, after_count, :lower_is_better), state),
         before: before,
         after: after_value,
         coverage: %{before: before, after: after_value},
         state: state,
         source_id: release.source_id
       }}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:database, error}}
  end

  defp monitor_comparisons(_scope, [], _environment, _window), do: {:ok, []}

  defp monitor_comparisons(scope, monitors, environment, window) do
    ids = Enum.map(monitors, & &1.id)

    metrics =
      Repo.query!(
        """
        SELECT c.monitor_id,
          count(*) FILTER (
            WHERE c.checked_at >= $5 AND c.checked_at < $6
          )::bigint,
          count(*) FILTER (
            WHERE c.checked_at >= $6 AND c.checked_at < $7
          )::bigint,
          count(c.latency_ms) FILTER (
            WHERE c.checked_at >= $5 AND c.checked_at < $6
          )::bigint,
          count(c.latency_ms) FILTER (
            WHERE c.checked_at >= $6 AND c.checked_at < $7
          )::bigint,
          percentile_cont(0.95) WITHIN GROUP (ORDER BY c.latency_ms) FILTER (
            WHERE c.checked_at >= $5 AND c.checked_at < $6 AND c.latency_ms IS NOT NULL
          ),
          percentile_cont(0.95) WITHIN GROUP (ORDER BY c.latency_ms) FILTER (
            WHERE c.checked_at >= $6 AND c.checked_at < $7 AND c.latency_ms IS NOT NULL
          )
        FROM monitor_checks AS c
        WHERE c.org_id = $1
          AND c.project_id = $2
          AND c.monitor_id = ANY($3::text[])
          AND c.environment IS NOT DISTINCT FROM $4
          AND c.checked_at >= $5
          AND c.checked_at < $7
          AND EXISTS (
            SELECT 1 FROM memberships AS m
            WHERE m.org_id = $1 AND m.user_id = $8
          )
        GROUP BY c.monitor_id
        """,
        [
          scope.org_id,
          scope.project_id,
          ids,
          environment,
          window.before_start,
          window.release_at,
          window.after_end,
          scope.user_id
        ]
      ).rows
      |> Map.new(&monitor_metric_row/1)

    incidents = incident_overlaps(scope, ids, environment, window)

    {:ok,
     Enum.map(monitors, fn monitor ->
       values =
         Map.get(metrics, monitor.id, %{
           before_samples: 0,
           after_samples: 0,
           before_latency_samples: 0,
           after_latency_samples: 0,
           before_p95: nil,
           after_p95: nil
         })

       before =
         evidence(values.before_samples, values.before_latency_samples, window.window_seconds)

       after_value =
         evidence(values.after_samples, values.after_latency_samples, window.window_seconds)

       incident =
         Map.get(incidents, monitor.id, %{ids: [], overlap?: false, incident_markers: []})

       comparison = metric(values.before_p95, values.after_p95, :lower_is_better)

       comparison =
         comparison_with_state(
           comparison,
           window,
           before,
           after_value,
           incident.overlap?,
           @minimum_latency_samples
         )

       comparison = mask_metric(comparison, comparison.state)

       %{
         resource: monitor,
         monitor: monitor,
         metric: :p95_latency,
         label: "p95 latency",
         before: values.before_p95,
         after: values.after_p95,
         comparison: comparison,
         before_after: comparison,
         incident_overlap?: incident.overlap?,
         confounded?: incident.overlap?,
         incident_ids: incident.ids,
         incident_markers: incident.incident_markers,
         coverage: %{before: before, after: after_value},
         state: comparison.state
       }
     end)}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:database, error}}
  end

  defp measure_comparisons(_scope, [], _environment, _window), do: {:ok, []}

  defp measure_comparisons(scope, sources, environment, window) do
    ids = Enum.map(sources, & &1.id)
    hour_rows = measure_hour_rows(scope, ids, environment, window)
    day_rows = measure_day_rows(scope, ids, environment, window)

    {:ok,
     Enum.map(sources, fn source ->
       values =
         case Map.get(hour_rows, source.id) do
           %{bucket_count: count} = row when count > 0 -> Map.put(row, :granularity, :hour)
           _ -> day_values(Map.get(day_rows, source.id), window)
         end

       before =
         evidence(
           values.before_buckets,
           values.before_buckets,
           window.window_seconds,
           values.granularity
         )

       after_value =
         evidence(
           values.after_buckets,
           values.after_buckets,
           window.window_seconds,
           values.granularity
         )

       comparison = metric(values.before_pageviews, values.after_pageviews, :descriptive)

       comparison = comparison_with_state(comparison, window, before, after_value, false, 0)

       comparison =
         Map.put(
           comparison,
           :traffic_direction,
           traffic_direction(comparison.delta, comparison.state)
         )

       comparison = mask_metric(comparison, comparison.state)

       comparison =
         if comparison.state == :ready,
           do: comparison,
           else: Map.put(comparison, :traffic_direction, :unavailable)

       %{
         resource: source,
         source: source,
         metric: :traffic,
         label: "Traffic",
         before: values.before_pageviews,
         after: values.after_pageviews,
         comparison: comparison,
         before_after: comparison,
         visitors: %{before: values.before_visitors, after: values.after_visitors},
         visits: %{before: values.before_visits, after: values.after_visits},
         granularity: values.granularity,
         coverage: %{before: before, after: after_value},
         state: comparison.state
       }
     end)}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:database, error}}
  end

  defp measure_hour_rows(scope, ids, environment, window) do
    Repo.query!(
      """
      SELECT a.source_id,
        count(*) FILTER (WHERE a.hour >= $5 AND a.hour < $6)::bigint,
        count(*) FILTER (WHERE a.hour >= $6 AND a.hour < $7)::bigint,
        sum(a.pageviews) FILTER (WHERE a.hour >= $5 AND a.hour < $6)::bigint,
        sum(a.pageviews) FILTER (WHERE a.hour >= $6 AND a.hour < $7)::bigint,
        sum(a.visitors) FILTER (WHERE a.hour >= $5 AND a.hour < $6)::bigint,
        sum(a.visitors) FILTER (WHERE a.hour >= $6 AND a.hour < $7)::bigint,
        sum(a.visits) FILTER (WHERE a.hour >= $5 AND a.hour < $6)::bigint,
        sum(a.visits) FILTER (WHERE a.hour >= $6 AND a.hour < $7)::bigint
      FROM analytics_hours AS a
      WHERE a.org_id = $1
        AND a.project_id = $2
        AND a.source_id = ANY($3::text[])
        AND a.environment IS NOT DISTINCT FROM $4
        AND a.hour >= $5
        AND a.hour < $7
        AND EXISTS (
          SELECT 1 FROM memberships AS m
          WHERE m.org_id = $1 AND m.user_id = $8
        )
      GROUP BY a.source_id
      """,
      [
        scope.org_id,
        scope.project_id,
        ids,
        environment,
        window.before_start,
        window.release_at,
        window.after_end,
        scope.user_id
      ]
    ).rows
    |> Map.new(&measure_hour_row/1)
  end

  defp measure_day_rows(scope, ids, environment, window) do
    before_start = DateTime.to_date(window.before_start)
    release_date = DateTime.to_date(window.release_at)
    after_end = DateTime.to_date(window.after_end)

    Repo.query!(
      """
      SELECT a.source_id,
        count(*) FILTER (WHERE a.date >= $5::date AND a.date < $6::date)::bigint,
        count(*) FILTER (WHERE a.date >= $6::date AND a.date < $7::date)::bigint,
        sum(a.pageviews) FILTER (WHERE a.date >= $5::date AND a.date < $6::date)::bigint,
        sum(a.pageviews) FILTER (WHERE a.date >= $6::date AND a.date < $7::date)::bigint,
        sum(a.visitors) FILTER (WHERE a.date >= $5::date AND a.date < $6::date)::bigint,
        sum(a.visitors) FILTER (WHERE a.date >= $6::date AND a.date < $7::date)::bigint,
        sum(a.visits) FILTER (WHERE a.date >= $5::date AND a.date < $6::date)::bigint,
        sum(a.visits) FILTER (WHERE a.date >= $6::date AND a.date < $7::date)::bigint
      FROM analytics_days AS a
      WHERE a.org_id = $1
        AND a.project_id = $2
        AND a.source_id = ANY($3::text[])
        AND a.environment IS NOT DISTINCT FROM $4
        AND a.date >= $5::date
        AND a.date < $7::date
        AND EXISTS (
          SELECT 1 FROM memberships AS m
          WHERE m.org_id = $1 AND m.user_id = $8
        )
      GROUP BY a.source_id
      """,
      [
        scope.org_id,
        scope.project_id,
        ids,
        environment,
        before_start,
        release_date,
        after_end,
        scope.user_id
      ]
    ).rows
    |> Map.new(&measure_day_row/1)
  end

  defp incident_overlaps(_scope, [], _environment, _window), do: %{}

  defp incident_overlaps(scope, monitor_ids, environment, window) do
    Repo.query!(
      """
      SELECT i.monitor_id,
             array_agg(i.id ORDER BY i.started_at, i.id),
             array_agg(i.started_at ORDER BY i.started_at, i.id),
             count(*)::bigint
      FROM incidents AS i
      WHERE i.org_id = $1
        AND i.project_id = $2
        AND i.monitor_id = ANY($3::text[])
        AND i.environment IS NOT DISTINCT FROM $4
        AND i.started_at < $6
        AND COALESCE(i.resolved_at, $6) > $5
        AND EXISTS (
          SELECT 1 FROM memberships AS m
          WHERE m.org_id = $1 AND m.user_id = $7
        )
      GROUP BY i.monitor_id
      """,
      [
        scope.org_id,
        scope.project_id,
        monitor_ids,
        environment,
        window.before_start,
        window.after_end,
        scope.user_id
      ]
    ).rows
    |> Map.new(fn [monitor_id, ids, started_at, count] ->
      markers = Enum.map(List.wrap(started_at), &%{at: normalize_datetime(&1)})

      {monitor_id,
       %{ids: List.wrap(ids), overlap?: integer_value(count) > 0, incident_markers: markers}}
    end)
  end

  defp build_result(release, window, resources, errors, monitors, measure_sources) do
    evidence_valid? = release.source_valid? and release.environment_valid?

    {monitors, measure_sources} =
      if evidence_valid? do
        {monitors, measure_sources}
      else
        {Enum.map(monitors, &mask_row/1), Enum.map(measure_sources, &mask_row/1)}
      end

    all_states =
      [errors.state | Enum.map(monitors ++ measure_sources, & &1.state)]

    state =
      cond do
        not release.environment_valid? -> :ambiguous
        not release.source_valid? -> :unavailable
        not window.equal? -> :unavailable
        Enum.any?(monitors, & &1.confounded?) -> :confounded
        Enum.any?(all_states, &(&1 == :ready)) -> :ready
        Enum.any?(all_states, &(&1 in [:partial, :insufficient])) -> :partial
        true -> :unavailable
      end

    reason =
      cond do
        not release.environment_valid? -> :missing_environment
        not release.source_valid? -> :invalid_source
        not window.equal? -> :unequal_windows
        Enum.any?(monitors, & &1.confounded?) -> :incident_overlap
        state in [:unavailable, :partial] -> :insufficient_evidence
        true -> nil
      end

    %{
      state: state,
      status: state,
      reason: reason,
      release: release,
      environment: release.environment,
      window: window,
      errors: errors,
      error: errors,
      monitors: monitors,
      monitor_comparisons: monitors,
      measure_sources: measure_sources,
      measure_comparisons: measure_sources,
      resources: resources,
      annotations: Enum.map(markers_from_release(release), &Map.put(&1, :kind, :deploy)),
      evidence: %{
        errors: errors.coverage,
        monitors: Enum.map(monitors, &%{id: &1.resource.id, coverage: &1.coverage}),
        measure_sources: Enum.map(measure_sources, &%{id: &1.resource.id, coverage: &1.coverage})
      }
    }
  end

  defp markers_from_release(release) do
    deployed_at = release.released_at

    [
      %{
        id: release.id,
        version: release.version,
        commit_sha: release.commit_sha,
        released_at: deployed_at,
        deployed_at: deployed_at,
        at: deployed_at
      }
    ]
  end

  defp build_window(released_at, options) do
    with {:ok, seconds} <- window_seconds(options),
         {:ok, now} <- option_now(options) do
      released_at = normalize_datetime(released_at)
      before_start = DateTime.add(released_at, -seconds, :second)
      requested_after_end = DateTime.add(released_at, seconds, :second)
      after_end = min_datetime(requested_after_end, now)
      after_seconds = max(DateTime.diff(after_end, released_at, :second), 0)

      {:ok,
       %{
         label: Keyword.get(options, :window, @default_window),
         window_seconds: seconds,
         expected_seconds: seconds,
         release_at: released_at,
         before_start: before_start,
         before_end: released_at,
         after_start: released_at,
         after_end: after_end,
         before_seconds: seconds,
         after_seconds: after_seconds,
         equal?: after_seconds == seconds,
         complete?: after_seconds == seconds,
         truncated?: after_seconds != seconds
       }}
    end
  end

  defp window_seconds(options) do
    value = Keyword.get(options, :window_seconds, Keyword.get(options, :seconds))

    value =
      if is_nil(value),
        do: Map.get(@windows, Keyword.get(options, :window, @default_window)),
        else: value

    if is_integer(value) and value > 0 and value <= @max_window_seconds,
      do: {:ok, value},
      else: {:error, :invalid_window}
  end

  defp option_now(options) do
    case Keyword.get(options, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, now}
      %NaiveDateTime{} = now -> {:ok, DateTime.from_naive!(now, "Etc/UTC")}
      _ -> {:error, :invalid_now}
    end
  end

  defp marker_bounds(options) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    now = normalize_datetime(now)

    seconds =
      Keyword.get(
        options,
        :window_seconds,
        Map.get(@windows, Keyword.get(options, :window), @max_window_seconds)
      )

    seconds =
      if is_integer(seconds) and seconds > 0,
        do: min(seconds, @max_window_seconds),
        else: @max_window_seconds

    since = DateTime.add(now, -seconds, :second)
    {since, DateTime.add(now, 1, :second)}
  end

  defp monitor_metric_row([
         id,
         before_samples,
         after_samples,
         before_latency,
         after_latency,
         before_p95,
         after_p95
       ]) do
    {id,
     %{
       before_samples: integer_value(before_samples),
       after_samples: integer_value(after_samples),
       before_latency_samples: integer_value(before_latency),
       after_latency_samples: integer_value(after_latency),
       before_p95: number_value(before_p95),
       after_p95: number_value(after_p95)
     }}
  end

  defp measure_hour_row([
         source_id,
         before_buckets,
         after_buckets,
         before_pageviews,
         after_pageviews,
         before_visitors,
         after_visitors,
         before_visits,
         after_visits
       ]) do
    {source_id,
     %{
       before_buckets: integer_value(before_buckets),
       after_buckets: integer_value(after_buckets),
       bucket_count: integer_value(before_buckets) + integer_value(after_buckets),
       before_pageviews: nullable_integer_value(before_pageviews),
       after_pageviews: nullable_integer_value(after_pageviews),
       before_visitors: nullable_integer_value(before_visitors),
       after_visitors: nullable_integer_value(after_visitors),
       before_visits: nullable_integer_value(before_visits),
       after_visits: nullable_integer_value(after_visits)
     }}
  end

  defp measure_day_row(row), do: measure_hour_row(row)

  defp day_values(nil, _window), do: empty_measure_values(:day)

  defp day_values(values, window) do
    if midnight?(window.release_at) and midnight_window?(window.window_seconds) do
      Map.put(values, :granularity, :day)
    else
      empty_measure_values(:day)
    end
  end

  defp empty_measure_values(granularity) do
    %{
      before_buckets: 0,
      after_buckets: 0,
      bucket_count: 0,
      before_pageviews: nil,
      after_pageviews: nil,
      before_visitors: nil,
      after_visitors: nil,
      before_visits: nil,
      after_visits: nil,
      granularity: granularity
    }
  end

  defp comparison_with_state(
         comparison,
         window,
         before,
         after_value,
         confounded?,
         minimum_samples
       ) do
    state =
      cond do
        confounded? ->
          :confounded

        not window.equal? ->
          :unavailable

        before.bucket_count == 0 or after_value.bucket_count == 0 ->
          :insufficient

        minimum_samples > 0 and
            (before.bucket_count < minimum_samples or after_value.bucket_count < minimum_samples) ->
          :insufficient

        before.coverage < 1.0 or after_value.coverage < 1.0 ->
          :partial

        comparison.state != :ready ->
          :insufficient

        true ->
          :ready
      end

    direction = if state == :ready, do: comparison.direction, else: :unavailable
    %{comparison | state: state, direction: direction}
  end

  defp evidence_metric_state(window, before, after_value) do
    cond do
      not window.equal? -> :unavailable
      before.bucket_count == 0 or after_value.bucket_count == 0 -> :insufficient
      before.coverage < 1.0 or after_value.coverage < 1.0 -> :partial
      true -> :ready
    end
  end

  defp evidence(sample_count, bucket_count, expected_seconds, granularity \\ :hour) do
    sample_count = integer_value(sample_count)
    bucket_count = integer_value(bucket_count)
    bucket_seconds = if granularity == :day, do: 86_400, else: 3_600
    expected_buckets = max(ceil(expected_seconds / bucket_seconds), 1)

    %{
      sample_count: sample_count,
      bucket_count: bucket_count,
      expected_buckets: expected_buckets,
      coverage: Float.round(min(bucket_count / expected_buckets, 1.0), 3),
      state: if(bucket_count > 0, do: :available, else: :missing)
    }
  end

  defp metric_state(before, after_value) when is_number(before) and is_number(after_value),
    do: :ready

  defp metric_state(_before, _after_value), do: :unavailable

  defp classify_direction(_delta, :unavailable, _kind), do: :unavailable
  defp classify_direction(0, :ready, _kind), do: :neutral
  defp classify_direction(delta, :ready, :lower_is_better) when delta < 0, do: :better
  defp classify_direction(delta, :ready, :lower_is_better) when delta > 0, do: :worse
  defp classify_direction(delta, :ready, :higher_is_better) when delta > 0, do: :better
  defp classify_direction(delta, :ready, :higher_is_better) when delta < 0, do: :worse
  defp classify_direction(_delta, :ready, :descriptive), do: :neutral

  defp traffic_direction(_delta, state) when state != :ready, do: :unavailable
  defp traffic_direction(0, :ready), do: :neutral
  defp traffic_direction(delta, :ready) when delta > 0, do: :increase
  defp traffic_direction(_delta, :ready), do: :decrease

  defp percentage_change(before, after_value)
       when is_number(before) and is_number(after_value) and before != 0,
       do: Float.round((after_value - before) / before * 100, 2)

  defp percentage_change(_before, _after_value), do: nil

  defp resource_row([id, name, environment, status], type),
    do: %{id: id, name: name, environment: environment, status: status, type: type}

  defp midnight?(%DateTime{hour: 0, minute: 0, second: 0}), do: true
  defp midnight?(_value), do: false

  defp midnight_window?(seconds), do: rem(seconds, 86_400) == 0

  defp min_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: left, else: right
  end

  defp normalize_datetime(%DateTime{} = value), do: value
  defp normalize_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp normalize_datetime(value), do: value

  defp unavailable_error(source_id) do
    coverage = %{
      sample_count: 0,
      bucket_count: 0,
      expected_buckets: 0,
      coverage: 0.0,
      state: :missing
    }

    %{
      key: :errors,
      label: "Error volume",
      metric: mask_metric(metric(nil, nil, :lower_is_better), :unavailable),
      before: coverage,
      after: coverage,
      coverage: %{before: coverage, after: coverage},
      state: :unavailable,
      source_id: source_id
    }
  end

  defp mask_row(row) do
    comparison = mask_metric(row.comparison, :unavailable)

    row
    |> Map.merge(%{
      before: nil,
      after: nil,
      visitors: %{before: nil, after: nil},
      visits: %{before: nil, after: nil},
      comparison: comparison,
      before_after: comparison,
      state: :unavailable
    })
  end

  defp mask_metric(metric, :ready), do: metric

  defp mask_metric(metric, _state) do
    %{metric | before: nil, after: nil, delta: nil, delta_percent: nil, direction: :unavailable}
  end

  defp integer_value(nil), do: 0
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value), do: trunc(value)

  defp nullable_integer_value(nil), do: nil
  defp nullable_integer_value(value), do: integer_value(value)

  defp number_value(nil), do: nil
  defp number_value(value) when is_integer(value), do: value
  defp number_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp number_value(value) when is_float(value), do: value
  defp number_value(value), do: value |> to_string() |> String.to_float()
end
