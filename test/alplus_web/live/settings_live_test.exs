defmodule AlplusWeb.SettingsLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth
  alias Alplus.Mcp.OAuthGrant

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp settings_path(org), do: ~p"/dashboard/orgs/#{org.id}/settings"

  describe "tenant isolation" do
    test "a cross-tenant org id renders 404", %{conn: conn} do
      owner = user_fixture()
      {_org_a, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      other_owner = user_fixture()
      {org_b, _other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))

      conn = log_in(conn, owner)

      assert_error_sent 404, fn ->
        live(conn, settings_path(org_b))
      end
    end

    test "the audit log lists only the current org's rows", %{conn: conn} do
      owner = user_fixture()
      {org_a, owner_scope_a} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})
      {org_b, owner_scope_b} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org B"})

      _project_a = project_fixture(owner_scope_a, org_a, %{name: "Project in A"})
      _project_b = project_fixture(owner_scope_b, org_b, %{name: "Project in B"})

      {:ok, view, html} =
        conn
        |> log_in(owner)
        |> live(settings_path(org_a))

      assert html =~ "project.create"
      assert has_element?(view, "#audit-log")
      assert has_element?(view, "#connected-mcp-clients div.relative")
      assert has_element?(view, "#audit-panel div.relative")

      logs = Alplus.Audit.list_audit_logs!(actor: owner_scope_a)
      org_a_log = Enum.find(logs, &(&1.org_id == org_a.id and &1.subject_type == "project"))
      org_b_log = Enum.find(logs, &(&1.org_id == org_b.id and &1.subject_type == "project"))

      assert has_element?(view, "#audit-action-#{org_a_log.id}")
      refute has_element?(view, "#audit-action-#{org_b_log.id}")
    end
  end

  describe "audit log" do
    test "uses a bounded opaque cursor without duplicates when timestamps tie", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      subscribed_fixture(org)

      # Each cycle writes a create and an archive entry and keeps the org under
      # its project limit.
      for index <- 1..13 do
        project = project_fixture(owner_scope, org, %{name: "Project #{index}"})
        :ok = Ash.destroy(project, action: :archive, actor: owner_scope)
      end

      tied_timestamp = ~U[2026-01-01 00:00:00.000000Z]

      Alplus.Repo.query!(
        "UPDATE audit_logs SET inserted_at = $1 WHERE org_id = $2",
        [tied_timestamp, org.id]
      )

      expected_logs = Alplus.Audit.list_audit_logs!(actor: owner_scope)
      assert Enum.count(expected_logs, &(&1.org_id == org.id)) > 25

      {:ok, view, first_html} =
        conn
        |> log_in(owner)
        |> live(settings_path(org))

      first_ids = audit_row_ids(first_html)
      assert length(first_ids) == 25
      assert has_element?(view, "#audit-log-load-more")

      second_html = render_click(view, "load_more_audit", %{})
      all_ids = audit_row_ids(second_html)

      assert length(all_ids) == length(Enum.uniq(all_ids))
      assert length(all_ids) == Enum.count(expected_logs, &(&1.org_id == org.id))
      refute second_html =~ "audit_cursor"
    end

    test "shows who performed each action, with no raw ISO timestamp or middot in visible copy",
         %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      _project = project_fixture(owner_scope, org, %{name: "Project"})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(settings_path(org))

      logs = Alplus.Audit.list_audit_logs!(actor: owner_scope)
      log = Enum.find(logs, &(&1.org_id == org.id and &1.subject_type == "project"))

      panel_html = view |> element("#audit-panel") |> render()

      # `timestamp/1` keeps the exact instant in `datetime`/`title` on purpose,
      # so strip every attribute before checking what the operator actually
      # reads. The regression being guarded is the old row copy, which dumped
      # "project project_06g1… · 2026-08-19T21:44:44.055354Z" into running text.
      visible_text = String.replace(panel_html, ~r/<[^>]*>/, " ")

      assert has_element?(view, "#audit-actor-#{log.id}", to_string(owner.email))
      refute visible_text =~ DateTime.to_iso8601(log.inserted_at)
      refute visible_text =~ "\u00B7"
    end
  end

  describe "role-correct UI" do
    test "organization settings links owners to notification routing", %{conn: conn} do
      owner = user_fixture()
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})

      {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))

      assert has_element?(
               view,
               "#org-view-notifications[href=\"/dashboard/orgs/#{org.public_token}/settings/notifications\"]",
               "Notifications"
             )
    end

    test "an administrator can manage organization settings and audit data", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})

      administrator = user_fixture()
      member_fixture(owner_scope, org, administrator, "admin")

      {:ok, view, _html} =
        conn
        |> log_in(administrator)
        |> live(settings_path(org))

      assert has_element?(view, "#org-name-form")
      assert has_element?(view, "#connected-mcp-clients")
      assert has_element?(view, "#audit-panel")
      refute has_element?(view, "#org-settings-permission")

      view
      |> form("#org-name-form", organization: %{name: "Admin-managed"})
      |> render_submit()

      assert {:ok, %{name: "Admin-managed"}} =
               Alplus.Orgs.get_organization(org.id, actor: owner_scope)
    end

    test "a member sees the org name read-only and no audit log", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})

      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      {:ok, view, html} =
        conn
        |> log_in(member_user)
        |> live(settings_path(org))

      assert has_element?(view, "#org-name-readonly", "Acme")
      refute has_element?(view, "#org-name-form")
      refute has_element?(view, "#audit-log")
      assert html =~ "Acme"
    end

    test "a member cannot rename the org by sending the event directly", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})

      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      {:ok, view, _html} =
        conn
        |> log_in(member_user)
        |> live(settings_path(org))

      render_submit(view, "save_name", %{"organization" => %{"name" => "Sneaky Co"}})

      assert {:ok, %{name: "Acme"}} = Alplus.Orgs.get_organization(org.id, actor: owner_scope)
    end

    test "member direct settings events cannot mutate protected state or revoke grants",
         %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      project = project_fixture(owner_scope, org, %{name: "Atlas"})

      connection =
        connect_mcp_client(owner_scope, org, project,
          client_name: "Member-denied client",
          scopes: ["changelog:read"]
        )

      member = user_fixture()
      member_fixture(owner_scope, org, member, "member")

      audit_count_before =
        Alplus.Audit.list_audit_logs!(actor: owner_scope)
        |> Enum.count(&(&1.org_id == org.id))

      {:ok, view, _html} =
        conn
        |> log_in(member)
        |> live(settings_path(org))

      render_change(view, "validate_name", %{"organization" => %{"name" => "Sneaky"}})
      render_click(view, "retry_audit", %{})
      render_click(view, "load_more_audit", %{})

      refute has_element?(view, "#revoke-#{connection.grant.id}-trigger")
      refute has_element?(view, "#audit-panel")

      render_click(view, "confirm_revoke", %{"grant_id" => connection.grant.id})

      render_click(view, "revoke_grant", %{
        "grant_id" => connection.grant.id,
        "confirm_text" => connection.client.client_name
      })

      html = render(view)
      assert html =~ "Acme"
      refute html =~ connection.access_token
      refute html =~ connection.refresh_token
      refute has_element?(view, "#new-credential")
      refute has_element?(view, "#credential-form")
      refute has_element?(view, "#credential-secret")

      assert {:ok, %{revoked_at: nil}} =
               Mcp.get_oauth_grant(connection.grant.id, actor: owner_scope)

      audit_count_after =
        Alplus.Audit.list_audit_logs!(actor: owner_scope)
        |> Enum.count(&(&1.org_id == org.id))

      assert audit_count_after == audit_count_before
    end
  end

  describe "as an owner" do
    test "renaming the org updates the name", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Old Name"})

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(settings_path(org))

      html =
        view
        |> form("#org-name-form", organization: %{name: "New Name"})
        |> render_submit()

      assert html =~ "New Name"
      assert {:ok, %{name: "New Name"}} = Alplus.Orgs.get_organization(org.id, actor: owner_scope)
    end
  end

  describe "connected MCP clients" do
    test "lists active grants for the selected org with plain labels and no secrets", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      project = project_fixture(owner_scope, org, %{name: "Atlas"})

      {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Other Co"})
      other_project = project_fixture(other_scope, other_org, %{name: "Other project"})

      live_connection =
        connect_mcp_client(owner_scope, org, project,
          client_name: "Claude Code",
          scopes: ["changelog:read", "monitor:write"]
        )

      revoked_connection =
        connect_mcp_client(owner_scope, org, project,
          client_name: "Revoked Client",
          scopes: ["status:read"]
        )

      {:ok, _revoked} =
        Mcp.revoke_oauth_grant(revoked_connection.grant, actor: owner_scope)

      foreign_connection =
        connect_mcp_client(other_scope, other_org, other_project,
          client_name: "Codex CLI",
          scopes: ["errors:read"]
        )

      {:ok, view, html} =
        conn
        |> log_in(owner)
        |> live(settings_path(org))

      assert has_element?(view, "#connected-mcp-clients", "Connected MCP Clients")
      assert has_element?(view, "#connected-mcp-client-rows[phx-update=stream]")
      refute has_element?(view, "#new-credential")
      refute has_element?(view, "#credential-form")
      refute has_element?(view, "#credential-secret")
      refute has_element?(view, "#mcp-credentials")

      grant_id = live_connection.grant.id
      assert has_element?(view, "#grant-#{grant_id}")
      refute has_element?(view, "#grant-#{revoked_connection.grant.id}")
      refute has_element?(view, "#grant-#{foreign_connection.grant.id}")

      row = view |> element("#grant-#{grant_id}") |> render()
      visible_row = String.replace(row, ~r/<[^>]*>/, " ")

      assert visible_row =~ "Claude Code"
      assert visible_row =~ to_string(owner.email)
      assert visible_row =~ "Acme"
      assert visible_row =~ "Atlas"
      assert visible_row =~ "Changelog read"
      assert visible_row =~ "Monitor write"
      assert visible_row =~ "just now"
      assert has_element?(view, "#grant-#{grant_id} time")

      refute visible_row =~ "changelog:read"
      refute visible_row =~ "monitor:write"
      refute visible_row =~ DateTime.to_iso8601(live_connection.grant.inserted_at)
      refute visible_row =~ DateTime.to_iso8601(live_connection.grant.last_used_at)

      refute html =~ live_connection.access_token
      refute html =~ live_connection.refresh_token
      refute html =~ revoked_connection.access_token
      refute html =~ foreign_connection.access_token
      refute html =~ live_connection.client.client_id
      refute html =~ hd(live_connection.client.redirect_uris)
      refute html =~ "code_verifier"
      refute html =~ "code_challenge"
      refute html =~ "code_challenge_method"
      refute html =~ "Revoked Client"
      refute html =~ "Codex CLI"
      refute html =~ "Errors read"
    end

    test "shows organization setup and organization-scoped connection details", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      _project = project_fixture(owner_scope, org, %{name: "Atlas"})

      connection =
        connect_mcp_client(owner_scope, org, nil,
          client_name: "Claude Code",
          scopes: ["projects:read", "monitor:write"],
          scope_mode: "organization"
        )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(settings_path(org))

      assert has_element?(view, "#org-agent-connection")

      assert has_element?(
               view,
               "#org-mcp-endpoint",
               OAuth.resource_uri(org.public_token)
             )

      row = view |> element("#grant-#{connection.grant.id}") |> render()
      visible_row = String.replace(row, ~r/<[^>]*>/, " ")

      assert visible_row =~ "All projects"
      assert visible_row =~ "Read and write"
      refute row =~ connection.access_token
      refute row =~ connection.refresh_token
    end

    test "an owner revokes a grant after confirmation and tokens fail immediately", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      project = project_fixture(owner_scope, org, %{name: "Atlas"})

      connection =
        connect_mcp_client(owner_scope, org, project,
          client_name: "Claude Code",
          scopes: ["projects:read"]
        )

      assert {:ok, _principal} =
               OAuth.authenticate_access_token(connection.access_token)

      {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))

      view |> element("#revoke-#{connection.grant.id}-trigger") |> render_click()
      assert has_element?(view, "#revoke-#{connection.grant.id}-confirm")

      confirm_html = view |> element("#revoke-#{connection.grant.id}-confirm") |> render()

      visible_confirm =
        confirm_html
        |> String.replace(~r/<[^>]*>/, " ")
        |> String.replace(~r/\s+/, " ")

      assert visible_confirm =~ "immediately"
      refute visible_confirm =~ "Type the client name to confirm"

      assert Regex.scan(~r/Type Claude Code to confirm/, visible_confirm) == [
               ["Type Claude Code to confirm"]
             ]

      view
      |> form("#revoke-#{connection.grant.id}-form", %{"confirm_text" => "wrong-name"})
      |> render_submit()

      assert {:ok, %{revoked_at: nil}} =
               Mcp.get_oauth_grant(connection.grant.id, actor: owner_scope)

      html =
        view
        |> form("#revoke-#{connection.grant.id}-form", %{"confirm_text" => "Claude Code"})
        |> render_submit()

      refute has_element?(view, "#grant-#{connection.grant.id}")
      refute html =~ connection.access_token
      refute html =~ connection.refresh_token

      assert {:ok, %OAuthGrant{revoked_at: revoked_at}} =
               Mcp.get_oauth_grant(connection.grant.id, actor: owner_scope)

      assert %DateTime{} = revoked_at

      assert {:error, :revoked} = OAuth.authenticate_access_token(connection.access_token)

      assert {:error, :invalid_grant} =
               OAuth.refresh_token(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => connection.refresh_token,
                 "client_id" => connection.client.client_id,
                 "resource" => OAuth.resource_uri()
               })
    end

    test "an administrator can revoke a connected client", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
      project = project_fixture(owner_scope, org, %{name: "Atlas"})
      administrator = user_fixture()
      member_fixture(owner_scope, org, administrator, "admin")

      connection =
        connect_mcp_client(owner_scope, org, project,
          client_name: "Admin-revoked client",
          scopes: ["analytics:read"]
        )

      {:ok, view, _html} =
        conn
        |> log_in(administrator)
        |> live(settings_path(org))

      view |> element("#revoke-#{connection.grant.id}-trigger") |> render_click()

      view
      |> form("#revoke-#{connection.grant.id}-form", %{
        "confirm_text" => "Admin-revoked client"
      })
      |> render_submit()

      refute has_element?(view, "#grant-#{connection.grant.id}")

      assert {:ok, %{revoked_at: %DateTime{}}} =
               Mcp.get_oauth_grant(connection.grant.id, actor: owner_scope)

      assert {:error, :revoked} = OAuth.authenticate_access_token(connection.access_token)
    end

    test "grant IDs from another organization are neither listed nor actionable", %{conn: conn} do
      owner = user_fixture()
      {org_a, scope_a} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})
      {org_b, scope_b} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org B"})
      _project_a = project_fixture(scope_a, org_a, %{name: "Project A"})
      project_b = project_fixture(scope_b, org_b, %{name: "Project B"})

      foreign =
        connect_mcp_client(scope_b, org_b, project_b,
          client_name: "Foreign client",
          scopes: ["monitor:read"]
        )

      {:ok, view, html} = conn |> log_in(owner) |> live(settings_path(org_a))

      refute has_element?(view, "#grant-#{foreign.grant.id}")
      refute html =~ "Foreign client"
      refute html =~ foreign.access_token
      refute html =~ foreign.refresh_token

      render_click(view, "confirm_revoke", %{"grant_id" => foreign.grant.id})

      render_click(view, "revoke_grant", %{
        "grant_id" => foreign.grant.id,
        "confirm_text" => "Foreign client"
      })

      assert {:ok, %{revoked_at: nil}} =
               Mcp.get_oauth_grant(foreign.grant.id, actor: scope_b)

      refute has_element?(view, "#revoke-#{foreign.grant.id}-confirm")
      assert {:ok, _principal} = OAuth.authenticate_access_token(foreign.access_token)
    end
  end

  test "validate events and extra audit page stay on settings", %{conn: conn} do
    owner = user_fixture()
    {org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})

    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))

    view |> form("#org-name-form", organization: %{name: "Acme Two"}) |> render_change()
    render_click(view, "load_more_audit", %{})
    assert render(view) =~ "Acme"
  end

  test "invalid organization names retain associated errors and the focus hook", %{conn: conn} do
    owner = user_fixture()
    {org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})

    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))

    assert has_element?(view, "#org-name-form[phx-hook=FocusInvalid]")

    view
    |> form("#org-name-form", organization: %{name: String.duplicate("x", 201)})
    |> render_submit()

    assert has_element?(view, "#org-name[aria-invalid=true]")
    assert has_element?(view, "#org-name[aria-describedby=org-name-error]")
    assert has_element?(view, "#org-name-error")
  end

  test "management tables stay dense and expose responsive columns", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Acme"})
    _project = project_fixture(owner_scope, org, %{name: "Project"})

    {:ok, view, _html} = conn |> log_in(owner) |> live(settings_path(org))

    assert has_element?(view, "#connected-mcp-clients [data-density=dense]")
    assert has_element?(view, "#audit-panel [data-density=dense]")
    assert render(view) =~ "sm:table-cell"
    assert render(view) =~ "lg:table-cell"
  end

  defp connect_mcp_client(scope, org, project, opts) do
    client_name = Keyword.fetch!(opts, :client_name)
    scopes = Keyword.fetch!(opts, :scopes)
    scope_mode = Keyword.get(opts, :scope_mode, "project")
    now = DateTime.utc_now()

    resource =
      if scope_mode == "organization",
        do: OAuth.resource_uri(org.public_token),
        else: OAuth.resource_uri()

    {:ok, client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id:
            "https://client.example/connected-#{System.unique_integer([:positive])}.json",
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
          org_id: org.id,
          project_id: if(project, do: project.id, else: nil),
          scope_mode: scope_mode,
          user_id: scope.user_id,
          oauth_client_id: client.id,
          issuer: OAuth.issuer(),
          resource: resource,
          scopes: scopes
        },
        actor: scope
      )

    {:ok, grant} = Mcp.touch_oauth_grant(grant, authorize?: false)

    {:ok, access} =
      Mcp.issue_oauth_access_token(
        %{grant_id: grant.id, resource: resource, scopes: scopes},
        authorize?: false
      )

    {:ok, refresh} =
      Mcp.issue_oauth_refresh_token(
        %{grant_id: grant.id, resource: resource, scopes: scopes},
        authorize?: false
      )

    access_token = Ash.Resource.get_metadata(access, :token)
    refresh_token = Ash.Resource.get_metadata(refresh, :token)

    %{
      client: client,
      grant: grant,
      access: access,
      refresh: refresh,
      access_token: access_token,
      refresh_token: refresh_token
    }
  end

  defp audit_row_ids(html) do
    Regex.scan(~r/id="audit-action-([^"]+)"/, html, capture: :all_but_first)
    |> List.flatten()
  end
end
