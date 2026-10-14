defmodule Alplus.Analytics.QueriesTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Analytics.Queries
  alias Alplus.Repo

  @now ~U[2026-09-20 12:00:00.000000Z]

  setup do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    {source, _secret} = source_fixture(owner_scope, org, project, %{type: :analytics})

    project_scope = Alplus.Scope.put_project(owner_scope, project.id)

    %{
      org: org,
      owner_scope: owner_scope,
      project: project,
      source: source,
      scope: project_scope
    }
  end

  # A second app in the same project: its own write key, the same event pool.
  defp second_app(context, name) do
    {source, _secret} =
      source_fixture(context.owner_scope, context.org, context.project, %{
        type: :analytics,
        name: name
      })

    source
  end

  # Writes one event directly, so a query test states its own data in one
  # line and never depends on the ingest pipeline's behaviour.
  defp event(source, name, distinct_id, occurred_at, properties \\ %{}) do
    Repo.query!(
      """
      INSERT INTO product_events
        (id, org_id, project_id, source_id, environment, event_name, distinct_id,
         occurred_at, received_at, properties)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8,$9)
      """,
      [
        Alplus.Id.generate(:product_event),
        source.org_id,
        source.project_id,
        source.id,
        source.environment,
        name,
        distinct_id,
        occurred_at,
        properties
      ]
    )
  end

  defp minutes_ago(minutes), do: DateTime.add(@now, -minutes, :minute)
  defp days_ago(days), do: DateTime.add(@now, -days, :day)

  describe "totals/3" do
    test "counts events and distinct ids", %{source: source, scope: scope} do
      event(source, "meal_logged", "a", minutes_ago(10))
      event(source, "meal_logged", "a", minutes_ago(9))
      event(source, "meal_logged", "b", minutes_ago(8))

      assert %{events: 3, users: 2} = Queries.totals(scope, Queries.range("24h", @now))
    end

    test "excludes events outside the range", %{source: source, scope: scope} do
      event(source, "meal_logged", "a", days_ago(40))

      assert %{events: 0, users: 0} = Queries.totals(scope, Queries.range("30d", @now))
    end

    test "excludes another project's events", %{
      source: source,
      scope: scope,
      org: org,
      project: _project
    } do
      {_user, other_owner} = {nil, nil}
      _ = {other_owner, org}

      event(source, "meal_logged", "a", minutes_ago(5))

      other_scope = %{scope | project_id: "proj_00000000000000000000000000"}

      assert %{events: 1} = Queries.totals(scope, Queries.range("24h", @now))
      assert %{events: 0} = Queries.totals(other_scope, Queries.range("24h", @now))
    end

    test "counts an event whose client clock is slightly ahead of the server", %{
      source: source,
      scope: scope
    } do
      # Ingest accepts a timestamp up to an hour ahead, and the database's own
      # now() can sit milliseconds ahead of the VM's. An event inside that
      # tolerance must be readable, or it counts against the quota while
      # appearing nowhere.
      event(source, "meal_logged", "a", DateTime.add(@now, 30, :second))

      assert %{events: 1, users: 1} = Queries.totals(scope, Queries.range("24h", @now))
    end

    test "filters by a property value", %{source: source, scope: scope} do
      event(source, "paywall_viewed", "a", minutes_ago(5), %{"platform" => "ios"})
      event(source, "paywall_viewed", "b", minutes_ago(4), %{"platform" => "android"})

      assert %{events: 1, users: 1} =
               Queries.totals(scope, Queries.range("24h", @now), filters: %{"platform" => "ios"})
    end
  end

  describe "several apps in one project" do
    test "a project holds one write key per app", context do
      ios = second_app(context, "iOS app")
      android = second_app(context, "Android app")

      assert ios.id != android.id
      assert ios.secret_prefix != android.secret_prefix
    end

    test "counts every app together by default", context do
      ios = second_app(context, "iOS app")
      android = second_app(context, "Android app")

      event(ios, "meal_logged", "person_a", minutes_ago(10))
      event(android, "meal_logged", "person_b", minutes_ago(9))

      assert %{events: 2, users: 2} = Queries.totals(context.scope, Queries.range("24h", @now))
    end

    test "counts one app alone when asked", context do
      ios = second_app(context, "iOS app")
      android = second_app(context, "Android app")

      event(ios, "meal_logged", "person_a", minutes_ago(10))
      event(ios, "meal_logged", "person_a", minutes_ago(9))
      event(android, "meal_logged", "person_b", minutes_ago(8))

      assert %{events: 2, users: 1} =
               Queries.totals(context.scope, Queries.range("24h", @now), source_id: ios.id)

      assert %{events: 1, users: 1} =
               Queries.totals(context.scope, Queries.range("24h", @now), source_id: android.id)
    end

    test "follows one person across two apps in one funnel", context do
      ios = second_app(context, "iOS app")
      web = second_app(context, "Web app")

      # The same distinct_id signs up on the web and logs a meal on iOS.
      # This is the reason to keep both apps in one project.
      event(web, "first_open", "person_a", minutes_ago(60))
      event(ios, "meal_logged", "person_a", minutes_ago(30))

      assert [entry] =
               Queries.funnel(context.scope, Queries.range("24h", @now), [
                 "first_open",
                 "meal_logged"
               ])

      assert Enum.map(entry.steps, & &1.users) == [1, 1]
    end

    test "a per-app funnel counts only that app's own journeys", context do
      ios = second_app(context, "iOS app")
      web = second_app(context, "Web app")

      event(web, "first_open", "person_a", minutes_ago(60))
      event(ios, "meal_logged", "person_a", minutes_ago(30))
      event(ios, "first_open", "person_b", minutes_ago(60))
      event(ios, "meal_logged", "person_b", minutes_ago(30))

      assert [entry] =
               Queries.funnel(
                 context.scope,
                 Queries.range("24h", @now),
                 ["first_open", "meal_logged"],
                 source_id: ios.id
               )

      assert Enum.map(entry.steps, & &1.users) == [1, 1]
    end

    test "a per-app cohort counts only that app's own returns", context do
      ios = second_app(context, "iOS app")
      android = second_app(context, "Android app")

      event(ios, "meal_logged", "person_a", days_ago(5))
      # The same person returns on Android. The iOS-only view must not count
      # that as an iOS return.
      event(android, "meal_logged", "person_a", days_ago(4))

      %{periods: periods} =
        Queries.retention(context.scope, Queries.range("30d", @now), "meal_logged", "meal_logged",
          today: DateTime.to_date(@now),
          source_id: ios.id
        )

      assert Enum.find(periods, &(&1.period == 1)).retained == 0

      %{periods: all_apps} =
        Queries.retention(context.scope, Queries.range("30d", @now), "meal_logged", "meal_logged",
          today: DateTime.to_date(@now)
        )

      assert Enum.find(all_apps, &(&1.period == 1)).retained == 1
    end

    test "the live feed and the event list narrow to one app", context do
      ios = second_app(context, "iOS app")
      android = second_app(context, "Android app")

      event(ios, "meal_logged", "person_a", minutes_ago(3))
      event(android, "paywall_viewed", "person_b", minutes_ago(2))

      assert [%{event_name: "meal_logged"}] =
               Queries.live_events(context.scope, now: @now, source_id: ios.id)

      assert [%{event_name: "meal_logged"}] =
               Queries.list_events(context.scope, Queries.range("24h", @now), source_id: ios.id)
    end
  end

  describe "list_events/3" do
    test "ranks events and reports users and last seen", %{source: source, scope: scope} do
      event(source, "meal_logged", "a", minutes_ago(30))
      event(source, "meal_logged", "a", minutes_ago(20))
      event(source, "meal_logged", "b", minutes_ago(10))
      event(source, "paywall_viewed", "a", minutes_ago(5))

      assert [meal, paywall] = Queries.list_events(scope, Queries.range("24h", @now))

      assert meal.event_name == "meal_logged"
      assert meal.events == 3
      assert meal.users == 2
      assert DateTime.compare(meal.last_seen, minutes_ago(10)) == :eq
      assert paywall.event_name == "paywall_viewed"
      assert paywall.events == 1
    end

    test "searches by name", %{source: source, scope: scope} do
      event(source, "meal_logged", "a", minutes_ago(5))
      event(source, "paywall_viewed", "a", minutes_ago(4))

      assert [%{event_name: "paywall_viewed"}] =
               Queries.list_events(scope, Queries.range("24h", @now), search: "paywall")
    end

    test "treats an underscore in the search as a character, not a wildcard", %{
      source: source,
      scope: scope
    } do
      event(source, "meal_logged", "a", minutes_ago(5))
      event(source, "mealXlogged", "a", minutes_ago(4))

      assert [%{event_name: "meal_logged"}] =
               Queries.list_events(scope, Queries.range("24h", @now), search: "meal_logged")
    end
  end

  describe "time_series/3" do
    test "buckets by UTC day, whatever the database session time zone", %{
      source: source,
      scope: scope
    } do
      # 23:30 UTC and 00:30 UTC the next day are two different days. A
      # session time zone west of UTC would put them both on the earlier day
      # unless the bucket casts to UTC first.
      Alplus.Repo.query!("SET TIME ZONE 'America/Los_Angeles'")
      on_exit(fn -> Alplus.Repo.query!("SET TIME ZONE 'UTC'") end)

      event(source, "meal_logged", "a", ~U[2026-09-18 23:30:00.000000Z])
      event(source, "meal_logged", "b", ~U[2026-09-19 00:30:00.000000Z])

      series =
        Queries.time_series(scope, Queries.range("7d", @now),
          event_name: "meal_logged",
          interval: "day"
        )

      assert [%{at: first}, %{at: second}] = series
      assert DateTime.to_date(first) == ~D[2026-09-18]
      assert DateTime.to_date(second) == ~D[2026-09-19]
    end

    test "buckets by day", %{source: source, scope: scope} do
      event(source, "meal_logged", "a", days_ago(2))
      event(source, "meal_logged", "b", days_ago(2))
      event(source, "meal_logged", "a", days_ago(1))

      series =
        Queries.time_series(scope, Queries.range("7d", @now),
          event_name: "meal_logged",
          interval: "day"
        )

      assert [%{events: 2, users: 2}, %{events: 1, users: 1}] = series
    end
  end

  describe "breakdown/4" do
    test "ranks property values", %{source: source, scope: scope} do
      for index <- 1..6,
          do:
            event(source, "paywall_viewed", "u#{index}", minutes_ago(index), %{
              "source" => "onboarding"
            })

      for index <- 7..9,
          do:
            event(source, "paywall_viewed", "u#{index}", minutes_ago(index), %{
              "source" => "settings"
            })

      assert [onboarding, settings] =
               Queries.breakdown(scope, Queries.range("24h", @now), "source",
                 event_name: "paywall_viewed"
               )

      assert onboarding == %{value: "onboarding", events: 6, users: 6}
      assert settings == %{value: "settings", events: 3, users: 3}
    end

    test "labels a missing property and collapses the tail into (other)", %{
      source: source,
      scope: scope
    } do
      event(source, "paywall_viewed", "a", minutes_ago(1))

      for index <- 1..4,
          do:
            event(source, "paywall_viewed", "u#{index}", minutes_ago(index + 1), %{
              "variant" => "v#{index}"
            })

      values = Queries.breakdown(scope, Queries.range("24h", @now), "variant", limit: 2)

      assert length(values) == 3
      assert List.last(values).value == "(other)"
      assert Enum.sum(Enum.map(values, & &1.events)) == 5
    end
  end

  describe "funnel/4" do
    test "counts users who complete each step in order", %{source: source, scope: scope} do
      # a completes all three; b stops after step two; c only opens.
      event(source, "first_open", "a", minutes_ago(60))
      event(source, "onboarding_completed", "a", minutes_ago(50))
      event(source, "meal_logged", "a", minutes_ago(40))

      event(source, "first_open", "b", minutes_ago(60))
      event(source, "onboarding_completed", "b", minutes_ago(55))

      event(source, "first_open", "c", minutes_ago(60))

      assert [entry] =
               Queries.funnel(
                 scope,
                 Queries.range("24h", @now),
                 ["first_open", "onboarding_completed", "meal_logged"]
               )

      assert Enum.map(entry.steps, & &1.users) == [3, 2, 1]
    end

    test "ignores a later step that happened before the earlier one", %{
      source: source,
      scope: scope
    } do
      event(source, "onboarding_completed", "a", minutes_ago(60))
      event(source, "first_open", "a", minutes_ago(30))

      assert [entry] =
               Queries.funnel(
                 scope,
                 Queries.range("24h", @now),
                 ["first_open", "onboarding_completed"]
               )

      assert Enum.map(entry.steps, & &1.users) == [1, 0]
    end

    test "ignores a later step outside the conversion window", %{source: source, scope: scope} do
      event(source, "first_open", "a", days_ago(10))
      event(source, "onboarding_completed", "a", days_ago(1))

      assert [entry] =
               Queries.funnel(
                 scope,
                 Queries.range("30d", @now),
                 ["first_open", "onboarding_completed"],
                 window_hours: 24
               )

      assert Enum.map(entry.steps, & &1.users) == [1, 0]
    end

    test "counts a repeated step once", %{source: source, scope: scope} do
      event(source, "first_open", "a", minutes_ago(60))
      event(source, "meal_logged", "a", minutes_ago(50))
      event(source, "meal_logged", "a", minutes_ago(40))

      assert [entry] =
               Queries.funnel(scope, Queries.range("24h", @now), ["first_open", "meal_logged"])

      assert Enum.map(entry.steps, & &1.users) == [1, 1]
    end

    test "splits by a breakdown property taken from the first step", %{
      source: source,
      scope: scope
    } do
      event(source, "first_open", "a", minutes_ago(60), %{"variant" => "short"})
      event(source, "onboarding_completed", "a", minutes_ago(50))
      event(source, "first_open", "b", minutes_ago(60), %{"variant" => "long"})

      entries =
        Queries.funnel(
          scope,
          Queries.range("24h", @now),
          ["first_open", "onboarding_completed"],
          breakdown: "variant"
        )

      by_value = Map.new(entries, &{&1.breakdown_value, Enum.map(&1.steps, fn s -> s.users end)})

      assert by_value == %{"short" => [1, 1], "long" => [1, 0]}
    end

    test "applies a property filter to every step", %{source: source, scope: scope} do
      event(source, "first_open", "a", minutes_ago(60), %{"platform" => "ios"})
      event(source, "onboarding_completed", "a", minutes_ago(50), %{"platform" => "ios"})
      event(source, "first_open", "b", minutes_ago(60), %{"platform" => "android"})

      assert [entry] =
               Queries.funnel(
                 scope,
                 Queries.range("24h", @now),
                 ["first_open", "onboarding_completed"],
                 filters: %{"platform" => "ios"}
               )

      assert Enum.map(entry.steps, & &1.users) == [1, 1]
    end

    test "never reads another project's events", %{source: source, scope: scope} do
      event(source, "first_open", "a", minutes_ago(60))
      event(source, "onboarding_completed", "a", minutes_ago(50))

      other = %{scope | project_id: "proj_00000000000000000000000000"}

      assert Queries.funnel(other, Queries.range("24h", @now), [
               "first_open",
               "onboarding_completed"
             ]) == []
    end
  end

  describe "with_conversions/1" do
    test "reports overall and step conversion and the largest drop" do
      entry = %{
        breakdown_value: nil,
        steps: [
          %{event_name: "first_open", users: 1000},
          %{event_name: "onboarding_completed", users: 700},
          %{event_name: "meal_logged", users: 630}
        ]
      }

      result = Queries.with_conversions(entry)

      assert [first, second, third] = result.steps
      assert first.overall_rate == 100.0
      assert second.overall_rate == 70.0
      assert second.step_rate == 70.0
      assert third.step_rate == 90.0
      assert result.largest_drop_event == "onboarding_completed"
      assert result.overall_rate == 63.0
    end

    test "reports no rate when nobody entered" do
      entry = %{
        breakdown_value: nil,
        steps: [%{event_name: "first_open", users: 0}, %{event_name: "done", users: 0}]
      }

      assert %{overall_rate: nil} = Queries.with_conversions(entry)
    end
  end

  describe "retention/5" do
    test "reports exact-day retention against a finished cohort", %{
      source: source,
      scope: scope
    } do
      # Two people start on day -10. One returns on day -9 (offset 1) and
      # day -3 (offset 7). The other never returns.
      event(source, "meal_logged", "a", days_ago(10))
      event(source, "meal_logged", "b", days_ago(10))
      event(source, "meal_logged", "a", days_ago(9))
      event(source, "meal_logged", "a", days_ago(3))

      %{periods: periods} =
        Queries.retention(scope, Queries.range("30d", @now), "meal_logged", "meal_logged",
          today: DateTime.to_date(@now)
        )

      by_period = Map.new(periods, &{&1.period, {&1.cohort, &1.retained}})

      assert by_period[0] == {2, 2}
      assert by_period[1] == {2, 1}
      assert by_period[3] == {2, 0}
      assert by_period[7] == {2, 1}
    end

    test "leaves an unfinished period out of the denominator", %{source: source, scope: scope} do
      # The cohort started yesterday. Their day 0 finished; their day 1 is
      # still running today, and their day 7 has not started. Counting an
      # unfinished period would report somebody who still has hours left as
      # somebody who did not return.
      event(source, "first_open", "a", days_ago(1))

      %{periods: periods} =
        Queries.retention(scope, Queries.range("30d", @now), "first_open", "first_open",
          today: DateTime.to_date(@now)
        )

      by_period = Map.new(periods, &{&1.period, &1.cohort})

      assert by_period[0] == 1
      assert by_period[1] == 0
      assert by_period[7] == 0
    end

    test "keeps a period that finished today in the denominator", %{
      source: source,
      scope: scope
    } do
      # Their day 1 ran yesterday and is over, so it counts.
      event(source, "first_open", "a", days_ago(2))

      %{periods: periods} =
        Queries.retention(scope, Queries.range("30d", @now), "first_open", "first_open",
          today: DateTime.to_date(@now)
        )

      by_period = Map.new(periods, &{&1.period, &1.cohort})

      assert by_period[1] == 1
      assert by_period[3] == 0
    end
  end

  describe "activation/3" do
    test "reports the rate from the configured pair", %{source: source, scope: scope} do
      event(source, "first_open", "a", minutes_ago(60))
      event(source, "meal_logged", "a", minutes_ago(30))
      event(source, "first_open", "b", minutes_ago(60))

      settings = %{
        activation_start_event: "first_open",
        activation_event: "meal_logged",
        activation_window_hours: 168
      }

      assert %{started: 2, activated: 1, rate: 50.0} =
               Queries.activation(scope, Queries.range("24h", @now), settings)
    end

    test "returns nothing when no activation is configured", %{scope: scope} do
      assert Queries.activation(scope, Queries.range("24h", @now), nil) == nil
    end
  end

  describe "live_events/2" do
    test "returns the most recent events with their properties", %{
      source: source,
      scope: scope
    } do
      event(source, "onboarding_started", "a", minutes_ago(3), %{"step" => 1})
      event(source, "onboarding_completed", "a", minutes_ago(1))

      assert [latest, earlier] = Queries.live_events(scope, now: @now)

      assert latest.event_name == "onboarding_completed"
      assert earlier.event_name == "onboarding_started"
      assert earlier.properties == %{"step" => 1}
    end

    test "leaves out events older than the live window", %{source: source, scope: scope} do
      event(source, "meal_logged", "a", minutes_ago(180))

      assert Queries.live_events(scope, now: @now) == []
    end
  end

  describe "property_keys/2" do
    test "lists the names ingest registered", %{
      source: source,
      scope: scope,
      org: org,
      project: project
    } do
      Repo.query!(
        """
        INSERT INTO product_event_property_keys (org_id, project_id, event_name, property_key)
        VALUES ($1,$2,'paywall_viewed','source'), ($1,$2,'paywall_viewed','variant')
        """,
        [org.id, project.id]
      )

      _ = source

      assert Queries.property_keys(scope, "paywall_viewed") == ["source", "variant"]
      assert Queries.property_keys(scope, "other_event") == []
    end
  end

  describe "delete_project_data/1" do
    test "removes every event and registry row for the project", %{
      source: source,
      scope: scope,
      org: org,
      project: project
    } do
      event(source, "meal_logged", "a", minutes_ago(5))

      Repo.query!(
        "INSERT INTO product_event_property_keys (org_id, project_id, event_name, property_key) VALUES ($1,$2,'meal_logged','source')",
        [org.id, project.id]
      )

      assert Queries.delete_project_data(scope) == 1
      assert %{events: 0} = Queries.totals(scope, Queries.range("24h", @now))
      assert Queries.property_keys(scope, "meal_logged") == []
    end
  end
end
