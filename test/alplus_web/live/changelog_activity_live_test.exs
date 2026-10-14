defmodule AlplusWeb.ChangelogActivityLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Changelog
  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth

  require Ash.Query

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

  defp activity_path(org, project),
    do:
      ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/changelog/activity"

  defp grant_fixture(owner_scope, project, client_name \\ "release-agent") do
    actor = Alplus.Scope.put_project(owner_scope, project.id)
    now = DateTime.utc_now()

    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id:
            "https://client.example/changelog-activity-#{System.unique_integer([:positive])}.json",
          client_name: client_name,
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
          project_id: project.id,
          user_id: actor.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: OAuth.resource_uri(),
          scopes: ["changelog:read", "changelog:write"]
        },
        actor: actor
      )

    {grant, client}
  end

  defp draft_fixture(scope, org, project) do
    project_scope = Alplus.Scope.put_project(scope, project.id)
    {grant, _client} = grant_fixture(scope, project)

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
          sources: [
            %{kind: "pull_request", url: "https://github.com/acme/app/pull/1", label: "PR 1"}
          ]
        },
        actor: project_scope
      )

    entry
  end

  test "renders the empty log for a member before any agent action", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} = conn |> log_in(member) |> live(activity_path(org, project))

    assert has_element?(view, "#changelog-subnav-activity[aria-current='page']")
    assert has_element?(view, "#activity-panel")
    assert has_element?(view, "#activity-log-empty")
    refute has_element?(view, "#activity-load-more")
  end

  test "a member sees a deletion tombstone as a content-free row", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    project_scope = Alplus.Scope.put_project(owner_scope, project.id)
    entry = draft_fixture(owner_scope, org, project)

    project_scope = %{
      project_scope
      | grant_id: entry.grant_id,
        correlation_id: "live-test"
    }

    :ok = Changelog.delete_permanently(entry.id, actor: project_scope)

    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    [event] =
      Alplus.Changelog.ActivityEvent
      |> Ash.Query.filter(event_type == "entry.deleted")
      |> Ash.read!(actor: project_scope)

    assert event.grant_id == entry.grant_id
    assert String.starts_with?(event.grant_id, "mcogr_")

    {:ok, view, html} = conn |> log_in(member) |> live(activity_path(org, project))

    assert has_element?(view, "#activity-action-#{event.id}", "entry.deleted")
    assert has_element?(view, "#activity-outcome-#{event.id}", "success")
    # Members may read the non-secret client label so MCP provenance remains
    # visible on the read-only activity log.
    assert has_element?(view, "#activity-actor-#{event.id}", "release-agent")
    refute has_element?(view, "#activity-actor-#{event.id}", to_string(owner.email))
    refute html =~ event.grant_id
  end

  test "shows content-free events for every lifecycle transition", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    entry = draft_fixture(owner_scope, org, project)
    actor = Alplus.Scope.put_project(owner_scope, project.id)

    assert {:ok, published} = Changelog.publish_entry(entry, 1, actor: actor)
    assert {:ok, archived} = Changelog.archive_entry(published, actor: actor)
    assert {:ok, _restored} = Changelog.restore_to_draft(archived, actor: actor)

    events =
      Alplus.Changelog.ActivityEvent
      |> Ash.Query.filter(
        event_type in ["entry.upserted", "entry.published", "entry.archived", "entry.restored"]
      )
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(events, & &1.event_type) == [
             "entry.upserted",
             "entry.published",
             "entry.archived",
             "entry.restored"
           ]

    assert Enum.all?(events, fn event ->
             event.entry_id == entry.id and is_binary(event.revision_id) and
               event.request_metadata == %{} and
               not Map.has_key?(event, :markdown) and
               not Map.has_key?(event, :source_url) and
               not Map.has_key?(event, :actor_email)
           end)

    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")
    {:ok, view, _html} = conn |> log_in(member) |> live(activity_path(org, project))

    for event <- events do
      assert has_element?(view, "#activity-log", event.entry_id)
      assert has_element?(view, "#activity-revision-#{event.id}", event.revision_id)
    end
  end

  test "owner and admin still see the cached OAuth client name after the grant is revoked", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    admin = user_fixture()
    member_fixture(owner_scope, org, admin, "admin")

    {grant, client} = grant_fixture(owner_scope, project, "revoked-historical-agent")

    project_scope = %{
      Alplus.Scope.put_project(owner_scope, project.id)
      | grant_id: grant.id,
        correlation_id: "revoked-grant-activity"
    }

    token_attrs = %{
      grant_id: grant.id,
      resource: OAuth.resource_uri(),
      scopes: grant.scopes
    }

    {:ok, access_token} = Mcp.issue_oauth_access_token(token_attrs, authorize?: false)
    {:ok, refresh_token} = Mcp.issue_oauth_refresh_token(token_attrs, authorize?: false)
    access = Ash.Resource.get_metadata(access_token, :token)
    refresh = Ash.Resource.get_metadata(refresh_token, :token)

    {:ok, _changelog} =
      Changelog.create_changelog(
        %{org_id: org.id, project_id: project.id, public_title: "Acme", public_slug: "acme"},
        actor: project_scope
      )

    {:ok, _entry} =
      Changelog.upsert_draft(
        %{
          project_id: project.id,
          grant_id: grant.id,
          external_id: "ext-revoked",
          markdown: @markdown,
          sources: [
            %{kind: "pull_request", url: "https://github.com/acme/app/pull/9", label: "PR 9"}
          ]
        },
        actor: project_scope
      )

    [event] =
      Alplus.Changelog.ActivityEvent
      |> Ash.Query.filter(event_type == "entry.upserted" and grant_id == ^grant.id)
      |> Ash.read!(actor: project_scope)

    assert {:ok, revoked} = Mcp.revoke_oauth_grant(grant, actor: owner_scope)
    assert %DateTime{} = revoked.revoked_at

    for viewer <- [owner, admin] do
      {:ok, view, html} = conn |> log_in(viewer) |> live(activity_path(org, project))

      assert has_element?(view, "#activity-action-#{event.id}", "entry.upserted")
      assert has_element?(view, "#activity-actor-#{event.id}", "revoked-historical-agent")
      refute has_element?(view, "#activity-actor-#{event.id}", "Unknown")

      refute html =~ client.client_id
      refute html =~ client.id
      refute html =~ access
      refute html =~ refresh
      refute html =~ "mcoat_"
      refute html =~ "mcort_"
    end
  end
end
