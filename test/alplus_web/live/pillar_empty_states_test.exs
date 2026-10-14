defmodule AlplusWeb.PillarEmptyStatesTest do
  @moduledoc """
  Observe, Measure, Monitor, and Billing have no data model yet
  (BUILD.md Phase 5 step 2) — these pages only hold the empty state and
  the nav slot. Any org member may view them (no mutation happens here),
  so the only behavior worth asserting is tenant isolation and that the
  empty state renders.
  """

  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The org in these tests has no project. Billing is org-scoped and always
  # shows the package summary; Observe/Measure/Monitor are project-scoped
  # pillars, which now bounce a project-less visit back to the Overview hub
  # instead of duplicating a "create a project first" dead end on every
  # pillar (onboarding overhaul §5, `AlplusWeb.OrgContext
  # .redirect_if_no_projects/4`).
  for {pillar, path} <- [{"Observe", "observe"}, {"Measure", "measure"}, {"Monitor", "monitor"}] do
    describe "#{pillar} empty state" do
      test "a project-less visit redirects to the Overview hub", %{conn: conn} do
        owner = user_fixture()
        {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
        member_user = user_fixture()
        member_fixture(owner_scope, org, member_user, "member")

        conn = log_in(conn, member_user)

        assert {:error, {:live_redirect, %{to: to}}} =
                 live(conn, "/dashboard/orgs/#{org.id}/#{unquote(path)}")

        assert to == "/dashboard/orgs/#{org.public_token}/projects"
      end

      test "a cross-tenant org id renders 404", %{conn: conn} do
        owner = user_fixture()
        {_org_a, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

        other_owner = user_fixture()
        {org_b, _other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))

        conn = log_in(conn, owner)

        assert_error_sent 404, fn ->
          live(conn, "/dashboard/orgs/#{org_b.id}/#{unquote(path)}")
        end
      end
    end
  end

  describe "Billing empty state" do
    test "renders the empty state for a member", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      {:ok, view, _html} =
        conn
        |> log_in(member_user)
        |> live("/dashboard/orgs/#{org.id}/billing")

      assert has_element?(view, "#billing-package")
    end

    test "a cross-tenant org id renders 404", %{conn: conn} do
      owner = user_fixture()
      {_org_a, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      other_owner = user_fixture()
      {org_b, _other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))

      conn = log_in(conn, owner)

      assert_error_sent 404, fn ->
        live(conn, "/dashboard/orgs/#{org_b.id}/billing")
      end
    end
  end
end
