defmodule Alplus.Observe.ReleaseHealthTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{EventWriter, Issue, Release, ReleaseArtifact, ReleaseHealth}
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
          released_at: ~U[2026-08-11 13:00:00.000000Z]
        },
        attrs
      ),
      actor: project_scope(scope, project)
    )
  end

  defp event(source, event_id, release, stack_marker) do
    now = ~U[2026-08-12 09:00:00.000000Z]

    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: now,
      received_at: now,
      level: "error",
      sdk_name: "@alplus/sdk",
      sdk_version: "0.3.0",
      exception_type: "TypeError",
      exception_value: "boom",
      frames: [%{file: "/src/#{stack_marker}.ts", function: "run", lineno: 1}],
      release: release
    }
  end

  test "counts new and resolved issues per release, from real rows" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    older = release_fixture(owner_scope, org, project, source, %{version: "1.0.0"})

    newer =
      release_fixture(owner_scope, org, project, source, %{
        version: "1.1.0",
        released_at: ~U[2026-08-12 08:00:00.000000Z]
      })

    {:ok, %{issue_id: older_issue_id}} =
      EventWriter.record(event(source, "err_health_older_1", "1.0.0", "older"))

    {:ok, %{issue_id: newer_issue_id}} =
      EventWriter.record(event(source, "err_health_newer_1", "1.1.0", "newer"))

    older_issue = Ash.get!(Issue, older_issue_id, actor: scope)

    Ash.update!(older_issue, %{resolved_in_release_id: newer.id}, action: :resolve, actor: scope)

    newer_health = ReleaseHealth.counts(scope, newer)
    assert newer_health == %{event_count: 1, new_issues: 1, resolved_issues: 1}

    older_health = ReleaseHealth.counts(scope, older)
    assert older_health == %{event_count: 1, new_issues: 1, resolved_issues: 0}

    refute newer_issue_id == older_issue_id
  end

  # Phase A (issue #46 follow-up, docs/observe-source-id-phase-b.md) keeps
  # `releases`' uniqueness on `(org_id, project_id, environment, version)`,
  # so two live Sources cannot yet each own a release row for the identical
  # `(environment, version)` pair -- that pair is genuinely still one slot
  # until Phase B moves the constraint to `source_id`. Two different
  # environments sharing one `version` string exercises the same read-side
  # regression this test guards against: a bare version match, with no
  # source_id predicate, would wrongly blend these two releases' events.
  test "a release's health never blends in a sibling Source's events, even a same-version one" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    {revoked_source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    Ash.update!(revoked_source, %{}, action: :revoke, actor: scope)

    {active_source, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})

    revoked_release =
      release_fixture(owner_scope, org, project, revoked_source, %{version: "1.0.0"})

    active_release =
      release_fixture(owner_scope, org, project, active_source, %{version: "1.0.0"})

    {:ok, _} = EventWriter.record(event(revoked_source, "err_health_shared_env_1", "1.0.0", "r"))
    {:ok, _} = EventWriter.record(event(active_source, "err_health_shared_env_2", "1.0.0", "a"))

    assert ReleaseHealth.counts(scope, revoked_release).event_count == 1
    assert ReleaseHealth.counts(scope, active_release).event_count == 1
  end

  test "previous_release finds the immediately-earlier release from the same Source" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project, %{environment: "production"})
    {other_source, _} = source_fixture(owner_scope, org, project, %{environment: "staging"})

    older = release_fixture(owner_scope, org, project, source, %{version: "1.0.0"})

    newer =
      release_fixture(owner_scope, org, project, source, %{
        version: "1.1.0",
        released_at: ~U[2026-08-12 08:00:00.000000Z]
      })

    other_environment =
      release_fixture(owner_scope, org, project, other_source, %{
        version: "1.1.0-staging",
        released_at: ~U[2026-08-12 09:00:00.000000Z]
      })

    assert ReleaseHealth.previous_release(scope, newer).id == older.id
    assert ReleaseHealth.previous_release(scope, older) == nil
    assert ReleaseHealth.previous_release(scope, other_environment) == nil
  end

  test "previous release ordering is deterministic when deploy timestamps tie" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)
    tied_at = ~U[2026-08-12 08:00:00.000000Z]

    first =
      release_fixture(owner_scope, org, project, source, %{version: "1.0.0", released_at: tied_at})

    second =
      release_fixture(owner_scope, org, project, source, %{
        version: "1.1.0",
        released_at: tied_at
      })

    later =
      release_fixture(owner_scope, org, project, source, %{
        version: "1.2.0",
        released_at: DateTime.add(tied_at, 3600, :second)
      })

    expected = Enum.max_by([first, second], & &1.id)
    assert ReleaseHealth.previous_release(scope, later).id == expected.id
  end

  test "compare requires both releases to have at least one event" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    older = release_fixture(owner_scope, org, project, source, %{version: "1.0.0"})

    newer =
      release_fixture(owner_scope, org, project, source, %{
        version: "1.1.0",
        released_at: ~U[2026-08-12 08:00:00.000000Z]
      })

    # Neither release has an event yet.
    assert ReleaseHealth.compare(ReleaseHealth.counts(scope, newer), nil) ==
             {:error, :not_enough_history}

    older_health = ReleaseHealth.counts(scope, older)
    newer_health = ReleaseHealth.counts(scope, newer)

    assert ReleaseHealth.compare(newer_health, older_health) == {:error, :not_enough_history}

    {:ok, %{issue_id: older_issue_id}} =
      EventWriter.record(event(source, "err_health_compare_1", "1.0.0", "a"))

    {:ok, %{issue_id: newer_issue_id}} =
      EventWriter.record(event(source, "err_health_compare_2", "1.1.0", "b"))

    older_health = ReleaseHealth.counts(scope, older)
    newer_health = ReleaseHealth.counts(scope, newer)

    assert {:ok, %{new_issues_delta: 0, resolved_issues_delta: 0}} =
             ReleaseHealth.compare(newer_health, older_health)

    refute older_issue_id == newer_issue_id
  end

  test "summaries batch release evidence, artifacts, and previous-release comparison" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    {source, _} = source_fixture(owner_scope, org, project)

    older = release_fixture(owner_scope, org, project, source, %{version: "1.0.0"})

    newer =
      release_fixture(owner_scope, org, project, source, %{
        version: "1.1.0",
        released_at: ~U[2026-08-12 08:00:00.000000Z]
      })

    {:ok, %{issue_id: older_issue_id}} =
      EventWriter.record(event(source, "err_health_summary_older", "1.0.0", "older"))

    {:ok, %{issue_id: newer_issue_id}} =
      EventWriter.record(event(source, "err_health_summary_newer", "1.1.0", "newer"))

    older_issue = Ash.get!(Issue, older_issue_id, actor: scope)
    Ash.update!(older_issue, %{resolved_in_release_id: newer.id}, action: :resolve, actor: scope)

    Ash.create!(
      ReleaseArtifact,
      %{
        org_id: org.id,
        project_id: project.id,
        release_id: newer.id,
        name: "app.js.map",
        type: "source_map",
        storage_key: "releases/#{newer.id}/app.js.map",
        sha256: String.duplicate("e", 64),
        byte_size: 512
      },
      actor: scope
    )

    summaries = ReleaseHealth.summaries(scope, [newer, older])
    newer_summary = summaries[newer.id]

    assert newer_summary.counts == %{event_count: 1, new_issues: 1, resolved_issues: 1}
    assert newer_summary.new_issue_ids == [newer_issue_id]
    assert newer_summary.resolved_issue_ids == [older_issue_id]
    assert newer_summary.artifacts == %{count: 1, source_maps: 1, debug_files: 0, state: :ready}
    assert newer_summary.symbolication_state == :ready
    assert newer_summary.previous_release_id == older.id
    assert newer_summary.previous_release_version == "1.0.0"
    assert newer_summary.comparison_state == :mixed
  end

  test "summaries reject release rows from another tenant" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    {other_source, _} = source_fixture(other_scope, other_org, other_project)

    other_release =
      release_fixture(other_scope, other_org, other_project, other_source, %{version: "9.9.9"})

    assert ReleaseHealth.summaries(scope, [other_release]) == %{}

    # Keep the local tenant setup explicit so this assertion remains useful
    # if the release read path later gains a broader project fallback.
    assert project.org_id == org.id
  end
end
