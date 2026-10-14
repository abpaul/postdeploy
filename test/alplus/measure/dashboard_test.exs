defmodule Alplus.Measure.DashboardTest.SilentCoverageAdapter do
  @moduledoc """
  An Analytics Engine sink that answers reads but never states how far back
  it retains, the way a third-party adapter that skips the optional callback
  would.
  """

  @behaviour Alplus.Measure.AnalyticsEngine

  alias Alplus.Measure.AnalyticsEngine.DevAdapter

  @impl true
  def write(points), do: DevAdapter.write(points)

  @impl true
  def recent(source_id, since), do: DevAdapter.recent(source_id, since)

  @impl true
  def recent_many(source_ids, since), do: DevAdapter.recent_many(source_ids, since)
end

defmodule Alplus.Measure.DashboardTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Measure.{AnalyticsEngine, Dashboard, Rollups}
  alias Alplus.Measure.DashboardTest.SilentCoverageAdapter
  alias Alplus.Scope

  setup do
    :ok = AnalyticsEngine.Batcher.flush()
    :ok = AnalyticsEngine.DevAdapter.clear()

    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)

    {site_a, _token} =
      source_fixture(owner_scope, org, project, %{
        type: :measure,
        environment: "production",
        name: "Site A"
      })

    {site_b, _token} =
      source_fixture(owner_scope, org, project, %{
        type: :measure,
        environment: "production",
        name: "Site B"
      })

    scope = Scope.put_project(owner_scope, project.id)
    connected_at = DateTime.add(DateTime.utc_now(), -400 * 24 * 3_600, :second)

    %{
      org: org,
      project: project,
      site_a: %{site_a | inserted_at: connected_at},
      site_b: %{site_b | inserted_at: connected_at},
      scope: scope
    }
  end

  defp record_pageview!(org, project, source, environment, path, now) do
    Rollups.record!(
      %{id: project.id, org_id: org.id},
      source.id,
      environment,
      %{type: "pageview", path: path, hostname: "example.com"},
      %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 0},
      now
    )
  end

  # `Rollups.record!/6` only writes the day bucket and dimensions — the hour
  # bucket is written by `Alplus.Measure.Ingest.upsert!/4` on the live
  # ingest path, so the Postgres-hour-fallback tests insert it directly
  # (same pattern as `Alplus.Measure.RetentionTest`).
  defp insert_hour!(org, project, source, pageviews, hour, environment \\ "production") do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_hours
        (id, org_id, project_id, source_id, environment, hour, pageviews, visitors, visits, bounces,
         duration_seconds, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $7, 0, 0, now(), now())
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        org.id,
        project.id,
        source.id,
        environment,
        hour,
        pageviews
      ]
    )
  end

  defp insert_legacy_dimension!(org, project, source, date, dimension, value, visitors) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_dimensions
        (id, org_id, project_id, source_id, environment, date, dimension, value,
         visitors, pageviews, visits, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, $6, $7, $8, $8, NULL, now(), now())
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        org.id,
        project.id,
        source.id,
        date,
        dimension,
        value,
        visitors
      ]
    )
  end

  defp record_analytics_engine!(org, project, source, pageviews, hour) do
    :ok =
      AnalyticsEngine.record(%{
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        hour: hour,
        pageviews: pageviews,
        visitors: pageviews,
        visits: pageviews,
        bounces: 0,
        duration_seconds: 0
      })

    :ok = AnalyticsEngine.Batcher.flush()
  end

  defp drain_reads(collected \\ []) do
    receive do
      {:read, query} -> drain_reads([query | collected])
    after
      0 -> collected
    end
  end

  describe "comparison/4" do
    test "the previous series sits on the same relative bucket, and quiet coverage becomes zero",
         %{
           org: org,
           project: project,
           site_a: site,
           scope: scope
         } do
      now = ~U[2026-08-21 12:00:00Z]
      project_ref = %{id: project.id, org_id: org.id}

      Rollups.record!(
        project_ref,
        site.id,
        "production",
        %{type: "pageview", path: "/now", hostname: "example.com"},
        %{pageviews: 12, visitors: 6, visits: 6, bounces: 0, duration_seconds: 60},
        ~U[2026-08-20 09:00:00Z]
      )

      Rollups.record!(
        project_ref,
        site.id,
        "production",
        %{type: "pageview", path: "/then", hostname: "example.com"},
        %{pageviews: 6, visitors: 3, visits: 3, bounces: 0, duration_seconds: 30},
        ~U[2026-07-12 09:00:00Z]
      )

      series = Dashboard.comparison(site, "30d", scope, now: now)

      refute series.unavailable?
      assert series.previous_available?
      assert length(series.slots) == 30

      # The headline totals come from the same read as the plotted slots.
      assert series.headlines.pageviews == %{value: 12, previous: 6, change: 100.0}

      assert Enum.map(series.slots, & &1.bucket) ==
               Enum.map(0..29, &Date.add(~D[2026-07-23], &1))

      # Every slot compares the same relative position in the two periods.
      assert Enum.all?(series.slots, &(Date.diff(&1.bucket, &1.previous_bucket) == 30))

      current_slot = Enum.at(series.slots, 28)
      previous_slot = Enum.at(series.slots, 19)

      assert current_slot.bucket == ~D[2026-08-20]
      assert current_slot.current.pageviews == 12
      assert current_slot.previous.pageviews == 0

      assert previous_slot.previous_bucket == ~D[2026-07-12]
      assert previous_slot.previous.pageviews == 6
      assert previous_slot.current.pageviews == 0

      assert Enum.count(series.slots, &(&1.current.pageviews == 0)) == 29
      assert Enum.count(series.slots, &(&1.previous.pageviews == 0)) == 29
    end

    test "hourly windows align the same hour of the day one window back", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:34:56Z]

      insert_hour!(org, project, site, 4, ~U[2026-08-21 11:00:00Z])
      insert_hour!(org, project, site, 2, ~U[2026-08-20 11:00:00Z])

      series = Dashboard.comparison(site, "24h", scope, now: now)

      assert length(series.slots) == 24
      assert Enum.at(series.slots, 21).current.pageviews == 0
      slot = Enum.at(series.slots, 22)

      assert slot.bucket == ~U[2026-08-21 11:00:00Z]
      assert slot.previous_bucket == ~U[2026-08-20 11:00:00Z]
      assert slot.current.pageviews == 4
      assert slot.previous.pageviews == 2
    end

    test "a durable period that recorded nothing is a measured zero, not an absence", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]

      Rollups.record!(
        %{id: project.id, org_id: org.id},
        site.id,
        "production",
        %{type: "pageview", path: "/", hostname: "example.com"},
        %{pageviews: 9, visitors: 9, visits: 9, bounces: 0, duration_seconds: 90},
        ~U[2026-08-20 09:00:00Z]
      )

      series = Dashboard.comparison(site, "30d", scope, now: now)

      # Rollups are complete inside retention, so "nobody visited" is a real
      # reading of zero and stays distinguishable from an unavailable period.
      assert series.previous_available?
      assert series.headlines.pageviews.previous == 0
      assert series.headlines.pageviews.change == nil
    end

    test "an Analytics Engine window without a durable read withholds the earlier period",
         %{org: org, project: project, site_a: site, scope: scope} do
      now = ~U[2026-08-21 12:00:00Z]
      record_analytics_engine!(org, project, site, 5, ~U[2026-08-21 10:00:00Z])
      Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

      # The engine's own boundary is inside the current period, and the failed
      # durable read cannot establish coverage for the earlier period.
      assert AnalyticsEngine.coverage_since() == {:ok, ~U[2026-08-21 10:00:00Z]}

      series = Dashboard.comparison(site, "24h", scope, now: now)

      refute series.previous_available?
      assert Enum.all?(series.slots, &is_nil(&1.previous))
      assert series.headlines.pageviews.value == nil
      assert series.headlines.pageviews.known_value == 5
      assert series.headlines.pageviews.coverage == :partial
      assert series.headlines.pageviews.previous == nil
      assert series.headlines.pageviews.change == nil
    end

    test "a successful empty durable read covers earlier buckets beyond the Analytics Engine boundary",
         %{org: org, project: project, site_a: site, scope: scope} do
      now = ~U[2026-08-21 12:00:00Z]
      record_analytics_engine!(org, project, site, 5, ~U[2026-08-21 10:00:00Z])

      # The durable query returns no rows, but its successful full-range read
      # proves every retained earlier bucket was measured.
      assert AnalyticsEngine.coverage_since() == {:ok, ~U[2026-08-21 10:00:00Z]}

      series = Dashboard.comparison(site, "24h", scope, now: now)

      assert series.previous_available?
      assert Enum.all?(series.slots, &(&1.previous.pageviews == 0))
      assert series.headlines.pageviews == %{value: 5, previous: 0, change: nil}
    end

    test "coverage comes from the sink's declared boundary, never from returned rows", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]

      # Written before the read's own lower bound, so this point is never
      # returned by the query. It only moves the sink's declared boundary back
      # past the first bucket of the previous 24 hours.
      record_analytics_engine!(org, project, site, 7, ~U[2026-08-18 00:00:00Z])
      record_analytics_engine!(org, project, site, 5, ~U[2026-08-21 10:00:00Z])

      assert AnalyticsEngine.coverage_since() == {:ok, ~U[2026-08-18 00:00:00Z]}

      series = Dashboard.comparison(site, "24h", scope, now: now)

      # Not one row came back for the previous 24 hours, yet the sink vouches
      # for the whole of it, so "nobody visited" is a measured zero.
      assert series.previous_available?
      assert Enum.all?(series.slots, &(&1.previous.pageviews == 0))
      assert series.headlines.pageviews.previous == 0
      assert series.headlines.pageviews.change == nil
    end

    test "an unknown Analytics Engine boundary withholds the earlier period after a durable failure",
         %{org: org, project: project, site_a: site, scope: scope} do
      now = ~U[2026-08-21 12:00:00Z]
      record_analytics_engine!(org, project, site, 7, ~U[2026-08-18 00:00:00Z])
      record_analytics_engine!(org, project, site, 5, ~U[2026-08-21 10:00:00Z])

      previous_adapter = Application.fetch_env!(:alplus, :analytics_engine_adapter)
      Application.put_env(:alplus, :analytics_engine_adapter, SilentCoverageAdapter)
      on_exit(fn -> Application.put_env(:alplus, :analytics_engine_adapter, previous_adapter) end)
      Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

      assert AnalyticsEngine.coverage_since() == :unknown

      series = Dashboard.comparison(site, "24h", scope, now: now)

      # The durable failure leaves the unknown engine boundary as the only
      # coverage evidence, so the earlier period is refused.
      assert series.headlines.pageviews.value == nil
      assert series.headlines.pageviews.known_value == 5
      assert series.headlines.pageviews.coverage == :partial
      refute series.previous_available?
      assert series.headlines.pageviews.previous == nil
    end

    test "an Analytics Engine window reaching the first earlier bucket is compared", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]
      record_analytics_engine!(org, project, site, 5, ~U[2026-08-21 10:00:00Z])
      record_analytics_engine!(org, project, site, 4, ~U[2026-08-19 13:00:00Z])

      series = Dashboard.comparison(site, "24h", scope, now: now)

      assert series.previous_available?
      assert series.headlines.pageviews == %{value: 5, previous: 4, change: 25.0}
      assert Enum.at(series.slots, 0).previous.pageviews == 4
    end

    test "the headline and the aligned series share one rollup read", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      insert_hour!(org, project, site, 3, DateTime.utc_now() |> DateTime.truncate(:second))

      handler = "measure-comparison-read-count-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:alplus, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:read, metadata.query})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Dashboard.comparison(site, "24h", scope)

      hour_reads = Enum.count(drain_reads(), &String.contains?(&1, "analytics_hours"))

      assert hour_reads == 1
    end

    test "pre-connection hours remain gaps while later quiet hours are measured zeros", %{
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]
      site = %{site | inserted_at: ~U[2026-08-21 10:30:00Z]}

      series = Dashboard.comparison(site, "24h", scope, now: now)

      refute series.previous_available?
      assert Enum.at(series.slots, 21).bucket == ~U[2026-08-21 10:00:00Z]
      assert Enum.at(series.slots, 21).current == nil
      assert Enum.at(series.slots, 22).current.pageviews == 0
      assert Enum.at(series.slots, 23).current.pageviews == 0
    end

    test "seven-day comparison draws seven calendar days by summing the hours of each", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]
      insert_hour!(org, project, site, 2, ~U[2026-08-21 07:00:00Z])
      insert_hour!(org, project, site, 3, ~U[2026-08-21 08:00:00Z])

      series = Dashboard.comparison(site, "7d", scope, now: now)
      slot = List.last(series.slots)

      assert length(series.slots) == 7
      assert Enum.map(series.slots, & &1.bucket) == Enum.map(0..6, &Date.add(~D[2026-08-15], &1))
      assert Enum.all?(series.slots, &(Date.diff(&1.bucket, &1.previous_bucket) == 7))
      assert slot.bucket == ~D[2026-08-21]
      assert slot.current.in_progress?
      assert slot.current.pageviews == 5
      assert slot.current.visits == 5
      assert slot.current.bounce_rate == 0.0
      assert slot.current.avg_duration == 0.0
    end

    test "a day that holds a reading is measured, whatever the site record's own timestamp says",
         %{
           org: org,
           project: project,
           site_a: site,
           scope: scope
         } do
      today = Date.utc_today()
      now = DateTime.new!(today, ~T[12:00:00], "Etc/UTC")

      # Backfilled history: one reading a day, all of it older than the site
      # record that carries it.
      site = %{site | inserted_at: DateTime.new!(Date.add(today, -2), ~T[17:00:00], "Etc/UTC")}

      readings = [
        {Date.add(today, -6), 38},
        {Date.add(today, -5), 45},
        {Date.add(today, -4), 52},
        {Date.add(today, -3), 61}
      ]

      for {day, pageviews} <- readings do
        insert_hour!(org, project, site, pageviews, DateTime.new!(day, ~T[09:00:00], "Etc/UTC"))
      end

      series = Dashboard.comparison(site, "7d", scope, now: now)
      by_day = Map.new(series.slots, &{&1.bucket, &1.current})

      for {day, pageviews} <- readings do
        assert by_day[day].coverage == :full
        assert by_day[day].pageviews == pageviews
      end

      # A quiet day after the site connected stays a measured zero.
      assert by_day[Date.add(today, -1)].coverage == :full
      assert by_day[Date.add(today, -1)].pageviews == 0

      # The screen's own total then reads as a whole number, not a lower bound.
      portfolio = Dashboard.portfolio([site], "7d", scope)

      assert portfolio.totals.pageviews.coverage == :full
      assert portfolio.totals.pageviews.value == 196
    end
  end

  describe "totals/3 and trend/3 (PostgreSQL fallback, 30d/90d always use it)" do
    test "headline metrics compare equal periods and average duration across engaged visits", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]
      project_ref = %{id: project.id, org_id: org.id}

      Rollups.record!(
        project_ref,
        site.id,
        "production",
        %{type: "pageview", path: "/current", hostname: "example.com"},
        %{pageviews: 20, visitors: 10, visits: 10, bounces: 4, duration_seconds: 600},
        now
      )

      Rollups.record!(
        project_ref,
        site.id,
        "production",
        %{type: "pageview", path: "/prior", hostname: "example.com"},
        %{pageviews: 10, visitors: 5, visits: 5, bounces: 0, duration_seconds: 250},
        DateTime.add(now, -30, :day)
      )

      headlines = Dashboard.headlines(site, "30d", scope, now: now)

      assert headlines.visits == %{value: 10, previous: 5, change: 100.0}
      assert headlines.visitors == %{value: 10, previous: 5, change: 100.0}
      assert headlines.pageviews == %{value: 20, previous: 10, change: 100.0}
      assert headlines.bounce_rate == %{value: 40.0, previous: 0.0, change: 40.0}
      assert headlines.avg_duration == %{value: 100.0, previous: 50.0, change: 100.0}
    end

    test "average duration has no value when every visit bounced", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]

      Rollups.record!(
        %{id: project.id, org_id: org.id},
        site.id,
        "production",
        %{type: "pageview", path: "/", hostname: "example.com"},
        %{pageviews: 3, visitors: 3, visits: 3, bounces: 3, duration_seconds: 0},
        now
      )

      assert Dashboard.headlines(site, "30d", scope, now: now).avg_duration.value == nil
    end

    test "one site's traffic never appears in a sibling site sharing the same project and environment",
         %{org: org, project: project, site_a: site_a, site_b: site_b, scope: scope} do
      now = DateTime.utc_now()

      record_pageview!(org, project, site_a, "production", "/a", now)
      record_pageview!(org, project, site_a, "production", "/a-2", now)
      record_pageview!(org, project, site_b, "production", "/b", now)

      {totals_a, "PostgreSQL rollups", false} = Dashboard.totals(site_a, "30d", scope)
      {totals_b, "PostgreSQL rollups", false} = Dashboard.totals(site_b, "30d", scope)

      assert totals_a.pageviews == 2
      assert totals_b.pageviews == 1

      trend_a = Dashboard.trend(site_a, "30d", scope)
      trend_b = Dashboard.trend(site_b, "30d", scope)

      assert Enum.sum(Enum.map(trend_a, & &1.pageviews)) == 2
      assert Enum.sum(Enum.map(trend_b, & &1.pageviews)) == 1
    end

    test "the 30d chart contains exactly thirty UTC day buckets", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      today = Date.utc_today()

      for offset <- [0, 29, 30] do
        record_pageview!(
          org,
          project,
          site,
          "production",
          "/day-#{offset}",
          DateTime.new!(Date.add(today, -offset), ~T[12:00:00], "Etc/UTC")
        )
      end

      {totals, "PostgreSQL rollups", false} = Dashboard.totals(site, "30d", scope)
      assert totals.pageviews == 2
      assert Enum.map(Dashboard.trend(site, "30d", scope), & &1.pageviews) == [1, 1]
    end

    test "the fallback hourly read (24h/7d with AE unconfigured) is also per site", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      previous = Application.fetch_env!(:alplus, :analytics_engine_adapter)
      Application.put_env(:alplus, :analytics_engine_adapter, AnalyticsEngine.UnavailableAdapter)
      on_exit(fn -> Application.put_env(:alplus, :analytics_engine_adapter, previous) end)

      hour = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_hour!(org, project, site_a, 1, hour)
      insert_hour!(org, project, site_b, 2, hour)

      {totals_a, "PostgreSQL rollups", false} = Dashboard.totals(site_a, "24h", scope)
      {totals_b, "PostgreSQL rollups", false} = Dashboard.totals(site_b, "24h", scope)

      assert totals_a.pageviews == 1
      assert totals_b.pageviews == 2

      summaries = Dashboard.summaries([site_a, site_b], "24h", scope)
      assert summaries[site_a.id].fallback?
      assert summaries[site_a.id].analytics_engine_unavailable?
      refute summaries[site_a.id].unavailable?
    end

    test "an engine that answers with no points falls back to the durable hour rollups", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      # The dev adapter is an in-memory store that empties on every boot,
      # so it can truthfully answer {:ok, []} while durable traffic exists
      # in analytics_hours. That must read as "no live signal", never as
      # "no traffic" (the bug behind a demo workspace showing "Waiting for
      # the first pageview" over 47 hours of seeded rollups).
      hour = DateTime.utc_now() |> DateTime.truncate(:second)
      insert_hour!(org, project, site_a, 3, hour)

      {totals, "PostgreSQL rollups", false} = Dashboard.totals(site_a, "24h", scope)
      assert totals.pageviews == 3

      summaries = Dashboard.summaries([site_a, site_b], "24h", scope)
      assert summaries[site_a.id].totals.pageviews == 3
      assert summaries[site_a.id].data_source == "PostgreSQL rollups"
      assert summaries[site_a.id].fallback?
      refute summaries[site_a.id].analytics_engine_unavailable?
      assert summaries[site_a.id].analytics_engine_state == :empty
    end

    test "partial engine coverage merges durable buckets and exposes partial state", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      :ok =
        AnalyticsEngine.record(%{
          org_id: org.id,
          project_id: project.id,
          source_id: site.id,
          hour: now,
          pageviews: 2,
          visitors: 2,
          visits: 2,
          bounces: 0,
          duration_seconds: 0
        })

      :ok = AnalyticsEngine.Batcher.flush()
      insert_hour!(org, project, site, 3, DateTime.add(now, -3600, :second))

      summary = Dashboard.summaries([site], "24h", scope)[site.id]

      {totals, "Analytics Engine and PostgreSQL rollups", false} =
        Dashboard.totals(site, "24h", scope)

      assert summary.analytics_engine_state == :partial
      assert summary.analytics_engine_partial?
      assert summary.data_source == "Analytics Engine and PostgreSQL rollups"
      assert Enum.sum(Enum.map(summary.trend, & &1.pageviews)) == 5
      assert totals.pageviews == 5
      refute Map.has_key?(totals, :coverage)
    end
  end

  describe "totals/3 and trend/3 (Analytics Engine, 24h/7d)" do
    test "public headlines and charts use the same live source when durable values conflict", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_hour!(org, project, site, 9, now)

      :ok =
        AnalyticsEngine.record(%{
          org_id: org.id,
          project_id: project.id,
          source_id: site.id,
          hour: now,
          pageviews: 3,
          visitors: 2,
          visits: 2,
          bounces: 0,
          duration_seconds: 0
        })

      :ok = AnalyticsEngine.Batcher.flush()

      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site.id,
        environment: site.environment
      }

      headlines = Dashboard.headlines(site, "24h", actor, now: now)
      chart = Dashboard.trend_with_metadata(site, "24h", actor)
      authenticated = Dashboard.headlines(site, "24h", scope, now: now)

      assert headlines.pageviews.value == 3
      assert headlines.data_source == authenticated.data_source
      assert headlines.data_source_key == authenticated.data_source_key
      assert headlines.partial? == authenticated.partial?
      assert headlines.pageviews.previous == authenticated.pageviews.previous
      assert chart.data_source == "Analytics Engine"
      assert Enum.sum(Enum.map(chart.trend, & &1.pageviews)) == 3

      {totals, "Analytics Engine", false} = Dashboard.totals(site, "24h", scope)

      assert authenticated.pageviews.value == 3
      assert authenticated.data_source == "Analytics Engine"
      assert totals.pageviews == 3
    end

    test "private and public reads keep valid empty telemetry distinct from an outage", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site.id,
        environment: site.environment
      }

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      private = Dashboard.headlines(site, "24h", scope, now: now)
      public = Dashboard.headlines(site, "24h", actor, now: now)

      assert private.data_source == "PostgreSQL rollups"
      assert private.data_source == public.data_source
      assert private.data_source_key == public.data_source_key
      refute private.unavailable?
      refute public.unavailable?
      assert private.pageviews.value == 0
      assert public.pageviews.value == 0
    end

    test "private and public reads use PostgreSQL after an Analytics Engine failure", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      previous = Application.fetch_env!(:alplus, :analytics_engine_adapter)
      Application.put_env(:alplus, :analytics_engine_adapter, AnalyticsEngine.UnavailableAdapter)
      on_exit(fn -> Application.put_env(:alplus, :analytics_engine_adapter, previous) end)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      insert_hour!(org, project, site, 4, now)

      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site.id,
        environment: site.environment
      }

      private = Dashboard.headlines(site, "24h", scope, now: now)
      public = Dashboard.headlines(site, "24h", actor, now: now)

      assert private.data_source == "PostgreSQL rollups"
      assert private.data_source == public.data_source
      assert private.data_source_key == public.data_source_key
      assert private.pageviews.value == 4
      assert public.pageviews.value == 4
    end

    test "private and public reads return unavailable when neither adapter answers", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      previous = Application.fetch_env!(:alplus, :analytics_engine_adapter)
      Application.put_env(:alplus, :analytics_engine_adapter, AnalyticsEngine.UnavailableAdapter)
      on_exit(fn -> Application.put_env(:alplus, :analytics_engine_adapter, previous) end)

      Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site.id,
        environment: site.environment
      }

      private = Dashboard.headlines(site, "24h", scope)
      public = Dashboard.headlines(site, "24h", actor)

      assert private.unavailable?
      assert public.unavailable?
      assert private.data_source_key == :unavailable
      assert public.data_source_key == :unavailable
    end

    test "private and public reads keep covered empty engine data valid after PostgreSQL fails",
         %{
           org: org,
           project: project,
           site_a: site_a,
           site_b: site_b,
           scope: scope
         } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      coverage_hour = DateTime.add(now, -48 * 3_600, :second)
      record_analytics_engine!(org, project, site_b, 1, coverage_hour)
      assert {:ok, ^coverage_hour} = AnalyticsEngine.coverage_since()
      Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site_a.id,
        environment: site_a.environment
      }

      private = Dashboard.headlines(site_a, "24h", scope, now: now)
      public = Dashboard.headlines(site_a, "24h", actor, now: now)

      assert private.data_source == "Analytics Engine"
      assert private.data_source == public.data_source
      assert private.data_source_key == public.data_source_key
      refute private.unavailable?
      refute public.unavailable?
      refute private.partial?
      refute public.partial?
      assert private.pageviews.value == 0
      assert private.pageviews.previous == 0
      assert public.pageviews.value == 0
      assert public.pageviews.previous == 0
    end

    test "private and public reads preserve an incomplete current engine window", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_analytics_engine!(org, project, site, 3, now)
      Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site.id,
        environment: site.environment
      }

      private = Dashboard.headlines(site, "24h", scope, now: now)
      public = Dashboard.headlines(site, "24h", actor, now: now)
      private_chart = Dashboard.comparison(site, "24h", scope, now: now)
      public_chart = Dashboard.trend_with_metadata(site, "24h", actor)
      {totals, "Analytics Engine", false} = Dashboard.totals(site, "24h", scope)

      assert private.data_source == "Analytics Engine (partial coverage)"
      assert private.data_source == public.data_source
      assert private.data_source_key == public.data_source_key
      assert private.partial?
      assert public.partial?
      refute private.unavailable?
      refute public.unavailable?
      assert private.pageviews.value == nil
      assert private.pageviews.coverage == :partial
      assert private.pageviews.known_value == 3
      assert private.pageviews.previous == nil
      assert public.pageviews.value == nil
      assert public.pageviews.coverage == :partial
      assert public.pageviews.known_value == 3
      assert public.pageviews.previous == nil
      assert private_chart.headlines.pageviews.value == nil
      assert private_chart.headlines.pageviews.known_value == 3
      assert public_chart.data_source == "Analytics Engine (partial coverage)"
      assert public_chart.partial?
      assert totals.pageviews == nil
      assert totals.known_pageviews == 3
      assert totals.coverage == :partial
    end

    test "complete current engine coverage keeps totals exact when comparison coverage is unavailable",
         %{
           org: org,
           project: project,
           site_a: site,
           scope: scope
         } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_analytics_engine!(org, project, site, 0, DateTime.add(now, -24 * 3_600, :second))
      record_analytics_engine!(org, project, site, 3, now)
      Alplus.Repo.query!("ALTER TABLE analytics_hours RENAME TO analytics_hours_unavailable")

      headlines = Dashboard.headlines(site, "24h", scope, now: now)
      {totals, "Analytics Engine", false} = Dashboard.totals(site, "24h", scope)

      assert headlines.data_source == "Analytics Engine (prior comparison unavailable)"
      assert headlines.partial?
      assert headlines.pageviews.value == 3
      assert headlines.pageviews.previous == nil
      assert totals.pageviews == 3
      refute Map.has_key?(totals, :coverage)
    end

    test "the real-time path never mixes two sites even when they share an environment", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      hour = DateTime.utc_now() |> DateTime.truncate(:second)

      :ok =
        AnalyticsEngine.record(%{
          org_id: org.id,
          project_id: project.id,
          source_id: site_a.id,
          hour: hour,
          pageviews: 3,
          visitors: 2,
          visits: 2,
          bounces: 1,
          duration_seconds: 0
        })

      :ok =
        AnalyticsEngine.record(%{
          org_id: org.id,
          project_id: project.id,
          source_id: site_b.id,
          hour: hour,
          pageviews: 5,
          visitors: 4,
          visits: 4,
          bounces: 0,
          duration_seconds: 0
        })

      :ok = AnalyticsEngine.Batcher.flush()

      {totals_a, "Analytics Engine", false} = Dashboard.totals(site_a, "24h", scope)
      {totals_b, "Analytics Engine", false} = Dashboard.totals(site_b, "24h", scope)

      assert totals_a.pageviews == 3
      assert totals_b.pageviews == 5

      trend_a = Dashboard.trend(site_a, "24h", scope)
      assert [%{pageviews: 3, visitors: 2}] = trend_a
    end

    test "a public actor reads only its shared source from Analytics Engine", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_analytics_engine!(org, project, site_b, 7, now)

      actor = %Alplus.Measure.ShareActor{
        share_id: Ecto.UUID.generate(),
        org_id: org.id,
        project_id: project.id,
        source_id: site_a.id,
        environment: site_a.environment
      }

      chart = Dashboard.trend_with_metadata(site_b, "24h", actor)

      assert chart.trend == []
      assert chart.data_source == "PostgreSQL rollups"
      refute chart.unavailable?
    end
  end

  describe "durable read failures" do
    test "a database outage becomes the unavailable state", %{site_a: site, scope: scope} do
      Alplus.Repo.query!("ALTER TABLE analytics_days RENAME TO analytics_days_unavailable")

      series = Dashboard.comparison(site, "30d", scope)

      assert series.unavailable?
      assert series.slots == []
      assert series.headlines.pageviews.value == nil
    end

    test "a non-database Ash.Error.Unknown keeps raising", %{site_a: site, scope: scope} do
      # A malformed actor breaks the query inside the read pipeline. Ash wraps
      # that as the same Ash.Error.Unknown a real outage arrives in, but the
      # cause is a bug in the caller, and reporting it as "temporarily
      # unavailable" would hide it behind a retry button forever.
      assert_raise Ash.Error.Unknown, fn ->
        Dashboard.comparison(site, "30d", %{scope | user_id: :not_a_user_id})
      end
    end

    # Ash flattens the cause of a data-layer failure to text before the rescue
    # sees it, so the classification these reads depend on is pinned directly:
    # only a confirmed database cause may be downgraded.
    test "only confirmed database causes are classified as unavailable" do
      wrapped = fn cause ->
        %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{error: cause}]}
      end

      assert Dashboard.database_unavailable_error?(%DBConnection.ConnectionError{message: "x"})
      assert Dashboard.database_unavailable_error?(%Ash.Error.Invalid.Unavailable{})

      assert Dashboard.database_unavailable_error?(
               wrapped.("** (Postgrex.Error) ERROR 57P01 (admin_shutdown)")
             )

      assert Dashboard.database_unavailable_error?(
               wrapped.("** (DBConnection.ConnectionError) connection not available")
             )

      # A bug inside the read pipeline arrives as the same Ash.Error.Unknown
      # and must not be downgraded.
      refute Dashboard.database_unavailable_error?(wrapped.("** (RuntimeError) boom"))
      refute Dashboard.database_unavailable_error?(wrapped.("** (FunctionClauseError) no clause"))
      refute Dashboard.database_unavailable_error?(%Ash.Error.Unknown{errors: []})
      refute Dashboard.database_unavailable_error?(%RuntimeError{message: "boom"})
    end
  end

  describe "legacy dimension rows" do
    test "historic nullable visits are reported as partial coverage on the panel", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      insert_legacy_dimension!(
        org,
        project,
        site,
        Date.add(Date.utc_today(), -1),
        "referrer",
        "legacy.example",
        4
      )

      assert Dashboard.panel(site, "30d", "referrer", 1, scope).partial?
    end
  end

  describe "panel/5" do
    test "reads dimension rollups once while returning metadata and rows", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      record_pageview!(org, project, site, "production", "/one", DateTime.utc_now())

      handler = "measure-panel-read-count-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:alplus, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:read, metadata.query})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      panel = Dashboard.panel(site, "30d", "path", 1, scope)
      assert [%{value: "/one", count: 1}] = panel.rows
      assert panel.distinct_values == 1

      dimension_reads =
        drain_reads()
        |> Enum.count(&String.contains?(&1, "analytics_dimensions"))

      assert dimension_reads == 1
    end

    test "pages eight ranked rows and pins the overflow bucket to the final page", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      project_ref = %{id: project.id, org_id: org.id}
      date = ~D[2026-08-21]

      for number <- 1..10 do
        Rollups.record_dimension!(
          project_ref,
          site.id,
          "production",
          date,
          "path",
          "/page-#{number}",
          %{pageviews: number, visitors: number, visits: number}
        )
      end

      Rollups.record_dimension!(
        project_ref,
        site.id,
        "production",
        date,
        "path",
        Rollups.other_value(),
        %{pageviews: 3, visitors: 3, visits: 3}
      )

      first = Dashboard.panel(site, "30d", "path", 1, scope, now: ~U[2026-08-21 12:00:00Z])
      final = Dashboard.panel(site, "30d", "path", 2, scope, now: ~U[2026-08-21 12:00:00Z])

      assert length(first.rows) == 8
      refute Enum.any?(first.rows, & &1.capped?)
      assert Enum.map(first.rows, & &1.value) == Enum.map(10..3//-1, &"/page-#{&1}")

      assert Enum.map(final.rows, & &1.value) == ["/page-2", "/page-1", "(other)"]
      assert List.last(final.rows).label == "(other) (per-day cardinality cap)"
      assert final.total_pages == 2
      assert final.distinct_values == 11
      assert final.capped?

      assert final.cap_metadata == %{
               value: "(other)",
               reason: "per-day cardinality cap",
               position: :last
             }
    end

    test "a full named page can leave the overflow bucket on its own page", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      for value <- [Rollups.other_value() | Enum.map(1..8, &"/tie-#{&1}")] do
        Rollups.record_dimension!(
          %{id: project.id, org_id: org.id},
          site.id,
          "production",
          Date.utc_today(),
          "path",
          value,
          %{pageviews: 1, visitors: 1, visits: 1}
        )
      end

      first = Dashboard.panel(site, "30d", "path", 1, scope)
      assert Enum.map(first.rows, & &1.value) == Enum.map(1..8, &"/tie-#{&1}")
      final = Dashboard.panel(site, "30d", "path", 999, scope)
      assert final.page == 2
      assert [%{value: "(other)", count: 1, capped?: true}] = final.rows
    end

    test "panel reads keep source, project, organization, environment, and membership boundaries",
         %{org: org, project: project, site_a: site, site_b: other_site, scope: scope} do
      record_pageview!(org, project, site, "production", "/own", DateTime.utc_now())
      record_pageview!(org, project, other_site, "production", "/other", DateTime.utc_now())
      outsider = scope_fixture()
      {other_org, _} = org_fixture(outsider)
      sibling = project_fixture(scope, org)
      assert [%{value: "/own"}] = Dashboard.panel(site, "30d", "path", 1, scope).rows

      for denied <- [
            %{scope | org_id: other_org.id},
            %{scope | project_id: sibling.id},
            %{scope | user_id: outsider.user_id}
          ] do
        result = Dashboard.panel(site, "30d", "path", 1, denied)
        assert result.rows == []
        assert result.distinct_values == 0
      end

      assert Dashboard.panel(%{site | environment: "staging"}, "30d", "path", 1, scope).rows == []
    end

    test "caps a requested page at the computed final page", %{site_a: site, scope: scope} do
      assert Dashboard.panel(site, "30d", "path", 999, scope).page == 1
    end

    test "bounds rollups to the requested window and exposes cap metadata", %{
      org: org,
      project: project,
      site_a: site,
      scope: scope
    } do
      insert_hour!(org, project, site, 3, DateTime.add(DateTime.utc_now(), 2, :hour))
      assert Dashboard.summaries([site], "24h", scope)[site.id].totals.pageviews == 0

      result = Dashboard.panel(site, "30d", "path", 999, scope)
      assert result.page == 1
      assert result.cap_metadata == nil
    end
  end

  describe "summaries/3 (batched card-grid read)" do
    test "batches every site's totals and trend in one call without cross-contamination", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      now = DateTime.utc_now()

      record_pageview!(org, project, site_a, "production", "/a", now)
      record_pageview!(org, project, site_b, "production", "/b", now)
      record_pageview!(org, project, site_b, "production", "/b-2", now)

      summaries = Dashboard.summaries([site_a, site_b], "30d", scope)

      assert summaries[site_a.id].totals.pageviews == 1
      assert summaries[site_b.id].totals.pageviews == 2
      assert summaries[site_a.id].unavailable? == false
      assert summaries[site_b.id].unavailable? == false
    end

    test "a site with no traffic gets an honest zeroed summary, not an error", %{
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      summaries = Dashboard.summaries([site_a, site_b], "7d", scope)

      assert summaries[site_a.id].totals.pageviews == 0
      assert summaries[site_a.id].trend == []
    end

    test "summaries ignore rollups attributed to a different source environment", %{
      org: org,
      project: project,
      site_a: site_a,
      scope: scope
    } do
      insert_hour!(
        org,
        project,
        site_a,
        9,
        DateTime.utc_now() |> DateTime.truncate(:second),
        "preview"
      )

      summary = Dashboard.summaries([site_a], "24h", scope)[site_a.id]

      assert summary.totals.pageviews == 0
      assert summary.state == :waiting
      refute summary.evidence?
    end
  end

  describe "portfolio/4" do
    test "batches source-isolated deltas and materializes the visible quiet-day baseline", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]

      Alplus.Repo.query!(
        "UPDATE organizations SET plan_status = 'active', plan_id = 'postdeploy' WHERE id = $1",
        [org.id]
      )

      record_pageview!(org, project, site_a, "production", "/a-now", ~U[2026-08-20 09:00:00Z])
      record_pageview!(org, project, site_a, "production", "/a-now-2", ~U[2026-08-20 09:00:00Z])
      record_pageview!(org, project, site_a, "production", "/a-then", ~U[2026-07-12 09:00:00Z])
      record_pageview!(org, project, site_b, "production", "/b-now", ~U[2026-08-20 09:00:00Z])

      handler = "measure-portfolio-read-count-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:alplus, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:read, metadata.query})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      portfolio = Dashboard.portfolio([site_a, site_b], "30d", scope, now: now)

      day_reads =
        drain_reads()
        |> Enum.filter(&String.contains?(&1, "analytics_days"))

      {evidence_reads, period_reads} =
        Enum.split_with(day_reads, &String.contains?(&1, "MIN(date) AS first_pageview_on"))

      # The period totals remain one batched read. Evidence is one separate
      # grouped query, also independent of the number of sites.
      assert length(period_reads) == 1
      assert length(evidence_reads) == 1
      refute portfolio.unavailable?
      refute portfolio.partial?

      assert portfolio.totals.pageviews == %{
               value: 3,
               previous: 1,
               change: 200.0,
               known_value: 3,
               coverage: :full
             }

      assert portfolio.totals.visits == %{
               value: 3,
               previous: 1,
               change: 200.0,
               known_value: 3,
               coverage: :full
             }

      assert portfolio.totals.active_sites == 2
      assert portfolio.totals.connected_sites == 2
      assert portfolio.evidence?
      assert portfolio.sites[site_a.id].evidence?
      assert portfolio.sites[site_a.id].pageviews == 2
      assert portfolio.sites[site_a.id].pageviews_previous == 1
      assert portfolio.sites[site_a.id].pageviews_delta == 1
      assert portfolio.sites[site_a.id].pageviews_change == 100.0
      assert portfolio.sites[site_b.id].pageviews == 1
      assert portfolio.sites[site_b.id].pageviews_previous == 0
      assert portfolio.sites[site_b.id].pageviews_delta == 1
      assert portfolio.sites[site_b.id].pageviews_change == nil
      assert length(portfolio.trend) == 30
      assert length(portfolio.sites[site_a.id].trend) == 30
      assert Enum.at(portfolio.trend, 0).pageviews == 0
    end

    test "partial site coverage exposes a lower bound without claiming a portfolio total", %{
      org: org,
      project: project,
      site_a: site_a,
      site_b: site_b,
      scope: scope
    } do
      now = ~U[2026-08-21 12:00:00Z]
      recently_connected = %{site_b | inserted_at: ~U[2026-08-18 12:00:00Z]}

      record_pageview!(org, project, site_a, "production", "/known", ~U[2026-08-20 09:00:00Z])

      portfolio =
        Dashboard.portfolio([site_a, recently_connected], "30d", scope, now: now)

      assert portfolio.coverage == :partial
      assert portfolio.totals.pageviews.value == nil
      assert portfolio.totals.pageviews.known_value == 1
      assert portfolio.totals.pageviews.coverage == :partial

      assert Enum.any?(portfolio.trend, fn point ->
               point.coverage == :partial and is_nil(point.pageviews) and
                 point.known_pageviews == 0
             end)
    end
  end
end
