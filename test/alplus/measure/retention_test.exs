defmodule Alplus.Measure.RetentionTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Measure.Retention
  alias Alplus.Measure.Goal
  alias Alplus.Scope

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)

    {source, _token} =
      source_fixture(owner_scope, org, project, %{type: :measure, environment: "production"})

    %{
      org: org,
      project: project,
      source: source,
      scope: Scope.put_project(owner_scope, project.id)
    }
  end

  test "prunes only expired rollups for the scoped project", %{
    org: org,
    project: project,
    source: source,
    scope: scope
  } do
    today = ~D[2026-08-11]
    # The plan keeps 730 days of rollups.
    cutoff = ~U[2024-08-11 00:00:00Z]
    old_hour = DateTime.add(cutoff, -1, :second)
    fresh_hour = cutoff
    old_date = Date.add(today, -731)
    fresh_date = Date.add(today, -730)

    insert_hour(org.id, project.id, source.id, old_hour)
    insert_hour(org.id, project.id, source.id, fresh_hour)
    insert_day(org.id, project.id, source.id, old_date)
    insert_day(org.id, project.id, source.id, fresh_date)
    insert_dimension(org.id, project.id, source.id, old_date)
    insert_dimension(org.id, project.id, source.id, fresh_date)

    goal =
      Ash.create!(
        Goal,
        %{
          org_id: org.id,
          project_id: project.id,
          name: "Pricing",
          kind: "pageview",
          path: "/pricing"
        },
        actor: scope
      )

    insert_conversion(org.id, project.id, goal.id, old_hour)
    insert_conversion(org.id, project.id, goal.id, fresh_hour)

    result = Retention.prune(scope, today)

    assert result.analytics_hours == 1
    assert result.analytics_days == 1
    assert result.analytics_dimensions == 1
    assert result.goal_conversions == 1
    assert result.cutoff == cutoff

    assert count("analytics_hours", project.id) == 1
    assert count("analytics_days", project.id) == 1
    assert count("analytics_dimensions", project.id) == 1
    assert count("goal_conversions", project.id) == 1
  end

  defp insert_hour(org_id, project_id, source_id, hour) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_hours
        (id, org_id, project_id, source_id, environment, hour, pageviews, visitors, visits, bounces,
         duration_seconds, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, 1, 1, 1, 0, 0, now(), now())
      """,
      [Ecto.UUID.generate() |> Ecto.UUID.dump!(), org_id, project_id, source_id, hour]
    )
  end

  defp insert_day(org_id, project_id, source_id, date) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_days
        (id, org_id, project_id, source_id, environment, date, pageviews, visitors, visits, bounces,
         duration_seconds, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, 1, 1, 1, 0, 0, now(), now())
      """,
      [Ecto.UUID.generate() |> Ecto.UUID.dump!(), org_id, project_id, source_id, date]
    )
  end

  defp insert_dimension(org_id, project_id, source_id, date) do
    Alplus.Repo.query!(
      """
      INSERT INTO analytics_dimensions
        (id, org_id, project_id, source_id, environment, date, dimension, value, visitors, pageviews,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, 'path', '/pricing', 1, 1, now(), now())
      """,
      [Ecto.UUID.generate() |> Ecto.UUID.dump!(), org_id, project_id, source_id, date]
    )
  end

  defp insert_conversion(org_id, project_id, goal_id, hour) do
    Alplus.Repo.query!(
      """
      INSERT INTO goal_conversions
        (id, org_id, project_id, goal_id, environment, hour, conversions, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, 1, now(), now())
      """,
      [Ecto.UUID.generate() |> Ecto.UUID.dump!(), org_id, project_id, goal_id, hour]
    )
  end

  defp count(table, project_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!("SELECT count(*) FROM " <> table <> " WHERE project_id = $1", [
        project_id
      ])

    count
  end
end
