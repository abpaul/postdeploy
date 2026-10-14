defmodule AlplusWeb.SignInLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # `/sign-in` had no way back to `/register` — this pins the fix. The link
  # lives in `Layouts.auth_live`'s header row (`AlplusWeb.AuthPageTitle`'s
  # `:sign_in` on_mount hook supplies its text and path), not in a
  # `sign_in_extra_component` override: `register_path` would shadow
  # `AlplusWeb.RegisterLive`'s Turnstile-aware route, and
  # `register_toggle_text` alone renders a same-page form that can't
  # collect a Turnstile token.
  test "links to /register for a visitor with no account", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sign-in")

    assert html =~ "New here?"
    assert has_element?(view, ~s(a[href="/register"]), "Create an account")
  end

  test "uses one focusable main landmark for the auth shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    assert has_element?(view, ~s(main#auth-main[tabindex="-1"]))
    refute has_element?(view, "main#auth-main main")
  end

  test "marks identity and password fields for sign-in autofill", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    assert has_element?(view, ~s(input[autocomplete="username"]))
    assert has_element?(view, ~s(input[type="password"][autocomplete="current-password"]))
  end

  test "renders a Turnstile challenge for sign-in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    assert has_element?(view, ~s([phx-hook="AuthTurnstile"]))
    assert has_element?(view, ~s(input[id$="-turnstile-token"]))
  end

  test "password reset verification errors stay visible and allow retry", %{conn: conn} do
    Req.Test.stub(Alplus.Turnstile.Client, fn request ->
      {:ok, body, request} = Plug.Conn.read_body(request)
      Req.Test.json(request, %{"success" => URI.decode_query(body)["response"] == "fresh-token"})
    end)

    {:ok, view, _html} = live(conn, "/reset")
    selector = "#user-password-request-password-reset-token"

    view
    |> form(selector, %{"user" => %{"email" => "unknown@example.com"}})
    |> render_submit(%{"user" => %{"turnstile_token" => "bad-token"}})

    assert has_element?(view, "#reset-request-error[role=alert]")
    refute render(view) =~ "we&#39;ll send a password reset link"

    assert [] =
             Oban.Testing.all_enqueued(
               repo: Alplus.Repo,
               worker: Alplus.Mailer.Worker,
               args: %{"purpose" => "password_reset"}
             )

    view
    |> form(selector, %{"user" => %{"email" => "unknown@example.com"}})
    |> render_submit(%{"user" => %{"turnstile_token" => "fresh-token"}})

    refute has_element?(view, "#reset-request-error")
    assert render(view) =~ "If an account uses this email"
  end
end
