defmodule Alplus.StatusPublicStateTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{ActiveCheckOutcome, DailyRollup, Heartbeat, HeartbeatConfig, Monitor}
  alias Alplus.Measure.PublicCache
  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status
  alias AlplusWeb.StatusHTML

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "public-state",
        title: "State"
      })

    {:ok, component} =
      Status.create_component(scope, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API"
      })

    baseline_monitor = monitor_fixture(%{org: org, project: project, scope: scope})
    Ash.Seed.update!(baseline_monitor, %{last_known_status: "up"})
    :ok = Status.link_monitor(scope, component, baseline_monitor.id)
    {:ok, page} = Status.publish_page(scope, page)
    {:ok, public_page} = PublicPages.get_for_project(scope, project.id)

    {:ok, page: page, public_page: public_page, org: org, project: project, scope: scope}
  end

  test "no monitor observation stays explicit in the public snapshot", context do
    {:ok, component} =
      Status.create_component(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "Database"
      })

    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    PublicCache.clear()

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :unknown
    assert Enum.any?(snapshot.components, &(&1.name == "Database" and &1.status == :unknown))
  end

  test "some down and all down use different public states", context do
    {:ok, api_component} = first_component(context)

    {:ok, database_component} =
      Status.create_component(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: context.page.id,
        name: "Database"
      })

    monitor_a = monitor_fixture(context)
    monitor_b = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, api_component, monitor_a.id)
    :ok = Status.link_monitor(context.scope, database_component, monitor_b.id)
    set_status(monitor_a, "down")
    set_status(monitor_b, "up")

    assert {:ok, snapshot} = Status.load_public("public-state")
    assert snapshot.status == :partial_outage

    set_status(monitor_b, "down")
    assert {:ok, snapshot} = Status.load_public("public-state")
    assert snapshot.status == :major_outage
  end

  test "a down monitor after the first fifty still affects public state", context do
    {:ok, component} = first_component(context)

    monitors =
      for index <- 1..50 do
        monitor = monitor_fixture(context)
        :ok = Status.link_monitor(context.scope, component, monitor.id)
        set_status(monitor, if(index == 50, do: "down", else: "up"))
        monitor
      end

    assert length(monitors) == 50
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert [%{status: :down}] = snapshot.components
  end

  test "a page without a connected service cannot publish and stays private", _context do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    assert {:ok, page} =
             Status.create_page(scope, %{
               org_id: org.id,
               project_id: project.id,
               public_slug: "empty-public-state",
               title: "Empty state"
             })

    assert {:error, :service_required} = Status.publish_page(scope, page)
    assert {:error, :not_found} = Status.load_public("empty-public-state")
  end

  test "an unscoped open incident degrades an otherwise empty public page", context do
    {:ok, component} = first_component(context)
    assert :ok = Status.delete_component(context.scope, component)

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.components == []
    assert snapshot.status == :unknown

    assert {:ok, _incident} =
             Status.create_incident(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: context.page.id,
               service_ids: [],
               title: "Service disruption",
               body: "We are investigating."
             })

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :degraded
  end

  test "active incident overrides reduce to the worst state for each service", context do
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    set_status(monitor, "up")

    for state <- ["outage", "degraded", "maintenance", "operational"] do
      assert {:ok, _incident} =
               Status.create_incident(context.scope, %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 status_page_id: context.page.id,
                 service_ids: [component.id],
                 service_states: %{component.id => state},
                 title: "#{state} incident",
                 body: "The service is #{state}."
               })
    end

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :major_outage
    assert [%{status: :down}] = snapshot.components
  end

  test "active check failure and recovery invalidate the public snapshot cache", context do
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    set_status(monitor, "up")

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :operational

    down = %{status: "down", status_code: 503, latency_ms: 10, error_class: "unavailable"}
    up = %{status: "up", status_code: 200, latency_ms: 10, error_class: nil}

    assert {:ok, %{status: "down"}} = ActiveCheckOutcome.record(monitor.id, down)
    assert {:ok, %{status: "down"}} = ActiveCheckOutcome.record(monitor.id, down)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :major_outage

    assert {:ok, %{status: "up"}} = ActiveCheckOutcome.record(monitor.id, up)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :operational

    assert {:ok, %{status: "up"}} = ActiveCheckOutcome.record(monitor.id, up)
  end

  test "heartbeat failure and recovery invalidate the public snapshot cache", context do
    {:ok, component} = first_component(context)

    {monitor, token} = heartbeat_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)

    assert :accepted = Heartbeat.accept(token, :finish)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :operational

    assert :accepted = Heartbeat.accept(token, :fail)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :major_outage

    assert :accepted = Heartbeat.accept(token, :finish)
    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    assert snapshot.status == :operational

    assert :accepted = Heartbeat.accept(token, :finish)
  end

  test "worst state order keeps outage above maintenance", context do
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    set_status(monitor, "down")

    now = DateTime.utc_now()

    assert {:ok, _maintenance} =
             Status.schedule_maintenance(
               context.scope,
               %{
                 org_id: context.org.id,
                 project_id: context.project.id,
                 status_page_id: context.page.id,
                 title: "Database work",
                 starts_at: DateTime.add(now, -60, :second),
                 ends_at: DateTime.add(now, 3_600, :second)
               },
               [monitor.id]
             )

    assert {:ok, snapshot} = Status.load_public("public-state")
    assert snapshot.status == :major_outage

    assert :ok = Alplus.Status.MaintenanceWorker.run()
    assert {:ok, snapshot} = Status.load_public("public-state")
    assert snapshot.status == :maintenance
    assert hd(snapshot.components).status == :maintenance
  end

  test "uptime percentage weights daily durations", context do
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)

    today = Date.utc_today()

    insert_rollup(
      context,
      monitor,
      Date.add(today, -2),
      1_000_000_000_000_000,
      1_000_000_000_000_000
    )

    insert_rollup(context, monitor, Date.add(today, -1), 99_000_000_000_000_000, 0)

    # A percentage is published only once seven days are observed. Five more
    # days at exactly 99% keep the weighted answer at 99.0.
    for offset <- 3..7 do
      insert_rollup(
        context,
        monitor,
        Date.add(today, -offset),
        20_000_000_000_000_000,
        200_000_000_000_000
      )
    end

    Alplus.Measure.PublicCache.clear()

    assert {:ok, snapshot} = Status.load_public("public-state")
    assert hd(snapshot.components).uptime_percent == 99.0
  end

  test "public history labels rollup-only days as partial evidence", context do
    subscribed_fixture(context.org)
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)

    insert_rollup(context, monitor, Date.add(Date.utc_today(), -31), 300_000_000, 0)
    PublicCache.clear()

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    history = hd(snapshot.components).history

    assert Enum.any?(history, fn day -> day.state == :partial and day.historical_partial? end)
  end

  test "public maintenance evidence wins over a partial retention day", context do
    subscribed_fixture(context.org)
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    day = Date.add(Date.utc_today(), -31)

    insert_rollup(context, monitor, day, 300_000_000, 0)
    insert_pause_interval(context, monitor, day)
    PublicCache.clear()

    assert {:ok, snapshot} = Status.load_public(context.public_page.public_slug)
    history_day = Enum.find(hd(snapshot.components).history, &(&1.day == day))

    assert history_day.state == :maintenance
    assert history_day.historical_partial?
    assert StatusHTML.day_detail(history_day) =~ "1 pauses"
  end

  test "public snapshots do not expose monitor configuration", context do
    {:ok, component} = first_component(context)
    monitor = monitor_fixture(context)
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    set_status(monitor, "up")

    assert {:ok, snapshot} = Status.load_public("public-state")
    refute inspect(snapshot) =~ monitor.id
    refute inspect(snapshot) =~ "https://"
    refute inspect(snapshot) =~ "interval_seconds"
  end

  defp first_component(context) do
    query =
      Ash.Query.for_read(
        Alplus.Status.StatusComponent,
        :for_page,
        %{
          status_page_id: context.page.id
        },
        actor: context.scope
      )

    {:ok, components} = Ash.read(query, actor: context.scope)

    component =
      case components do
        %{results: rows} -> List.first(rows)
        rows when is_list(rows) -> List.first(rows)
      end

    {:ok, component}
  end

  defp monitor_fixture(context) do
    Ash.create!(
      Monitor,
      %{
        org_id: context.org.id,
        project_id: context.project.id,
        type: "http",
        name: "API monitor"
      },
      action: :create,
      actor: context.scope
    )
  end

  defp heartbeat_fixture(context) do
    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "heartbeat",
          name: "Heartbeat"
        },
        action: :create,
        actor: context.scope
      )

    config =
      Ash.create!(
        HeartbeatConfig,
        %{
          org_id: context.org.id,
          monitor_id: monitor.id,
          interval_seconds: 300,
          grace_period_seconds: 60
        },
        action: :issue,
        actor: context.scope
      )

    {monitor, Ash.Resource.get_metadata(config, :heartbeat_token)}
  end

  defp set_status(monitor, status) do
    # The check runtime owns this read-model field; no user-facing action
    # accepts it, so the fixture seeds the persisted observation directly.
    Ash.Seed.update!(monitor, %{last_known_status: status})

    PublicCache.clear()
  end

  defp insert_rollup(context, monitor, day, monitored, downtime) do
    # DailyRollup is a read-only resource. The production Rollup finalizer
    # owns writes, but this fixture needs exact durations to test weighting.
    Ash.Seed.seed!(DailyRollup, %{
      org_id: context.org.id,
      project_id: context.project.id,
      monitor_id: monitor.id,
      day: day,
      uptime_ratio: (monitored - downtime) / monitored,
      monitored_microseconds: monitored,
      downtime_microseconds: downtime,
      check_count: 1
    })
  end

  defp insert_pause_interval(context, monitor, day) do
    paused_at = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    resumed_at = DateTime.add(paused_at, 3_600, :second)

    Alplus.Repo.query!(
      """
      INSERT INTO monitor_pause_intervals
        (id, org_id, project_id, monitor_id, paused_at, resumed_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $5, $6)
      """,
      [
        Alplus.Id.generate(:monitor_pause_interval),
        context.org.id,
        context.project.id,
        monitor.id,
        paused_at,
        resumed_at
      ]
    )
  end
end
