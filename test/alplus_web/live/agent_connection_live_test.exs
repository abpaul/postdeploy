defmodule AlplusWeb.AgentConnectionLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures
  alias Alplus.Mcp.{Confirmations, Principal}
  import Alplus.AuditFixtures

  # Every project destination except MCP closes while the project has no
  # agent connection; MCP is the screen that opens them.
  @locked_rows ~w(overview monitors issues traffic status_page changelog public_settings)

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp connection_path(org, project),
    do: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/connect"

  defp visible_text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> then(&Regex.replace(~r/<[^>]+>/, &1, " "))
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp refute_static_credential_ui(view) do
    html = render(view)

    refute has_element?(view, "#agent-credential-form")
    refute has_element?(view, "#agent-credential-access")
    refute has_element?(view, "#agent-credential-access-default")
    refute has_element?(view, "#agent-credential-create")
    refute has_element?(view, "#agent-credential-name")
    refute has_element?(view, "#agent-credential-error")
    refute has_element?(view, "#agent-credentials")
    refute has_element?(view, "#agent-credentials-empty")
    refute has_element?(view, "#agent-credentials-loading")
    refute has_element?(view, "#agent-secret-once")
    refute has_element?(view, "#agent-secret")
    refute has_element?(view, "#agent-secret-dismiss")
    refute has_element?(view, "#agent-scope-access")
    refute has_element?(view, "#new-credential")
    refute has_element?(view, "#credential-form")
    refute has_element?(view, "#credential-secret")
    refute has_element?(view, "#mcp-credentials")
    refute html =~ "Create credential"
    refute html =~ "Bearer token"
    refute html =~ "authentication token"
    refute html =~ "one-time key"
    refute html =~ "Do not put the token"
    refute html =~ "Copy this credential"
    refute html =~ "Copy this request"
    refute html =~ ~r/id="revoke-/
    refute html =~ ~r/id="agent-credential-/
  end

  defp assert_oauth_connection_guidance(view, endpoint, project_name) do
    guidance = visible_text(view, "#agent-connection")

    assert has_element?(view, "#remote-mcp-endpoint", endpoint)
    assert has_element?(view, "#remote-mcp-setup-prompt", endpoint)

    assert has_element?(
             view,
             "#remote-mcp-setup-prompt",
             ~s(Set up a remote MCP server named "PostDeploy" for this organization.)
           )

    assert has_element?(view, "#remote-mcp-setup-prompt", project_name)
    assert has_element?(view, "#remote-mcp-setup-prompt", "project_ref")
    assert has_element?(view, "#remote-mcp-setup-prompt", "OAuth")
    refute has_element?(view, "#remote-mcp-setup-prompt", "Bearer token")
    refute has_element?(view, "#remote-mcp-setup-prompt", "Do not put the token in chat")

    assert guidance =~ "OAuth"
    refute guidance =~ "Bearer"
    refute guidance =~ "authentication token"
    assert guidance =~ ~r/sign[- ]in/i
    assert guidance =~ "every project"
    assert guidance =~ ~r/approve/i
  end

  test "signed-out visitors are sent to sign-in, not into a crash", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)

    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, connection_path(org, project))
    assert redirected_to(get(conn, connection_path(org, project))) == "/sign-in"
  end

  test "the page shows the MCP URL and OAuth guidance until a real remote call is verified", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    conn = log_in(conn, owner)

    {:ok, view, _html} = live(conn, connection_path(org, project))

    # The screen's one visible h1 is its opening sentence; the breadcrumb
    # names the page.
    assert has_element?(view, "h1", "Connect your agent")
    refute has_element?(view, "#agent-handshake")

    # One primary action carries the task, and the troubleshooting steps are
    # the screen's answer to "the check found nothing".
    assert has_element?(view, "#check-remote-connection", "Check connection")
    assert has_element?(view, "#agent-connection-help-steps")

    endpoint = Alplus.Mcp.OAuth.resource_uri(org.public_token)

    assert endpoint == "http://localhost:4002/mcp/org/#{org.public_token}"
    assert_oauth_connection_guidance(view, endpoint, project.name)
    refute_static_credential_ui(view)

    agent_audit_fixture(owner_scope, project, "remote_mcp")

    view |> element("#check-remote-connection") |> render_click()

    assert has_element?(view, "#agent-handshake", "Agent connected")
    assert has_element?(view, "#handshake-transport", "remote_mcp")
    assert has_element?(view, "#handshake-operation", "monitor.list")
    refute_static_credential_ui(view)

    {:ok, resumed, _html} = live(conn, connection_path(org, project))
    assert has_element?(resumed, "#agent-handshake", "Agent connected")
    assert has_element?(resumed, "#handshake-transport", "remote_mcp")
    assert_oauth_connection_guidance(resumed, endpoint, project.name)
    refute_static_credential_ui(resumed)
  end

  test "transport checks require evidence from the selected transport", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project, "remote_mcp")

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(connection_path(org, project))

    assert has_element?(view, "#handshake-transport", "remote_mcp")

    view |> element("#check-webmcp-connection") |> render_click()
    refute has_element?(view, "#agent-handshake")
    assert has_element?(view, "#agent-connection-status", "No allowed WebMCP call")

    agent_audit_fixture(owner_scope, project, "webmcp")
    view |> element("#check-webmcp-connection") |> render_click()

    assert has_element?(view, "#handshake-transport", "webmcp")
    assert has_element?(view, "#handshake-access", "read and write")
    refute_static_credential_ui(view)
  end

  test "members see OAuth connection guidance without credential or token controls", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    member = user_fixture()
    _member_scope = member_fixture(owner_scope, org, member)

    {:ok, view, _html} =
      conn
      |> log_in(member)
      |> live(connection_path(org, project))

    endpoint = String.trim_trailing(AlplusWeb.Endpoint.url(), "/") <> "/mcp"

    assert_oauth_connection_guidance(view, endpoint, project.name)
    refute_static_credential_ui(view)
    refute has_element?(view, "#agent-member-owner-action")
  end

  describe "project navigation while the project has no agent connection" do
    test "the rail locks every project destination but MCP, and says so once", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(connection_path(org, project))

      assert has_element?(view, "#agent-scope", "Not connected yet")

      for row <- @locked_rows do
        assert has_element?(view, "#desktop-nav-#{row}[aria-disabled=true]")
        refute has_element?(view, "a#desktop-nav-#{row}")
        assert has_element?(view, "#mobile-nav-#{row}[aria-disabled=true]")
      end

      # The prerequisite is stated once per rail, not repeated on every row.
      assert has_element?(
               view,
               "#desktop-nav-locked-note",
               "Connect an agent to manage this project."
             )

      refute render(view) =~ "MCP required"

      assert has_element?(view, "a#desktop-nav-mcp[aria-current=page]", "MCP")
      assert has_element?(view, "a#mobile-nav-mcp", "MCP")

      # Getting out of the project is never locked.
      assert has_element?(view, "#desktop-nav-org-toggle", org.name)
      assert has_element?(view, "a#breadcrumbs-0", org.name)
      assert has_element?(view, "a#desktop-nav-account")
    end

    test "a connected project renders normal project links", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org)
      agent_audit_fixture(scope, project)

      {:ok, view, _html} = conn |> log_in(owner) |> live(connection_path(org, project))

      assert has_element?(view, "#agent-scope", "Connected")

      for row <- @locked_rows do
        assert has_element?(view, "a#desktop-nav-#{row}")
        assert has_element?(view, "a#mobile-nav-#{row}")
      end

      refute render(view) =~ "MCP required"
    end

    test "a verified check unlocks the rail in place", %{conn: conn} do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(connection_path(org, project))

      assert has_element?(view, "#desktop-nav-overview[aria-disabled=true]")

      agent_audit_fixture(scope, project)
      view |> element("#check-remote-connection") |> render_click()

      assert has_element?(view, "#agent-handshake", "Agent connected")
      assert has_element?(view, "a#desktop-nav-overview")
      assert has_element?(view, "a#mobile-nav-overview")
      refute has_element?(view, "#desktop-nav-overview[aria-disabled=true]")
      assert has_element?(view, "#agent-scope", "Connected")
    end

    test "a check with no evidence keeps the operator on Connect and says what to do", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(scope, org)

      {:ok, view, _html} = conn |> log_in(owner) |> live(connection_path(org, project))

      view |> element("#check-remote-connection") |> render_click()

      # No redirect, no bounce loop: the same screen reports the result.
      assert has_element?(view, "#agent-connection-status", "No allowed remote MCP call")
      assert has_element?(view, "#agent-connection-panel")
      assert has_element?(view, "#agent-connection-help-steps")
      assert has_element?(view, "#desktop-nav-overview[aria-disabled=true]")
      refute has_element?(view, "#agent-handshake")
    end

    test "owners can review pending destructive confirmations", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      project = project_fixture(owner_scope, org)

      principal = %Principal{
        grant_id: nil,
        org_id: org.id,
        project_id: project.id,
        user_id: owner.id,
        role: "owner",
        correlation_id: Alplus.Id.generate(:request),
        scopes: nil,
        access: :read_write,
        source: :session
      }

      assert {:ok, confirmation} =
               Confirmations.request(
                 principal,
                 "projects.archive",
                 %{"project_handle" => project.id},
                 "confirm-ui-#{System.unique_integer([:positive])}"
               )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(connection_path(org, project))

      assert has_element?(view, "#pending-confirmations")
      assert has_element?(view, "#pending-confirmation-#{confirmation.id}", "projects.archive")
      assert has_element?(view, "#approve-confirmation-#{confirmation.id}", "Approve")
      assert has_element?(view, "#reject-confirmation-#{confirmation.id}", "Reject")
      assert has_element?(view, "#pending-confirmation-#{confirmation.id}", "Pending")
    end
  end
end
