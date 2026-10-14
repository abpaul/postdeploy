defmodule AlplusWeb.ConfirmEmailBannerTest do
  @moduledoc """
  The dashboard-wide "Confirm your email" banner (onboarding overhaul
  decision #1): a dismissible nudge, never a gate. Driven through
  `AlplusWeb.DashboardLive` (any `dashboard_shell/1` page would do — the
  banner is a `Phoenix.LiveComponent`, not a per-page concern).
  """

  use AlplusWeb.ConnCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  alias Alplus.Mailer.Worker

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "is absent for a confirmed user", %{conn: conn} do
    user = user_fixture(%{confirmed: true})

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard")

    refute has_element?(view, "#confirm-email-banner-content")
  end

  test "resends the confirmation email and can be dismissed", %{conn: conn} do
    user = user_fixture(%{confirmed: false})

    {:ok, view, _html} =
      conn
      |> log_in(user)
      |> live(~p"/dashboard")

    assert has_element?(view, "#confirm-email-banner-content")

    view
    |> element("#confirm-email-resend")
    |> render_click()

    assert length(all_enqueued(worker: Worker, args: %{"user_id" => user.id})) == 2
    assert has_element?(view, "#confirm-email-notice", "Confirmation email sent")
    assert has_element?(view, "#confirm-email-banner-content")

    view
    |> element("#confirm-email-dismiss")
    |> render_click()

    refute has_element?(view, "#confirm-email-banner-content")
  end
end
