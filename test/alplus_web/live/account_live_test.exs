defmodule AlplusWeb.AccountLiveTest do
  @moduledoc """
  `/dashboard/account` — the operator's own account. These two flows moved
  here from org Settings (personal details are not an organization setting)
  and then from `/dashboard` (a settings form is not an answer to "which org
  do I want").
  """

  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "renders both account concerns as their own panels", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/account")

    assert has_element?(view, "h1", "Account")
    assert has_element?(view, "#account-name-title", "Display name")
    assert has_element?(view, "#account-email-title", "Email address")
  end

  test "submitting the name form updates the name immediately", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/account")

    html =
      view
      |> form("#profile-name-form", user: %{name: "Ada Lovelace"})
      |> render_submit()

    assert html =~ "Profile updated."

    assert Ash.get!(Alplus.Accounts.User, user.id, authorize?: false).name == "Ada Lovelace"
  end

  test "invalid profile fields keep explicit error associations and focus hook", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/account")

    assert has_element?(view, "#profile-name-form[phx-hook=FocusInvalid]")
    assert has_element?(view, "#profile-email-form[phx-hook=FocusInvalid]")

    view
    |> form("#profile-name-form", user: %{name: String.duplicate("x", 121)})
    |> render_submit()

    assert has_element?(view, "#profile-name[aria-invalid=true]")
    assert has_element?(view, "#profile-name[aria-describedby=profile-name-error]")
    assert has_element?(view, "#profile-name-error")
  end

  test "submitting the email form shows a check-your-inbox notice and never changes the login email",
       %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/account")

    new_email = unique_email()

    html =
      view
      |> form("#profile-email-form", user: %{email: new_email})
      |> render_submit()

    assert html =~ "Check your inbox"
    # The email shown (and the login identity) is still the old address.
    assert has_element?(view, "*", to_string(user.email))
    refute has_element?(view, "*", new_email)

    assert to_string(Ash.get!(Alplus.Accounts.User, user.id, authorize?: false).email) ==
             to_string(user.email)
  end

  test "the sidebar account link marks this page as current and offers a way back", %{conn: conn} do
    owner = user_fixture()
    {_org, _scope} = org_fixture(Alplus.Scope.for_user(owner.id), %{name: "Org A"})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(~p"/dashboard/account")

    assert has_element?(view, "#desktop-nav-account[aria-current=page]")
    assert has_element?(view, "#desktop-nav-all-orgs", "All organizations")
    assert has_element?(view, "#desktop-nav-organization-list", "Org A")
  end

  test "an account with no organization still renders", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/account")

    assert has_element?(view, "#profile-name-form")
    assert has_element?(view, "#desktop-nav-organization-list", "None yet.")
  end
end
