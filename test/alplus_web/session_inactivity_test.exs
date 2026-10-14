defmodule AlplusWeb.SessionInactivityTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.OrgsFixtures

  alias AshAuthentication.Plug.Helpers

  test "an inactive browser session revokes its stored authentication token", %{conn: conn} do
    user = user_fixture()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user_with_token = Ash.Resource.put_metadata(user, :token, token)

    expired_conn =
      conn
      |> Plug.Test.init_test_session(%{
        last_seen_at: System.system_time(:second) - 8 * 24 * 60 * 60
      })
      |> Helpers.store_in_session(user_with_token)
      |> get("/")

    refute expired_conn.assigns[:current_user]

    replayed_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{last_seen_at: System.system_time(:second)})
      |> Helpers.store_in_session(user_with_token)
      |> get("/")

    refute replayed_conn.assigns[:current_user]
  end
end
