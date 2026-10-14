defmodule Alplus.Observe.IssueEvidenceTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Observe.{EventWriter, IssueEvidence}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp event(source, event_id, overrides \\ %{}) do
    now = ~U[2026-08-12 09:00:00.000000Z]

    Map.merge(
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
        frames: [%{file: "/src/app.ts", function: "run", lineno: 1, in_app: true}],
        breadcrumbs: [%{"category" => "navigation", "message" => "checkout"}],
        tags: %{"build" => "main"}
      },
      overrides
    )
  end

  test "recent returns evidence fields scoped to org, project, and issue" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(event(source, "err_evidence_1"))

    {:ok, %{issue_id: ^issue_id}} =
      EventWriter.record(
        event(source, "err_evidence_2", %{
          received_at: ~U[2026-08-12 09:00:01.000000Z]
        })
      )

    [latest, oldest] = IssueEvidence.recent(project_scoped, issue_id)

    assert latest.event_id == "err_evidence_2"
    assert oldest.event_id == "err_evidence_1"
    assert [%{function: "run", in_app: true}] = latest.frames
    assert [%{category: "navigation"}] = latest.breadcrumbs
    assert latest.tags == %{"build" => "main"}
    assert latest.sdk_name == "@alplus/sdk"
    assert %Alplus.Observe.Occurrence{} = latest
  end

  test "recent is empty for an issue with no events under this scope" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)

    assert IssueEvidence.recent(project_scope(scope, project), Alplus.Id.generate(:issue)) == []
  end

  test "recent carries context, user, mechanism, and causes" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(
        event(source, "err_evidence_full", %{
          context: %{"request" => %{"method" => "POST", "url" => "https://app.test/orders"}},
          user_id: "user_42",
          user_email: "person@example.com",
          mechanism: "rack.middleware",
          causes: [%{type: "Timeout::Error", value: "expired", frames: nil}]
        })
      )

    [occurrence] = IssueEvidence.recent(project_scope(scope, project), issue_id)

    assert occurrence.context["request"]["method"] == "POST"
    assert occurrence.user_id == "user_42"
    assert occurrence.user_email == "person@example.com"
    assert occurrence.mechanism == "rack.middleware"
    assert [%{type: "Timeout::Error"}] = occurrence.causes
  end

  test "users_affected counts distinct users and ignores userless events" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(event(source, "err_users_1", %{user_id: "user_a"}))

    {:ok, _} =
      EventWriter.record(
        event(source, "err_users_2", %{
          user_id: "user_a",
          received_at: ~U[2026-08-12 09:00:01.000000Z]
        })
      )

    {:ok, _} =
      EventWriter.record(
        event(source, "err_users_3", %{
          user_email: "b@example.com",
          received_at: ~U[2026-08-12 09:00:02.000000Z]
        })
      )

    {:ok, _} =
      EventWriter.record(
        event(source, "err_users_4", %{received_at: ~U[2026-08-12 09:00:03.000000Z]})
      )

    assert IssueEvidence.users_affected(project_scoped, issue_id) == 2
  end

  test "fetch returns one occurrence and 404s across tenants" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(event(source, "err_fetch_1"))

    assert {:ok, occurrence} = IssueEvidence.fetch(project_scoped, issue_id, "err_fetch_1")
    assert occurrence.event_id == "err_fetch_1"

    {org_b, scope_b} = org_fixture(scope_fixture())
    project_b = project_fixture(scope_b, org_b)

    assert IssueEvidence.fetch(project_scope(scope_b, project_b), issue_id, "err_fetch_1") ==
             {:error, :not_found}
  end

  test "recent never returns another tenant's events for the same issue id" do
    {org_a, scope_a} = org_fixture(scope_fixture())
    project_a = project_fixture(scope_a, org_a)
    {source_a, _} = source_fixture(scope_a, org_a, project_a)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(event(source_a, "err_evidence_tenant_a"))

    {org_b, scope_b} = org_fixture(scope_fixture())
    project_b = project_fixture(scope_b, org_b)

    assert IssueEvidence.recent(project_scope(scope_b, project_b), issue_id) == []
  end

  test "page returns occurrences, users, and the merge group in one call" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} =
      EventWriter.record(event(source, "err_page_1", %{user_id: "user_a"}))

    issue = Ash.get!(Alplus.Observe.Issue, issue_id, actor: project_scoped)
    page = IssueEvidence.page(project_scoped, issue)

    assert [%{event_id: "err_page_1"}] = page.occurrences
    assert page.users_affected == 1
    assert page.merged_children == []
    assert page.merged_parent == nil
    assert page.group_event_count == issue.event_count
  end

  test "issue_ids_for_tag returns only issues whose events carry that tag" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: tagged}} =
      EventWriter.record(event(source, "err_tag_hit", %{tags: %{"component" => "mailer"}}))

    {:ok, %{issue_id: _other}} =
      EventWriter.record(
        event(source, "err_tag_miss", %{
          tags: %{"component" => "web"},
          received_at: ~U[2026-08-12 09:00:02.000000Z],
          frames: [%{file: "/src/other.ts", function: "other", lineno: 2}]
        })
      )

    assert IssueEvidence.issue_ids_for_tag(project_scoped, source.id, "component", "mailer") == [
             tagged
           ]
  end

  test "discussion_page returns comments oldest first with the author loaded" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} = EventWriter.record(event(source, "err_discussion_1"))

    Enum.each(["first", "second"], fn body ->
      Ash.create!(
        Alplus.Observe.IssueComment,
        %{
          org_id: org.id,
          project_id: project.id,
          issue_id: issue_id,
          user_id: scope.user_id,
          body: body
        },
        actor: project_scoped
      )
    end)

    assert {[first, second], 2, false} =
             IssueEvidence.discussion_page(project_scoped, issue_id, :comments, 1)

    assert first.body == "first"
    assert second.body == "second"
    assert first.author.id == scope.user_id
  end

  test "discussion_page returns user reports newest first" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scoped = project_scope(scope, project)
    {source, _} = source_fixture(scope, org, project)

    {:ok, %{issue_id: issue_id}} = EventWriter.record(event(source, "err_discussion_2"))

    Enum.each(["older", "newer"], fn comments ->
      Ash.create!(
        Alplus.Observe.IssueUserReport,
        %{
          org_id: org.id,
          project_id: project.id,
          issue_id: issue_id,
          name: "Reporter",
          email: "reporter@example.com",
          comments: comments
        },
        actor: project_scoped
      )
    end)

    assert {[newest, oldest], 2, false} =
             IssueEvidence.discussion_page(project_scoped, issue_id, :reports, 1)

    assert newest.comments == "newer"
    assert oldest.comments == "older"
  end
end
