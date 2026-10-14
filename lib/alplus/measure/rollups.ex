defmodule Alplus.Measure.Rollups do
  @moduledoc "Direct PostgreSQL writer for privacy-safe Measure daily rollups."

  # This is a direct Ecto escape hatch. Ingest needs atomic UPSERTs on every
  # accepted hit, which is clearer and materially cheaper than Ash actions.

  @other "(other)"
  @dimension_limit 1_000
  @dimensions ~w(path landing_page hostname referrer country browser event)

  def other_value, do: @other
  def dimension_limit, do: @dimension_limit

  @doc """
  Writes the day bucket and the hit's closed-set dimension deltas.
  `environment` is server-trusted (the caller's resolved Source), never a
  client-supplied value. `source_id` is the resolved Measure Source (site,
  issue #34 Model A) that owns this rollup row; every rollup is partitioned
  by its source, not only by project and environment.
  """
  def record!(project, source_id, environment, hit, deltas, now)
      when is_binary(source_id) and is_binary(environment) do
    date = DateTime.to_date(now)
    upsert_day!(project, source_id, environment, date, deltas)

    hit
    |> dimensions(deltas)
    |> Enum.each(fn {dimension, value} ->
      record_dimension!(project, source_id, environment, date, dimension, value, deltas)
    end)
  end

  @doc "Counts one registered custom event without changing visit or pageview totals."
  def record_event!(project, source_id, environment, event_name, now) do
    record_dimension!(
      project,
      source_id,
      environment,
      DateTime.to_date(now),
      "event",
      event_name,
      %{pageviews: 1, visitors: 0, visits: 0}
    )
  end

  @doc "Writes one bounded dimension increment. This is the public ingest integration seam."
  def record_dimension!(project, source_id, environment, %Date{} = date, dimension, value, deltas)
      when dimension in @dimensions and is_binary(value) and is_binary(source_id) and
             is_binary(environment) do
    value = String.slice(value, 0, 128)

    Alplus.Repo.query!(
      """
      WITH dimension_lock AS (
        SELECT pg_advisory_xact_lock(hashtextextended($1, 0))
      ), bucket AS (
        SELECT CASE
          WHEN EXISTS (
            SELECT 1 FROM analytics_dimensions
            WHERE source_id = $2 AND environment = $3 AND date = $4
              AND dimension = $5 AND value = $6
          ) THEN $6
          WHEN (SELECT count(*) FROM analytics_dimensions
                WHERE source_id = $2 AND environment = $3 AND date = $4
                  AND dimension = $5) < $7 THEN $6
          ELSE $8
        END AS value
        FROM dimension_lock
      )
      INSERT INTO analytics_dimensions (id, org_id, project_id, source_id, environment, date, dimension, value, visitors, pageviews, visits, inserted_at, updated_at)
      SELECT $9,$10,$11,$2,$3,$4,$5,bucket.value,$12,$13,$14,now(),now()
      FROM bucket
      ON CONFLICT (project_id, environment, date, dimension, value, source_id) DO UPDATE SET
        visitors = analytics_dimensions.visitors + EXCLUDED.visitors,
        pageviews = analytics_dimensions.pageviews + EXCLUDED.pageviews,
        visits = COALESCE(analytics_dimensions.visits, 0) + EXCLUDED.visits,
        updated_at = now()
      """,
      [
        "#{source_id}:#{environment}:#{Date.to_iso8601(date)}:#{dimension}",
        source_id,
        environment,
        date,
        dimension,
        value,
        @dimension_limit,
        @other,
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        project.org_id,
        project.id,
        Map.fetch!(deltas, :visitors),
        Map.fetch!(deltas, :pageviews),
        Map.fetch!(deltas, :visits)
      ]
    )
  end

  defp upsert_day!(project, source_id, environment, date, deltas) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_days (id, org_id, project_id, source_id, environment, date, pageviews, visitors, visits, bounces, duration_seconds, inserted_at, updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,GREATEST(0,$10),$11,now(),now())
      ON CONFLICT (project_id, environment, date, source_id) DO UPDATE SET
        pageviews = analytics_days.pageviews + EXCLUDED.pageviews,
        visitors = analytics_days.visitors + EXCLUDED.visitors,
        visits = analytics_days.visits + EXCLUDED.visits,
        bounces = GREATEST(0, analytics_days.bounces + $10),
        duration_seconds = analytics_days.duration_seconds + EXCLUDED.duration_seconds,
        updated_at = now()
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        project.org_id,
        project.id,
        source_id,
        environment,
        date,
        Map.fetch!(deltas, :pageviews),
        Map.fetch!(deltas, :visitors),
        Map.fetch!(deltas, :visits),
        Map.fetch!(deltas, :bounces),
        Map.fetch!(deltas, :duration_seconds)
      ]
    )
  end

  defp dimensions(%{type: "pageview", path: path, hostname: hostname} = hit, deltas) do
    landing_page =
      if Map.get(deltas, :landing_page_visits, 0) > 0, do: [{"landing_page", path}], else: []

    [{"path", path}, {"hostname", hostname} | landing_page ++ shared_dimensions(hit)]
  end

  # Referrer, country, and browser (issue #9) are collected for every hit
  # type. `country` is omitted entirely when unresolved (`Country.normalize/1`
  # returns `nil`) rather than fabricated — the dashboard's empty state is
  # the honest signal for "no data yet", not a fake `(other)` bucket.
  defp shared_dimensions(hit) do
    [
      {"referrer", Map.get(hit, :referrer_host)},
      {"country", Map.get(hit, :country)},
      {"browser", Map.get(hit, :browser)}
    ]
    |> Enum.reject(fn {_dimension, value} -> is_nil(value) end)
  end
end
