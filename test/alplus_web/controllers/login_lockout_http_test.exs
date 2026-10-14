defmodule AlplusWeb.LoginLockoutHttpTest do
  # Shares the global login-lockout ETS table and posts to the same
  # sign-in endpoint, so this file runs alone.
  use AlplusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Alplus.Accounts.LoginLockout

  @password "a-str0ng-passphrase"

  setup do
    email = "http-lockout-#{System.unique_integer([:positive])}@example.com"

    user =
      Ash.create!(
        Alplus.Accounts.User,
        %{
          email: email,
          password: @password,
          password_confirmation: @password,
          turnstile_token: "test-token"
        },
        action: :register_with_password,
        authorize?: false
      )

    ip = "198.51.100.#{rem(System.unique_integer([:positive]), 254) + 1}"

    on_exit(fn ->
      LoginLockout.clear({:email, email})
      LoginLockout.clear({:ip, ip})
    end)

    %{user: user, email: email, ip: ip}
  end

  defp sign_in(conn, ip, email, password) do
    conn
    |> Map.put(:remote_ip, ip_tuple(ip))
    |> post("/auth/user/password/sign_in", %{
      "user" => %{"email" => email, "password" => password, "turnstile_token" => "test-token"}
    })
  end

  defp sign_in_through_cloudflare(conn, socket_ip, visitor_ip, email, password) do
    conn
    |> Map.put(:remote_ip, ip_tuple(socket_ip))
    |> put_req_header("cf-connecting-ip", visitor_ip)
    |> put_private(:phoenix_recycled, true)
    |> post("/auth/user/password/sign_in", %{
      "user" => %{"email" => email, "password" => password, "turnstile_token" => "test-token"}
    })
  end

  defp ip_tuple(ip) do
    ip |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end

  test "wrong password redirects with an error and is not signed in", %{
    conn: conn,
    email: email,
    ip: ip
  } do
    conn = sign_in(conn, ip, email, "totally-wrong")

    assert redirected_to(conn) == "/sign-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Email or password is incorrect. Check both, or reset your password."
  end

  test "locks out after 10 failed attempts, then blocks a correct password", %{
    email: email,
    ip: ip
  } do
    for _ <- 1..10, do: sign_in(build_conn(), ip, email, "totally-wrong")

    # The 11th attempt uses the *correct* password but the identity is
    # already locked, so it must still be rejected — and rejected before
    # bcrypt ever runs.
    conn = sign_in(build_conn(), ip, email, @password)

    assert redirected_to(conn) == "/sign-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Too many failed sign-in attempts"
  end

  test "a successful sign-in clears the failure counter", %{email: email, ip: ip} do
    for _ <- 1..5 do
      sign_in(build_conn(), ip, email, "totally-wrong")
    end

    conn = sign_in(build_conn(), ip, email, @password)
    assert redirected_to(conn) == "/dashboard"

    {:ok, dashboard_view, _html} = live(conn, "/dashboard")
    assert has_element?(dashboard_view, "#activation-email-verification")

    refute LoginLockout.locked?({:email, email})
    refute LoginLockout.locked?({:ip, ip})
  end

  test "visitors behind one proxy socket get independent IP lockout buckets", %{
    email: email_a,
    ip: ip_a
  } do
    email_b = "http-lockout-#{System.unique_integer([:positive])}@example.com"
    password = @password

    Ash.create!(
      Alplus.Accounts.User,
      %{
        email: email_b,
        password: password,
        password_confirmation: password,
        turnstile_token: "test-token"
      },
      action: :register_with_password,
      authorize?: false
    )

    ip_b = "198.51.100.#{rem(System.unique_integer([:positive]), 254) + 1}"
    socket_ip = "10.0.0.7"

    on_exit(fn ->
      LoginLockout.clear({:email, email_b})
      LoginLockout.clear({:ip, ip_b})
    end)

    for _ <- 1..10 do
      sign_in_through_cloudflare(build_conn(), socket_ip, ip_a, email_a, "totally-wrong")
    end

    for _ <- 1..9 do
      sign_in_through_cloudflare(build_conn(), socket_ip, ip_b, email_b, "totally-wrong")
    end

    blocked = sign_in_through_cloudflare(build_conn(), socket_ip, ip_a, email_a, password)
    allowed = sign_in_through_cloudflare(build_conn(), socket_ip, ip_b, email_b, password)

    assert redirected_to(blocked) == "/sign-in"

    assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~
             "Too many failed sign-in attempts"

    assert redirected_to(allowed) == "/dashboard"

    {:ok, dashboard_view, _html} = live(allowed, "/dashboard")
    assert has_element?(dashboard_view, "#activation-email-verification")
  end

  test "malformed user parameters fail closed through the HTTP pipeline", %{conn: conn} do
    Req.Test.stub(Alplus.Turnstile.Client, fn _ -> flunk("Do not verify malformed requests") end)
    conn = post(conn, "/auth/user/password/sign_in", %{"user" => "invalid"})
    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user") == nil
  end

  test "valid credentials cannot sign in with a failed challenge", %{conn: conn, email: email} do
    Req.Test.stub(Alplus.Turnstile.Client, fn request ->
      Req.Test.json(request, %{"success" => false})
    end)

    conn =
      post(conn, "/auth/user/password/sign_in", %{
        "user" => %{
          "email" => email,
          "password" => @password,
          "turnstile_token" => "invalid-token"
        }
      })

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, "user") == nil
    refute LoginLockout.locked?({:email, email})
  end
end
