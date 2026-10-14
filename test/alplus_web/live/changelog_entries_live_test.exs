defmodule AlplusWeb.ChangelogEntriesLiveTest do
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

  defp grant_fixture(owner_scope, project, client_name \\ "release-agent") do
    actor = Alplus.Scope.put_project(owner_scope, project.id)
    now = DateTime.utc_now()

    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id:
            "https://client.example/changelog-entries-#{System.unique_integer([:positive])}.json",
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

    grant
  end

  defp changelog_fixture(scope, org, project) do
    {:ok, changelog} =
      Changelog.create_changelog(
        %{
          org_id: org.id,
          project_id: project.id,
          public_title: "Acme",
          public_slug: "acme-#{System.unique_integer([:positive])}"
        },
        actor: Alplus.Scope.put_project(scope, project.id)
      )

    changelog
  end

  defp entry_fixture(scope, project, grant, external_id, markdown \\ @markdown) do
    {:ok, entry} =
      Changelog.upsert_draft(
        %{
          project_id: project.id,
          grant_id: grant.id,
          external_id: external_id,
          markdown: markdown,
          sources: [
            %{kind: "pull_request", url: "https://github.com/acme/app/pull/1", label: "PR 1"}
          ]
        },
        actor: Alplus.Scope.put_project(scope, project.id)
      )

    entry
  end

  test "the bare changelog URL redirects to Entries", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    assert {:error, {:live_redirect, %{to: to}}} =
             conn
             |> log_in(owner)
             |> live(
               ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/public/changelog"
             )

    assert to == entries_path(org, project)
  end

  test "without an OAuth grant, explains the prerequisite with connection evidence", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    {:ok, view, _html} = conn |> log_in(owner) |> live(entries_path(org, project))

    assert has_element?(view, "#changelog-needs-credential")
    # The prerequisite is stated once, by the card that owns the action: its
    # title and its link, never a badge repeating the shell's own line.
    assert has_element?(view, "#changelog-needs-credential", "Connect an agent first")
    assert has_element?(view, "#changelog-needs-credential a[href$='/connect']")

    assert has_element?(
             view,
             "#changelog-needs-credential-task",
             "Write and publish the first customer update"
           )

    assert has_element?(view, "#copy-changelog-needs-credential-task", "Copy task")
    assert has_element?(view, "#changelog-needs-credential-action", "Open agent connection")
    refute has_element?(view, "#changelog-public-state")
    refute has_element?(view, "#changelog-entries-empty")
    refute has_element?(view, "#changelog-entry-list")
    refute has_element?(view, "#changelog-create-credential")
  end

  test "a member sees the prerequisite evidence without mutation actions", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} = conn |> log_in(member) |> live(entries_path(org, project))

    assert has_element?(view, "#changelog-needs-credential")
    assert has_element?(view, "#changelog-needs-credential", "Connect an agent first")

    assert has_element?(
             view,
             "#changelog-needs-credential-task",
             "Write and publish the first customer update"
           )

    assert has_element?(view, "#copy-changelog-needs-credential-task", "Copy task")
    assert has_element?(view, "#changelog-needs-credential-action", "Open agent connection")
    refute has_element?(view, "#changelog-create-credential")
  end

  test "with an OAuth grant but no entries, shows connection and first-entry evidence", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    grant_fixture(scope, project)

    {:ok, view, _html} = conn |> log_in(owner) |> live(entries_path(org, project))

    assert has_element?(view, "#changelog-entries-empty")
    assert has_element?(view, "#topbar-agent-connection", "Agent connected")
    refute has_element?(view, "#changelog-entries-empty", "Agent connected")

    assert has_element?(
             view,
             "#changelog-entries-empty-task",
             "Write and publish the first customer update"
           )

    assert has_element?(view, "#copy-changelog-entries-empty-task", "Copy task")
    assert has_element?(view, "#changelog-entries-empty-action", "Check connection")
    refute has_element?(view, "#changelog-public-state")
    refute has_element?(view, "#changelog-needs-credential")
  end

  test "a member sees the entry list with counts and no create affordance", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    grant = grant_fixture(owner_scope, project)
    changelog_fixture(owner_scope, org, project)
    entry = entry_fixture(owner_scope, project, grant, "ext-1")
    member = user_fixture()
    member_fixture(owner_scope, org, member, "member")

    {:ok, view, _html} = conn |> log_in(member) |> live(entries_path(org, project))

    assert has_element?(view, "#changelog-subnav-entries[aria-current='page']")
    assert has_element?(view, "#changelog-summary")
    assert has_element?(view, "#review-entry-#{entry.id}", "Faster deploys")
    assert has_element?(view, "#changelog-summary", "Agents write updates.")

    refute has_element?(view, "#changelog-read-only")

    refute has_element?(view, "#changelog-needs-credential")
  end

  test "the status filter narrows the entry list", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    project_scope = Alplus.Scope.put_project(scope, project.id)
    grant = grant_fixture(scope, project)
    changelog_fixture(scope, org, project)

    draft = entry_fixture(scope, project, grant, "ext-draft")

    published_markdown = """
    ---
    title: New alerts
    ---

    Alerts route to the on-call rotation.
    """

    published = entry_fixture(scope, project, grant, "ext-pub", published_markdown)
    {:ok, _} = Changelog.publish_entry(published.id, 1, actor: project_scope)

    {:ok, view, _html} = conn |> log_in(owner) |> live(entries_path(org, project))
    assert has_element?(view, "#review-entry-#{draft.id}")
    assert has_element?(view, "#review-entry-#{published.id}")

    {:ok, view, _html} =
      conn |> log_in(owner) |> live(entries_path(org, project) <> "?status=published")

    assert has_element?(view, "#review-entry-#{published.id}")
    refute has_element?(view, "#review-entry-#{draft.id}")
    assert has_element?(view, "#changelog-filters")
  end

  test "the status filter applies in place and writes the URL", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    project_scope = Alplus.Scope.put_project(scope, project.id)
    grant = grant_fixture(scope, project)
    changelog_fixture(scope, org, project)

    draft = entry_fixture(scope, project, grant, "ext-draft")

    published_markdown = """
    ---
    title: New alerts
    ---

    Alerts route to the on-call rotation.
    """

    published = entry_fixture(scope, project, grant, "ext-pub", published_markdown)
    {:ok, _} = Changelog.publish_entry(published.id, 1, actor: project_scope)

    {:ok, view, _html} = conn |> log_in(owner) |> live(entries_path(org, project))

    queries =
      entry_queries(view, fn ->
        view |> element("#changelog-filters") |> render_change(%{"status" => "published"})
        assert has_element?(view, "#review-entry-#{published.id}")
      end)

    assert length(queries) == 2

    assert has_element?(view, "#review-entry-#{published.id}")
    refute has_element?(view, "#review-entry-#{draft.id}")
    assert_patched(view, entries_path(org, project) <> "?status=published")

    view |> element("#changelog-filters") |> render_change(%{"status" => ""})

    assert has_element?(view, "#review-entry-#{draft.id}")
    assert_patched(view, entries_path(org, project))

    view |> element("#changelog-filters") |> render_change(%{"status" => "draft"})
    assert has_element?(view, "#review-entry-#{draft.id}")
    refute has_element?(view, "#review-entry-#{published.id}")

    {:ok, _} = Changelog.archive_entry(published.id, actor: project_scope)
    view |> element("#changelog-filters") |> render_change(%{"status" => "archived"})
    assert has_element?(view, "#review-entry-#{published.id}")
    refute has_element?(view, "#review-entry-#{draft.id}")
    assert_patched(view, entries_path(org, project) <> "?status=archived")
  end

  test "long entry lists use bounded pages", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    grant = grant_fixture(scope, project)
    changelog_fixture(scope, org, project)

    entries =
      for index <- 1..26 do
        entry_fixture(scope, project, grant, "ext-page-#{index}")
      end

    oldest = List.first(entries)
    newest = List.last(entries)

    {:ok, view, _html} = conn |> log_in(owner) |> live(entries_path(org, project))

    assert has_element?(view, "#changelog-entries-pagination")
    assert has_element?(view, "#changelog-entries-pagination-page-1")
    assert has_element?(view, "#review-entry-#{newest.id}")
    refute has_element?(view, "#review-entry-#{oldest.id}")

    {:ok, page_two, _html} =
      conn |> log_in(owner) |> live(entries_path(org, project) <> "?page=2")

    assert has_element?(page_two, "#review-entry-#{oldest.id}")
    refute has_element?(page_two, "#review-entry-#{newest.id}")
  end

  defp entry_queries(view, action) do
    handler = {__MODULE__, make_ref()}
    caller = self()
    pid = view.pid

    :telemetry.attach(
      handler,
      [:alplus, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == pid and String.contains?(metadata.query, "changelog_entries"),
          do: send(caller, {handler, metadata.query})
      end,
      nil
    )

    try do
      action.()
      drain_queries(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(handler, queries) do
    receive do
      {^handler, query} -> drain_queries(handler, [query | queries])
    after
      0 -> queries
    end
  end

  test "entries from another project never appear", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    other_project = project_fixture(scope, org, %{name: "Other"})
    grant_fixture(scope, project)
    other_grant = grant_fixture(scope, other_project)
    changelog_fixture(scope, org, project)
    changelog_fixture(scope, org, other_project)
    entry = entry_fixture(scope, other_project, other_grant, "ext-other")

    {:ok, view, _html} = conn |> log_in(owner) |> live(entries_path(org, project))

    refute has_element?(view, "#review-entry-#{entry.id}")
  end
end
