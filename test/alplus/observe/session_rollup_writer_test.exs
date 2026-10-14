defmodule Alplus.Observe.SessionRollupWriterTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.SessionRollupWriter

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

  test "a fresh session id is :claimed and increments sessions_count" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project)

    assert :claimed =
             SessionRollupWriter.record!(session(org.id, project.id, source.id, "ses_fresh_1"))

    assert %{rows: [[1, 0, 0, source_id]]} =
             Alplus.Repo.query!(
               "SELECT sessions_count, errored_count, crashed_count, source_id FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )

    assert source_id == source.id
  end

  test "the same session id replayed is :duplicate and does not double-count" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project)
    entry = session(org.id, project.id, source.id, "ses_replay_1")

    assert :claimed = SessionRollupWriter.record!(entry)
    assert :duplicate = SessionRollupWriter.record!(entry)

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT sessions_count FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "an errored status increments errored_count only, a crashed status increments crashed_count only" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project)

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_e", %{status: "errored"})
    )

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_c", %{status: "crashed"})
    )

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_h", %{status: "healthy"})
    )

    assert %{rows: [[3, 1, 1]]} =
             Alplus.Repo.query!(
               "SELECT sessions_count, errored_count, crashed_count FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "separate rollup rows per environment and per release" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project)

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_prod", %{environment: "production"})
    )

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_stg", %{environment: "staging"})
    )

    SessionRollupWriter.record!(
      session(org.id, project.id, source.id, "ses_rel2", %{release: "2.0.0"})
    )

    assert %{rows: [[3]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "a nil release rolls up under a NULL release bucket, not dropped" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project)

    assert :claimed =
             SessionRollupWriter.record!(
               session(org.id, project.id, source.id, "ses_no_release", %{release: nil})
             )

    assert %{rows: [[nil, 1]]} =
             Alplus.Repo.query!(
               "SELECT release, sessions_count FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )
  end

  test "Phase A: two sources sharing one environment share one rollup row, keyed by environment" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Alplus.Scope.put_project(owner_scope, project.id)
    {source_a, _} = source_fixture(owner_scope, org, project)
    Ash.update!(source_a, %{}, action: :revoke, actor: scope)
    {source_b, _} = source_fixture(owner_scope, org, project)

    SessionRollupWriter.record!(session(org.id, project.id, source_a.id, "ses_a"))
    SessionRollupWriter.record!(session(org.id, project.id, source_b.id, "ses_b"))

    assert %{rows: [[2, source_id]]} =
             Alplus.Repo.query!(
               "SELECT sessions_count, source_id FROM observe_session_rollups WHERE project_id = $1",
               [project.id]
             )

    assert source_id == source_b.id
  end
end
