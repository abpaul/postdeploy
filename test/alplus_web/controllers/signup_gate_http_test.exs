defmodule AlplusWeb.SignupGateHttpTest do
  use AlplusWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:alplus, :signups_enabled?)
    on_exit(fn -> Application.put_env(:alplus, :signups_enabled?, original) end)
    :ok
  end

  test "POST /auth/user/password/register fails with a clear error when signups are disabled",
       %{conn: conn} do
    Application.put_env(:alplus, :signups_enabled?, false)

    conn =
      post(conn, "/auth/user/password/register", %{
        "user" => %{
          "email" => "blocked-#{System.unique_integer([:positive])}@example.com",
          "password" => "a-str0ng-passphrase",
          "password_confirmation" => "a-str0ng-passphrase",
          "turnstile_token" => "test-token"
        }
      })

    assert redirected_to(conn) == "/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-ups are currently disabled"
  end
end
