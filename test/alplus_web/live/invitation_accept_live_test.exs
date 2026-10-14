defmodule AlplusWeb.InvitationAcceptLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Orgs.Membership

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp accept_path(token), do: ~p"/invitations/#{token}"

  describe "signed in, email matches" do
    test "shows the org name and role, and accepting creates the membership", %{conn: conn} do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {_invitation, token} = invitation_fixture(owner_scope, org, %{role: "admin", email: email})

      {:ok, view, _html} =
        conn
        |> log_in(invitee_user)
        |> live(accept_path(token))

      assert has_element?(view, "#invitation-details", org.name)
      assert has_element?(view, "#invitation-details", "admin")
      assert has_element?(view, "#invitation-accept-btn")

      {:error, {:live_redirect, %{to: redirect_to}}} =
        view |> element("#invitation-accept-btn") |> render_click()

      assert redirect_to == ~p"/dashboard/orgs/#{org.public_token}/projects"

      assert Membership
             |> Ash.Query.filter(org_id == ^org.id and user_id == ^invitee_user.id)
             |> Ash.exists?(actor: owner_scope)
    end
  end

  describe "signed in, email does not match" do
    test "refuses and offers no accept action", %{conn: conn} do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      {_invitation, token} =
        invitation_fixture(owner_scope, org, %{email: "intended@example.com"})

      other_user = user_fixture(%{email: "someone-else@example.com"})

      {:ok, view, _html} =
        conn
        |> log_in(other_user)
        |> live(accept_path(token))

      assert has_element?(view, "#invitation-email-mismatch")
      refute has_element?(view, "#invitation-accept-btn")

      render_click(view, "accept", %{})

      refute Membership
             |> Ash.Query.filter(org_id == ^org.id and user_id == ^other_user.id)
             |> Ash.exists?(actor: owner_scope)
    end
  end

  describe "not signed in" do
    test "offers sign-in and register links, no accept action, and stashes return_to", %{
      conn: conn
    } do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      {_invitation, token} = invitation_fixture(owner_scope, org)

      conn = Plug.Test.init_test_session(conn, %{})
      {:ok, view, _html} = live(conn, accept_path(token))

      assert has_element?(view, "#invitation-sign-in-link")
      assert has_element?(view, "#invitation-register-link")
      refute has_element?(view, "#invitation-accept-btn")
    end

    test "token-bearing invitation HTML is noindex and has no canonical", %{conn: conn} do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      {_invitation, token} = invitation_fixture(owner_scope, org)

      {:ok, _view, html} = live(conn, accept_path(token))
      document = LazyHTML.from_document(html)

      assert LazyHTML.attribute(LazyHTML.query(document, ~s(meta[name="robots"])), "content") ==
               ["noindex,nofollow"]

      assert document |> LazyHTML.query(~s(link[rel="canonical"])) |> Enum.empty?()
    end

    test "the emailed link's path is stashed as return_to for the sign-in round trip", %{
      conn: conn
    } do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      {_invitation, token} = invitation_fixture(owner_scope, org)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get(accept_path(token))

      assert Plug.Conn.get_session(conn, :return_to) == accept_path(token)
    end
  end

  describe "terminal invitations" do
    test "an expired invitation shows its own message and no accept action", %{conn: conn} do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {invitation, token} = invitation_fixture(owner_scope, org, %{email: email})

      import Ecto.Query

      Alplus.Repo.update_all(
        from(i in "invitations", where: i.id == ^invitation.id),
        set: [
          inserted_at: DateTime.add(DateTime.utc_now(), -8, :day),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        ]
      )

      {:ok, view, _html} =
        conn
        |> log_in(invitee_user)
        |> live(accept_path(token))

      assert has_element?(view, "#invitation-message-expired")
      refute has_element?(view, "#invitation-accept-btn")
    end

    test "a revoked invitation shows its own message and no accept action", %{conn: conn} do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {invitation, token} = invitation_fixture(owner_scope, org, %{email: email})
      Ash.update!(invitation, %{}, action: :revoke, actor: owner_scope)

      {:ok, view, _html} =
        conn
        |> log_in(invitee_user)
        |> live(accept_path(token))

      assert has_element?(view, "#invitation-message-revoked")
      refute has_element?(view, "#invitation-accept-btn")
    end

    test "an already-accepted invitation shows its own message and no accept action", %{
      conn: conn
    } do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {_invitation, token} = invitation_fixture(owner_scope, org, %{email: email})

      invitee_scope = Alplus.Scope.for_user(invitee_user.id)
      assert {:ok, _} = Alplus.Orgs.accept_invitation(invitee_scope, token)

      {:ok, view, _html} =
        conn
        |> log_in(invitee_user)
        |> live(accept_path(token))

      assert has_element?(view, "#invitation-message-accepted")
      refute has_element?(view, "#invitation-accept-btn")
    end
  end

  describe "unknown token" do
    test "renders a 404", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{})

      assert_error_sent 404, fn ->
        live(conn, accept_path("not-a-real-token"))
      end
    end
  end
end
