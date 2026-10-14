defmodule Alplus.Analytics.DemoSeedTest do
  @moduledoc """
  The demo workspace is what product screenshots and manual QA are taken
  from, so its analytics data has to demonstrate the thing each screen
  exists to show: drop-off, a release difference, and return visits.

  A seed that silently produced a flat funnel would leave every analytics
  screenshot empty and nobody would notice until they took one.
  """

  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Analytics.Queries

  @now ~U[2026-09-20 12:00:00.000000Z]

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)

    Mix.Tasks.Alplus.DemoSeed.seed_analytics(scope, org, project, @now)

    # Rows inserted inside the test sandbox transaction are invisible to
    # autovacuum, so the planner still believes the table is empty and picks
    # a nested loop. Refresh the statistics before running an analytic query,
    # exactly as `scripts/benchmark-measure-queries.exs` does.
    Alplus.Repo.query!("ANALYZE product_events")

    %{org: org, project: project, scope: scope}
  end

  test "the onboarding funnel loses people at every step", %{scope: scope} do
    [entry] =
      scope
      |> Queries.funnel(
        Queries.range("90d", @now),
        ["first_open", "onboarding_started", "onboarding_completed", "meal_logged"]
      )
      |> Enum.map(&Queries.with_conversions/1)
      |> List.wrap()

    users = Enum.map(entry.steps, & &1.users)

    assert List.first(users) > 0
    assert users == Enum.sort(users, :desc)
    assert Enum.uniq(users) == users, "every step must lose somebody, or the screen shows nothing"
    assert entry.largest_drop_event
  end

  test "onboarding completes less often on the newer app version", %{scope: scope} do
    rates =
      for version <- ["1.8.0", "1.9.0"], into: %{} do
        [entry] =
          Queries.funnel(
            scope,
            Queries.range("90d", @now),
            ["first_open", "onboarding_completed"],
            filters: %{"app_version" => version}
          )

        {version, Queries.with_conversions(entry).overall_rate}
      end

    assert rates["1.9.0"] < rates["1.8.0"]
  end

  test "some people come back on later days", %{scope: scope} do
    %{periods: periods} =
      Queries.retention(scope, Queries.range("90d", @now), "meal_logged", "meal_logged",
        today: DateTime.to_date(@now)
      )

    assert Enum.find(periods, &(&1.period == 1)).retained > 0
    assert Enum.find(periods, &(&1.period == 7)).retained > 0
  end

  test "it seeds the same numbers every run", %{scope: scope} do
    first = Queries.totals(scope, Queries.range("90d", @now))

    other_scope = scope_fixture()
    {other_org, other_owner} = org_fixture(other_scope)
    subscribed_fixture(other_org)
    other_project = project_fixture(other_owner, other_org)
    other = Alplus.Scope.put_project(other_owner, other_project.id)

    Mix.Tasks.Alplus.DemoSeed.seed_analytics(other, other_org, other_project, @now)

    assert Queries.totals(other, Queries.range("90d", @now)) == first
  end
end
