defmodule Alplus.Observe.SourceIdBackfill.RunnerTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Observe.SourceIdBackfill.Runner
  alias Alplus.Repo
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  # Inserts a row the way the pre-source_id ingest/backfill schema would
  # have left it: `source_id` is NULL, `environment` is the only clue.
  # sobelow_skip ["SQL.Query"]
  defp insert_raw_issue(org, project, environment, first_seen_at, fingerprint) do
    id = Alplus.Id.generate(:issue)

    Repo.query!(
      """
      INSERT INTO issues (
        id, org_id, project_id, environment, fingerprint, status, level, title,
        first_seen_at, last_seen_at, event_count, retention_policy_version,
        inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, 'open', 'error', 'Boom', $6, $6, 1, 1, $6, $6)
      """,
      [id, org.id, project.id, environment, fingerprint, first_seen_at]
    )

    id
  end

  test "attributes a historical issue to the Source whose window contains its first_seen_at" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    {revoked, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(revoked, ~U[2026-01-01 00:00:00.000000Z])

    Ash.update!(revoked, %{}, action: :revoke, actor: scope)

    {active, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(active, ~U[2026-03-01 00:00:00.000000Z])

    old_issue_id =
      insert_raw_issue(
        org,
        project,
        "production",
        ~U[2026-02-01 00:00:00.000000Z],
        "sha256:" <> String.duplicate("a", 64)
      )

    new_issue_id =
      insert_raw_issue(
        org,
        project,
        "production",
        ~U[2026-04-01 00:00:00.000000Z],
        "sha256:" <> String.duplicate("b", 64)
      )

    results = Runner.run()

    assert results.issues.attributed >= 2

    assert Repo.query!("SELECT source_id FROM issues WHERE id = $1", [old_issue_id]).rows == [
             [revoked.id]
           ]

    assert Repo.query!("SELECT source_id FROM issues WHERE id = $1", [new_issue_id]).rows == [
             [active.id]
           ]
  end

  test "is idempotent: a second run leaves already-backfilled rows untouched" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})

    issue_id =
      insert_raw_issue(
        org,
        project,
        "production",
        DateTime.utc_now(),
        "sha256:" <> String.duplicate("c", 64)
      )

    first_run = Runner.run()
    assert first_run.issues.attributed >= 1

    assert Repo.query!("SELECT source_id FROM issues WHERE id = $1", [issue_id]).rows == [
             [source.id]
           ]

    second_run = Runner.run()
    assert second_run.issues.attributed == 0
    assert second_run.issues.fallback == 0

    assert Repo.query!("SELECT source_id FROM issues WHERE id = $1", [issue_id]).rows == [
             [source.id]
           ]
  end

  # Mirrors the private `@batch_size` in `Alplus.Observe.SourceIdBackfill.Runner`.
  @batch_size 500

  # sobelow_skip ["SQL.Query"]
  defp insert_raw_error_event(org, project, issue_id, environment, received_at, event_id) do
    Repo.query!(
      """
      INSERT INTO error_events (
        received_at, event_id, issue_id, org_id, project_id, environment,
        occurred_at, level, sdk_name, sdk_version
      ) VALUES ($1, $2, $3, $4, $5, $6, $1, 'error', 'test-sdk', '0.0.1')
      """,
      [received_at, event_id, issue_id, org.id, project.id, environment]
    )
  end

  test "spans more than one @batch_size batch with no skipped or double-attributed row (issues)" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source, ~U[2020-01-01 00:00:00.000000Z])

    base = ~U[2026-05-01 00:00:00.000000Z]
    count = @batch_size + 1

    ids =
      Enum.map(1..count, fn n ->
        fingerprint = "sha256:" <> (Integer.to_string(n) |> String.pad_leading(64, "0"))
        insert_raw_issue(org, project, "production", DateTime.add(base, n, :second), fingerprint)
      end)

    results = Runner.run()

    assert results.issues.attributed >= count

    rows =
      Repo.query!(
        "SELECT id, source_id FROM issues WHERE id = ANY($1)",
        [ids]
      ).rows

    assert length(rows) == count
    assert Enum.all?(rows, fn [_id, source_id] -> source_id == source.id end)

    # Idempotent re-run touches none of the now-backfilled rows -- proves
    # the second batch's cursor genuinely advanced past the first 500 and
    # neither batch was skipped nor revisited.
    second_run = Runner.run()
    assert second_run.issues.attributed == 0
  end

  test "spans more than one @batch_size batch with no skipped or double-attributed row (error_events)" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source, ~U[2020-01-01 00:00:00.000000Z])

    issue_id =
      insert_raw_issue(
        org,
        project,
        "production",
        ~U[2026-05-01 00:00:00.000000Z],
        "sha256:" <> String.duplicate("e", 64)
      )

    base = ~U[2026-05-01 00:00:00.000000Z]
    count = @batch_size + 1

    event_ids =
      Enum.map(1..count, fn n ->
        event_id = "evt_batch_span_#{n}"

        insert_raw_error_event(
          org,
          project,
          issue_id,
          "production",
          DateTime.add(base, n, :second),
          event_id
        )

        event_id
      end)

    results = Runner.run()

    assert results.error_events.attributed >= count

    rows =
      Repo.query!(
        "SELECT event_id, source_id FROM error_events WHERE event_id = ANY($1)",
        [event_ids]
      ).rows

    assert length(rows) == count
    assert Enum.all?(rows, fn [_event_id, source_id] -> source_id == source.id end)

    second_run = Runner.run()
    assert second_run.error_events.attributed == 0
  end

  test "spans more than one @batch_size batch for observe_session_rollups" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source, ~U[2020-01-01 00:00:00.000000Z])

    base = ~D[2026-05-01]
    count = @batch_size + 1

    ids =
      Enum.map(1..count, fn n ->
        insert_raw_session_rollup(
          org,
          project,
          "production",
          Date.add(base, n),
          "1.0.#{n}"
        )
      end)

    results = Runner.run()

    assert results.session_rollups.attributed >= count

    rows =
      Repo.query!(
        "SELECT id, source_id FROM observe_session_rollups WHERE id = ANY($1)",
        [ids]
      ).rows

    assert length(rows) == count
    assert Enum.all?(rows, fn [_id, source_id] -> source_id == source.id end)
  end

  test "two Sources tied at the identical inserted_at resolve deterministically, without crashing (issues)" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    tie = ~U[2026-06-01 00:00:00.000000Z]

    scope = project_scope(owner_scope, project)

    {source_a, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source_a, tie)
    Ash.update!(source_a, %{}, action: :revoke, actor: scope)

    {source_b, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source_b, tie)

    winner = Enum.max_by([source_a, source_b], & &1.id)

    issue_id =
      insert_raw_issue(
        org,
        project,
        "production",
        tie,
        "sha256:" <> String.duplicate("f", 64)
      )

    results = Runner.run()

    assert results.issues.attributed >= 1

    assert Repo.query!("SELECT source_id FROM issues WHERE id = $1", [issue_id]).rows == [
             [winner.id]
           ]

    # A second run against the same tied slot is equally deterministic and
    # does not re-attribute (idempotent).
    second_run = Runner.run()
    assert second_run.issues.attributed == 0
  end

  test "two Sources tied at the identical inserted_at resolve deterministically, without crashing (session_rollups)" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    tie = ~U[2026-06-01 00:00:00.000000Z]

    scope = project_scope(owner_scope, project)

    {source_a, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source_a, tie)
    Ash.update!(source_a, %{}, action: :revoke, actor: scope)

    {source_b, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    move_source_inserted_at(source_b, tie)

    winner = Enum.max_by([source_a, source_b], & &1.id)

    rollup_id =
      insert_raw_session_rollup(org, project, "production", ~D[2026-06-01], "1.0.0")

    results = Runner.run()

    assert results.session_rollups.attributed >= 1

    assert Repo.query!(
             "SELECT source_id FROM observe_session_rollups WHERE id = $1",
             [rollup_id]
           ).rows == [[winner.id]]
  end

  # sobelow_skip ["SQL.Query"]
  defp insert_raw_session_rollup(org, project, environment, window_start, release) do
    id = Alplus.Id.generate(:session_rollup)

    Repo.query!(
      """
      INSERT INTO observe_session_rollups (
        id, org_id, project_id, environment, release, window_start,
        sessions_count, errored_count, crashed_count, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, 1, 0, 0, now(), now())
      """,
      [id, org.id, project.id, environment, release, window_start]
    )

    id
  end

  # sobelow_skip ["SQL.Query"]
  defp move_source_inserted_at(source, inserted_at) do
    Repo.query!("UPDATE sources SET inserted_at = $1 WHERE id = $2", [inserted_at, source.id])
  end
end
