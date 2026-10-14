defmodule AlplusWeb.AdminObservabilityTest do
  use AlplusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Scope
  alias AlplusWeb.Admin.HomeLive

  setup do
    original = Application.get_env(:alplus, :founder_emails, [])
    Application.put_env(:alplus, :founder_emails, ["founder@example.com"])

    on_exit(fn -> Application.put_env(:alplus, :founder_emails, original) end)
    :ok
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "a confirmed founder can inspect overview, organization, and user details", %{conn: conn} do
    founder = user_fixture(%{email: "founder@example.com"})
    {org, _scope} = org_fixture(Scope.for_user(founder.id))

    {:ok, view, html} = conn |> log_in(founder) |> live(~p"/admin")

    assert html =~ "Internal observability"
    render_async(view)
    assert has_element?(view, "#admin-signups")
    assert has_element?(view, "a", "System metrics")

    view
    |> render_patch(~p"/admin?view=organizations&window=30d")

    render_async(view)
    assert has_element?(view, "#admin-org-#{org.id}")
    assert has_element?(view, "#admin-org-#{org.id}", org.name)
    assert render(view) =~ "founder@example.com"

    view
    |> render_patch(~p"/admin?view=users&window=30d")

    render_async(view)
    assert has_element?(view, "#admin-user-#{founder.id}")
    assert has_element?(view, "#admin-user-#{founder.id}", "founder@example.com")
    assert has_element?(view, "#admin-user-#{founder.id}", "Confirmed")
  end

  test "a detail load error hides rows retained from the previous window" do
    socket = %Phoenix.LiveView.Socket{
      router: AlplusWeb.Router,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)

    socket =
      socket
      |> Phoenix.LiveView.stream(:organizations, [%{id: "stale"}])
      |> Phoenix.Component.assign(
        view: "organizations",
        loading: false,
        load_error: "Product data could not be loaded."
      )

    html =
      socket.assigns
      |> HomeLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ ~s(id="admin-load-error")
    refute html =~ ~s(id="admin-organization-details")
    refute html =~ ~s(id="admin-org-stale")
  end

  test "a confirmed founder can open LiveDashboard", %{conn: conn} do
    founder = user_fixture(%{email: "founder@example.com"})

    conn = log_in(conn, founder)

    assert {:error, {:live_redirect, %{to: "/admin/system/home"}}} = live(conn, ~p"/admin/system")

    {:ok, _view, html} = live(conn, ~p"/admin/system/home")

    assert html =~ "LiveDashboard"
  end

  test "a confirmed non-founder receives 404", %{conn: conn} do
    member = user_fixture(%{email: "member@example.com"})

    response = conn |> log_in(member) |> get(~p"/admin")

    assert response.status == 404
  end

  test "an unconfirmed founder receives 404", %{conn: conn} do
    founder = user_fixture(%{email: "founder@example.com", confirmed: false})

    response = conn |> log_in(founder) |> get(~p"/admin")

    assert response.status == 404
  end

  test "a signed-out visitor receives 404", %{conn: conn} do
    response = get(conn, ~p"/admin")

    assert response.status == 404
  end
end
