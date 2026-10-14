defmodule Alplus.Measure.Dashboard.RollupFallback do
  @moduledoc """
  The durable PostgreSQL rollup reads `Alplus.Measure.Dashboard` falls back to
  when `Alplus.Measure.AnalyticsEngine` is unavailable, unconfigured, or does
  not retain the requested window.

  Every function here reads `analytics_hours`, `analytics_days`, or
  `analytics_dimensions` only — never Analytics Engine. `Dashboard` decides
  when to call these (its own coverage/merge logic), and stays the only
  caller: this module has no opinion about Analytics Engine at all.

  Functions that previously rescued a durable-read exception keep exactly the
  same rescue semantics: only a confirmed database cause
  (`Alplus.Measure.DataLayerErrors.unavailable?/1`) is downgraded to
  `{:error, :unavailable}`; anything else re-raises, because a bug must not
  be reported to a reader as an outage.
  """

  alias Alplus.Measure
  alias Alplus.Measure.{DataLayerErrors, Rollups}

  @doc "Hour rollups for `source_ids`, scoped by `actor` and filtered to each source's own environment."
  def hour_rollups(source_ids, since, until, actor, environments) do
    rows =
      Measure.list_hours_for_sources!(source_ids, since, until, actor: actor)
      |> Enum.filter(
        &(DateTime.compare(&1.hour, until) == :lt and environment_matches?(&1, environments))
      )

    {:ok, Enum.group_by(rows, & &1.source_id)}
  rescue
    error in [
      Ash.Error.Unknown,
      Ash.Error.Unknown.UnknownError,
      Ash.Error.Invalid.Unavailable,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      if DataLayerErrors.unavailable?(error),
        do: {:error, :unavailable},
        else: reraise(error, __STACKTRACE__)
  end

  @doc "Day rollups for `source_ids`, scoped by `actor` and filtered to each source's own environment."
  def day_rollups(source_ids, since, until, actor, environments) do
    rows =
      Measure.list_days_for_sources!(source_ids, since, until, actor: actor)
      |> Enum.filter(
        &(Date.compare(&1.date, until) == :lt and environment_matches?(&1, environments))
      )

    {:ok, Enum.group_by(rows, & &1.source_id)}
  rescue
    error in [
      Ash.Error.Unknown,
      Ash.Error.Unknown.UnknownError,
      Ash.Error.Invalid.Unavailable,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      if DataLayerErrors.unavailable?(error),
        do: {:error, :unavailable},
        else: reraise(error, __STACKTRACE__)
  end

  defp environment_matches?(row, environments) do
    case Map.fetch(environments, row.source_id) do
      {:ok, environment} -> row.environment == environment
      :error -> true
    end
  end

  @doc "One public share's hour rollups, filtered to the share's own environment."
  def share_hour_rollups(since, until, actor) do
    {:ok,
     Measure.list_hours_for_share!(since, until, actor: actor)
     |> Enum.filter(&(&1.environment == actor.environment))}
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

  @doc "One public share's day rollups, filtered to the share's own environment."
  def share_day_rollups(since, until, actor) do
    {:ok,
     Measure.list_days_for_share!(since, until, actor: actor)
     |> Enum.filter(&(&1.environment == actor.environment))}
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

  @doc """
  Grouped first/last-pageview evidence for every `source_id`, within
  `[since, until)`.

  Deliberate narrow escape hatch: no existing Ash read exposes the grouped
  first/last evidence needed for every source without one query per card.
  Keep the tenant, project, membership, source, and environment predicates in
  this SQL in line with ARCHITECTURE.md §4's scoped-read requirement; this
  query never accepts a caller-supplied table or clause.
  """
  def evidence([], _actor, _since, _until), do: {:ok, %{}}

  def evidence(source_ids, actor, since, until) do
    result =
      Alplus.Repo.query!(
        """
        SELECT source_id,
               MIN(date) AS first_pageview_on,
               MAX(date) AS last_pageview_on,
               COALESCE(SUM(pageviews), 0)::bigint AS pageviews,
               COALESCE(SUM(visitors), 0)::bigint AS visitors,
               COALESCE(SUM(visits), 0)::bigint AS visits
        FROM analytics_days
        WHERE org_id = $1
          AND project_id = $2
          AND source_id = ANY($3::text[])
          AND pageviews > 0
          AND date >= $5
          AND date < $6
          AND EXISTS (
            SELECT 1 FROM sources
            WHERE sources.id = analytics_days.source_id
              AND sources.org_id = analytics_days.org_id
              AND sources.project_id = analytics_days.project_id
              AND sources.environment = analytics_days.environment
          )
          AND EXISTS (
            SELECT 1 FROM memberships
            WHERE memberships.org_id = analytics_days.org_id
              AND memberships.user_id = $4
          )
        GROUP BY source_id
        """,
        [actor.org_id, actor.project_id, source_ids, actor.user_id, since, until]
      )

    evidence =
      Map.new(result.rows, fn [
                                source_id,
                                first_pageview_on,
                                last_pageview_on,
                                pageviews,
                                visitors,
                                visits
                              ] ->
        {source_id,
         %{
           first_pageview_on: first_pageview_on,
           last_pageview_on: last_pageview_on,
           pageviews: pageviews,
           visitors: visitors,
           visits: visits
         }}
      end)

    {:ok, evidence}
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
    Postgrex.Error -> {:error, :unavailable}
  end

  @doc "Top-5 rows per dimension, ranked by summed visitors, for one source and date range."
  # `analytics_dimensions` only tracks `visitors` (no `visits` column, unlike
  # `analytics_days`), so this always ranks by that one metric.
  def top_dimension_rows(source, actor, since, until, dimensions) do
    result =
      Alplus.Repo.query!(
        """
        WITH ranked AS (
          SELECT
            dimensions.dimension,
            dimensions.value,
            SUM(visitors)::bigint AS count,
            SUM(SUM(visitors)) OVER (PARTITION BY dimensions.dimension)::bigint AS dimension_total,
            ROW_NUMBER() OVER (PARTITION BY dimensions.dimension ORDER BY SUM(visitors) DESC, dimensions.value) AS rank
          FROM analytics_dimensions AS dimensions
          WHERE dimensions.org_id = $1
            AND dimensions.project_id = $2
            AND dimensions.source_id = $3
            AND dimensions.environment = $4
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = dimensions.org_id AND memberships.user_id = $5
            )
            AND dimensions.dimension = ANY($6::text[])
            AND dimensions.date BETWEEN $7 AND $8
          GROUP BY dimensions.dimension, dimensions.value
        )
        SELECT dimension, value, count, dimension_total
        FROM ranked
        WHERE rank <= 5
        ORDER BY dimension, count DESC, value
        """,
        [
          actor.org_id,
          actor.project_id,
          source.id,
          source.environment,
          actor.user_id,
          dimensions,
          since,
          until
        ]
      )

    Enum.reduce(result.rows, %{}, fn [dimension, value, count, total], rows ->
      share = if total == 0, do: 0, else: Float.round(count / total * 100, 1)
      row = %{value: value, visits: count, visitors: count, share: share}
      Map.update(rows, dimension, [row], &(&1 ++ [row]))
    end)
  end

  @doc "One metadata and page read for a panel dimension, grouped once in PostgreSQL."
  def panel(source, dimension, actor, since, until, requested_page, page_size, max_page) do
    result =
      Alplus.Repo.query!(
        """
        WITH grouped AS MATERIALIZED (
          SELECT value,
                 SUM(CASE WHEN dimension IN ('path', 'event')
                          THEN pageviews ELSE COALESCE(visits, visitors) END)::bigint AS count,
                 bool_or(dimension NOT IN ('path', 'event') AND visits IS NULL) AS partial
          FROM analytics_dimensions AS dimensions
          WHERE dimensions.org_id = $1
            AND dimensions.project_id = $2
            AND dimensions.source_id = $3
            AND dimensions.environment = $4
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = dimensions.org_id AND memberships.user_id = $5
            )
            AND dimensions.dimension = $6
            AND dimensions.date BETWEEN $7 AND $8
          GROUP BY value
        ), metadata AS (
          SELECT
            count(*) FILTER (WHERE value <> $9)::bigint AS named_count,
            COALESCE(max(count) FILTER (WHERE value = $9), 0)::bigint AS other_count,
            COALESCE(sum(count), 0)::bigint AS total_count,
            COALESCE(bool_or(partial), false) AS partial
          FROM grouped
        ), page_info AS (
          SELECT metadata.*,
                 (named_count + CASE WHEN other_count > 0 THEN 1 ELSE 0 END)::bigint AS distinct_values,
                 LEAST(
                   GREATEST(
                     (named_count + CASE WHEN other_count > 0 THEN 1 ELSE 0 END + $10 - 1) / $10,
                     1
                   ),
                   $11
                 )::bigint AS total_pages
          FROM metadata
        ), page AS (
          SELECT page_info.*,
                 LEAST(GREATEST($12, 1), total_pages)::bigint AS page
          FROM page_info
        )
        SELECT page.named_count, page.other_count, page.total_count, page.partial,
               page.distinct_values, page.total_pages, page.page,
               rows.value, rows.count
        FROM page
        LEFT JOIN LATERAL (
          SELECT value, count
          FROM grouped
          WHERE value <> $9
          ORDER BY count DESC, value
          LIMIT $10
          OFFSET ((page.page - 1) * $10)
        ) AS rows ON TRUE
        ORDER BY rows.count DESC, rows.value
        """,
        [
          actor.org_id,
          actor.project_id,
          source.id,
          source.environment,
          actor.user_id,
          dimension,
          since,
          until,
          Rollups.other_value(),
          page_size,
          max_page,
          requested_page
        ]
      )

    [
      [named_count, other_count, total_count, partial?, distinct_values, total_pages, page | _]
      | _
    ] = result.rows

    metadata = %{
      named_count: named_count,
      other_count: other_count,
      total_count: total_count,
      partial?: partial?,
      distinct_values: distinct_values,
      total_pages: total_pages,
      page: page
    }

    rows =
      for [_, _, _, _, _, _, _, value, count] <- result.rows, not is_nil(value) do
        panel_row(value, count, total_count)
      end

    {metadata, rows}
  end

  defp panel_row(value, count, total_count) do
    %{value: value, label: value, count: count, share: share(count, total_count), capped?: false}
  end

  defp share(_count, 0), do: 0.0
  defp share(count, total), do: Float.round(count / total * 100, 1)
end
