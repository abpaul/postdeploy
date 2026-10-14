defmodule Alplus.Observe.IssueTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Audit.AuditLog
  alias Alplus.Observe.Issue
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp audit_rows_for(org_id, action) do
    AuditLog
    |> Ash.Query.filter(org_id == ^org_id and action == ^action)
    |> Ash.read!(authorize?: false)
  end

  defp issue_fixture(org, project) do
    now = ~U[2026-08-11 12:00:00.000000Z]

    Ash.create!(
      Issue,
      %{
        org_id: org.id,
        project_id: project.id,
        environment: "production",
        fingerprint: "sha256:" <> String.duplicate("a", 64),
        level: "error",
        title: "Request failed",
        first_seen_at: now,
        last_seen_at: now
      },
      action: :record,
      authorize?: false
    )
  end

  test "an owner resolves, ignores for ninety days, and a regression reopens an issue" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)

    assert issue.status == :open

    resolved = Ash.update!(issue, %{}, action: :resolve, actor: scope)
    assert resolved.status == :resolved
    assert %DateTime{} = resolved.resolved_at

    ignored = Ash.update!(resolved, %{}, action: :ignore, actor: scope)
    assert ignored.status == :ignored
    assert ignored.resolved_at == nil
    assert DateTime.diff(ignored.ignored_until, DateTime.utc_now(), :day) in 89..90

    reopened =
      Ash.update!(
        ignored,
        %{last_seen_at: DateTime.add(ignored.last_seen_at, 1, :second), event_count: 2},
        action: :regress,
        authorize?: false
      )

    assert reopened.status == :open
    assert reopened.resolved_at == nil
    assert reopened.ignored_until == nil
  end

  test "a member can read a project issue but cannot change its lifecycle" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    issue = issue_fixture(org, project)

    member_scope =
      member_fixture(owner_scope, org, user_fixture(), "member") |> project_scope(project)

    assert %Issue{id: issue_id} = Ash.get!(Issue, issue.id, actor: member_scope)
    assert issue_id == issue.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(issue, %{}, action: :resolve, actor: member_scope)
  end

  test "a project actor cannot read another tenant's issue" do
    {org_a, owner_a} = org_fixture(scope_fixture())
    project_a = project_fixture(owner_a, org_a)
    issue = issue_fixture(org_a, project_a)

    {org_b, owner_b} = org_fixture(scope_fixture())
    project_b = project_fixture(owner_b, org_b)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.get(Issue, issue.id, actor: project_scope(owner_b, project_b))
  end

  test "an owner manually reopens a resolved issue and an ignored issue" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)

    resolved = Ash.update!(issue, %{}, action: :resolve, actor: scope)
    reopened = Ash.update!(resolved, %{}, action: :reopen, actor: scope)

    assert reopened.status == :open
    assert reopened.resolved_at == nil
    assert reopened.resolved_in_release_id == nil

    ignored = Ash.update!(reopened, %{}, action: :ignore, actor: scope)
    reopened_again = Ash.update!(ignored, %{}, action: :reopen, actor: scope)

    assert reopened_again.status == :open
    assert reopened_again.ignored_until == nil
  end

  test "a member is denied reopening an issue" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)
    resolved = Ash.update!(issue, %{}, action: :resolve, actor: scope)

    member_scope =
      member_fixture(owner_scope, org, user_fixture(), "member") |> project_scope(project)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(resolved, %{}, action: :reopen, actor: member_scope)
  end

  test "reopening an already-open issue is an invalid transition" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(issue, %{}, action: :reopen, actor: scope)
  end

  test "reopening a cross-tenant issue id 404s through the actor-scoped path" do
    {org_a, owner_a} = org_fixture(scope_fixture())
    project_a = project_fixture(owner_a, org_a)
    issue = issue_fixture(org_a, project_a)
    resolved = Ash.update!(issue, %{}, action: :resolve, actor: project_scope(owner_a, project_a))

    {org_b, owner_b} = org_fixture(scope_fixture())
    project_b = project_fixture(owner_b, org_b)
    scope_b = project_scope(owner_b, project_b)

    assert {:error, %Ash.Error.Invalid{}} = Ash.get(Issue, resolved.id, actor: scope_b)
  end

  test "reopening an issue writes an audit log row" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)
    resolved = Ash.update!(issue, %{}, action: :resolve, actor: scope)

    reopened = Ash.update!(resolved, %{}, action: :reopen, actor: scope)

    assert [row] = audit_rows_for(org.id, "issue.reopen")
    assert row.outcome == "allowed"
    assert row.actor_id == owner_scope.user_id
    assert row.subject_type == "issue"
    assert row.subject_id == reopened.id
    assert row.project_id == project.id
  end

  test "a member's denied reopen attempt writes a denied audit log row" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)
    resolved = Ash.update!(issue, %{}, action: :resolve, actor: scope)

    member_scope =
      member_fixture(owner_scope, org, user_fixture(), "member") |> project_scope(project)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(resolved, %{}, action: :reopen, actor: member_scope)

    assert [row] = audit_rows_for(org.id, "issue.reopen")
    assert row.outcome == "denied"
  end

  test "automatic regression on a new event still works, unchanged, forbidden to browser actors" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    issue = issue_fixture(org, project)
    resolved = Ash.update!(issue, %{}, action: :resolve, actor: scope)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(resolved, %{}, action: :regress, actor: scope)

    regressed =
      Ash.update!(
        resolved,
        %{last_seen_at: DateTime.add(resolved.last_seen_at, 1, :second), event_count: 2},
        action: :regress,
        authorize?: false
      )

    assert regressed.status == :open
  end

  test "an owner assigns an org member, reassignment to nil unassigns, and it is audited" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    issue = issue_fixture(org, project)
    scope = project_scope(owner_scope, project)

    member_user = user_fixture()
    member_fixture(owner_scope, org, member_user, "member")

    assigned =
      Ash.update!(issue, %{assignee_id: member_user.id}, action: :assign, actor: scope)

    assert assigned.assignee_id == member_user.id
    assert [_ | _] = audit_rows_for(org.id, "issue.assign")

    unassigned = Ash.update!(assigned, %{assignee_id: nil}, action: :assign, actor: scope)
    assert unassigned.assignee_id == nil
  end

  defp issue_fixture_with(org, project, attrs) do
    now = ~U[2026-08-11 12:00:00.000000Z]

    Ash.create!(
      Issue,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          environment: "production",
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Request failed",
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      ),
      action: :record,
      authorize?: false
    )
  end

  test "an owner merges an issue into a sibling and unmerges it, audited" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    canonical = issue_fixture(org, project)

    child =
      issue_fixture_with(org, project, %{
        fingerprint: "sha256:" <> String.duplicate("b", 64),
        title: "Request failed (variant)"
      })

    merged =
      Ash.update!(child, %{merged_into_issue_id: canonical.id}, action: :merge, actor: scope)

    assert merged.merged_into_issue_id == canonical.id
    assert [_ | _] = audit_rows_for(org.id, "issue.merge")

    unmerged = Ash.update!(merged, %{}, action: :unmerge, actor: scope)
    assert unmerged.merged_into_issue_id == nil
    assert [_ | _] = audit_rows_for(org.id, "issue.unmerge")
  end

  test "merge rejects self, chains, cross-tenant targets, and a member actor" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)

    canonical = issue_fixture(org, project)

    child =
      issue_fixture_with(org, project, %{fingerprint: "sha256:" <> String.duplicate("b", 64)})

    grandchild =
      issue_fixture_with(org, project, %{fingerprint: "sha256:" <> String.duplicate("c", 64)})

    # Self-merge.
    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(canonical, %{merged_into_issue_id: canonical.id},
               action: :merge,
               actor: scope
             )

    # A merged issue is not a valid target (no chains)...
    Ash.update!(child, %{merged_into_issue_id: canonical.id}, action: :merge, actor: scope)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(grandchild, %{merged_into_issue_id: child.id},
               action: :merge,
               actor: scope
             )

    # ...and a canonical parent cannot itself be merged while it has children.
    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(canonical, %{merged_into_issue_id: grandchild.id},
               action: :merge,
               actor: scope
             )

    # A cross-tenant target reads exactly like a nonexistent one.
    {org_b, owner_b} = org_fixture(scope_fixture())
    project_b = project_fixture(owner_b, org_b)
    foreign = issue_fixture(org_b, project_b)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(grandchild, %{merged_into_issue_id: foreign.id},
               action: :merge,
               actor: scope
             )

    member_scope =
      member_fixture(owner_scope, org, user_fixture(), "member") |> project_scope(project)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(grandchild, %{merged_into_issue_id: canonical.id},
               action: :merge,
               actor: member_scope
             )
  end

  test "assignment rejects a user outside the org and a member actor" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    issue = issue_fixture(org, project)
    scope = project_scope(owner_scope, project)

    outsider = user_fixture()

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(issue, %{assignee_id: outsider.id}, action: :assign, actor: scope)

    member_user = user_fixture()

    member_scope =
      member_fixture(owner_scope, org, member_user, "member") |> project_scope(project)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(issue, %{assignee_id: member_user.id},
               action: :assign,
               actor: member_scope
             )
  end
end
