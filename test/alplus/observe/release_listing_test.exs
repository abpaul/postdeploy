defmodule Alplus.Observe.ReleaseListingTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{Release, ReleaseListing}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp release_fixture(scope, org, project, source, attrs) do
    Ash.create!(
      Release,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: source.environment,
          version: "2026.08.11",
          released_at: ~U[2026-08-11 13:00:00.000000Z]
        },
        attrs
      ),
      actor: scope
    )
  end

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    {other, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})

    %{
      org: org,
      project: project,
      source: source,
      other: other,
      scope: project_scope(owner_scope, project)
    }
  end

  test "page returns one Source's releases, newest first, and the more flag", ctx do
    older =
      release_fixture(ctx.scope, ctx.org, ctx.project, ctx.source, %{
        version: "2026.08.10",
        released_at: ~U[2026-08-10 13:00:00.000000Z]
      })

    newer = release_fixture(ctx.scope, ctx.org, ctx.project, ctx.source, %{})

    release_fixture(ctx.scope, ctx.org, ctx.project, ctx.other, %{version: "2026.08.09"})

    assert {[first], true} = ReleaseListing.page(ctx.scope, ctx.source.id, 1, 1)
    assert first.id == newer.id

    assert {[second], false} = ReleaseListing.page(ctx.scope, ctx.source.id, 2, 1)
    assert second.id == older.id
  end

  test "count and latest stay scoped to one Source", ctx do
    newer = release_fixture(ctx.scope, ctx.org, ctx.project, ctx.source, %{})
    release_fixture(ctx.scope, ctx.org, ctx.project, ctx.other, %{version: "2026.08.09"})

    assert ReleaseListing.count(ctx.scope, ctx.source.id) == 1
    assert ReleaseListing.latest(ctx.scope, ctx.source.id).id == newer.id
    assert ReleaseListing.latest(ctx.scope, nil) == nil
  end
end
