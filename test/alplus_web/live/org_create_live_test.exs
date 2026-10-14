defmodule AlplusWeb.OrgCreateLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Orgs.Membership
  alias Alplus.Orgs.Organization

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "creating an org makes the creator its owner and lands on its project list", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/orgs/new")

    view
    |> form("#new-org-form", organization: %{name: "Launch Org"})
    |> render_submit()

    assert %Organization{id: org_id, public_token: public_token} =
             Ash.read_one!(
               Ash.Query.filter(Organization, name == "Launch Org"),
               authorize?: false
             )

    assert_redirect(view, ~p"/dashboard/orgs/#{public_token}/projects")

    assert {:ok, %Membership{role: "owner"}} =
             Membership
             |> Ash.Query.filter(org_id == ^org_id and user_id == ^user.id)
             |> Ash.read_one(authorize?: false)
  end

  test "a trial user who already owns an org sees the limit in place", %{conn: conn} do
    user = user_fixture()
    {_org, _scope} = org_fixture(Alplus.Scope.for_user(user.id))

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/orgs/new")

    assert has_element?(view, "#org-limit-notice", "one organization")
    refute has_element?(view, "#new-org-form")
  end

  test "a user who owns a paid org can still create another", %{conn: conn} do
    user = user_fixture()
    {org, _scope} = org_fixture(Alplus.Scope.for_user(user.id))
    subscribed_fixture(org)

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/orgs/new")

    assert has_element?(view, "#new-org-form")
  end

  test "invalid params re-render the form with errors instead of crashing", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard/orgs/new")

    html =
      view
      |> form("#new-org-form", organization: %{name: ""})
      |> render_submit()

    assert html =~ "is required"
  end
end
