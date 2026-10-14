defmodule AlplusWeb.DashboardLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "the page title names the picker, not the account", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard")

    assert has_element?(view, "h1", "Organizations")
  end

  test "the org table does not print the word Organization twice", %{conn: conn} do
    owner = user_fixture()
    {_org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard")

    # The panel carries no title, so "Organization" appears once, as the
    # column header. A panel heading above it would repeat the word one line
    # apart.
    panel = view |> element("#organizations-panel") |> render()
    refute panel =~ "organizations-panel-title"
    # Count the word itself, not a `>Organization<` adjacency: the header cell
    # wraps its label across lines, and the plural "Organizations" in the band
    # above lives outside this panel.
    assert length(Regex.scan(~r/\bOrganization\b/, panel)) == 1
  end

  test "each org row carries its plan, the actor's role, and a project count", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})
    :ok = subscribed_fixture(org)
    project_fixture(scope, org, %{name: "Alpha"})
    project_fixture(scope, org, %{name: "Beta"})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard")

    row = view |> element("#organizations tr", "Org A") |> render()

    assert row =~ "PostDeploy"
    assert row =~ "Owner"

    assert has_element?(view, "#org-projects-#{org.id}", "2")
    assert has_element?(view, "#organizations-stat-projects", "2")
  end

  test "a running trial states its remaining term once, without a status badge", %{conn: conn} do
    owner = user_fixture()
    {_org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})

    {:ok, view, _html} = conn |> log_in(owner) |> live(~p"/dashboard")

    row = view |> element("#organizations tr", "Org A") |> render()

    # The cell said "Trial" and then a dotted pill saying "Trial, 12 days
    # left" one space later. The plan name appears once; the term completes
    # it rather than repeating it.
    assert row =~ "Trial"
    assert length(Regex.scan(~r/\bTrial\b/, row)) == 1
    assert row =~ ~r/\d+ days? left/
    refute row =~ "Trial,"
  end

  test "organization rows stack identity, plan, role, and projects on small screens", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})
    project_fixture(scope, org)

    other_owner = user_fixture()

    {other_org, other_scope} =
      org_fixture(Alplus.Scope.for_user(other_owner.id), %{name: "Org B"})

    project_fixture(other_scope, other_org)

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard")

    assert has_element?(view, "#organizations tr[data-org-row]")

    row = view |> element("#organizations tr[data-org-row]", "Org A") |> render()
    assert row =~ ~s(data-org-row="true")
    assert row =~ ~s(data-label="Subscription")
    assert row =~ ~s(data-label="Role")
    assert row =~ ~s(data-label="Projects")
    assert row =~ "Owner"
    refute html =~ "Org B"
  end

  test "the profile forms are not on the picker", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard")

    refute has_element?(view, "#profile-name-form")
    refute has_element?(view, "#profile-email-form")
  end

  test "lists only the current user's organizations", %{conn: conn} do
    owner = user_fixture()
    {org_a, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})

    other_owner = user_fixture()
    {_org_b, _other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id), %{name: "Org B"})

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard")

    assert html =~ "Org A"
    refute html =~ "Org B"
    assert has_element?(view, "#org-link-#{org_a.id}", "Org A")

    _ = owner_scope
  end

  test "an org owner with a paid plan sees exactly one create-organization control", %{conn: conn} do
    owner = user_fixture()
    {org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard")

    assert has_element?(view, "#create-org-link")
    assert length(Regex.scan(~r/id="create-org-link"/, html)) == 1
  end

  test "a signed-in user with no organization gets the empty state, not an error", %{conn: conn} do
    user = user_fixture()

    {:ok, view, html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard")

    assert html =~ "No organizations yet"
    assert has_element?(view, "#organizations-empty")
    assert has_element?(view, "#create-org-link")
  end

  test "an unconfirmed user reaches /dashboard and sees the email verification gate", %{
    conn: conn
  } do
    user = user_fixture(%{confirmed: false})

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard")

    assert has_element?(view, "#activation-email-verification")
  end

  test "an expired trial shows the separate 30-day data purge date", %{conn: conn} do
    owner = user_fixture()
    {org, _scope} = expired_trial_fixture(Alplus.Scope.for_user(owner.id))

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard")

    row = view |> element("#organizations tr", org.name) |> render()
    assert row =~ "Data is deleted on"
    assert row =~ "31 Jan 2000"
  end
end
