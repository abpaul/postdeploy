defmodule Alplus.Measure.RollupsTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Measure.Rollups
  alias Alplus.Sources.Source

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)

    {source, _token} =
      source_fixture(owner_scope, org, project, %{type: :measure, environment: "production"})

    %{project: %{id: project.id, org_id: org.id}, source_id: source.id, date: ~D[2026-08-11]}
  end

  test "writes daily totals and privacy-safe page dimensions", %{
    project: project,
    source_id: source_id
  } do
    Rollups.record!(
      project,
      source_id,
      "production",
      %{type: "pageview", path: "/pricing", hostname: "app.example.test"},
      %{pageviews: 1, visitors: 1, visits: 1, bounces: 1, duration_seconds: 0},
      ~U[2026-08-11 12:00:00Z]
    )

    assert %{rows: [[1, 1, 1, 1]]} =
             Alplus.Repo.query!(
               "SELECT pageviews, visitors, visits, bounces FROM analytics_days WHERE project_id = $1",
               [project.id]
             )

    assert %{rows: [["hostname", "app.example.test"], ["path", "/pricing"]]} =
             Alplus.Repo.query!(
               "SELECT dimension, value FROM analytics_dimensions WHERE project_id = $1 ORDER BY dimension",
               [project.id]
             )
  end

  test "folds the 1,001st distinct value into other", %{
    project: project,
    source_id: source_id,
    date: date
  } do
    deltas = %{pageviews: 1, visitors: 1, visits: 0, bounces: 0, duration_seconds: 0}

    Enum.each(1..1_001, fn number ->
      Rollups.record_dimension!(
        project,
        source_id,
        "production",
        date,
        "path",
        "/page-#{number}",
        deltas
      )
    end)

    assert %{rows: [[1_001, 1_001]]} =
             Alplus.Repo.query!(
               "SELECT count(*), sum(pageviews)::bigint FROM analytics_dimensions WHERE project_id = $1 AND dimension = 'path'",
               [project.id]
             )

    assert %{rows: [[1_000]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM analytics_dimensions WHERE project_id = $1 AND dimension = 'path' AND value != $2",
               [project.id, Rollups.other_value()]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT pageviews FROM analytics_dimensions WHERE project_id = $1 AND dimension = 'path' AND value = $2",
               [project.id, Rollups.other_value()]
             )
  end

  describe "per-source partition (issue #34, Model A)" do
    test "two measure Sources sharing a project and environment accumulate separate rollups", %{
      project: project,
      source_id: first_source_id,
      date: date
    } do
      # Reuse the same project's org so both sources share the exact
      # `(project_id, environment)` — the case the old one-active-source-
      # per-project-per-environment identity forbade.
      second_source =
        Ash.create!(
          Source,
          %{
            org_id: project.org_id,
            project_id: project.id,
            type: :measure,
            name: "Second production site",
            environment: "production"
          },
          action: :create,
          authorize?: false
        )

      deltas = %{pageviews: 1, visitors: 1, visits: 1, bounces: 0, duration_seconds: 0}
      hit = %{type: "pageview", path: "/pricing", hostname: "app.example.test"}
      now = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

      Rollups.record!(project, first_source_id, "production", hit, deltas, now)
      Rollups.record!(project, second_source.id, "production", hit, deltas, now)

      assert %{rows: [[^first_source_id, 1], [second_source_id, 1]]} =
               Alplus.Repo.query!(
                 """
                 SELECT source_id, pageviews FROM analytics_days
                 WHERE project_id = $1 AND environment = 'production'
                 ORDER BY source_id
                 """,
                 [project.id]
               )

      assert second_source_id == second_source.id

      assert %{rows: [[2]]} =
               Alplus.Repo.query!(
                 """
                 SELECT count(DISTINCT source_id) FROM analytics_dimensions
                 WHERE project_id = $1 AND environment = 'production' AND dimension = 'path'
                 """,
                 [project.id]
               )
    end
  end
end
