defmodule Alplus.Measure.Dashboard do
  @moduledoc """
  Per-source (site) Measure reads for issue #34 Model A.

  A Measure Source is a site: two sites can share a project, and even an
  environment, so every read here is scoped by `source_id` — never merely
  `project_id`. Real-time windows (`24h`/`7d`) prefer
  `Alplus.Measure.AnalyticsEngine`; when it is unavailable (or unconfigured,
  the production default today) every read falls back to the durable
  PostgreSQL rollups the ingest path already attributes to this source
  (`Alplus.Measure.Rollups`, `Alplus.Measure.Ingest`). `30d`/`90d` windows
  always read the PostgreSQL day rollups — Analytics Engine only retains a
  short recent window.

  Every function takes an `actor` (a `%Alplus.Scope{}` already carrying
  `project_id: source.project_id`) and passes it straight to the
  `analytics_days`/`analytics_hours`/`analytics_dimensions` Ash policies,
  which re-check `org_id`/`project_id` at the query — the `source_id`
  arguments below are the additional, per-site narrowing this module adds
  on top of that project-level authorization.

  This module is the facade for dashboard reads. `Alplus.Measure.Dashboard.TelemetryResolver`
  owns telemetry resolution, including source selection, merging, and fallback
  between Analytics Engine and durable PostgreSQL rollups. The PostgreSQL-only
  queries live in `Alplus.Measure.Dashboard.RollupFallback`, which acts only as
  their adapter. The shared outage classifier lives in
  `Alplus.Measure.DataLayerErrors`.
  """

  alias Alplus.Measure
  alias Alplus.Measure.{DataLayerErrors, Rollups, ShareActor}
  alias Alplus.Measure.Dashboard.RollupFallback
  alias Alplus.Measure.Dashboard.TelemetryResolver
  alias Alplus.Measure.Retention

  @windows ~w(24h 7d 30d 90d)
  @breakdown_labels %{
    "country" => "Countries",
    "browser" => "Browsers"
  }
  @panel_dimensions ~w(path referrer event country browser)
  @panel_page_size 8
  @max_panel_page 25

  @doc "Four honest headline metrics and their immediately preceding equal-period comparisons."
  def headlines(source, window, actor, opts \\ []) when window in @windows do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {current, previous, metadata} = period_totals(source, window, actor, now, opts)

    headline_metrics(current, previous, metadata)
  end

  defp headline_metrics(current, previous, metadata) do
    current_bounce_rate = rate(current.bounces, current.visits)
    previous_bounce_rate = rate(previous.bounces, previous.visits)
    current_duration = engaged_duration(current)
    previous_duration = engaged_duration(previous)

    %{
      visits:
        current.visits
        |> compared(previous.visits)
        |> with_coverage(Map.get(current, :coverage), Map.get(current, :known_visits)),
      visitors:
        current.visitors
        |> compared(previous.visitors)
        |> with_coverage(Map.get(current, :coverage), Map.get(current, :known_visitors)),
      pageviews:
        current.pageviews
        |> compared(previous.pageviews)
        |> with_coverage(Map.get(current, :coverage), Map.get(current, :known_pageviews)),
      bounce_rate: compared_points(current_bounce_rate, previous_bounce_rate),
      avg_duration: compared(current_duration, previous_duration),
      unavailable?: metadata.data_source_key == :unavailable,
      data_source: metadata.data_source,
      data_source_key: metadata.data_source_key,
      partial?: metadata.partial?
    }
  end

  @doc """
  One bounded, source-isolated portfolio read for the current display period
  and its immediately preceding equal period.

  The response deliberately carries only the metrics the portfolio needs.
  Its trend and every per-site sparkline use the same visible bucket grid:
  twenty-four hourly buckets, seven daily buckets, or thirty daily buckets,
  each ending in the bucket now in progress. A quiet bucket becomes zero only when retention, the selected data
  source, and that source's connection time prove it was measurable.
  """
  def portfolio(sources, window, actor, opts \\ []) when window in @windows do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    source_ids = Enum.map(sources, & &1.id)
    environments = Map.new(sources, &{&1.id, &1.environment})
    {current_buckets, previous_buckets, until} = comparison_grid(window, now)
    first_previous = List.first(previous_buckets)
    retention_boundary = retention_cutoff(actor)

    {points_by_source, metadata_by_source} =
      batched_range_points(source_ids, window, actor, environments, first_previous, until)

    {evidence_by_source, evidence_unavailable?} = batched_evidence(source_ids, actor, window)

    site_results =
      Map.new(sources, fn source ->
        metadata = Map.get(metadata_by_source, source.id, unavailable_metadata())
        evidence = Map.get(evidence_by_source, source.id, empty_evidence())
        points = Map.get(points_by_source, source.id, [])
        coverage_since = coverage_boundary(metadata)

        current_points =
          materialize_points(
            source,
            current_buckets,
            points,
            coverage_since,
            retention_boundary,
            window
          )

        previous_available? =
          not metadata.unavailable? and
            previous_covered?(coverage_since, first_previous, retention_boundary) and
            source_connected?(source, first_previous)

        previous_points =
          if previous_available? do
            materialize_points(
              source,
              previous_buckets,
              points,
              coverage_since,
              retention_boundary,
              window
            )
          else
            List.duplicate(nil, length(previous_buckets))
          end

        current = materialized_period(current_points)

        previous =
          if(previous_available?,
            do: materialized_period(previous_points),
            else: unavailable_period()
          )

        {source.id,
         %{
           pageviews: current.pageviews,
           known_pageviews: Map.get(current, :known_pageviews, current.pageviews),
           visits: current.visits,
           known_visits: Map.get(current, :known_visits, current.visits),
           coverage: Map.get(current, :coverage, :unknown),
           pageviews_previous: previous.pageviews,
           visits_previous: previous.visits,
           previous_coverage: Map.get(previous, :coverage, :unknown),
           pageviews_delta: numeric_delta(current.pageviews, previous.pageviews),
           pageviews_change: percentage_change_value(current.pageviews, previous.pageviews),
           active?:
             is_number(Map.get(current, :known_pageviews, current.pageviews)) and
               Map.get(current, :known_pageviews, current.pageviews) > 0,
           evidence?: evidence.pageviews > 0,
           first_pageview_on: evidence.first_pageview_on,
           last_pageview_on: evidence.last_pageview_on,
           trend: display_trend(window, current_buckets, current_points)
         }}
      end)

    unavailable? =
      evidence_unavailable? or
        Enum.any?(sources, fn source ->
          metadata_by_source
          |> Map.get(source.id, unavailable_metadata())
          |> Map.fetch!(:unavailable?)
        end)

    partial? =
      not unavailable? and
        Enum.any?(site_results, fn {_source_id, site} ->
          site.coverage != :full or site.previous_coverage != :full
        end)

    current_totals = portfolio_period(site_results, :current)
    previous_totals = portfolio_period(site_results, :previous)

    trend = portfolio_trend(current_buckets, site_results, window)

    %{
      totals: %{
        pageviews:
          current_totals.pageviews
          |> compared(previous_totals.pageviews)
          |> Map.put(:known_value, current_totals.known_pageviews)
          |> Map.put(:coverage, current_totals.coverage),
        visits:
          current_totals.visits
          |> compared(previous_totals.visits)
          |> Map.put(:known_value, current_totals.known_visits)
          |> Map.put(:coverage, current_totals.coverage),
        active_sites: Enum.count(site_results, fn {_id, site} -> site.active? end),
        connected_sites:
          Enum.count(sources, fn source ->
            source_connected?(source, List.last(current_buckets))
          end)
      },
      trend: trend,
      coverage: portfolio_coverage(trend),
      sites:
        Map.new(site_results, fn {source_id, site} ->
          {source_id, Map.delete(site, :visits_previous)}
        end),
      evidence?: Enum.any?(site_results, fn {_source_id, site} -> site.evidence? end),
      unavailable?: unavailable?,
      partial?: partial?
    }
  end

  @doc "One site's headline totals for `window`, the data source label, and an unavailable flag."
  def totals(source, window, actor) when window in @windows do
    {points, metadata} = window_points(source, window, actor)
    {totals_with_coverage(points, metadata), metadata.data_source, metadata.unavailable?}
  end

  @doc "One site's pageviews/visitors trend series for `window`, oldest bucket first."
  def trend(_source, window, %ShareActor{} = actor) when window in @windows do
    {points, _metadata} = public_window_points(actor, window)
    to_trend(points)
  end

  def trend(source, window, actor) when window in @windows do
    {points, _metadata} = window_points(source, window, actor)
    to_trend(points)
  end

  @doc "One public share's trend and the same data-source metadata used by totals."
  def trend_with_metadata(_source, window, %ShareActor{} = actor) when window in @windows do
    {points, metadata} = public_window_points(actor, window)

    %{
      trend: to_trend(points),
      data_source: chart_data_source(metadata),
      data_source_key: metadata.data_source_key,
      unavailable?: metadata.unavailable?,
      partial?: metadata.analytics_engine_partial?
    }
  end

  @doc """
  One doubled-range read for the detail hero: current and immediately prior
  equal periods, aligned into display-resolution slots.

  A slot is zero only inside proven source and retention coverage. It remains
  `nil` before connection, beyond coverage, or after an unavailable read. The
  earlier series is withheld unless its entire period is covered.
  """
  def comparison(source, window, actor, opts \\ []) when window in @windows do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {current_buckets, previous_buckets, until} = comparison_grid(window, now)
    first_previous = List.first(previous_buckets)
    retention_boundary = retention_cutoff(actor)

    case comparison_points(source, window, actor, first_previous, until) do
      {:ok, points, data_source_key, coverage_since} ->
        previous_available? =
          previous_covered?(coverage_since, first_previous, retention_boundary) and
            source_connected?(source, first_previous)

        current_points =
          materialize_points(
            source,
            current_buckets,
            points,
            coverage_since,
            retention_boundary,
            window
          )

        previous_points =
          if previous_available? do
            materialize_points(
              source,
              previous_buckets,
              points,
              coverage_since,
              retention_boundary,
              window
            )
          else
            List.duplicate(nil, length(previous_buckets))
          end

        current = materialized_period(current_points)

        previous =
          if(previous_available?,
            do: materialized_period(previous_points),
            else: unavailable_period()
          )

        %{
          headlines:
            headline_metrics(
              current,
              previous,
              period_metadata(data_source_key, current, previous)
            ),
          slots:
            display_slots(
              window,
              current_buckets,
              previous_buckets,
              current_points,
              previous_points
            ),
          unavailable?: false,
          previous_available?: previous_available?
        }

      {:error, :unavailable} ->
        %{
          headlines:
            headline_metrics(
              unavailable_period(),
              unavailable_period(),
              period_metadata(:unavailable)
            ),
          slots: [],
          unavailable?: true,
          previous_available?: false
        }
    end
  end

  @doc "One site's bounded top-5 dimension breakdowns for `window`."
  def breakdowns(source, window, actor) when window in @windows do
    {since, until} = dimension_date_range(window)

    rows =
      RollupFallback.top_dimension_rows(source, actor, since, until, Map.keys(@breakdown_labels))

    for {dimension, label} <- @breakdown_labels,
        grouped = Map.get(rows, dimension, []),
        grouped != [] do
      {dimension, label, grouped}
    end
  end

  @doc """
  Batched per-site summary (headline totals + trend) for every `sources`,
  scoped to one project, in one query per rollup table — never one query
  per card.
  """
  def summaries(sources, window, actor) when window in @windows do
    source_ids = Enum.map(sources, & &1.id)
    environments = Map.new(sources, &{&1.id, &1.environment})

    {points_by_source, metadata_by_source} =
      batched_window_points(source_ids, window, actor, environments)

    {evidence_by_source, evidence_unavailable?} = batched_evidence(source_ids, actor, window)

    Map.new(sources, fn source ->
      points = Map.get(points_by_source, source.id, [])
      metadata = Map.get(metadata_by_source, source.id, unavailable_metadata())
      evidence = Map.get(evidence_by_source, source.id, empty_evidence())
      totals = sum_points(points)
      evidence? = evidence.pageviews > 0
      unavailable? = metadata.unavailable? or evidence_unavailable?

      {source.id,
       %{
         totals: totals,
         trend: to_trend(points),
         data_source: metadata.data_source,
         data_source_key: metadata.data_source_key,
         analytics_engine_state: metadata.analytics_engine_state,
         analytics_engine_partial?: metadata.analytics_engine_partial?,
         analytics_engine_unavailable?: metadata.analytics_engine_unavailable?,
         fallback?: metadata.fallback?,
         unavailable?: unavailable?,
         state: summary_state(source, totals, evidence?, unavailable?),
         traffic_state: summary_state(source, totals, evidence?, unavailable?),
         evidence?: evidence?,
         evidence: evidence
       }}
    end)
  end

  @doc "One paged dashboard breakdown, with the capped overflow bucket fixed at the end."
  def panel(source, window, dimension, requested_page, actor, opts \\ [])

  def panel(_source, window, dimension, requested_page, %ShareActor{} = actor, opts)
      when window in @windows and dimension in @panel_dimensions do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    page = requested_page |> normalize_page() |> min(@max_panel_page)
    {since, until} = panel_date_range(window, now)

    Alplus.Measure.DashboardShare
    |> Ash.ActionInput.for_action(
      :public_panel,
      %{
        share_id: actor.share_id,
        org_id: actor.org_id,
        project_id: actor.project_id,
        source_id: actor.source_id,
        environment: actor.environment,
        dimension: String.to_existing_atom(dimension),
        since: since,
        until: until,
        page: page
      },
      actor: actor,
      domain: Alplus.Measure
    )
    |> Ash.run_action!()
  end

  def panel(source, window, dimension, requested_page, actor, opts)
      when window in @windows and dimension in @panel_dimensions do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    requested_page = requested_page |> normalize_page() |> min(@max_panel_page)
    {since, until} = panel_date_range(window, now)

    {metadata, rows} =
      RollupFallback.panel(
        source,
        dimension,
        actor,
        since,
        until,
        requested_page,
        @panel_page_size,
        @max_panel_page
      )

    %{
      other_count: other_count,
      total_count: total_count,
      partial?: partial?,
      distinct_values: distinct_values,
      total_pages: total_pages,
      page: page
    } =
      metadata

    other? = other_count > 0

    rows =
      if other? and page == total_pages do
        rows ++
          [
            %{
              value: Rollups.other_value(),
              label: "(other) (per-day cardinality cap)",
              count: other_count,
              share: share(other_count, total_count),
              capped?: true
            }
          ]
      else
        rows
      end

    %{
      rows: rows,
      page: page,
      total_pages: total_pages,
      distinct_values: distinct_values,
      capped?: other?,
      partial?: partial?,
      cap_metadata:
        if other? do
          %{value: Rollups.other_value(), reason: "per-day cardinality cap", position: :last}
        end,
      previous?: page > 1,
      next?: page < total_pages
    }
  end

  # ---- window resolution ---------------------------------------------------

  defp merged_recent_points_for(source_id, since, until, actor, environment) do
    source = %{id: source_id, environment: environment}
    {points_by_source, metadata_by_source} = resolve_recent_points([source], actor, since, until)
    {Map.get(points_by_source, source_id, []), Map.fetch!(metadata_by_source, source_id)}
  end

  defp window_points(source, window, actor) when window in ["24h", "7d"] do
    since = DateTime.add(DateTime.utc_now(), -window_hours(window) * 3_600, :second)
    until = DateTime.utc_now()

    {points, metadata} =
      merged_recent_points_for(source.id, since, until, actor, source.environment)

    {points, metadata}
  end

  defp window_points(source, window, actor) do
    since = Date.add(Date.utc_today(), -(window_days(window) - 1))
    until = Date.add(Date.utc_today(), 1)
    {points, metadata} = resolved_window_points(source, window, actor, since, until)
    {points, metadata}
  end

  defp batched_window_points(source_ids, window, actor, environments)
       when window in ["24h", "7d"] do
    until = DateTime.utc_now()
    since = DateTime.add(until, -window_hours(window) * 3_600, :second)
    batched_range_points(source_ids, window, actor, environments, since, until)
  end

  defp batched_window_points(source_ids, window, actor, environments) do
    until = Date.add(Date.utc_today(), 1)
    since = Date.add(until, -window_days(window))
    batched_range_points(source_ids, window, actor, environments, since, until)
  end

  defp batched_range_points(source_ids, window, actor, environments, since, until)
       when window in ["24h", "7d"] do
    sources = Enum.map(source_ids, &%{id: &1, environment: Map.fetch!(environments, &1)})
    resolve_recent_points(sources, actor, since, until)
  end

  defp batched_range_points(source_ids, _window, actor, environments, since, until) do
    sources = Enum.map(source_ids, &%{id: &1, environment: Map.fetch!(environments, &1)})
    resolve_historical_points(sources, actor, since, until)
  end

  defp resolve_recent_points(sources, actor, since, until) do
    TelemetryResolver.recent(sources, since, until, &hour_rollups_for(actor, &1, &2, &3))
  end

  defp resolve_historical_points(sources, actor, since, until) do
    TelemetryResolver.historical(sources, since, until, &day_rollups_for(actor, &1, &2, &3))
  end

  defp hour_rollups_for(%ShareActor{} = actor, _sources, since, until) do
    case RollupFallback.share_hour_rollups(since, until, actor) do
      {:ok, points} -> {:ok, %{actor.source_id => points}}
      error -> error
    end
  end

  defp hour_rollups_for(actor, sources, since, until) do
    RollupFallback.hour_rollups(
      Enum.map(sources, & &1.id),
      since,
      until,
      actor,
      Map.new(sources, &{&1.id, &1.environment})
    )
  end

  defp day_rollups_for(%ShareActor{} = actor, _sources, since, until) do
    case RollupFallback.share_day_rollups(since, until, actor) do
      {:ok, points} -> {:ok, %{actor.source_id => points}}
      error -> error
    end
  end

  defp day_rollups_for(actor, sources, since, until) do
    RollupFallback.day_rollups(
      Enum.map(sources, & &1.id),
      since,
      until,
      actor,
      Map.new(sources, &{&1.id, &1.environment})
    )
  end

  defp batched_evidence([], _actor, _window), do: {%{}, false}

  defp batched_evidence(source_ids, actor, _window) do
    with {:ok, retention_cutoff} <- retention_cutoff(actor),
         {:ok, evidence} <-
           RollupFallback.evidence(
             source_ids,
             actor,
             retention_cutoff,
             Date.add(Date.utc_today(), 1)
           ) do
      {evidence, false}
    else
      _error -> {%{}, true}
    end
  end

  defp empty_evidence do
    %{first_pageview_on: nil, last_pageview_on: nil, pageviews: 0, visitors: 0, visits: 0}
  end

  defp unavailable_metadata do
    %{
      data_source: "Data unavailable",
      data_source_key: :unavailable,
      fallback?: false,
      unavailable?: true,
      analytics_engine_state: :unavailable,
      analytics_engine_partial?: false,
      analytics_engine_unavailable?: true
    }
  end

  defp summary_state(%{status: :revoked}, _totals, _evidence?, _unavailable?),
    do: :revoked

  defp summary_state(_source, _totals, _evidence?, true), do: :unavailable

  defp summary_state(_source, %{pageviews: pageviews}, true, _unavailable?)
       when pageviews == 0,
       do: :zero_traffic

  defp summary_state(_source, %{pageviews: pageviews}, _evidence?, _unavailable?)
       when pageviews > 0,
       do: :receiving

  defp summary_state(_source, _totals, _evidence?, _unavailable?), do: :waiting

  # ---- shaping --------------------------------------------------------------

  # `analytics_hours`/AE points carry `:hour`, `analytics_days` rows carry
  # `:date` — never both in the same list, since `window_points/3` picks one
  # table per call. Each branch sorts with its own bucket's real ordering
  # (`DateTime.compare/2` / `Date.compare/2`), never a struct's default term
  # order, which does not reflect chronological order for either type.
  defp to_trend([%{hour: _} | _] = points) do
    points
    |> Enum.sort_by(& &1.hour, {:asc, DateTime})
    |> Enum.map(&trend_point(&1.hour, &1))
  end

  defp to_trend([%{date: _} | _] = points) do
    points
    |> Enum.sort_by(& &1.date, {:asc, Date})
    |> Enum.map(&trend_point(&1.date, &1))
  end

  defp to_trend([]), do: []

  defp sum_points(points) do
    summed =
      Enum.reduce(points, empty_totals(), fn point, totals ->
        %{
          totals
          | pageviews: totals.pageviews + point.pageviews,
            visitors: totals.visitors + point.visitors,
            visits: totals.visits + point.visits,
            bounces: totals.bounces + point.bounces,
            duration_seconds: totals.duration_seconds + point.duration_seconds
        }
      end)

    %{
      summed
      | bounce_rate:
          if(summed.visits == 0,
            do: "-",
            else: "#{Float.round(summed.bounces / summed.visits * 100, 1)}%"
          )
    }
  end

  defp totals_with_coverage(points, %{durable_coverage?: true}), do: sum_points(points)

  defp totals_with_coverage(points, %{analytics_engine_partial?: true}) do
    points |> sum_points() |> partial_period()
  end

  defp totals_with_coverage(points, _metadata), do: sum_points(points)

  defp empty_totals,
    do: %{
      pageviews: 0,
      visitors: 0,
      visits: 0,
      bounces: 0,
      duration_seconds: 0,
      bounce_rate: "-"
    }

  defp trend_point(bucket, point) do
    bounce_rate = rate(point.bounces, point.visits)

    %{
      bucket: bucket,
      pageviews: point.pageviews,
      visitors: point.visitors,
      visits: point.visits,
      bounce_rate: bounce_rate,
      avg_duration: engaged_duration(point)
    }
  end

  defp period_totals(_source, window, %ShareActor{} = actor, now, opts) do
    {_table, bucket, current_since, current_until, previous_since, _previous_until} =
      period_boundaries(window, now)

    case public_period_points(window, actor, previous_since, current_until, opts) do
      {:ok, points, data_source_key, metadata} ->
        {current_points, previous_points} =
          Enum.split_with(points, fn point ->
            value = Map.fetch!(point, String.to_existing_atom(bucket))
            compare_bucket(value, current_since) != :lt
          end)

        {current, previous} =
          retention_aware_periods(
            period_sum(current_points),
            period_sum(previous_points),
            actor,
            current_since,
            previous_since
          )

        current = covered_current_period(current, metadata, actor, current_since)
        previous = covered_previous_period(previous, metadata, actor, previous_since)

        {current, previous, period_metadata(data_source_key, current, previous)}

      {:error, :unavailable} ->
        {unavailable_period(), unavailable_period(), period_metadata(:unavailable)}
    end
  end

  defp period_totals(source, window, actor, now, _opts),
    do: period_totals(source, window, actor, now)

  defp period_totals(source, window, actor, now)
       when window in ["24h", "7d"] do
    {_table, bucket, current_since, current_until, previous_since, _previous_until} =
      period_boundaries(window, now)

    {points, metadata} =
      merged_recent_points_for(
        source.id,
        previous_since,
        current_until,
        actor,
        source.environment
      )

    {current_points, previous_points} =
      Enum.split_with(points, fn point ->
        value = Map.fetch!(point, String.to_existing_atom(bucket))
        compare_bucket(value, current_since) != :lt
      end)

    if metadata.unavailable? do
      {unavailable_period(), unavailable_period(), period_metadata(:unavailable)}
    else
      {current, previous} =
        retention_aware_periods(
          period_sum(current_points),
          period_sum(previous_points),
          actor,
          current_since,
          previous_since
        )

      current = covered_current_period(current, metadata, actor, current_since)
      previous = covered_previous_period(previous, metadata, actor, previous_since)

      {current, previous, period_metadata(metadata.data_source_key, current, previous)}
    end
  end

  defp period_totals(source, window, actor, now) do
    {_table, bucket, current_since, current_until, previous_since, _previous_until} =
      period_boundaries(window, now)

    {points, metadata} =
      resolved_window_points(source, window, actor, previous_since, current_until)

    {current_points, previous_points} =
      Enum.split_with(points, fn point ->
        value = Map.fetch!(point, String.to_existing_atom(bucket))
        compare_bucket(value, current_since) != :lt
      end)

    current = period_sum(current_points)
    previous = period_sum(previous_points)

    if metadata.unavailable? do
      {unavailable_period(), unavailable_period(), period_metadata(:unavailable)}
    else
      {current, previous} =
        retention_aware_periods(current, previous, actor, current_since, previous_since)

      current = covered_current_period(current, metadata, actor, current_since)
      previous = covered_previous_period(previous, metadata, actor, previous_since)

      {current, previous, period_metadata(metadata.data_source_key, current, previous)}
    end
  end

  defp period_boundaries(window, now) when window in ["24h", "7d"] do
    hours = window_hours(window)
    current_until = DateTime.add(now, 1, :second)
    current_since = DateTime.add(current_until, -hours * 3_600, :second)
    previous_since = DateTime.add(current_since, -hours * 3_600, :second)

    {"analytics_hours", "hour", current_since, current_until, previous_since, current_since}
  end

  defp period_boundaries(window, now) do
    days = window_days(window)
    current_until = now |> DateTime.to_date() |> Date.add(1)
    current_since = Date.add(current_until, -days)
    previous_since = Date.add(current_since, -days)

    {"analytics_days", "date", current_since, current_until, previous_since, current_since}
  end

  # ---- aligned comparison series -------------------------------------------

  # The grid is the window's own buckets, hour-truncated or calendar days, so
  # every slot is a real rollup bucket rather than an offset from "now". The
  # previous grid is the same list shifted back by exactly one window, which
  # is what makes slot `i` comparable across the two periods.
  defp comparison_grid("24h", now) do
    hours = window_hours("24h")
    last = %{now | minute: 0, second: 0, microsecond: {0, 0}}
    current = for offset <- (hours - 1)..0//-1, do: DateTime.add(last, -offset * 3_600, :second)
    previous = Enum.map(current, &DateTime.add(&1, -hours * 3_600, :second))

    {current, previous, DateTime.add(last, 3_600, :second)}
  end

  # "Last 7 days" reads hourly rollups (they cover the live window) but draws
  # seven calendar days ending today, so its bucket count is the count in the
  # label. The grid is every hour from the seventh day back until the hour in
  # progress; `display_groups/2` folds it into days. The previous period is
  # the same hours one week earlier, so slot `i` compares day for day.
  defp comparison_grid("7d", now) do
    last = %{now | minute: 0, second: 0, microsecond: {0, 0}}
    start = now |> DateTime.to_date() |> Date.add(-6) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    count = div(DateTime.diff(last, start, :second), 3_600) + 1
    current = for offset <- (count - 1)..0//-1, do: DateTime.add(last, -offset * 3_600, :second)
    previous = Enum.map(current, &DateTime.add(&1, -7 * 86_400, :second))

    {current, previous, DateTime.add(last, 3_600, :second)}
  end

  defp comparison_grid(window, now) do
    days = window_days(window)
    today = DateTime.to_date(now)
    current = for offset <- (days - 1)..0//-1, do: Date.add(today, -offset)
    previous = Enum.map(current, &Date.add(&1, -days))

    {current, previous, Date.add(today, 1)}
  end

  defp comparison_points(source, window, actor, since, until) when window in ["24h", "7d"] do
    {points, metadata} =
      merged_recent_points_for(source.id, since, until, actor, source.environment)

    if metadata.unavailable? do
      {:error, :unavailable}
    else
      {:ok, points, metadata.data_source_key, coverage_boundary(metadata)}
    end
  end

  defp comparison_points(source, _window, actor, since, until) do
    {points, metadata} = resolved_window_points(source, "30d", actor, since, until)

    if metadata.unavailable?,
      do: {:error, :unavailable},
      else: {:ok, points, metadata.data_source_key, coverage_boundary(metadata)}
  end

  # Analytics Engine's boundary limits only a response that lacks durable
  # coverage. A successful durable read covers every bucket it was asked for;
  # retention remains the outer limit enforced by `materialize_points/5`.
  defp coverage_boundary(%{coverage_since: coverage_since}), do: coverage_since

  defp coverage_boundary(%{durable_coverage?: true}), do: :complete

  defp coverage_boundary(%{data_source_key: data_source_key}),
    do: coverage_boundary(data_source_key)

  defp coverage_boundary(:analytics_engine), do: Measure.AnalyticsEngine.coverage_since()
  defp coverage_boundary(_data_source_key), do: :complete

  # "No previous line" and "a previous line of nothing" are different claims,
  # and so are "measured nothing" and "we cannot see that far back".
  #
  # Coverage is never inferred from the rows a read returned: an hour with no
  # traffic and an hour the sink dropped come back identically empty. The
  # durable rollups are complete inside plan retention, and Analytics Engine
  # declares its own boundary, so the earlier period is only compared when a
  # stated boundary reaches its first bucket. An undeclared boundary proves
  # nothing and is never treated as coverage.
  defp previous_covered?(coverage_since, first_previous_bucket, retention_boundary) do
    cond do
      not retention_covers?(retention_boundary, first_previous_bucket) -> false
      coverage_since == :complete -> true
      true -> covers?(coverage_since, first_previous_bucket)
    end
  end

  defp covered_previous_period(previous, metadata, actor, previous_since) do
    if previous_covered?(coverage_boundary(metadata), previous_since, retention_cutoff(actor)) do
      previous
    else
      unavailable_period()
    end
  end

  defp covered_current_period(current, metadata, actor, current_since) do
    if previous_covered?(coverage_boundary(metadata), current_since, retention_cutoff(actor)) do
      current
    else
      partial_period(current)
    end
  end

  defp covers?({:ok, %DateTime{} = boundary}, %DateTime{} = first_bucket),
    do: DateTime.compare(boundary, first_bucket) != :gt

  defp covers?({:ok, %DateTime{} = boundary}, %Date{} = first_bucket),
    do: covers?({:ok, boundary}, DateTime.new!(first_bucket, ~T[00:00:00], "Etc/UTC"))

  defp covers?(_coverage_since, _first_bucket), do: false

  defp point_bucket(%{hour: hour}), do: hour
  defp point_bucket(%{date: date}), do: date

  # Hour rollups, Analytics Engine points and the grid all name the same hour
  # but not always with the same precision, so slots are keyed by the whole
  # hour (or the calendar day) rather than by struct equality.
  defp slot_key(%DateTime{} = bucket), do: bucket |> DateTime.to_unix() |> div(3_600)
  defp slot_key(%Date{} = bucket), do: Date.to_erl(bucket)

  defp materialize_points(source, buckets, points, coverage_since, retention_boundary, window) do
    points_by_bucket = Map.new(points, &{slot_key(point_bucket(&1)), &1})

    buckets
    |> Enum.map(fn bucket ->
      case Map.fetch(points_by_bucket, slot_key(bucket)) do
        {:ok, point} ->
          point

        :error ->
          if measurable_bucket?(source, bucket, coverage_since, retention_boundary) do
            zero_point(bucket)
          end
      end
    end)
    |> fill_measured_days(window, buckets)
  end

  # A day that holds a reading was collecting all day, so its quiet hours are
  # measured zeros rather than gaps. Without this, "last 7 days" reads the
  # hourly grid and calls a day partial whenever any of its hours fall before
  # the source record's own timestamp, while "last 30 days" reads the durable
  # day rollup for the same day and calls it measured. One range then draws a
  # solid line and states a total, and the other draws a dashed gap and states
  # a lower bound, from the same evidence.
  defp fill_measured_days(materialized, "7d", buckets) do
    groups = display_groups("7d", buckets)

    [groups, chunk_like(materialized, groups)]
    |> Enum.zip_with(fn [bucket_group, point_group] ->
      if Enum.any?(point_group, &(not is_nil(&1))) do
        Enum.zip_with(bucket_group, point_group, fn bucket, point ->
          point || zero_point(bucket)
        end)
      else
        point_group
      end
    end)
    |> Enum.concat()
  end

  defp fill_measured_days(materialized, _window, _buckets), do: materialized

  defp measurable_bucket?(source, bucket, coverage_since, retention_boundary) do
    source_connected?(source, bucket) and
      retention_covers?(retention_boundary, bucket) and
      data_source_covers?(coverage_since, bucket)
  end

  defp retention_covers?({:ok, cutoff}, bucket), do: not before_retention?(bucket, cutoff)

  defp data_source_covers?(:complete, _bucket), do: true
  defp data_source_covers?(coverage_since, bucket), do: covers?(coverage_since, bucket)

  defp source_connected?(%{inserted_at: %DateTime{} = connected_at}, %DateTime{} = bucket),
    do: DateTime.compare(bucket, connected_at) != :lt

  defp source_connected?(%{inserted_at: %DateTime{} = connected_at}, %Date{} = bucket),
    do: Date.compare(bucket, DateTime.to_date(connected_at)) != :lt

  defp source_connected?(_source, _bucket), do: true

  defp zero_point(%DateTime{} = hour),
    do: %{hour: hour, pageviews: 0, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0}

  defp zero_point(%Date{} = date),
    do: %{date: date, pageviews: 0, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0}

  defp materialized_period(points) do
    measured = Enum.reject(points, &is_nil/1)

    cond do
      measured == [] ->
        unavailable_period()

      length(measured) == length(points) ->
        Map.put(period_sum(measured), :coverage, :full)

      true ->
        known = period_sum(measured)

        %{
          pageviews: nil,
          visitors: nil,
          visits: nil,
          bounces: nil,
          duration_seconds: nil,
          known_pageviews: known.pageviews,
          known_visitors: known.visitors,
          known_visits: known.visits,
          known_bounces: known.bounces,
          known_duration_seconds: known.duration_seconds,
          coverage: :partial
        }
    end
  end

  defp display_slots(window, current_buckets, previous_buckets, current_points, previous_points) do
    groups = display_groups(window, current_buckets)
    group_count = length(groups)

    [
      groups,
      chunk_like(previous_buckets, groups),
      chunk_like(current_points, groups),
      chunk_like(previous_points, groups)
    ]
    |> Enum.zip_with(fn [current_group, previous_group, current_point_group, previous_point_group] ->
      bucket = group_bucket(window, current_group)
      previous_bucket = group_bucket(window, previous_group)

      %{
        bucket: bucket,
        previous_bucket: previous_bucket,
        current: display_point(bucket, current_point_group),
        previous: display_point(previous_bucket, previous_point_group)
      }
    end)
    |> Enum.with_index()
    |> Enum.map(fn {slot, index} ->
      # The last slot is still being measured: it is a lower bound, never a
      # drop, and it is drawn as one.
      if index == group_count - 1 and is_map(slot.current),
        do: %{slot | current: Map.put(slot.current, :in_progress?, true)},
        else: slot
    end)
  end

  defp display_trend(window, buckets, points) do
    groups = display_groups(window, buckets)
    group_count = length(groups)

    [groups, chunk_like(points, groups)]
    |> Enum.zip_with(fn [bucket_group, point_group] ->
      bucket = group_bucket(window, bucket_group)
      measured = Enum.reject(point_group, &is_nil/1)

      cond do
        measured == [] ->
          %{
            bucket: bucket,
            pageviews: nil,
            visits: nil,
            known_pageviews: nil,
            known_visits: nil,
            coverage: :unknown
          }

        length(measured) == length(point_group) ->
          point = trend_point(bucket, period_sum(measured))

          Map.merge(point, %{
            known_pageviews: point.pageviews,
            known_visits: point.visits,
            coverage: :full
          })

        true ->
          known = period_sum(measured)

          %{
            bucket: bucket,
            pageviews: nil,
            visits: nil,
            known_pageviews: known.pageviews,
            known_visits: known.visits,
            coverage: :partial
          }
      end
    end)
    |> Enum.with_index()
    |> Enum.map(fn {point, index} -> Map.put(point, :in_progress?, index == group_count - 1) end)
  end

  defp display_point(bucket, points) do
    measured = Enum.reject(points, &is_nil/1)

    cond do
      measured == [] ->
        nil

      length(measured) == length(points) ->
        bucket |> trend_point(period_sum(measured)) |> Map.put(:coverage, :full)

      true ->
        known = trend_point(bucket, period_sum(measured))

        %{
          bucket: bucket,
          pageviews: nil,
          visitors: nil,
          visits: nil,
          bounce_rate: nil,
          avg_duration: nil,
          known_pageviews: known.pageviews,
          known_visitors: known.visitors,
          known_visits: known.visits,
          known_bounce_rate: known.bounce_rate,
          known_avg_duration: known.avg_duration,
          coverage: :partial
        }
    end
  end

  # How the raw grid folds into the buckets the chart draws: one hour per
  # bucket for 24h, one calendar day per bucket for 7d (grouping the hourly
  # grid by its UTC date), and the day rollups as they are for 30d and 90d.
  defp display_groups("7d", buckets), do: Enum.chunk_by(buckets, &DateTime.to_date/1)
  defp display_groups(_window, buckets), do: Enum.chunk_every(buckets, 1)

  # Splits `list` into runs of the same lengths as `groups`, so a list that is
  # aligned 1:1 with the grid folds exactly the way the grid does.
  defp chunk_like(list, groups) do
    {chunks, []} =
      Enum.reduce(groups, {[], list}, fn group, {acc, rest} ->
        {chunk, rest} = Enum.split(rest, length(group))
        {[chunk | acc], rest}
      end)

    Enum.reverse(chunks)
  end

  # The bucket a group is labelled with: the day for a 7d group of hours, the
  # grid's own bucket otherwise.
  defp group_bucket("7d", [first | _]), do: DateTime.to_date(first)
  defp group_bucket(_window, [first | _]), do: first

  defp portfolio_trend(current_buckets, site_results, window) do
    groups = display_groups(window, current_buckets)
    group_count = length(groups)

    groups
    |> Enum.with_index()
    |> Enum.map(fn {bucket_group, index} ->
      points = site_results |> Map.values() |> Enum.map(&Enum.at(&1.trend, index))
      expected = length(points)
      measured = Enum.count(points, &(Map.get(&1, :coverage) == :full))
      known_pageviews = portfolio_known_metric(points, :known_pageviews)
      known_visits = portfolio_known_metric(points, :known_visits)

      # Beacons counted before a site's day is fully covered are still
      # evidence: the bucket is partial with a known minimum, never unknown.
      coverage =
        cond do
          expected == 0 -> :unknown
          measured == expected -> :full
          measured == 0 and (known_pageviews || 0) == 0 -> :unknown
          true -> :partial
        end

      %{
        bucket: group_bucket(window, bucket_group),
        pageviews: if(coverage == :full, do: known_pageviews),
        visits: if(coverage == :full, do: known_visits),
        known_pageviews: known_pageviews,
        known_visits: known_visits,
        coverage: coverage,
        measured_sites: measured,
        expected_sites: expected,
        in_progress?: index == group_count - 1
      }
    end)
  end

  defp portfolio_known_metric(points, metric) do
    values = points |> Enum.map(&Map.get(&1, metric)) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp portfolio_period(site_results, period) do
    sites = Map.values(site_results)

    values =
      Enum.map(sites, fn site ->
        case period do
          :current ->
            %{
              pageviews: site.pageviews,
              visits: site.visits,
              coverage: site.coverage,
              known_pageviews: site.known_pageviews,
              known_visits: site.known_visits
            }

          :previous ->
            %{
              pageviews: site.pageviews_previous,
              visits: site.visits_previous,
              coverage: site.previous_coverage,
              known_pageviews: site.pageviews_previous,
              known_visits: site.visits_previous
            }
        end
      end)

    measured = Enum.count(values, &(&1.coverage == :full))
    expected = length(values)
    known_pageviews = portfolio_known_metric(values, :known_pageviews)
    known_visits = portfolio_known_metric(values, :known_visits)

    coverage =
      cond do
        expected == 0 -> :unknown
        measured == expected -> :full
        measured == 0 and (known_pageviews || 0) == 0 -> :unknown
        true -> :partial
      end

    %{
      pageviews: if(coverage == :full, do: known_pageviews),
      visits: if(coverage == :full, do: known_visits),
      known_pageviews: known_pageviews,
      known_visits: known_visits,
      coverage: coverage
    }
  end

  defp portfolio_coverage(trend) do
    states = Enum.map(trend, & &1.coverage)

    cond do
      states == [] or Enum.all?(states, &(&1 == :unknown)) -> :unknown
      Enum.all?(states, &(&1 == :full)) -> :full
      true -> :partial
    end
  end

  defp numeric_delta(value, previous) when is_number(value) and is_number(previous),
    do: value - previous

  defp numeric_delta(_value, _previous), do: nil

  defp panel_date_range(window, now) do
    until = DateTime.to_date(now)
    {Date.add(until, -(dimension_days(window) - 1)), until}
  end

  defp public_window_points(actor, window) do
    {_table, _bucket, since, until, _previous_since, _previous_until} =
      period_boundaries(window, DateTime.utc_now())

    source = %{id: actor.source_id, environment: actor.environment}
    resolved_window_points(source, window, actor, since, until)
  end

  defp public_period_points(window, actor, since, until, opts) do
    case Keyword.get(opts, :public_period_points) do
      nil ->
        public_period_points(window, actor, since, until)

      loader when is_function(loader, 4) ->
        {:ok, loader.(window, actor, since, until), :postgres_rollup,
         %{coverage_since: :complete}}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, :unavailable}

    Postgrex.Error ->
      {:error, :unavailable}

    error in [Ash.Error.Unknown, Ash.Error.Unknown.UnknownError, Ash.Error.Invalid.Unavailable] ->
      if DataLayerErrors.unavailable?(error),
        do: {:error, :unavailable},
        else: reraise(error, __STACKTRACE__)
  end

  defp public_period_points(window, actor, since, until) when window in ["24h", "7d"] do
    source = %{id: actor.source_id, environment: actor.environment}
    {points, metadata} = resolved_window_points(source, window, actor, since, until)

    if metadata.unavailable?,
      do: {:error, :unavailable},
      else: {:ok, points, metadata.data_source_key, metadata}
  end

  defp public_period_points(_window, actor, since, until) do
    source = %{id: actor.source_id, environment: actor.environment}
    {points, metadata} = resolved_window_points(source, "30d", actor, since, until)

    if metadata.unavailable?,
      do: {:error, :unavailable},
      else: {:ok, points, metadata.data_source_key, metadata}
  end

  defp resolved_window_points(source, window, actor, since, until)
       when window in ["24h", "7d"] do
    {points_by_source, metadata_by_source} = resolve_recent_points([source], actor, since, until)
    {Map.get(points_by_source, source.id, []), Map.fetch!(metadata_by_source, source.id)}
  end

  defp resolved_window_points(source, _window, actor, since, until) do
    {points_by_source, metadata_by_source} =
      resolve_historical_points([source], actor, since, until)

    {Map.get(points_by_source, source.id, []), Map.fetch!(metadata_by_source, source.id)}
  end

  @doc """
  Whether an exception raised by a durable read is a database outage.

  Only these become the dashboard's `unavailable` state. Everything else is a
  bug and keeps raising, so a broken query is never reported to a reader as
  "temporarily unavailable". Delegates to `Alplus.Measure.DataLayerErrors`,
  which every rescue clause in this module and `RollupFallback` also uses.
  """
  defdelegate database_unavailable_error?(error), to: DataLayerErrors, as: :unavailable?

  defp compare_bucket(%DateTime{} = value, %DateTime{} = boundary),
    do: DateTime.compare(value, boundary)

  defp compare_bucket(%Date{} = value, %Date{} = boundary), do: Date.compare(value, boundary)

  defp period_sum(points) do
    Enum.reduce(
      points,
      %{pageviews: 0, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0},
      fn point, totals ->
        %{
          pageviews: totals.pageviews + point.pageviews,
          visitors: totals.visitors + point.visitors,
          visits: totals.visits + point.visits,
          bounces: totals.bounces + point.bounces,
          duration_seconds: totals.duration_seconds + point.duration_seconds
        }
      end
    )
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> 1
    end
  end

  defp normalize_page(_page), do: 1

  defp share(_count, 0), do: 0.0
  defp share(count, total), do: Float.round(count / total * 100, 1)

  defp rate(_numerator, 0), do: nil
  defp rate(nil, _denominator), do: nil
  defp rate(_numerator, nil), do: nil
  defp rate(numerator, denominator), do: Float.round(numerator / denominator * 100, 1)

  defp engaged_duration(%{visits: nil}), do: nil

  defp engaged_duration(%{visits: visits, bounces: bounces}) when visits <= bounces, do: nil

  defp engaged_duration(%{visits: visits, bounces: bounces, duration_seconds: duration}) do
    Float.round(duration / (visits - bounces), 1)
  end

  defp compared(value, previous) do
    %{value: value, previous: previous, change: percentage_change_value(value, previous)}
  end

  defp compared_points(value, previous) do
    change = if is_number(value) and is_number(previous), do: Float.round(value - previous, 1)
    %{value: value, previous: previous, change: change}
  end

  defp with_coverage(reading, :partial, known_value) do
    reading
    |> Map.put(:coverage, :partial)
    |> Map.put(:known_value, known_value)
  end

  defp with_coverage(reading, _coverage, _known_value), do: reading

  defp percentage_change_value(nil, _previous), do: nil
  defp percentage_change_value(_value, nil), do: nil
  # `0` alone never matches a float zero, and an average duration of 0.0 for
  # the earlier period is a real reading, so the literal clause let a division
  # by zero through.
  defp percentage_change_value(_value, previous) when previous == 0, do: nil

  defp percentage_change_value(value, previous),
    do: Float.round((value - previous) / previous * 100, 1)

  defp retention_cutoff(_actor),
    do: {:ok, Date.add(Date.utc_today(), -Retention.retention_days())}

  defp retention_aware_periods(current, previous, actor, current_since, previous_since) do
    {:ok, cutoff} = retention_cutoff(actor)

    cond do
      before_retention?(current_since, cutoff) -> {unavailable_period(), unavailable_period()}
      before_retention?(previous_since, cutoff) -> {current, unavailable_period()}
      true -> {current, previous}
    end
  end

  defp period_metadata(:analytics_engine, current, previous) do
    partial? = period_partial?(current, previous)

    %{
      data_source: analytics_engine_label(current, previous, partial?),
      data_source_key: :analytics_engine,
      partial?: partial?
    }
  end

  defp period_metadata(:postgres_rollup, current, previous) do
    %{
      data_source: "PostgreSQL rollups",
      data_source_key: :postgres_rollup,
      partial?: period_partial?(current, previous)
    }
  end

  defp period_metadata(:mixed_rollup, _current, _previous) do
    %{
      data_source: "Analytics Engine and PostgreSQL rollups",
      data_source_key: :mixed_rollup,
      partial?: true
    }
  end

  defp period_metadata(:unavailable),
    do: %{data_source: "Data unavailable", data_source_key: :unavailable, partial?: false}

  defp period_partial?(current, previous) do
    Map.get(current, :coverage) == :partial or
      (is_number(current.pageviews) and is_nil(previous.pageviews))
  end

  defp analytics_engine_label(%{coverage: :partial}, _previous, _partial?),
    do: "Analytics Engine (partial coverage)"

  defp analytics_engine_label(_current, _previous, true),
    do: "Analytics Engine (prior comparison unavailable)"

  defp analytics_engine_label(_current, _previous, false), do: "Analytics Engine"

  defp chart_data_source(%{data_source_key: :analytics_engine, analytics_engine_partial?: true}),
    do: "Analytics Engine (partial coverage)"

  defp chart_data_source(metadata), do: metadata.data_source

  defp before_retention?(%DateTime{} = value, %Date{} = cutoff),
    do: DateTime.compare(value, DateTime.new!(cutoff, ~T[00:00:00], "Etc/UTC")) == :lt

  defp before_retention?(%Date{} = value, %Date{} = cutoff),
    do: Date.compare(value, cutoff) == :lt

  defp unavailable_period do
    %{
      pageviews: nil,
      visitors: nil,
      visits: nil,
      bounces: nil,
      duration_seconds: nil,
      known_pageviews: nil,
      known_visitors: nil,
      known_visits: nil,
      known_bounces: nil,
      known_duration_seconds: nil,
      coverage: :unknown
    }
  end

  defp partial_period(known) do
    %{
      pageviews: nil,
      visitors: nil,
      visits: nil,
      bounces: nil,
      duration_seconds: nil,
      known_pageviews: known.pageviews,
      known_visitors: known.visitors,
      known_visits: known.visits,
      known_bounces: known.bounces,
      known_duration_seconds: known.duration_seconds,
      coverage: :partial
    }
  end

  defp window_hours("24h"), do: 24
  defp window_hours("7d"), do: 7 * 24
  defp window_days("30d"), do: 30
  defp window_days("90d"), do: 90

  defp dimension_date_range(window) do
    days = dimension_days(window)
    until = Date.utc_today()
    {Date.add(until, -(days - 1)), until}
  end

  defp dimension_days("24h"), do: 1
  defp dimension_days("7d"), do: 7
  defp dimension_days("30d"), do: 30
  defp dimension_days("90d"), do: 90
end
