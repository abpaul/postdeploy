defmodule Alplus.Status.PublicPage do
  @moduledoc "Loads the cacheable, configuration-free public status snapshot."

  require Ash.Query

  alias Alplus.Measure.PublicCache
  alias Alplus.Monitoring.Reliability
  alias Alplus.Repo
  alias Alplus.Scope

  alias Alplus.Status.{
    PublicActor,
    ScheduledMaintenance,
    StatusAnnouncement,
    StatusComponent,
    StatusIncident,
    StatusIncidentUpdate,
    StatusPage
  }

  @history_days 90
  # The fewest observed days a 90-day uptime percentage may be printed over.
  @uptime_coverage_floor_days 7
  @max_public_components 100
  @max_linked_monitors 300
  @max_public_incidents 100
  @max_public_incident_updates 500
  @max_public_incident_services 1_000
  @max_public_announcements 100
  @max_public_maintenances 100
  @max_public_history_items 100
  @incident_state_priority %{down: 4, degraded: 3, maintenance: 2, up: 1}

  @typedoc "Canonical state vocabulary emitted by public status components."
  @type public_state :: :up | :down | :degraded | :maintenance | :unknown

  @doc "Normalizes a stored incident impact to the public service state."
  @spec incident_state(String.t()) :: public_state()
  def incident_state("outage"), do: :down
  def incident_state("degraded"), do: :degraded
  def incident_state("maintenance"), do: :maintenance
  def incident_state("operational"), do: :up
  def incident_state(_state), do: :degraded

  @doc "Returns the worst of two active incident service states."
  def worst_incident_state(left, right) do
    if Map.fetch!(@incident_state_priority, right) > Map.fetch!(@incident_state_priority, left) do
      right
    else
      left
    end
  end

  @doc "Reduces active incident service rows to one worst state per service."
  def reduce_incident_overrides(rows) do
    Enum.reduce(rows, %{}, fn [component_id, state], acc ->
      state = incident_state(state)
      Map.update(acc, component_id, state, &worst_incident_state(&1, state))
    end)
  end

  @doc "Calculates the public state for connected monitors and maintenance."
  @spec service_status(list(), boolean()) :: public_state()
  def service_status([], _maintenance?), do: :degraded

  def service_status(monitors, maintenance?) when is_list(monitors) do
    statuses = Enum.map(monitors, &monitor_status/1)

    degraded? =
      Enum.zip(monitors, statuses)
      |> Enum.any?(fn {monitor, status} ->
        status == :degraded and not paused_monitor?(monitor)
      end)

    paused? = Enum.any?(monitors, &paused_monitor?/1)
    unknown? = Enum.any?(statuses, &(&1 == :unknown))

    cond do
      :down in statuses -> :down
      maintenance? -> :maintenance
      degraded? -> :degraded
      paused? -> :degraded
      unknown? -> :unknown
      true -> :up
    end
  end

  @doc "Resolves a published page through its scoped public Ash actor."
  def resolve(slug) when is_binary(slug) do
    case Alplus.PublicPages.resolve(slug, alias_kind: "status") do
      {:ok, %{identity: identity, alias?: alias?}} -> resolve_identity(identity, slug, alias?)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def resolve(_slug), do: {:error, :not_found}

  @doc "Returns the public page snapshot, cached by the page update timestamp."
  def load(slug) do
    with {:ok, %{page: page, actor: actor, identity: identity}} <- resolve(slug) do
      PublicCache.fetch({:status_page, page.id, page.updated_at, identity.updated_at}, fn ->
        build(page, actor, identity)
      end)
      |> then(&{:ok, &1})
    end
  end

  defp page_by_project(identity) do
    actor = PublicActor.for_project(identity.project_id)
    actor = %{actor | public_page_id: identity.id, status_slug: identity.public_slug}

    query =
      StatusPage
      |> Ash.Query.for_read(:public_for_project, %{project_id: identity.project_id}, actor: actor)
      |> Ash.Query.filter(org_id == ^identity.org_id and project_id == ^identity.project_id)

    case Ash.read(query, actor: actor) do
      {:ok, [%StatusPage{} = page | _]} -> {:ok, page}
      _ -> {:error, :not_found}
    end
  end

  defp resolve_identity(identity, requested_slug, legacy?) do
    # Deliberately does not require `public_components(page, actor) != []`.
    # A published page with a component that has no linked monitor yet (or no
    # components at all) has zero evidence, not zero existence: `build/3`
    # renders that as the neutral "no observations yet" state. Gating
    # existence on evidence here made a genuinely published page 404 in
    # production (mock 08, line 651: the page's whole job is to answer in
    # seconds). Only an unpublished or unknown slug may 404 — that happens
    # above, in `Access.check/1` and `page_by_project/1`.
    with {:ok, _access} <- Alplus.Billing.Access.check(identity.org_id),
         {:ok, page} <- page_by_project(identity),
         actor <- actor_for(page, identity),
         {:ok, page} <- Ash.get(StatusPage, page.id, action: :read_public, actor: actor) do
      {:ok,
       %{
         page: page,
         actor: actor,
         identity: identity,
         requested_slug: requested_slug,
         legacy?: legacy?
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp actor_for(page, identity),
    do: %PublicActor{
      status_page_id: page.id,
      status_slug: identity.public_slug,
      public_page_id: identity.id,
      org_id: page.org_id,
      project_id: page.project_id,
      now: DateTime.utc_now()
    }

  defp public_components(page, actor) do
    query =
      Ash.Query.for_read(StatusComponent, :public_for_page, %{status_page_id: page.id},
        actor: actor
      )
      |> Ash.Query.limit(@max_public_components)

    components = query |> Ash.read!(actor: actor) |> results()

    page
    |> component_ids_with_monitors(Enum.map(components, & &1.id))
    |> then(fn linked_ids -> Enum.filter(components, &Enum.member?(linked_ids, &1.id)) end)
  end

  defp component_ids_with_monitors(_page, []), do: MapSet.new()

  defp component_ids_with_monitors(page, component_ids) do
    Repo.query!(
      """
      SELECT DISTINCT cm.status_component_id
      FROM status_component_monitors AS cm
      INNER JOIN monitors AS m
        ON m.id = cm.monitor_id AND m.org_id = $1 AND m.project_id = $2
      WHERE cm.org_id = $1 AND cm.project_id = $2
        AND cm.status_component_id = ANY($3::text[])
      ORDER BY cm.status_component_id
      LIMIT $4
      """,
      [page.org_id, page.project_id, component_ids, @max_linked_monitors]
    ).rows
    |> MapSet.new(fn [component_id] -> component_id end)
  end

  defp build(page, actor, identity) do
    components = public_components(page, actor)
    component_ids = Enum.map(components, & &1.id)
    component_monitors = component_monitors(page, component_ids)

    monitor_ids =
      component_monitors
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.take(@max_linked_monitors)

    monitor_statuses = monitor_statuses(page, monitor_ids)
    active_maintenance_monitors = active_maintenance_monitors(page, monitor_ids)
    history = history(page, monitor_ids, monitor_statuses)
    {incident_overrides, page_incident_status} = incident_service_overrides(page, component_ids)

    component_data =
      Enum.map(components, fn component ->
        ids = Map.get(component_monitors, component.id, []) |> Enum.filter(&(&1 in monitor_ids))

        current =
          component_status(
            ids,
            monitor_statuses,
            active_maintenance_monitors,
            component.id,
            incident_overrides
          )

        history_rows = component_history(ids, history)

        reliability = component_reliability(ids, history)
        observed_days = Enum.count(history_rows, & &1.evidence?)

        %{
          id: component.id,
          name: component.name,
          description: component.description,
          position: component.position,
          status: current,
          # A percentage over fewer than a week of observed days overstates
          # its certainty, so it is withheld and the coverage is stated
          # instead. The days are always named beside the number.
          uptime_percent:
            if(observed_days >= @uptime_coverage_floor_days,
              do: uptime_percent(history_rows),
              else: nil
            ),
          observed_days: observed_days,
          no_data_days: length(history_rows) - observed_days,
          window_days: length(history_rows),
          history: history_rows,
          reliability: reliability
        }
      end)
      |> Enum.sort_by(&{&1.position, &1.name})

    incidents = public_incidents(page, actor, component_data)
    announcements = public_announcements(page, actor)
    announcement_history = public_announcement_history(page, actor)
    maintenances = public_maintenance(page, actor)
    maintenance_history = public_maintenance_history(page, actor)
    maintenance_active? = Enum.any?(component_data, &(&1.status == :maintenance))

    %{
      page: page,
      public_page: public_page(identity, page),
      status: overall_status(component_data, {maintenance_active?, page_incident_status}),
      components: component_data,
      services: component_data,
      incidents: incidents,
      announcements: announcements,
      announcement_history: announcement_history,
      maintenances: maintenances,
      maintenance_history: maintenance_history,
      generated_at: DateTime.utc_now()
    }
  end

  # `vendor?` is the hosted page's brand owner, read from the authoritative
  # vendor designation on the project's changelog. It travels with the cached
  # snapshot, so `/status/:slug` and `/status/:slug/history` answer it
  # identically without either template inspecting a slug or a title.
  defp public_page(identity, _status_page) do
    %{
      id: identity.id,
      public_slug: identity.public_slug,
      title: identity.title,
      logo_url: identity.logo_url,
      published_at: identity.published_at,
      status_slug: identity.public_slug,
      legacy_status_slug: nil,
      changelog_slug: identity.public_slug,
      vendor?: Alplus.Changelog.Public.vendor_project?(identity.project_id)
    }
  end

  defp component_monitors(_page, []), do: %{}

  defp component_monitors(page, component_ids) do
    Repo.query!(
      """
      SELECT cm.status_component_id, cm.monitor_id
      FROM status_component_monitors AS cm
      INNER JOIN monitors AS m
        ON m.id = cm.monitor_id AND m.org_id = $1 AND m.project_id = $2
      WHERE cm.org_id = $1 AND cm.project_id = $2
        AND cm.status_component_id = ANY($3::text[])
      ORDER BY cm.status_component_id, cm.monitor_id
      LIMIT $4
      """,
      [page.org_id, page.project_id, component_ids, @max_linked_monitors]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), &Enum.at(&1, 1))
  end

  defp monitor_statuses(_page, []), do: %{}

  defp monitor_statuses(page, monitor_ids) do
    Repo.query!(
      """
      SELECT id, status, last_known_status, slo_target
      FROM monitors
      WHERE org_id = $1 AND project_id = $2 AND id = ANY($3::text[])
      """,
      [page.org_id, page.project_id, monitor_ids]
    ).rows
    |> Map.new(fn [id, status, last_known_status, slo_target] ->
      {id, %{status: status, last_known_status: last_known_status, slo_target: slo_target}}
    end)
  end

  defp active_maintenance_monitors(_page, []), do: MapSet.new()

  defp active_maintenance_monitors(page, monitor_ids) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      SELECT monitor_id
      FROM status_maintenance_monitors AS mm
      INNER JOIN status_scheduled_maintenances AS m
        ON m.id = mm.maintenance_id AND m.org_id = $1 AND m.project_id = $2
      WHERE mm.org_id = $1 AND mm.project_id = $2
        AND m.status_page_id = $4
        AND mm.monitor_id = ANY($3::text[])
        AND m.status IN ('scheduled', 'active') AND m.starts_at <= $5 AND m.ends_at > $5
      """,
      [page.org_id, page.project_id, monitor_ids, page.id, now]
    ).rows
    |> MapSet.new(fn [monitor_id] -> monitor_id end)
  end

  @doc false
  defp history(_page, [], _monitor_statuses) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    %{by_monitor: %{}, today: today, first_day: Date.add(today, -(@history_days - 1)), now: now}
  end

  defp history(page, monitor_ids, monitor_statuses) do
    monitors =
      Enum.map(monitor_ids, fn monitor_id ->
        status = Map.get(monitor_statuses, monitor_id, %{})

        %{
          id: monitor_id,
          org_id: page.org_id,
          project_id: page.project_id,
          slo_target: Map.get(status, :slo_target)
        }
      end)

    scope = %Scope{org_id: page.org_id, project_id: page.project_id}

    histories =
      case Reliability.histories(monitors, scope) do
        {:ok, histories} ->
          Map.new(histories, fn {monitor_id, reliability} ->
            {monitor_id,
             Map.put(reliability, :days_by_date, Map.new(reliability.days, &{&1.day, &1}))}
          end)

        {:error, reason} ->
          raise ArgumentError, "public status history unavailable: #{inspect(reason)}"
      end

    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    %{
      by_monitor: histories,
      today: today,
      first_day: Date.add(today, -(@history_days - 1)),
      now: now
    }
  end

  defp component_history([], _history), do: []

  defp component_history(monitor_ids, history) do
    for offset <- 0..(@history_days - 1) do
      day = Date.add(history.first_day, offset)
      values = Enum.map(monitor_ids, &monitor_day(&1, day, history))
      monitored = Enum.sum(Enum.map(values, & &1.monitored))
      downtime = Enum.sum(Enum.map(values, & &1.downtime))
      incident_count = Enum.sum(Enum.map(values, & &1.incident_count))
      pause_count = Enum.sum(Enum.map(values, & &1.pause_count))
      check_count = Enum.sum(Enum.map(values, & &1.check_count))
      degraded_check_count = Enum.sum(Enum.map(values, & &1.degraded_check_count))
      historical_partial? = Enum.any?(values, & &1.historical_partial?)
      evidence? = Enum.any?(values, & &1.evidence?)
      ratio = if evidence? and monitored > 0, do: (monitored - downtime) / monitored

      state =
        cond do
          pause_count > 0 -> :maintenance
          downtime > 0 -> :down
          historical_partial? -> :partial
          degraded_check_count > 0 -> :degraded
          evidence? -> :up
          true -> :unknown
        end

      %{
        day: day,
        state: state,
        uptime: ratio,
        monitored_microseconds: monitored,
        downtime_microseconds: downtime,
        monitored: monitored,
        downtime: downtime,
        check_count: check_count,
        incident_count: incident_count,
        pause_count: pause_count,
        degraded_check_count: degraded_check_count,
        evidence?: evidence?,
        partial?: day == history.today,
        historical_partial?: historical_partial?
      }
    end
  end

  defp monitor_day(monitor_id, day, history) do
    case get_in(history, [:by_monitor, monitor_id, :days_by_date, day]) do
      %{monitored_microseconds: monitored, downtime_microseconds: downtime} = reliability_day ->
        %{
          monitored: monitored,
          downtime: downtime,
          incident_count: reliability_day.incident_count,
          pause_count: reliability_day.pause_count,
          check_count: reliability_day.check_count,
          degraded_check_count: reliability_day.degraded_check_count,
          evidence?: reliability_day.evidence?,
          historical_partial?: reliability_day.historical_partial?
        }

      _ ->
        %{
          monitored: 0,
          downtime: 0,
          incident_count: 0,
          pause_count: 0,
          check_count: 0,
          degraded_check_count: 0,
          evidence?: false,
          historical_partial?: false
        }
    end
  end

  defp component_reliability([], _history), do: nil

  defp component_reliability([monitor_id], history) do
    case get_in(history, [:by_monitor, monitor_id]) do
      %{target: target, summary: summary, budget: budget}
      when is_number(target) and target > 0 and target <= 1 ->
        %{target: target, summary: summary, budget: budget}

      _ ->
        nil
    end
  end

  defp component_reliability(_monitor_ids, _history), do: nil

  defp component_status(
         ids,
         monitor_statuses,
         active_maintenance_monitors,
         component_id,
         incident_overrides
       ) do
    case Map.get(incident_overrides, component_id) do
      nil -> component_status_from_monitors(ids, monitor_statuses, active_maintenance_monitors)
      override -> override
    end
  end

  defp component_status_from_monitors([], _monitor_statuses, _active_maintenance_monitors),
    do: :unknown

  defp component_status_from_monitors(ids, monitor_statuses, active_maintenance_monitors) do
    maintenance_ids = Enum.filter(ids, &Enum.member?(active_maintenance_monitors, &1))
    statuses = Enum.map(ids, &status_for(&1, monitor_statuses))
    maintenance_active? = maintenance_ids != []

    cond do
      :down in statuses -> :down
      maintenance_active? -> :maintenance
      :degraded in statuses -> :degraded
      :paused in statuses -> :degraded
      :unknown in statuses -> :unknown
      true -> :up
    end
  end

  defp status_for(id, statuses) do
    case Map.get(statuses, id) do
      %{status: status} when status in ["paused", :paused] ->
        :paused

      %{status: status, last_known_status: last_known} ->
        monitor_status(%{status: status, last_known_status: last_known})

      _ ->
        :unknown
    end
  end

  @doc """
  The public reading of one monitor's private state. Shared with the
  authenticated status-page screens so their previews and glance dots say
  exactly what the public page will say.
  """
  def monitor_status(%{status: "paused"}), do: :degraded
  def monitor_status(%{status: :paused}), do: :degraded
  def monitor_status(%{last_known_status: last}) when last in ["down", :down], do: :down

  def monitor_status(%{last_known_status: last}) when last in ["degraded", :degraded],
    do: :degraded

  def monitor_status(%{last_known_status: last}) when last in ["up", :up], do: :up
  def monitor_status(_monitor), do: :unknown

  defp paused_monitor?(%{status: status}) when status in ["paused", :paused], do: true
  defp paused_monitor?(_monitor), do: false

  defp overall_status(components, {maintenance_active?, page_incident_status}) do
    Alplus.Status.aggregate_health(
      components,
      maintenance_active?,
      page_incident_status,
      :unknown
    )
  end

  defp uptime_percent(rows) do
    monitored = Enum.sum(Enum.map(rows, & &1.monitored))
    downtime = Enum.sum(Enum.map(rows, & &1.downtime))

    if monitored == 0 do
      nil
    else
      Float.round((monitored - downtime) / monitored * 100, 2)
    end
  end

  # A published, non-private incident with no confirmed affected services yet
  # still means something is wrong right now for every currently public
  # component: the banner must never read "no observations" (or the embed
  # repeat the same pill next to red history squares) while it is open. Mock
  # 08, line 651: the banner is the answer, derived from the worst active
  # state across services *and* open incidents.
  defp incident_service_overrides(page, component_ids) do
    scoped =
      Repo.query!(
        """
        SELECT sis.status_component_id, sis.state
        FROM status_incident_services AS sis
        INNER JOIN status_incidents AS si
          ON si.id = sis.status_incident_id
         AND si.org_id = $1
         AND si.project_id = $2
        WHERE sis.org_id = $1
          AND sis.project_id = $2
          AND si.status_page_id = $3
          AND si.status = 'open'
          AND si.is_private = false
        ORDER BY si.published_at DESC
        """,
        [page.org_id, page.project_id, page.id]
      ).rows
      |> reduce_incident_overrides()

    if unscoped_open_incident?(page) do
      overrides =
        Enum.reduce(component_ids, scoped, fn component_id, acc ->
          Map.update(acc, component_id, :degraded, &worst_incident_state(&1, :degraded))
        end)

      {overrides, :degraded}
    else
      {scoped, nil}
    end
  end

  defp unscoped_open_incident?(page) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 1
        FROM status_incidents AS si
        WHERE si.org_id = $1 AND si.project_id = $2 AND si.status_page_id = $3
          AND si.status = 'open' AND si.is_private = false
          AND NOT EXISTS (
            SELECT 1 FROM status_incident_services AS sis
            WHERE sis.status_incident_id = si.id
              AND sis.org_id = $1 AND sis.project_id = $2
          )
        LIMIT 1
        """,
        [page.org_id, page.project_id, page.id]
      )

    rows != []
  end

  defp public_incidents(page, actor, components) do
    query =
      Ash.Query.for_read(StatusIncident, :public_for_page, %{status_page_id: page.id},
        actor: actor
      )

    query
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.Query.limit(@max_public_incidents)
    |> Ash.read!(actor: actor)
    |> results()
    |> then(fn incidents ->
      incident_ids = Enum.map(incidents, & &1.id)
      updates = public_incident_updates(actor, incident_ids)
      services = incident_services(page, incident_ids, components)

      Enum.map(incidents, fn incident ->
        incident_updates = Map.get(updates, incident.id, [])

        %{
          id: incident.id,
          title: incident.title,
          body: incident.body,
          status: incident.status,
          stage: incident.stage,
          next_update_at: incident.next_update_at,
          published_at: incident.published_at,
          closed_at: incident.closed_at,
          affected_services: Map.get(services, incident.id, []),
          updates:
            Enum.map(incident_updates, fn update ->
              %{body: update.body, kind: update.kind, inserted_at: update.inserted_at}
            end)
        }
      end)
    end)
  end

  defp public_incident_updates(_actor, []), do: %{}

  defp public_incident_updates(actor, incident_ids) do
    StatusIncidentUpdate
    |> Ash.Query.for_read(:public_for_incidents, %{status_incident_ids: incident_ids},
      actor: actor
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@max_public_incident_updates)
    |> Ash.read!(actor: actor)
    |> results()
    |> Enum.group_by(& &1.status_incident_id)
  end

  defp incident_services(_page, [], _components), do: %{}

  defp incident_services(page, incident_ids, components) do
    names = Map.new(components, &{&1.id, &1.name})

    Repo.query!(
      """
      SELECT sis.status_incident_id, sis.status_component_id, sis.state
      FROM status_incident_services AS sis
      WHERE sis.status_incident_id = ANY($1::text[])
        AND sis.org_id = $2
        AND sis.project_id = $3
      ORDER BY sis.status_incident_id, sis.status_component_id
      LIMIT $4
      """,
      [incident_ids, page.org_id, page.project_id, @max_public_incident_services]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), fn [_incident_id, service_id, state] ->
      %{id: service_id, name: Map.get(names, service_id), state: incident_state(state)}
    end)
  end

  defp public_announcements(page, actor) do
    query =
      Ash.Query.for_read(StatusAnnouncement, :public_for_page, %{status_page_id: page.id},
        actor: actor
      )

    query
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.Query.limit(@max_public_announcements)
    |> Ash.read!(actor: actor)
    |> results()
    |> Enum.map(fn announcement ->
      %{
        id: announcement.id,
        title: announcement.title,
        body: announcement.body,
        published_at: announcement.published_at,
        expires_at: announcement.expires_at
      }
    end)
  end

  defp public_announcement_history(page, actor) do
    StatusAnnouncement
    |> Ash.Query.for_read(:public_history, %{status_page_id: page.id}, actor: actor)
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.Query.limit(@max_public_history_items)
    |> Ash.read!(actor: actor)
    |> results()
    |> Enum.map(fn announcement ->
      %{
        id: announcement.id,
        title: announcement.title,
        body: announcement.body,
        published_at: announcement.published_at,
        expires_at: announcement.expires_at,
        status: announcement_history_status(announcement)
      }
    end)
  end

  defp announcement_history_status(%{expires_at: nil}), do: "published"

  defp announcement_history_status(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt, do: "expired", else: "published"
  end

  defp public_maintenance(page, actor) do
    query =
      Ash.Query.for_read(ScheduledMaintenance, :public_for_page, %{status_page_id: page.id},
        actor: actor
      )

    now = DateTime.utc_now()

    query
    |> Ash.Query.filter((status == "scheduled" or status == "active") and ends_at > ^now)
    |> Ash.Query.sort(starts_at: :asc)
    |> Ash.Query.limit(@max_public_maintenances)
    |> Ash.read!(actor: actor)
    |> results()
    |> Enum.map(fn maintenance ->
      %{
        id: maintenance.id,
        title: maintenance.title,
        description: maintenance.description,
        starts_at: maintenance.starts_at,
        ends_at: maintenance.ends_at,
        status: maintenance.status
      }
    end)
  end

  defp public_maintenance_history(page, actor) do
    ScheduledMaintenance
    |> Ash.Query.for_read(:public_history, %{status_page_id: page.id}, actor: actor)
    |> Ash.Query.sort(ends_at: :desc)
    |> Ash.Query.limit(@max_public_history_items)
    |> Ash.read!(actor: actor)
    |> results()
    |> Enum.map(fn maintenance ->
      %{
        id: maintenance.id,
        title: maintenance.title,
        description: maintenance.description,
        starts_at: maintenance.starts_at,
        ends_at: maintenance.ends_at,
        status: maintenance.status
      }
    end)
  end

  defp results(%{results: results}), do: results
  defp results(results) when is_list(results), do: results
end
