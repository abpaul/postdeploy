defmodule Alplus.Measure.Ingest do
  @moduledoc false

  alias Alplus.Billing.EventMeter

  alias Alplus.Measure.{
    Browser,
    Country,
    Hit,
    OriginAllowlist,
    Referrer,
    Rollups,
    VisitorHash,
    VisitorState
  }

  @doc """
  Records one accepted Measure beacon. `source` is the already-resolved,
  active `:measure` Source (`Alplus.Sources.Source.resolve_measure/1`).
  `source.environment` is the sole, server-trusted origin of the
  environment written into every rollup row — never a client-supplied
  value (ARCHITECTURE.md §4/§8).
  """
  def record(
        source,
        origin,
        body,
        remote_ip,
        user_agent,
        country_header \\ nil,
        now \\ DateTime.utc_now()
      ) do
    with {:ok, hit} <- Hit.normalize(body),
         hit <- annotate(hit, country_header, user_agent),
         project <- %{id: source.project_id, org_id: source.org_id},
         allowed_domains <- domains(project.id),
         :ok <- authorize_origin(hit, origin, allowed_domains),
         hit <- resolve_referrer(hit, allowed_domains),
         :ok <- validate_event(project.id, hit),
         %{accepted?: true} <- EventMeter.consume(project.org_id, :analytics_events, now),
         :ok <- persist(project, source, hit, remote_ip, user_agent, now) do
      :accepted
    else
      {:error, :invalid_event} -> :invalid_event
      _ -> :rejected
    end
  end

  defp authorize_origin(hit, origin, allowed_domains) do
    origin_hostname = OriginAllowlist.origin_hostname(origin)

    if OriginAllowlist.allowed?(origin_hostname || "", allowed_domains) and
         hit.hostname == origin_hostname,
       do: :ok,
       else: {:error, :origin}
  end

  defp validate_event(_project_id, %{type: "pageview"}), do: :ok

  defp validate_event(project_id, %{type: "event", name: name}) do
    case Alplus.Repo.query!(
           "SELECT 1 FROM custom_event_definitions WHERE project_id = $1 AND name = $2 LIMIT 1",
           [project_id, name]
         ).rows do
      [[1]] -> :ok
      [] -> {:error, :invalid_event}
    end
  end

  # Never store the raw `country_header` or `user_agent` — only the derived
  # closed-set values reach `Rollups`/`analytics_dimensions` (issue #9
  # privacy bar). Both discard their raw input inline.
  defp annotate(hit, country_header, user_agent) do
    hit
    |> Map.put(:country, Country.normalize(country_header))
    |> Map.put(:browser, Browser.label(user_agent))
  end

  # Classifies the referrer against the project's own allow-listed domains
  # (already resolved above for origin auth) rather than a public-suffix
  # heuristic — that allowlist is the authoritative definition of "this
  # site". The raw referrer never reaches `Rollups`/persistence; only the
  # derived host (or "direct") does.
  defp resolve_referrer(hit, allowed_domains) do
    hit
    |> Map.put(:referrer_host, Referrer.host(Map.get(hit, :referrer), allowed_domains))
    |> Map.delete(:referrer)
  end

  defp domains(project_id) do
    Alplus.Repo.query!("SELECT hostname FROM project_domains WHERE project_id = $1", [project_id]).rows
    |> Enum.map(&hd/1)
  end

  defp persist(project, source, %{type: "event", name: name}, _remote_ip, _user_agent, now) do
    Rollups.record_event!(project, source.id, source.environment, name, now)
    :ok
  end

  defp persist(project, source, hit, remote_ip, user_agent, now) do
    hash = VisitorHash.hash(project.id, source.id, remote_ip, user_agent, now)
    persist_pageview(project, source.id, source.environment, hit, hash, now)
  end

  defp persist_pageview(project, source_id, environment, hit, hash, now) do
    now_ms = DateTime.to_unix(now, :millisecond)
    date = DateTime.to_date(now)
    hour = now |> DateTime.truncate(:second) |> Map.put(:minute, 0) |> Map.put(:second, 0)

    visit_deltas = VisitorState.transition({source_id, hash}, now_ms, hit)
    visitor_delta = upsert!(project, source_id, environment, date, hour, hash, visit_deltas)
    deltas = Map.put(visit_deltas, :visitors, visitor_delta)
    Rollups.record!(project, source_id, environment, hit, deltas, now)

    Alplus.Measure.AnalyticsEngine.record(%{
      org_id: project.org_id,
      project_id: project.id,
      source_id: source_id,
      hour: hour,
      pageviews: deltas.pageviews,
      visitors: deltas.visitors,
      visits: deltas.visits,
      bounces: deltas.bounces,
      duration_seconds: deltas.duration_seconds
    })

    :ok
  end

  # The durable daily-visitor claim and hourly rollup share one statement.
  # This keeps a warm accepted pageview's SQL count unchanged while making a
  # process restart irrelevant to visitor uniqueness.
  defp upsert!(project, source_id, environment, date, hour, hash, deltas) do
    %{rows: [[visitor_delta]]} =
      Alplus.Repo.query!(
        """
        WITH seen AS (
          INSERT INTO measure_visitor_seen (day, visitor_hash, inserted_at)
          VALUES ($1,$2,now())
          ON CONFLICT (day, visitor_hash) DO NOTHING
          RETURNING 1
        ), visitor AS (
          SELECT count(*)::bigint AS delta FROM seen
        ), hour_upsert AS (
          INSERT INTO analytics_hours (id, org_id, project_id, source_id, environment, hour, pageviews, visitors, visits, bounces, duration_seconds, inserted_at, updated_at)
          SELECT $3,$4,$5,$6,$7,$8,$9,visitor.delta,$10,GREATEST(0,$11),$12,now(),now()
          FROM visitor
          ON CONFLICT (project_id, environment, hour, source_id) DO UPDATE SET
            pageviews = analytics_hours.pageviews + EXCLUDED.pageviews,
            visitors = analytics_hours.visitors + EXCLUDED.visitors,
            visits = analytics_hours.visits + EXCLUDED.visits,
            bounces = GREATEST(0, analytics_hours.bounces + $11),
            duration_seconds = analytics_hours.duration_seconds + EXCLUDED.duration_seconds,
            updated_at = now()
          RETURNING 1
        )
        SELECT delta FROM visitor
        """,
        [
          date,
          hash,
          Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          project.org_id,
          project.id,
          source_id,
          environment,
          hour,
          deltas.pageviews,
          deltas.visits,
          deltas.bounces,
          deltas.duration_seconds
        ]
      )

    visitor_delta
  end
end
