defmodule Alplus.Observe.DashboardTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{Dashboard, EventWriter, Issue, Release}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp event(source, event_id, received_at, stack_marker) do
    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: received_at,
      received_at: received_at,
      level: "error",
      sdk_name: "@alplus/sdk",
      sdk_version: "0.3.0",
      exception_type: "TypeError",
      exception_value: "boom",
      frames: [%{file: "/src/#{stack_marker}.ts", function: "run", lineno: 1}]
    }
  end

  defp release_fixture(scope, org, project, source, attrs) do
    Ash.create!(
      Release,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment
        },
        attrs
      ),
      actor: project_scope(scope, project)
    )
  end

  defp issue_fixture(org, project, source, attrs) do
    now = DateTime.utc_now()

    params =
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Boom",
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      )

    Ash.create!(Issue, params, action: :record, authorize?: false)
  end

  describe "trend/3" do
    test "batches project trends by the supplied project and Source pairs" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project_a = project_fixture(owner_scope, org)
      project_b = project_fixture(owner_scope, org)
      {source_a, _} = source_fixture(owner_scope, org, project_a)
      {source_b, _} = source_fixture(owner_scope, org, project_b)
      now = DateTime.utc_now()

      {:ok, _} = EventWriter.record(event(source_a, "batch_trend_a", now, "a"))
      {:ok, _} = EventWriter.record(event(source_b, "batch_trend_b", now, "b"))

      trends =
        Dashboard.trends_for_projects(
          %{project_a.id => [source_a], project_b.id => [source_b]},
          "7d",
          owner_scope
        )

      today = Date.convert!(now, Calendar.ISO)
      assert Map.keys(trends) |> Enum.sort() == Enum.sort([project_a.id, project_b.id])
      assert Enum.find(trends[project_a.id], &(&1.bucket == today)).event_count == 1
      assert Enum.find(trends[project_b.id], &(&1.bucket == today)).event_count == 1
    end

    test "buckets error_events by day, gap-filled across empty days" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      now = DateTime.utc_now()
      three_days_ago = DateTime.add(now, -3 * 86_400, :second)

      {:ok, _} = EventWriter.record(event(source, "trend_evt_1", three_days_ago, "a"))
      {:ok, _} = EventWriter.record(event(source, "trend_evt_2", now, "b"))

      trend = Dashboard.trend(source.id, "7d", scope)

      # Gap-filled: the two real days plus the empty days between them, in
      # ascending order, never missing a day in the middle.
      assert length(trend) >= 4
      assert trend == Enum.sort_by(trend, & &1.bucket, Date)

      first_day = Date.convert!(three_days_ago, Calendar.ISO)
      last_day = Date.convert!(now, Calendar.ISO)

      assert Enum.find(trend, &(&1.bucket == first_day)).event_count == 1
      assert Enum.find(trend, &(&1.bucket == last_day)).event_count == 1

      # A day with no events in between still appears, with a real zero.
      middle_day = Date.add(first_day, 1)
      assert Enum.find(trend, &(&1.bucket == middle_day)).event_count == 0
    end

    test "filters per Source, never leaking a sibling Source's events" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {prod, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      {staging, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})
      now = DateTime.utc_now()

      {:ok, _} = EventWriter.record(event(prod, "env_evt_prod", now, "p"))
      {:ok, _} = EventWriter.record(event(staging, "env_evt_staging", now, "s"))

      prod_trend = Dashboard.trend(prod.id, "24h", scope)
      staging_trend = Dashboard.trend(staging.id, "24h", scope)

      # A 24-hour window is hourly: the event lands in the hour in progress.
      hour = %{now | minute: 0, second: 0, microsecond: {0, 0}}
      assert length(prod_trend) == 24
      assert Enum.find(prod_trend, &(&1.bucket == hour)).event_count == 1
      assert Enum.find(staging_trend, &(&1.bucket == hour)).event_count == 1

      # Neither trend counts the other Source's event.
      assert Enum.sum(Enum.map(prod_trend, & &1.event_count)) == 1
      assert Enum.sum(Enum.map(staging_trend, & &1.event_count)) == 1
    end

    # The exact regression the reviewer named: an active Source and a
    # revoked one sharing an environment must never share a trend, issue
    # list, or release list.
    test "a revoked Source and an active Source in one environment show separate, non-shared data" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)

      {revoked, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      Ash.update!(revoked, %{}, action: :revoke, actor: project_scope(owner_scope, project))

      {active, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      now = DateTime.utc_now()

      {:ok, %{issue_id: revoked_issue_id}} =
        EventWriter.record(event(revoked, "shared_env_evt_revoked", now, "r"))

      {:ok, %{issue_id: active_issue_id}} =
        EventWriter.record(event(active, "shared_env_evt_active", now, "a"))

      refute revoked_issue_id == active_issue_id

      summaries = Dashboard.summaries([revoked, active], "24h", scope)

      assert Map.fetch!(summaries, revoked.id).open_issues == 1
      assert Map.fetch!(summaries, active.id).open_issues == 1

      revoked_trend_total =
        summaries
        |> Map.fetch!(revoked.id)
        |> Map.fetch!(:trend)
        |> Enum.map(& &1.event_count)
        |> Enum.sum()

      active_trend_total =
        summaries
        |> Map.fetch!(active.id)
        |> Map.fetch!(:trend)
        |> Enum.map(& &1.event_count)
        |> Enum.sum()

      assert revoked_trend_total == 1
      assert active_trend_total == 1
    end

    test "Source-scoped reads remain isolated while Phase A keeps ingest identity environment-keyed" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)

      {first, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
      Ash.update!(first, %{}, action: :revoke, actor: scope)
      {second, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      now = DateTime.utc_now()

      {:ok, %{issue_id: first_issue_id}} =
        EventWriter.record(event(first, "same_fingerprint_first", now, "same"))

      {:ok, %{issue_id: second_issue_id}} =
        EventWriter.record(event(second, "same_fingerprint_second", now, "same"))

      # Phase A intentionally keeps the ingest conflict target environment-keyed.
      assert first_issue_id == second_issue_id

      first_release =
        release_fixture(owner_scope, org, project, first, %{
          version: "1.0.0",
          released_at: now
        })

      second_release =
        release_fixture(owner_scope, org, project, second, %{
          version: "2.0.0",
          released_at: now
        })

      refute first_release.id == second_release.id

      summaries = Dashboard.summaries([first, second], "24h", scope)
      assert Map.fetch!(summaries, first.id).event_count == 1
      assert Map.fetch!(summaries, second.id).event_count == 1
    end

    test "never counts a different org's or project's events with the same environment name" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      {other_org, other_owner_scope} = org_fixture(scope_fixture())
      other_project = project_fixture(other_owner_scope, other_org)

      {other_source, _} =
        source_fixture(other_owner_scope, other_org, other_project, %{environment: "production"})

      now = DateTime.utc_now()

      {:ok, _} = EventWriter.record(event(other_source, "cross_org_evt", now, "x"))

      trend = Dashboard.trend(source.id, "24h", scope)

      assert Enum.sum(Enum.map(trend, & &1.event_count)) == 0
    end

    test "respects the window boundary, excluding events older than it" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      now = DateTime.utc_now()
      old = DateTime.add(now, -10 * 86_400, :second)

      {:ok, _} = EventWriter.record(event(source, "window_evt_old", old, "o"))

      trend = Dashboard.trend(source.id, "7d", scope)

      assert Enum.sum(Enum.map(trend, & &1.event_count)) == 0
    end

    test "a Source with no events at all returns a real, gap-filled zero series" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      trend = Dashboard.trend(source.id, "7d", scope)

      # Seven calendar days ending today: exactly the count the label states.
      assert length(trend) == 7
      assert List.last(trend).bucket == Date.utc_today()
      assert Enum.all?(trend, &(&1.event_count == 0))
    end
  end

  describe "effective Observe retention" do
    test "the plan bounds a requested 90d window to thirty days" do
      {org, owner_scope} = org_fixture(scope_fixture())
      subscribed_fixture(org)
      project = project_fixture(owner_scope, org)
      {source, _} = source_fixture(owner_scope, org, project)
      expired_at = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

      {:ok, _} = EventWriter.record(event(source, "expired-boundary", expired_at, "expired"))
      {:ok, _} = EventWriter.record(event(source, "recent", DateTime.utc_now(), "recent"))

      trend = Dashboard.trend(source.id, "90d", project_scope(owner_scope, project))

      assert Enum.sum_by(trend, & &1.event_count) == 1

      summary =
        Dashboard.summaries([source], "90d", project_scope(owner_scope, project))[source.id]

      assert summary.data_state == :partial
    end

    test "the plan retains an event inside its thirty-day window" do
      {org, owner_scope} = org_fixture(scope_fixture())
      subscribed_fixture(org)
      project = project_fixture(owner_scope, org)
      {source, _} = source_fixture(owner_scope, org, project)
      received_at = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)

      {:ok, _} =
        EventWriter.record(event(source, "pro-retained-boundary", received_at, "postdeploy"))

      trend = Dashboard.trend(source.id, "30d", project_scope(owner_scope, project))

      assert Enum.sum_by(trend, & &1.event_count) == 1

      summary =
        Dashboard.summaries([source], "30d", project_scope(owner_scope, project))[source.id]

      assert summary.data_state == :ready
    end
  end

  describe "summaries/3" do
    test "returns release markers, dense volume, and reconciled bounded rankings" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project)
      now = DateTime.utc_now()

      for index <- 1..6 do
        {:ok, _} =
          EventWriter.record(event(source, "ranked_#{index}", now, "ranked_#{index}"))
      end

      _release =
        release_fixture(owner_scope, org, project, source, %{
          version: "2.0.0",
          commit_sha: "abcdef1",
          released_at: now
        })

      summary = Dashboard.summaries([source], "24h", scope) |> Map.fetch!(source.id)

      assert summary.data_state == :ready
      assert summary.total_events == 6
      # Twenty-four hourly buckets for a 24-hour window, the current one last.
      assert length(summary.volume) == 24
      assert Enum.any?(summary.volume, &match?(%{release: %{version: "2.0.0"}}, &1))
      assert [%{deployed_at: deployed_at}] = summary.release_markers
      assert DateTime.compare(deployed_at, now) == :eq
      assert Enum.any?(summary.step, &match?(%{release: %{version: "2.0.0"}}, &1))
      assert Enum.all?(summary.step, &Map.has_key?(&1, :start_at))
      assert length(summary.top_issues) <= 5
      assert length(summary.top_culprits) <= 5
      assert summary.ranking.ranked_event_count + summary.ranking.unranked_event_count == 6
    end

    test "marks a source with no retained events as missing instead of zero data" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project)

      summary = Dashboard.summaries([source], "24h", scope) |> Map.fetch!(source.id)

      assert summary.data_state == :missing
      assert summary.total_events == 0
      assert Enum.all?(summary.volume, &(&1.event_count == 0))
      assert summary.release_markers == []
    end

    test "bounds release markers per source before building the overview" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)
      {source, _} = source_fixture(owner_scope, org, project)
      now = DateTime.utc_now()

      for index <- 1..(Dashboard.max_release_markers() + 1) do
        release_fixture(owner_scope, org, project, source, %{
          version: "marker-#{index}",
          released_at: DateTime.add(now, -index * 60, :second)
        })
      end

      summary = Dashboard.summaries([source], "24h", scope) |> Map.fetch!(source.id)

      assert length(summary.release_markers) == Dashboard.max_release_markers()
      assert hd(summary.release_markers).version == "marker-101"
    end

    test "batches trend, open-issue count, and latest release per source, in one query each" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)

      {prod_source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

      {staging_source, _} =
        source_fixture(owner_scope, org, project, %{environment: "staging"})

      now = DateTime.utc_now()

      {:ok, _} = EventWriter.record(event(prod_source, "summary_evt_prod", now, "p"))

      _open_issue =
        issue_fixture(org, project, prod_source, %{
          fingerprint: "sha256:" <> String.duplicate("b", 64)
        })

      release_fixture(owner_scope, org, project, prod_source, %{
        version: "1.0.0",
        released_at: now
      })

      summaries = Dashboard.summaries([prod_source, staging_source], "24h", scope)

      prod_summary = Map.fetch!(summaries, prod_source.id)
      staging_summary = Map.fetch!(summaries, staging_source.id)

      # The ingested event itself opens an Issue too, alongside the one
      # created directly above, so both are open for the production Source.
      assert prod_summary.open_issues == 2
      assert prod_summary.latest_release.version == "1.0.0"
      assert Enum.sum(Enum.map(prod_summary.trend, & &1.event_count)) == 1

      assert staging_summary.open_issues == 0
      assert staging_summary.latest_release == nil
      assert Enum.sum(Enum.map(staging_summary.trend, & &1.event_count)) == 0
    end

    test "an empty source list never queries error_events and returns an empty map" do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = project_scope(owner_scope, project)

      assert Dashboard.summaries([], "24h", scope) == %{}
    end
  end
end
