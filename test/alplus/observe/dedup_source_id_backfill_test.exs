defmodule Alplus.Observe.DedupSourceIdBackfillTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Observe.DedupSourceIdBackfill
  alias Alplus.Repo

  setup do
    previous = Application.get_env(:alplus, :observe_dedup_backfill_batch_size)
    on_exit(fn -> Application.put_env(:alplus, :observe_dedup_backfill_batch_size, previous) end)
  end

  test "backfills a group of rows that share one event_id and spans a batch boundary" do
    # Batch size 2 with 3 rows sharing the same event_id forces the second
    # batch's cursor to land INSIDE the group (regression coverage for the
    # event_id-only cursor bug: a plain `event_id > $cursor` boundary would
    # have skipped the row(s) still sharing that event_id).
    Application.put_env(:alplus, :observe_dedup_backfill_batch_size, 2)

    {org, scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)

    shared_event_id = "evt-group-boundary-01"

    rows =
      for _ <- 1..3 do
        project = project_fixture(scope, org)
        {source, _} = source_fixture(scope, org, project)
        insert_legacy_dedup_row(org, project, source, shared_event_id)
        %{project: project, source: source}
      end

    result = DedupSourceIdBackfill.run()

    assert result == %{matched: 3, unmatched: 0}

    assert %{rows: dedup_rows} =
             Repo.query!(
               "SELECT org_id, project_id, source_id FROM error_event_deduplications WHERE event_id = $1",
               [shared_event_id]
             )

    assert length(dedup_rows) == 3

    backfilled_source_ids =
      dedup_rows
      |> Enum.reject(fn [_org_id, _project_id, source_id] -> is_nil(source_id) end)
      |> Enum.map(fn [_org_id, _project_id, source_id] -> source_id end)
      |> Enum.sort()

    expected_source_ids = rows |> Enum.map(& &1.source.id) |> Enum.sort()

    assert backfilled_source_ids == expected_source_ids
  end

  test "leaves source_id NULL and counts it unmatched when no error_events row exists" do
    Application.put_env(:alplus, :observe_dedup_backfill_batch_size, 500)

    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _} = source_fixture(scope, org, project)

    event_id = "evt-unmatched-legacy-01"

    Repo.query!(
      "INSERT INTO error_event_deduplications (event_id, org_id, project_id, received_at) VALUES ($1, $2, $3, now())",
      [event_id, org.id, project.id]
    )

    # No matching error_events row is inserted for this event_id -- the
    # backfill has nothing to join against.
    _ = source

    result = DedupSourceIdBackfill.run()

    assert result.unmatched >= 1

    assert %{rows: [[nil]]} =
             Repo.query!(
               "SELECT source_id FROM error_event_deduplications WHERE event_id = $1",
               [event_id]
             )
  end

  defp insert_legacy_dedup_row(org, project, source, event_id) do
    now = DateTime.utc_now()

    Repo.query!(
      "INSERT INTO error_event_deduplications (event_id, org_id, project_id, received_at) VALUES ($1, $2, $3, $4)",
      [event_id, org.id, project.id, now]
    )

    Repo.query!(
      """
      INSERT INTO error_events (
        received_at, event_id, issue_id, org_id, project_id, source_id, environment,
        occurred_at, level, sdk_name, sdk_version
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $1, 'error', 'sdk', '1.0')
      """,
      [
        now,
        event_id,
        fixture_issue_id(org, project, source),
        org.id,
        project.id,
        source.id,
        "production"
      ]
    )
  end

  # `error_events.issue_id` is NOT NULL with an FK to `issues`; a real Issue
  # row is the cheapest way to satisfy it without duplicating
  # `Alplus.Observe.EventWriter`'s issue-upsert SQL in this test.
  defp fixture_issue_id(org, project, source) do
    id = Alplus.Id.generate(:issue)
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO issues (
        id, org_id, project_id, source_id, environment, fingerprint, status, level, title,
        first_seen_at, last_seen_at, event_count, retention_policy_version, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, 'open', 'error', 'fixture issue', $7, $7, 1, 1, $7, $7)
      """,
      [
        id,
        org.id,
        project.id,
        source.id,
        source.environment,
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, id), case: :lower),
        now
      ]
    )

    id
  end
end
