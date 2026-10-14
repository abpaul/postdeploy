defmodule AlplusWeb.ChangelogEntryLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth

  @markdown """
  ---
  title: Faster deploys
  ---

  Deploys now finish in half the time.
  """

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp entries_path(org, project),
    do:
      ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/changelog/entries"

  defp entry_review_path(org, project, entry),
    do: entries_path(org, project) <> "/#{entry.id}"

  defp grant_fixture(owner_scope, project_id) do
    actor = Alplus.Scope.put_project(owner_scope, project_id)
    now = DateTime.utc_now()

    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id:
            "https://client.example/changelog-entry-#{System.unique_integer([:positive])}.json",
          client_name: "release-agent",
          redirect_uris: ["https://client.example/oauth/callback"],
          fetched_at: now,
          expires_at: DateTime.add(now, 3600, :second)
        },
        authorize?: false
      )

    {:ok, grant} =
      Mcp.authorize_oauth_grant(
        %{
          org_id: actor.org_id,
          project_id: project_id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: ["changelog:read", "changelog:write"]
        },
        actor: actor
      )

    grant
  end

  defp draft_fixture(
         scope,
         org,
         project,
         sources \\ [
           %{kind: "pull_request", url: "https://github.com/acme/app/pull/1", label: "PR 1"}
         ]
       ) do
    project_scope = Alplus.Scope.put_project(scope, project.id)
    grant = grant_fixture(scope, project.id)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{org_id: org.id, project_id: project.id, public_title: "Acme", public_slug: "acme"},
        actor: project_scope
      )

    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: project.id,
          grant_id: grant.id,
          external_id: "ext-1",
          markdown: @markdown,
          sources: sources
        },
        actor: project_scope
      )

    entry
  end

  test "a member reviews a draft with document, evidence, revisions, and activity", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    entry = draft_fixture(owner_scope, org, project)
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} =
      conn |> log_in(member) |> live(entry_review_path(org, project, entry))

    assert has_element?(view, "#changelog-entry")
    assert has_element?(view, "#entry-document")
    refute has_element?(view, "#entry-editor")
    refute has_element?(view, "#entry-view-write")
    refute has_element?(view, "#entry-view-preview")
    assert has_element?(view, "#entry-preview")
    assert has_element?(view, "#entry-evidence")
    assert has_element?(view, "#entry-source-" <> source_id(owner_scope, project, entry))
    assert has_element?(view, "#entry-revisions")
    assert has_element?(view, "#view-revision-1")
    assert has_element?(view, "#entry-activity")
    refute has_element?(view, "#publish-entry")
    refute has_element?(view, "#archive-entry")
    refute has_element?(view, "#restore-entry")
    refute has_element?(view, "#entry-danger")
  end

  test "an owner sees the same analysis surface without editor or lifecycle controls", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    entry = draft_fixture(owner_scope, org, project)

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(entry_review_path(org, project, entry))

    assert has_element?(view, "#entry-preview")
    assert has_element?(view, "#entry-evidence")
    assert has_element?(view, "#entry-revisions")
    assert has_element?(view, "#entry-activity")
    refute has_element?(view, "#entry-editor")
    refute has_element?(view, "#entry-view-write")
    refute has_element?(view, "#publish-entry")
    refute has_element?(view, "#archive-entry")
    refute has_element?(view, "#restore-entry")
    refute has_element?(view, "#entry-danger")
  end

  test "an entry without a revision gives the agent an exact release task", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    project_scope = Alplus.Scope.put_project(owner_scope, project.id)
    entry = draft_fixture(owner_scope, org, project)

    assert {:ok, [revision]} = Changelog.list_revisions(entry, actor: project_scope)
    assert :ok = Ash.destroy(revision, actor: project_scope)

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(entry_review_path(org, project, entry))

    assert has_element?(view, "#entry-no-revision")
    assert has_element?(view, "#entry-agent-guidance")
    assert has_element?(view, "#entry-agent-guidance-task")
    refute has_element?(view, "#entry-editor")
  end

  test "a draft without evidence gives the agent a release task", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    entry = draft_fixture(owner_scope, org, project, [])

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(entry_review_path(org, project, entry))

    assert has_element?(view, "#entry-agent-guidance")
    assert has_element?(view, "#entry-agent-guidance-task")
    refute has_element?(view, "#publish-entry")
  end

  test "an owner cannot mutate the analysis-only entry surface", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    entry = draft_fixture(owner_scope, org, project)

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(entry_review_path(org, project, entry))

    refute has_element?(view, "#entry-editor")
    refute has_element?(view, "#publish-entry")
    refute has_element?(view, "#archive-entry")
    refute has_element?(view, "#restore-entry")
    refute has_element?(view, "#entry-danger")
  end

  test "an inactive organization member can read but has no lifecycle controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    entry = draft_fixture(owner_scope, org, project)
    member = user_fixture()
    member_scope = member_fixture(owner_scope, org, member, "member")

    Alplus.Repo.query!(
      "UPDATE organizations SET plan_status = 'trialing', plan_id = 'trial', trial_ends_at = $1 WHERE id = $2",
      [~U[2000-01-01 00:00:00.000000Z], org.id]
    )

    {:ok, view, _html} =
      conn |> log_in(member) |> live(entry_review_path(org, project, entry))

    assert has_element?(view, "#entry-document")
    refute has_element?(view, "#entry-editor")
    refute has_element?(view, "#entry-danger")

    member_project_scope = Alplus.Scope.put_project(member_scope, project.id)
    assert {:ok, %{status: :draft}} = Changelog.get_entry(entry.id, actor: member_project_scope)
  end

  test "the analysis surface never offers permanent deletion", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    project_scope = Alplus.Scope.put_project(scope, project.id)
    entry = draft_fixture(scope, org, project)

    {:ok, view, _html} = conn |> log_in(owner) |> live(entry_review_path(org, project, entry))

    refute has_element?(view, "#entry-danger")
    refute has_element?(view, "#delete-entry")
    assert {:ok, _entry} = Changelog.get_entry(entry.id, actor: project_scope)
  end

  test "a cross-project entry handle is not found", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    other_project = project_fixture(scope, org, %{name: "Other"})
    entry = draft_fixture(scope, org, other_project)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn |> log_in(owner) |> live(entry_review_path(org, project, entry))
    end
  end

  defp source_id(scope, project, entry) do
    require Ash.Query

    [source] =
      Alplus.Changelog.SourceReference
      |> Ash.Query.filter(entry_id == ^entry.id)
      |> Ash.read!(actor: Alplus.Scope.put_project(scope, project.id))

    source.id
  end
end
