defmodule Mix.Tasks.Alplus.DemoSeed do
  @moduledoc """
  Seeds the dev database with one realistic demo workspace so the running
  dashboard renders populated charts: for product screenshots on the
  marketing site, design review, and manual QA.

  Creates (idempotently, keyed on the demo email):

    - user `demo@postdeploy.dev` / password `demo-supersecret1`, confirmed
    - org "Acme Dev Co" on the scale plan, project "side-project"
    - monitors: two HTTP checks, one TCP check, one heartbeat, with 30 days
      of check history, one resolved incident, and finalized daily rollups
    - an Observe source with 14 days of error events (a bad deploy spike)
      and two releases
    - a Measure source with 14 days of day rollups and 48 hours of hour
      rollups
    - a product analytics source with 30 days of a realistic onboarding and
      subscription funnel, two app versions, two onboarding variants, and
      return visits, plus a saved funnel and an activation definition

  Run with:

      mix alplus.demo_seed

  Dev only: this file lives in `dev/`, so it never compiles into a release.
  Everything goes through the real Ash actions or the real ingest writers,
  the same layering `mix alplus.loadtest` uses.
  """

  use Mix.Task

  @shortdoc "Seeds a demo org with 30 days of monitoring, errors and analytics"

  @email "demo@postdeploy.dev"
  @password "demo-supersecret1"

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:alplus)

    previous_log_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      seed()
    after
      Logger.configure(level: previous_log_level)
    end
  end

  defp seed do
    now = DateTime.utc_now()

    user = ensure_user()
    scope = Alplus.Scope.for_user(user.id)

    org =
      Ash.create!(
        Alplus.Orgs.Organization,
        %{name: "Acme Dev Co"},
        action: :create,
        actor: scope
      )

    Alplus.Repo.query!(
      "UPDATE organizations SET plan_status = 'active', plan_id = 'postdeploy' WHERE id = $1",
      [org.id]
    )

    {:ok, owner_scope} = Alplus.Orgs.build_scope(scope, org.id)

    project =
      Ash.create!(
        Alplus.Projects.Project,
        %{org_id: org.id, name: "side-project"},
        action: :create,
        actor: owner_scope
      )

    project_scope = Alplus.Scope.put_project(owner_scope, project.id)

    seed_monitoring(project_scope, org, project, now)
    seed_observe(project_scope, org, project, now)
    seed_measure(project_scope, org, project, now)
    seed_analytics(project_scope, org, project, now)

    Mix.shell().info("demo workspace ready: #{@email} / #{@password}")
    Mix.shell().info("org #{org.id}, project #{project.id}")
  end

  defp ensure_user do
    require Ash.Query

    existing =
      Alplus.Accounts.User
      |> Ash.Query.filter(email == ^@email)
      |> Ash.read!(authorize?: false)

    case existing do
      [_user | _] ->
        Mix.raise("""
        #{@email} already exists. The demo workspace is append-only; drop and
        recreate the dev database (mix ecto.reset) to reseed, or sign in with
        the existing account.
        """)

      [] ->
        Alplus.Accounts.User
        |> Ash.create!(
          %{
            email: @email,
            password: @password,
            password_confirmation: @password,
            turnstile_token: "dev-demo-seed"
          },
          action: :register_with_password,
          authorize?: false
        )
        |> Ash.update!(%{}, action: :mark_confirmed, authorize?: false)
    end
  end

  # -- Monitor -------------------------------------------------------------

  defp seed_monitoring(scope, org, project, now) do
    api =
      create_http(scope, org, project, "api.side-project.dev", "https://example.com/health", 60)

    site =
      create_http(scope, org, project, "side-project.dev", "https://example.com/", 300)

    tcp = create_tcp(scope, org, project, "db.side-project.dev")
    heartbeat = create_heartbeat(scope, org, project, "nightly-backup")

    # Six days ago the API had a two-hour incident; everything else is green.
    incident_start = now |> DateTime.add(-6 * 86_400, :second) |> at_hour(3)
    incident_end = DateTime.add(incident_start, 2 * 3_600, :second)

    seed_checks(org, project, api, now, 1_800, fn checked_at ->
      if within?(checked_at, incident_start, incident_end) do
        {"down", 503, jitter(2_000, 400)}
      else
        {"up", 200, jitter(140, 60)}
      end
    end)

    seed_checks(org, project, site, now, 3_600, fn _ -> {"up", 200, jitter(90, 30)} end)
    seed_checks(org, project, tcp, now, 3_600, fn _ -> {"up", nil, jitter(12, 6)} end)
    # One heartbeat ping per day at 03:00 UTC.
    for days_ago <- 30..1//-1 do
      checked_at = now |> DateTime.add(-days_ago * 86_400, :second) |> at_hour(3)
      record_check(org, project, heartbeat, checked_at, "up", nil, nil)
    end

    incident =
      Ash.create!(
        Alplus.Monitoring.Incident,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: api.id,
          environment: "production",
          cause: "availability",
          cause_detail: %{"status_code" => 503},
          started_at: incident_start,
          checks_failed_count: 4
        },
        action: :open,
        authorize?: false
      )

    Ash.update!(
      incident,
      %{
        resolved_at: incident_end,
        duration_seconds: DateTime.diff(incident_end, incident_start, :second)
      },
      action: :resolve,
      authorize?: false
    )

    # Materialize daily rollups for every completed day, through the real
    # finalizer, so 30d/90d availability views read real rows.
    for monitor <- [api, site, tcp, heartbeat], days_ago <- 30..1//-1 do
      day = Date.add(DateTime.to_date(now), -days_ago)
      {:ok, _} = Alplus.Monitoring.Rollup.finalize(scope, monitor.id, day)
    end

    # `:record` check inserts do not touch the monitor row itself (the live
    # scheduler does that), so reflect the seeded history on the fleet
    # health card directly.
    Alplus.Repo.query!(
      "UPDATE monitors SET last_known_status = 'up' WHERE org_id = $1",
      [org.id]
    )
  end

  defp create_http(scope, org, project, name, url, interval) do
    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: name,
          environment: "production"
        },
        action: :create,
        actor: scope
      )

    Ash.create!(
      Alplus.Monitoring.HttpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        url: url,
        method: "GET",
        expected_status: %{"kind" => "range", "min" => 200, "max" => 299},
        interval_seconds: interval,
        timeout_seconds: 10
      },
      action: :create,
      actor: scope
    )

    monitor
  end

  defp create_tcp(scope, org, project, hostname) do
    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "tcp",
          name: hostname,
          environment: "production"
        },
        action: :create,
        actor: scope
      )

    Ash.create!(
      Alplus.Monitoring.TcpConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        hostname: hostname,
        port: 5432,
        timeout_seconds: 5,
        interval_seconds: 3_600
      },
      action: :create,
      actor: scope
    )

    monitor
  end

  defp create_heartbeat(scope, org, project, name) do
    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "heartbeat",
          name: name,
          environment: "production"
        },
        action: :create,
        actor: scope
      )

    Ash.create!(
      Alplus.Monitoring.HeartbeatConfig,
      %{
        monitor_id: monitor.id,
        org_id: org.id,
        grace_period_seconds: 3_600,
        interval_seconds: 86_400,
        timezone: "UTC",
        track_duration: false
      },
      action: :issue,
      actor: scope
    )

    monitor
  end

  defp seed_checks(org, project, monitor, now, step_seconds, outcome_fun) do
    window_start = DateTime.add(now, -30 * 86_400, :second)
    total_steps = div(30 * 86_400, step_seconds)

    for step <- 0..(total_steps - 1) do
      checked_at = DateTime.add(window_start, step * step_seconds, :second)
      {status, status_code, latency} = outcome_fun.(checked_at)
      record_check(org, project, monitor, checked_at, status, status_code, latency)
    end
  end

  defp record_check(org, project, monitor, checked_at, status, status_code, latency_ms) do
    Ash.create!(
      Alplus.Monitoring.MonitorCheck,
      %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor.id,
        environment: "production",
        status: status,
        checked_at: checked_at,
        status_code: status_code,
        latency_ms: latency_ms
      },
      action: :record,
      authorize?: false
    )
  end

  # -- Observe ---------------------------------------------------------------

  defp seed_observe(scope, org, project, now) do
    {source, _secret} = create_source(scope, org, project, :observe, "side-project api")

    release = fn version, days_ago ->
      Ash.create!(
        Alplus.Observe.Release,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: "production",
          version: version,
          commit_sha: String.duplicate(String.at(version, -1), 40),
          released_at: DateTime.add(now, -days_ago * 86_400, :second)
        },
        action: :create,
        actor: scope
      )
    end

    release.("v2.4.0", 9)
    release.("v2.4.1", 6)

    # A quiet fortnight, a bad deploy six days ago, then mostly fixed.
    daily_counts = [0, 0, 2, 0, 0, 1, 0, 0, 14, 3, 1, 0, 1, 3]

    for {count, index} <- Enum.with_index(daily_counts), count > 0 do
      days_ago = 13 - index

      for n <- 1..count do
        occurred_at =
          now
          |> DateTime.add(-days_ago * 86_400, :second)
          |> at_hour(rem(n * 5, 24))

        {:ok, _} =
          Alplus.Observe.EventWriter.record(%{
            event_id: Ash.UUID.generate(),
            org_id: org.id,
            project_id: project.id,
            source_id: source.id,
            environment: "production",
            occurred_at: occurred_at,
            received_at: occurred_at,
            level: "error",
            sdk_name: "@alplus/sdk",
            sdk_version: "0.4.2",
            exception_type: exception_type(days_ago, n),
            exception_value: exception_value(days_ago, n),
            message: nil
          })
      end
    end
  end

  # The bad-deploy day (five days ago, the 14-event spike in
  # `daily_counts`) groups into one loud TypeError issue; the rest is a
  # slow trickle of a second, older issue.
  defp exception_type(5, _n), do: "TypeError"
  defp exception_type(_days_ago, _n), do: "TimeoutError"

  defp exception_value(5, _n), do: "fetch failed"
  defp exception_value(_days_ago, _n), do: "connection pool exhausted"

  # -- Measure ---------------------------------------------------------------

  defp seed_measure(scope, org, project, now) do
    {source, _secret} = create_source(scope, org, project, :measure, "side-project.dev")

    paths = ["/", "/pricing", "/blog/launch", "/docs"]
    base = [312, 285, 340, 298, 355, 410, 388, 452, 421, 489, 512, 543, 575, 604]

    for {total, index} <- Enum.with_index(base) do
      day_at = DateTime.add(now, -(13 - index) * 86_400, :second)

      for {path, share} <- Enum.zip(paths, [0.5, 0.2, 0.2, 0.1]) do
        pageviews = round(total * share)

        Alplus.Measure.Rollups.record!(
          %{id: project.id, org_id: org.id},
          source.id,
          "production",
          %{type: "pageview", path: path, hostname: "side-project.dev"},
          %{
            pageviews: pageviews,
            visitors: round(pageviews * 0.62),
            visits: round(pageviews * 0.7),
            bounces: round(pageviews * 0.3),
            duration_seconds: pageviews * 40
          },
          day_at
        )
      end
    end

    # Hour buckets for the 24h/7d dashboard windows.
    for hours_ago <- 47..0//-1 do
      hour_at = DateTime.add(now, -hours_ago * 3_600, :second)
      pageviews = 8 + rem(hours_ago * 7, 23)

      insert_hour!(org, project, source, hour_at, pageviews)
    end
  end

  defp insert_hour!(org, project, source, hour_at, pageviews) do
    hour = %{hour_at | minute: 0, second: 0, microsecond: {0, 6}}

    # Mirrors the raw insert in `Alplus.Measure.DashboardTest.insert_hour!/5`:
    # hour buckets are only written by the live ingest path, so a seed
    # backfill writes the table directly.
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_hours
        (id, org_id, project_id, source_id, environment, hour, pageviews,
         visitors, visits, bounces, duration_seconds, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, $6, $7, $8, 0, 0, now(), now())
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        org.id,
        project.id,
        source.id,
        hour,
        pageviews,
        max(div(pageviews * 3, 5), 1),
        max(div(pageviews * 7, 10), 1)
      ]
    )
  end

  defp create_source(scope, org, project, type, name) do
    source =
      Ash.create!(
        Alplus.Sources.Source,
        %{
          org_id: org.id,
          project_id: project.id,
          type: type,
          name: name,
          environment: "production"
        },
        action: :create,
        actor: scope
      )

    {source, Ash.Resource.get_metadata(source, :secret)}
  end


  # -- Product analytics -----------------------------------------------------

  # Deterministic on purpose: every count below comes from the person's index,
  # never from `:rand`. A screenshot taken today and one taken tomorrow show
  # the same numbers, so a visual diff means somebody changed the product.
  @cohort_size 1_200
  @cohort_days 30

  @doc false
  # Public so a test can seed one project's analytics without creating a
  # demo user, which registration's HIBP check makes impossible outside dev.
  def seed_analytics(scope, org, project, now) do
    {source, _key} = create_source(scope, org, project, :analytics, "iOS app")

    rows =
      0..(@cohort_size - 1)
      |> Enum.flat_map(&person_events(&1, now))
      |> Enum.map(fn {event, distinct_id, at, properties} ->
        [
          Alplus.Id.generate(:product_event),
          org.id,
          project.id,
          source.id,
          "production",
          event,
          distinct_id,
          at,
          properties
        ]
      end)

    Enum.each(Enum.chunk_every(rows, 500), &insert_product_events/1)

    {:ok, funnel} =
      Alplus.Analytics.create_funnel(
        %{
          org_id: org.id,
          project_id: project.id,
          name: "Onboarding to first meal",
          steps: ["first_open", "onboarding_started", "onboarding_completed", "meal_logged"],
          window_hours: 168,
          breakdown_property: "onboarding_variant"
        },
        actor: scope
      )

    {:ok, _subscription_funnel} =
      Alplus.Analytics.create_funnel(
        %{
          org_id: org.id,
          project_id: project.id,
          name: "Paywall to subscription",
          steps: ["paywall_viewed", "trial_started", "subscription_started"],
          window_hours: 336
        },
        actor: scope
      )

    {:ok, _settings} =
      Alplus.Analytics.configure_settings(
        %{
          org_id: org.id,
          project_id: project.id,
          activation_start_event: "first_open",
          activation_event: "meal_logged",
          activation_window_hours: 168,
          primary_funnel_id: funnel.id
        },
        actor: scope
      )

    :ok
  end

  # One person's whole journey. Each drop-off is a modulus over the index, so
  # the shape is fixed: 92% start onboarding, 77% of those finish, 83% of
  # those log a meal, half of those see the paywall, and a sixth of those
  # start a trial. Version 1.9.0 completes onboarding less often than 1.8.0,
  # which is the release comparison the screen exists to show.
  @doc false
  def person_events(index, now) do
    day = rem(index, @cohort_days)
    started_at = now |> DateTime.add(-(@cohort_days - day) * 86_400, :second) |> at_hour(9)
    distinct_id = "anon_#{String.pad_leading(Integer.to_string(index), 5, "0")}"

    version = if day >= @cohort_days - 10, do: "1.9.0", else: "1.8.0"
    variant = if rem(index, 2) == 0, do: "short", else: "long"
    platform = Enum.at(~w(ios android web), rem(index, 3))

    base = %{
      "app_version" => version,
      "platform" => platform,
      "onboarding_variant" => variant
    }

    events = [{"first_open", distinct_id, started_at, base}]

    events
    |> maybe_add(rem(index, 25) != 0, "onboarding_started", distinct_id, offset(started_at, 60), base)
    |> maybe_add(completes_onboarding?(index, version), "onboarding_completed", distinct_id, offset(started_at, 300), base)
    |> maybe_add(logs_meal?(index, version), "meal_logged", distinct_id, offset(started_at, 900), Map.put(base, "source", "camera"))
    |> maybe_add(returns?(index, version, 1), "meal_logged", distinct_id, offset(started_at, 86_400), Map.put(base, "source", "camera"))
    |> maybe_add(returns?(index, version, 3), "meal_logged", distinct_id, offset(started_at, 3 * 86_400), Map.put(base, "source", "camera"))
    |> maybe_add(returns?(index, version, 7), "meal_logged", distinct_id, offset(started_at, 7 * 86_400), Map.put(base, "source", "camera"))
    |> maybe_add(sees_paywall?(index, version), "paywall_viewed", distinct_id, offset(started_at, 4_000), Map.put(base, "source", "feature_gate"))
    |> maybe_add(starts_trial?(index, version), "trial_started", distinct_id, offset(started_at, 4_200), base)
    |> maybe_add(subscribes?(index, version), "subscription_started", distinct_id, offset(started_at, 10 * 86_400), Map.put(base, "plan", "annual"))
    |> Enum.reject(fn {_event, _id, at, _props} -> DateTime.compare(at, DateTime.utc_now()) == :gt end)
  end

  defp completes_onboarding?(index, "1.9.0"), do: rem(index, 25) != 0 and rem(index, 3) != 0
  defp completes_onboarding?(index, _version), do: rem(index, 25) != 0 and rem(index, 4) != 0

  defp logs_meal?(index, version), do: completes_onboarding?(index, version) and rem(index, 6) != 0

  defp returns?(index, version, day),
    do: logs_meal?(index, version) and rem(index, day + 2) == 0

  defp sees_paywall?(index, version), do: logs_meal?(index, version) and rem(index, 2) == 0

  defp starts_trial?(index, version), do: sees_paywall?(index, version) and rem(index, 12) == 0

  defp subscribes?(index, version), do: starts_trial?(index, version) and rem(index, 24) == 0

  defp maybe_add(events, false, _event, _id, _at, _props), do: events

  defp maybe_add(events, true, event, id, at, props), do: events ++ [{event, id, at, props}]

  defp offset(at, seconds), do: DateTime.add(at, seconds, :second)

  defp insert_product_events(rows) do
    {placeholders, params} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {row, index}, {groups, params} ->
        base = index * 9

        group =
          "($#{base + 1},$#{base + 2},$#{base + 3},$#{base + 4},$#{base + 5},$#{base + 6}," <>
            "$#{base + 7},$#{base + 8},$#{base + 8},$#{base + 9})"

        {groups ++ [group], params ++ row}
      end)

    Alplus.Repo.query!(
      """
      INSERT INTO product_events
        (id, org_id, project_id, source_id, environment, event_name, distinct_id,
         occurred_at, received_at, properties)
      VALUES #{Enum.join(placeholders, ", ")}
      """,
      params
    )
  end

  # -- helpers ---------------------------------------------------------------

  defp at_hour(datetime, hour) do
    %{datetime | hour: hour, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp within?(time, left, right) do
    DateTime.compare(time, left) != :lt and DateTime.compare(time, right) == :lt
  end

  defp jitter(base, spread), do: base + :rand.uniform(spread) - div(spread, 2)
end
