defmodule Alplus.Observe.Dashboard do
  @moduledoc """
  Batched per-Source Observe reads for the reworked Observe index (issue
  #46): a daily error-events trend, an open-issue count, and the latest
  release, one query per rollup per project -- never one query per card.

  Every read here is keyed by `source_id`, not `environment` (issue #46
  follow-up): two Sources sharing one `environment` -- an active Source and
  a revoked predecessor, for example -- each get their own trend,
  open-issue count, and latest release, never a shared one.

  `error_events` is a raw, range-partitioned table with no Ash resource
  (`docs/DIRECT-ECTO-ESCAPE-HATCHES.md`), so the trend query is a direct SQL
  read. It repeats the tenant predicate explicitly (`org_id`, `project_id`,
  `source_id IN (...)`) and re-checks organization membership itself,
  exactly like `Alplus.Measure.Dashboard`'s direct dimension queries -- it
  never trusts the caller's `actor` as its authorization mechanism. The
  window is capped to 30 days so it never reaches beyond `error_events`
  retention (a dropped monthly partition).
  """

  alias Alplus.Billing.Package
  alias Alplus.Observe.{Issue, Release}
  alias Alplus.Repo

  require Ash.Query

  @windows ~w(24h 7d 30d 90d)
  @max_window_hours 90 * 24
  @max_ranked_items 5
  # The index only needs a bounded set of deployment markers per Source. Keep
  # this cap in SQL so dense release history cannot turn the overview into an
  # unbounded read.
  @max_release_markers 100

  @doc "The Observe index/detail window options, capped to error_events retention."
  def windows, do: @windows

  @doc "Maximum release markers returned per Source by the overview."
  def max_release_markers, do: @max_release_markers

  @doc """
  Batched per-Source summary (daily error trend, open-issue count, latest
  release) for every `sources`, scoped to one project. Every read below is
  one query across all of them, keyed by `source_id`.
  """
  def summaries(sources, window, actor) when window in @windows do
    if sources == [] do
      %{}
    else
      summaries_for_sources(sources, window, actor)
    end
  end

  defp summaries_for_sources(sources, window, actor) do
    source_ids = Enum.map(sources, & &1.id)

    retention_days = observe_retention_days(actor)
    bounds = window_bounds(window, retention_days)
    trends = batched_daily_trend(actor, source_ids, bounds)
    open_issue_counts = batched_open_issue_counts(actor, source_ids)
    latest_releases = batched_latest_releases(actor, source_ids)
    releases = batched_releases(actor, source_ids, bounds)
    rankings = batched_rankings(actor, source_ids, bounds)

    Map.new(sources, fn source ->
      trend = Map.get(trends, source.id, [])
      source_releases = Map.get(releases, source.id, [])
      total_events = Enum.sum_by(trend, & &1.event_count)

      source_rankings =
        rankings
        |> Map.get(source.id, empty_ranking(total_events))
        |> normalize_ranking(total_events)

      {source.id,
       %{
         source_id: source.id,
         trend: decorate_trend(trend, source_releases),
         # `volume` is intentionally separate from `trend`. The trend is a
         # compact step series; bars use dense, gap-filled buckets so a quiet
         # interval is visible instead of being removed from the chart.
         volume: volume_buckets(trend, source_releases),
         deploy_volume: volume_buckets(trend, source_releases),
         step: step_intervals(decorate_trend(trend, source_releases), window),
         release_markers: release_markers(source_releases),
         open_issues: Map.get(open_issue_counts, source.id, 0),
         latest_release: Map.get(latest_releases, source.id),
         event_count: total_events,
         total_events: total_events,
         top_issues: source_rankings.top_issues,
         top_culprits: source_rankings.top_culprits,
         ranking: source_rankings,
         # A source with no retained rows is not the same as a source with a
         # real zero bucket. Consumers use this state to render an empty
         # state, while `volume` still contains zero buckets for known data.
         data_state: data_state(total_events, window, retention_days)
       }}
    end)
  end

  @doc "Returns one source overview, or an empty missing overview for an unknown source."
  def overview(source_id, window, actor) when window in @windows do
    case Alplus.Sources.list_sources_for_project!(actor.project_id, actor: actor)
         |> Enum.find(&(&1.id == source_id and &1.type == :observe)) do
      nil -> empty_overview(source_id)
      source -> summaries([source], window, actor) |> Map.fetch!(source.id)
    end
  end

  @doc "Returns the Source's ranked issue and culprit lists."
  def rankings(source_id, window, actor) when window in @windows do
    overview(source_id, window, actor).ranking
  end

  @doc "Returns the retention-bounded range model used by the Source charts."
  def range(source_id, window, actor) when window in @windows do
    source = overview(source_id, window, actor)

    %{
      source_id: source_id,
      data_state: source.data_state,
      total_events: source.total_events,
      step: source.step,
      buckets: source.volume,
      volume: source.volume,
      release_markers: source.release_markers
    }
  end

  @doc """
  Returns one bounded daily error trend per project for an org-level project
  index. `sources_by_project` must already be the result of the policy-scoped
  Source read; this function repeats the org, project, source, and membership
  predicates in SQL because `error_events` has no Ash resource.
  """
  def trends_for_projects(sources_by_project, window, actor) when window in @windows do
    pairs =
      Enum.flat_map(sources_by_project, fn {project_id, sources} ->
        Enum.map(sources, &{project_id, &1.id})
      end)

    if pairs == [] do
      %{}
    else
      project_ids = Enum.map(pairs, &elem(&1, 0))
      source_ids = Enum.map(pairs, &elem(&1, 1))

      trends =
        batched_daily_trend_for_projects(
          actor,
          project_ids,
          source_ids,
          window_bounds(window, actor)
        )

      Map.new(Map.keys(sources_by_project), fn project_id ->
        {project_id, Map.get(trends, project_id, [])}
      end)
    end
  end

  @doc "One Source's daily error-event trend for `window`, gap-filled, oldest bucket first."
  def trend(source_id, window, actor) when window in @windows do
    actor
    |> then(&batched_daily_trend(&1, [source_id], window_bounds(window, &1)))
    |> Map.get(source_id, [])
  end

  # ---- trend (direct SQL: error_events has no Ash resource) -----------------

  defp batched_daily_trend(_actor, [], _bounds), do: %{}

  defp batched_daily_trend(actor, source_ids, {since, until, unit}) do
    unit_name = Atom.to_string(unit)

    %{rows: rows} =
      Repo.query!(
        """
        WITH bounds AS (
          SELECT date_trunc($7, $4::timestamptz) AS since_day,
                 date_trunc($7, $5::timestamptz) AS until_day
        ), days AS (
          SELECT generate_series(
            (SELECT since_day FROM bounds),
            (SELECT until_day FROM bounds),
            ('1 ' || $7)::interval
          ) AS day
        ), wanted_sources AS (
          SELECT unnest($3::text[]) AS source_id
        ), counts AS (
          SELECT
            source_id,
            date_trunc($7, received_at) AS day,
            count(*)::bigint AS event_count
          FROM error_events
          WHERE org_id = $1
            AND project_id = $2
            AND source_id = ANY($3::text[])
            AND EXISTS (
              SELECT 1 FROM sources
              WHERE sources.id = error_events.source_id
                AND sources.org_id = $1
                AND sources.project_id = $2
                AND sources.type = 'observe'
            )
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1 AND memberships.user_id = $6
            )
            AND received_at >= $4
            AND received_at <= $5
          GROUP BY source_id, date_trunc($7, received_at)
        )
        SELECT wanted_sources.source_id, days.day, COALESCE(counts.event_count, 0)
        FROM wanted_sources
        CROSS JOIN days
        LEFT JOIN counts
          ON counts.source_id = wanted_sources.source_id AND counts.day = days.day
        ORDER BY wanted_sources.source_id, days.day
        """,
        [actor.org_id, actor.project_id, source_ids, since, until, actor.user_id, unit_name]
      )

    rows
    |> Enum.map(fn [source_id, day, event_count] -> {source_id, day, event_count} end)
    |> Enum.group_by(fn {source_id, _day, _count} -> source_id end, fn {_id, day, count} ->
      %{bucket: to_bucket(day, unit), event_count: count}
    end)
  end

  defp batched_daily_trend_for_projects(actor, project_ids, source_ids, {since, until, unit}) do
    unit_name = Atom.to_string(unit)

    %{rows: rows} =
      Repo.query!(
        """
        WITH bounds AS (
          SELECT date_trunc($8, $5::timestamptz) AS since_day,
                 date_trunc($8, $6::timestamptz) AS until_day
        ), days AS (
          SELECT generate_series(
            (SELECT since_day FROM bounds),
            (SELECT until_day FROM bounds),
            ('1 ' || $8)::interval
          ) AS day
        ), wanted_sources AS (
          SELECT * FROM unnest($3::text[], $4::text[]) AS wanted(project_id, source_id)
        ), counts AS (
          SELECT
            project_id,
            source_id,
            date_trunc($8, received_at) AS day,
            count(*)::bigint AS event_count
          FROM error_events
          WHERE org_id = $1
            AND project_id = ANY($2::text[])
            AND source_id = ANY($4::text[])
            AND EXISTS (
              SELECT 1 FROM sources
              WHERE sources.id = error_events.source_id
                AND sources.org_id = $1
                AND sources.project_id = error_events.project_id
                AND sources.type = 'observe'
            )
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1 AND memberships.user_id = $7
            )
            AND received_at >= $5
            AND received_at <= $6
          GROUP BY project_id, source_id, date_trunc($8, received_at)
        )
        SELECT wanted_sources.project_id, wanted_sources.source_id, days.day,
               COALESCE(counts.event_count, 0)
        FROM wanted_sources
        CROSS JOIN days
        LEFT JOIN counts
          ON counts.project_id = wanted_sources.project_id
         AND counts.source_id = wanted_sources.source_id
         AND counts.day = days.day
        ORDER BY wanted_sources.project_id, wanted_sources.source_id, days.day
        """,
        [
          actor.org_id,
          project_ids,
          project_ids,
          source_ids,
          since,
          until,
          actor.user_id,
          unit_name
        ]
      )

    rows
    |> Enum.group_by(fn [project_id, _source_id, _day, _count] -> project_id end, fn [
                                                                                       _project_id,
                                                                                       _source_id,
                                                                                       day,
                                                                                       count
                                                                                     ] ->
      %{bucket: to_bucket(day, unit), event_count: count}
    end)
    |> Enum.map(fn {project_id, points} ->
      {project_id,
       points
       |> Enum.group_by(& &1.bucket)
       |> Enum.map(fn {bucket, bucket_points} ->
         %{bucket: bucket, event_count: Enum.sum(Enum.map(bucket_points, & &1.event_count))}
       end)
       |> Enum.sort_by(&DateTime.to_unix(bucket_start(&1.bucket)))
       |> Enum.map(fn point ->
         label = bucket_label(point.bucket)
         event_count = point.event_count

         %{
           id: "observe-#{project_id}-#{label}",
           label: label,
           bucket: point.bucket,
           value: event_count,
           event_count: event_count,
           tone: if(event_count > 0, do: :error, else: :neutral),
           tooltip: "#{label}: #{event_count} errors",
           aria_label: "#{label}, #{event_count} errors",
           table_cells: [label, "#{event_count} errors"]
         }
       end)}
    end)
    |> Map.new()
  end

  defp window_bounds(window, actor) when is_map(actor) do
    window_bounds(window, observe_retention_days(actor))
  end

  # "Last 24 hours" is 24 hourly buckets ending in the hour in progress; "Last
  # 7 days" is 7 calendar days ending today, "Last 30 days" 30. The grid is
  # aligned to the unit, so the count of buckets is exactly the count in the
  # label (the old now-relative bounds produced 8 days for a 7-day window).
  # Retention still clips the start.
  defp window_bounds(window, retention_days) when is_integer(retention_days) do
    now = DateTime.utc_now()
    unit = bucket_unit(window)

    requested_since =
      case unit do
        :hour ->
          now
          |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})
          |> DateTime.add(-23 * 3_600, :second)

        :day ->
          now
          |> DateTime.to_date()
          |> Date.add(-(div(window_hours(window), 24) - 1))
          |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      end

    retention_since = DateTime.add(now, -retention_days * 86_400, :second)

    since =
      if DateTime.compare(requested_since, retention_since) == :lt,
        do: retention_since,
        else: requested_since

    {since, now, unit}
  end

  defp bucket_unit("24h"), do: :hour
  defp bucket_unit(_window), do: :day

  # A bucket is a `Date` on the daily grid and a `DateTime` on the hourly one.
  defp to_bucket(value, :day), do: value |> normalize_datetime() |> DateTime.to_date()

  defp to_bucket(value, :hour),
    do: value |> normalize_datetime() |> Map.merge(%{microsecond: {0, 0}})

  @doc "The instant a bucket starts, whichever grid it sits on."
  def bucket_start(%Date{} = bucket), do: DateTime.new!(bucket, ~T[00:00:00], "Etc/UTC")
  def bucket_start(%DateTime{} = bucket), do: bucket

  @doc "The instant a bucket ends, exclusive."
  def bucket_end(%Date{} = bucket), do: DateTime.add(bucket_start(bucket), 86_400, :second)
  def bucket_end(%DateTime{} = bucket), do: DateTime.add(bucket, 3_600, :second)

  @doc "The bucket an instant falls in, on the grid `sample` uses."
  def bucket_for(%DateTime{} = at, %Date{}), do: DateTime.to_date(at)

  def bucket_for(%DateTime{} = at, %DateTime{}),
    do: Map.merge(at, %{minute: 0, second: 0, microsecond: {0, 0}})

  @doc "One bucket as text: the ISO date, or the hour with its date."
  def bucket_label(%Date{} = bucket), do: Date.to_iso8601(bucket)
  def bucket_label(%DateTime{} = bucket), do: Calendar.strftime(bucket, "%Y-%m-%d %H:%M UTC")

  defp data_state(0, _window, _actor), do: :missing

  defp data_state(_total_events, window, retention_days) do
    if window_hours(window) > retention_days * 24,
      do: :partial,
      else: :ready
  end

  defp observe_retention_days(_actor), do: Package.limit(:error_event_retention_days)

  defp window_hours("24h"), do: 24
  defp window_hours("7d"), do: 7 * 24
  defp window_hours("30d"), do: 30 * 24
  defp window_hours("90d"), do: @max_window_hours

  # ---- open issues + latest release (Ash reads, one query for every source) --

  defp batched_open_issue_counts(_actor, []), do: %{}

  defp batched_open_issue_counts(actor, source_ids) do
    Issue
    |> Ash.Query.for_read(:list_for_project, %{project_id: actor.project_id}, actor: actor)
    |> Ash.Query.filter(status == :open and source_id in ^source_ids)
    |> Ash.Query.select([:source_id])
    |> Ash.read!(actor: actor)
    |> Enum.frequencies_by(& &1.source_id)
  end

  defp batched_latest_releases(_actor, []), do: %{}

  defp batched_latest_releases(actor, source_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH ranked AS (
          SELECT id, source_id, version, commit_sha, released_at,
                 row_number() OVER (
                   PARTITION BY source_id
                   ORDER BY released_at DESC, id DESC
                 ) AS rank
          FROM releases
          WHERE org_id = $1
            AND project_id = $2
            AND source_id = ANY($3::text[])
            AND EXISTS (
              SELECT 1 FROM sources
              WHERE sources.id = releases.source_id
                AND sources.org_id = $1
                AND sources.project_id = $2
                AND sources.type = 'observe'
            )
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1 AND memberships.user_id = $4
            )
        )
        SELECT id, source_id, version, commit_sha, released_at
        FROM ranked
        WHERE rank = 1
        """,
        [actor.org_id, actor.project_id, source_ids, actor.user_id]
      )

    Map.new(rows, fn [id, source_id, version, commit_sha, released_at] ->
      {source_id,
       struct(Release,
         id: id,
         source_id: source_id,
         version: version,
         commit_sha: commit_sha,
         released_at: released_at
       )}
    end)
  end

  defp batched_releases(_actor, [], _bounds), do: %{}

  defp batched_releases(actor, source_ids, {since, until, _unit}) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH ranked AS (
          SELECT id, source_id, version, commit_sha, released_at,
                 row_number() OVER (
                   PARTITION BY source_id
                   ORDER BY released_at ASC, id ASC
                 ) AS rank
          FROM releases
          WHERE org_id = $1
            AND project_id = $2
            AND source_id = ANY($3::text[])
            AND released_at >= $4
            AND released_at <= $5
            AND EXISTS (
              SELECT 1 FROM sources
              WHERE sources.id = releases.source_id
                AND sources.org_id = $1
                AND sources.project_id = $2
                AND sources.type = 'observe'
            )
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1 AND memberships.user_id = $6
            )
        )
        SELECT id, source_id, version, commit_sha, released_at
        FROM ranked
        WHERE rank <= $7
        ORDER BY source_id, released_at ASC, id ASC
        """,
        [
          actor.org_id,
          actor.project_id,
          source_ids,
          since,
          until,
          actor.user_id,
          @max_release_markers
        ]
      )

    rows
    |> Enum.map(fn [id, source_id, version, commit_sha, released_at] ->
      {source_id,
       struct(Release,
         id: id,
         source_id: source_id,
         version: version,
         commit_sha: commit_sha,
         released_at: released_at
       )}
    end)
    |> Enum.group_by(fn {source_id, _release} -> source_id end, fn {_source_id, release} ->
      release
    end)
  end

  defp batched_rankings(_actor, [], _bounds), do: %{}

  defp batched_rankings(actor, source_ids, {since, until, _unit}) do
    issue_rows =
      Repo.query!(
        """
        WITH ranked AS (
          SELECT
            events.source_id,
            events.issue_id,
            issues.title,
            issues.culprit,
            count(*)::bigint AS event_count,
            max(events.received_at) AS last_seen_at,
            row_number() OVER (
              PARTITION BY events.source_id
              ORDER BY count(*) DESC, max(events.received_at) DESC, events.issue_id
            ) AS rank
          FROM error_events events
          JOIN issues
            ON issues.id = events.issue_id
           AND issues.org_id = events.org_id
           AND issues.project_id = events.project_id
           AND issues.source_id = events.source_id
          WHERE events.org_id = $1
            AND events.project_id = $2
            AND events.source_id = ANY($3::text[])
            AND events.received_at >= $4
            AND events.received_at <= $5
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1 AND memberships.user_id = $6
            )
            AND EXISTS (
              SELECT 1 FROM sources
              WHERE sources.id = events.source_id
                AND sources.org_id = $1
                AND sources.project_id = $2
                AND sources.type = 'observe'
            )
          GROUP BY events.source_id, events.issue_id, issues.title, issues.culprit
        )
        SELECT source_id, issue_id, title, culprit, event_count, last_seen_at, rank
        FROM ranked
        WHERE rank <= $7
        ORDER BY source_id, rank
        """,
        [
          actor.org_id,
          actor.project_id,
          source_ids,
          since,
          until,
          actor.user_id,
          @max_ranked_items
        ]
      ).rows

    culprit_rows =
      Repo.query!(
        """
        WITH ranked AS (
          SELECT
            events.source_id,
            COALESCE(NULLIF(btrim(issues.culprit), ''), 'Unknown culprit') AS culprit,
            count(*)::bigint AS event_count,
            count(DISTINCT issues.id)::bigint AS issue_count,
            row_number() OVER (
              PARTITION BY events.source_id
              ORDER BY count(*) DESC,
                       COALESCE(NULLIF(btrim(issues.culprit), ''), 'Unknown culprit')
            ) AS rank
          FROM error_events events
          JOIN issues
            ON issues.id = events.issue_id
           AND issues.org_id = events.org_id
           AND issues.project_id = events.project_id
           AND issues.source_id = events.source_id
          WHERE events.org_id = $1
            AND events.project_id = $2
            AND events.source_id = ANY($3::text[])
            AND events.received_at >= $4
            AND events.received_at <= $5
            AND EXISTS (
              SELECT 1 FROM memberships
              WHERE memberships.org_id = $1 AND memberships.user_id = $6
            )
            AND EXISTS (
              SELECT 1 FROM sources
              WHERE sources.id = events.source_id
                AND sources.org_id = $1
                AND sources.project_id = $2
                AND sources.type = 'observe'
            )
          GROUP BY events.source_id, COALESCE(NULLIF(btrim(issues.culprit), ''), 'Unknown culprit')
        )
        SELECT source_id, culprit, event_count, issue_count, rank
        FROM ranked
        WHERE rank <= $7
        ORDER BY source_id, rank
        """,
        [
          actor.org_id,
          actor.project_id,
          source_ids,
          since,
          until,
          actor.user_id,
          @max_ranked_items
        ]
      ).rows

    issues_by_source =
      issue_rows
      |> Enum.map(fn [source_id, issue_id, title, culprit, event_count, last_seen_at, rank] ->
        {source_id,
         %{
           rank: rank,
           issue_id: issue_id,
           title: title,
           culprit: culprit,
           event_count: event_count,
           last_seen_at: normalize_datetime(last_seen_at)
         }}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    culprits_by_source =
      culprit_rows
      |> Enum.map(fn [source_id, culprit, event_count, issue_count, rank] ->
        {source_id,
         %{rank: rank, culprit: culprit, event_count: event_count, issue_count: issue_count}}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new()

    source_ids
    |> Enum.uniq()
    |> Map.new(fn source_id ->
      top_issues = Map.get(issues_by_source, source_id, [])
      top_culprits = Map.get(culprits_by_source, source_id, [])
      # The total comes from the same retention-bounded rows as the ranking.
      # The caller adds the exact total from the gap-filled range buckets.
      {source_id,
       %{
         top_issues: top_issues,
         top_culprits: top_culprits,
         ranked_event_count: Enum.sum_by(top_issues, & &1.event_count),
         unranked_event_count: nil,
         total_events: nil
       }}
    end)
  end

  defp empty_ranking(total_events) do
    %{
      top_issues: [],
      top_culprits: [],
      ranked_event_count: 0,
      unranked_event_count: total_events,
      total_events: total_events,
      limit: @max_ranked_items
    }
  end

  defp normalize_ranking(ranking, total_events) do
    ranked = Map.get(ranking, :ranked_event_count, 0)

    Map.merge(ranking, %{
      ranked_event_count: ranked,
      unranked_event_count: max(total_events - ranked, 0),
      total_events: total_events,
      limit: @max_ranked_items
    })
  end

  defp normalize_datetime(%NaiveDateTime{} = value),
    do: DateTime.from_naive!(value, "Etc/UTC")

  defp normalize_datetime(value), do: value

  defp empty_overview(source_id) do
    %{
      source_id: source_id,
      trend: [],
      volume: [],
      deploy_volume: [],
      step: [],
      release_markers: [],
      open_issues: 0,
      latest_release: nil,
      event_count: 0,
      total_events: 0,
      top_issues: [],
      top_culprits: [],
      ranking: empty_ranking(0),
      data_state: :missing
    }
  end

  defp decorate_trend(trend, releases) do
    Enum.map(trend, fn point ->
      marker =
        Enum.filter(releases, fn release ->
          release.released_at
          |> normalize_datetime()
          |> bucket_for(point.bucket) == point.bucket
        end)

      Map.put(point, :releases, release_markers(marker))
      |> Map.put(:release, List.last(release_markers(marker)))
    end)
  end

  defp volume_buckets(trend, releases) do
    trend
    |> decorate_trend(releases)
    |> Enum.map(fn point ->
      label = Map.get(point, :label, bucket_label(point.bucket))
      event_count = point.event_count

      %{
        id: Map.get(point, :id, "observe-#{label}"),
        bucket: point.bucket,
        label: label,
        event_count: event_count,
        value: event_count,
        release: point.release,
        tone: Map.get(point, :tone, if(event_count > 0, do: :error, else: :neutral)),
        tooltip: Map.get(point, :tooltip, "#{label}: #{event_count} errors"),
        aria_label: Map.get(point, :aria_label, "#{label}, #{event_count} errors")
      }
    end)
  end

  defp step_intervals([], _window), do: []

  defp step_intervals(trend, _window) do
    # The SQL range is deliberately dense for bar charts. A step series only
    # needs one interval for a run of equal values, plus a boundary whenever
    # a release marker lands in the run. This preserves quiet spans without
    # allocating one rendered point per day.
    if Enum.all?(trend, fn point ->
         point.event_count == 0 and Map.get(point, :releases, []) == []
       end) do
      []
    else
      trend
      |> Enum.chunk_by(fn point ->
        {point.event_count, Enum.map(Map.get(point, :releases, []), & &1.id)}
      end)
      |> Enum.map(fn points ->
        first = List.first(points)
        last = List.last(points)
        start_at = bucket_start(first.bucket)
        end_at = bucket_end(last.bucket)

        releases = Enum.flat_map(points, &Map.get(&1, :releases, []))

        %{
          start_at: start_at,
          end_at: end_at,
          from: start_at,
          to: end_at,
          bucket: first.bucket,
          value: first.event_count,
          event_count: first.event_count,
          release: List.last(releases),
          releases: releases
        }
      end)
    end
  end

  defp release_markers(releases) do
    Enum.map(releases, fn release ->
      deployed_at = normalize_datetime(release.released_at)

      %{
        id: release.id,
        source_id: release.source_id,
        version: release.version,
        commit_sha: release.commit_sha,
        released_at: deployed_at,
        deployed_at: deployed_at
      }
    end)
  end
end
