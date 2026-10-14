defmodule Alplus.Observe.SessionHealthTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{Release, SessionHealth, SessionRollupWriter}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp session(org_id, project_id, source_id, session_id, attrs \\ %{}) do
    Map.merge(
      %{
        session_id: session_id,
        org_id: org_id,
        project_id: project_id,
        source_id: source_id,
        environment: "production",
        status: "healthy",
        release: "1.0.0",
        received_at: ~U[2026-08-12 09:00:00.000000Z]
      },
      attrs
    )
  end

  defp release(scope, org, project, source, version) do
    Ash.create!(
      Release,
      %{
        org_id: org.id,
        project_id: project.id,
        source_id: source.id,
        environment: source.environment,
        version: version,
        released_at: ~U[2026-08-12 09:00:00.000000Z]
      },
      actor: project_scope(scope, project)
    )
  end

  test "returns :not_enough_data below the minimum session count" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    Enum.each(1..(SessionHealth.min_sessions() - 1), fn n ->
      SessionRollupWriter.record!(session(org.id, project.id, source.id, "ses_low_#{n}"))
    end)

    assert SessionHealth.crash_free(scope, "1.0.0", source.id) == :not_enough_data
  end

  test "computes the crash-free percentage once the minimum is reached" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    total = SessionHealth.min_sessions()

    Enum.each(1..(total - 1), fn n ->
      SessionRollupWriter.record!(session(org.id, project.id, source.id, "ses_ok_#{n}"))
    end)

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_crash_1", %{status: "crashed"})
    )

    assert {:ok, %{sessions: ^total, crashed: 1, crash_free_pct: pct}} =
             SessionHealth.crash_free(scope, "1.0.0", source.id)

    expected = (total - 1) / total * 100
    assert_in_delta pct, expected, 0.0001
  end

  test "an errored (non-crashed) session never lowers crash-free %" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    total = SessionHealth.min_sessions()

    Enum.each(1..total, fn n ->
      SessionRollupWriter.record!(
        session(org.id, project.id, source.id, "ses_err_#{n}", %{status: "errored"})
      )
    end)

    assert {:ok, %{crashed: 0, crash_free_pct: 100.0}} =
             SessionHealth.crash_free(scope, "1.0.0", source.id)
  end

  test "is scoped per source: a sibling source in the same environment never counts" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source_a, _} = source_fixture(owner_scope, org, project)
    Ash.update!(source_a, %{}, action: :revoke, actor: scope)
    {source_b, _} = source_fixture(owner_scope, org, project)

    Enum.each(1..SessionHealth.min_sessions(), fn n ->
      SessionRollupWriter.record!(session(org.id, project.id, source_b.id, "ses_b_#{n}"))
    end)

    assert SessionHealth.crash_free(scope, "1.0.0", source_a.id) == :not_enough_data
  end

  test "is scoped per release: a different release's sessions never mix in" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    Enum.each(1..SessionHealth.min_sessions(), fn n ->
      SessionRollupWriter.record!(
        session(org.id, project.id, source.id, "ses_v2_#{n}", %{release: "2.0.0"})
      )
    end)

    assert SessionHealth.crash_free(scope, "1.0.0", source.id) == :not_enough_data
  end

  test "a second org's sessions never leak into this org's crash-free % (tenant isolation)" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    {other_source, _} = source_fixture(other_owner_scope, other_org, other_project)

    Enum.each(1..SessionHealth.min_sessions(), fn n ->
      SessionRollupWriter.record!(
        session(other_org.id, other_project.id, other_source.id, "ses_other_#{n}")
      )
    end)

    assert SessionHealth.crash_free(scope, "1.0.0", source.id) == :not_enough_data
  end

  test "returns :not_enough_data for a nil source_id instead of raising" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    assert SessionHealth.crash_free(scope, "1.0.0", nil) == :not_enough_data
  end

  test "summaries return sample state for each release in one source-scoped result" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    low_release = release(owner_scope, org, project, source, "1.0.0")
    ready_release = release(owner_scope, org, project, source, "2.0.0")

    Enum.each(1..(SessionHealth.min_sessions() - 1), fn n ->
      SessionRollupWriter.record!(session(org.id, project.id, source.id, "ses_summary_low_#{n}"))
    end)

    Enum.each(1..SessionHealth.min_sessions(), fn n ->
      SessionRollupWriter.record!(
        session(org.id, project.id, source.id, "ses_summary_ready_#{n}", %{release: "2.0.0"})
      )
    end)

    summaries = SessionHealth.summaries(scope, [low_release, ready_release])

    assert summaries[low_release.id].state == :not_enough_data
    assert summaries[low_release.id].sessions == SessionHealth.min_sessions() - 1
    assert summaries[ready_release.id].state == :ready

    assert {:ok, %{sessions: sessions, crashed: 0, crash_free_pct: 100.0}} =
             summaries[ready_release.id].result

    assert sessions == SessionHealth.min_sessions()
  end

  test "summaries do not expose another tenant's release rows" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    {other_source, _} = source_fixture(other_scope, other_org, other_project)
    other_release = release(other_scope, other_org, other_project, other_source, "9.9.9")

    assert SessionHealth.summaries(scope, [other_release]) == %{}
  end
end
