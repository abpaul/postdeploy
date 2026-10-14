defmodule AlplusWeb.TeamLiveTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Orgs.{Invitation, Membership}
  alias Phoenix.LiveView.LiveStream

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp team_path(org), do: ~p"/dashboard/orgs/#{org.id}/team"

  describe "tenant isolation" do
    test "a cross-tenant org id renders 404", %{conn: conn} do
      owner = user_fixture()
      {_org_a, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      other_owner = user_fixture()
      {org_b, _other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))

      conn = log_in(conn, owner)

      assert_error_sent 404, fn ->
        live(conn, team_path(org_b))
      end
    end

    test "direct member and invitation events cannot target another organization", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      foreign_owner = user_fixture()
      {foreign_org, foreign_scope} = org_fixture(Alplus.Scope.for_user(foreign_owner.id))
      foreign_member_user = user_fixture()
      foreign_member = member_fixture_with_row(foreign_scope, foreign_org, foreign_member_user)
      {foreign_invitation, _token} = invitation_fixture(foreign_scope, foreign_org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      render_change(view, "change_role", %{
        "membership_id" => foreign_member.id,
        "role" => "admin"
      })

      render_click(view, "confirm_remove", %{"id" => foreign_member.id})

      render_click(view, "resend_invitation", %{"id" => foreign_invitation.id})
      render_click(view, "revoke_invitation", %{"id" => foreign_invitation.id})

      assert {:ok, %{role: "member"}} =
               Ash.get(Membership, foreign_member.id, actor: foreign_scope)

      assert {:ok, %{status: "pending"}} =
               Ash.get(Alplus.Orgs.Invitation, foreign_invitation.id, actor: foreign_scope)

      refute has_element?(view, "#member-remove-#{foreign_member.id}-confirm")
      assert render(view) =~ "not available in this organization"

      _ = owner_scope
    end

    test "an org owner cannot forge the invite org_id", %{conn: conn} do
      owner = user_fixture()
      {current_org, current_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      {foreign_org, foreign_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      subscribed_fixture(current_org)
      subscribed_fixture(foreign_org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(current_org))

      render_submit(view, "invite", %{
        "invitation" => %{
          "org_id" => foreign_org.id,
          "email" => "forged-org@example.com",
          "role" => "member"
        }
      })

      assert [%Invitation{org_id: current_org_id, email: "forged-org@example.com"}] =
               Alplus.Orgs.list_invitations_for_org!(current_org.id, actor: current_scope)

      assert [] =
               Alplus.Orgs.list_invitations_for_org!(foreign_org.id, actor: foreign_scope)

      assert current_org_id == current_org.id
    end
  end

  describe "seat capacity and delivery copy" do
    test "capacity fails before creating an invitation", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      subscribed_fixture(org)
      for _ <- 1..4, do: member_fixture(owner_scope, org, user_fixture())

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      view |> element("#invite-toggle") |> render_click()

      view
      |> form("#invite-form", invitation: %{email: "capacity@example.com", role: "member"})
      |> render_submit()

      refute Enum.any?(
               Alplus.Orgs.list_invitations_for_org!(org.id, actor: owner_scope),
               &(&1.email == "capacity@example.com")
             )

      html = render(view)
      assert html =~ "all seats are taken"
      assert html =~ "The invitation was not created"
      refute html =~ "email service accepted the handoff"
    end

    test "invite feedback names the address and the pending state", %{conn: conn} do
      owner = user_fixture()
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      subscribed_fixture(org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      view |> element("#invite-toggle") |> render_click()

      view
      |> form("#invite-form", invitation: %{email: "handoff@example.com", role: "member"})
      |> render_submit()

      html = render(view)
      assert html =~ "Invitation sent to handoff@example.com"
      assert html =~ "pending until accepted"
      refute html =~ "delivered successfully"
    end

    test "resend fails before regenerating a token when capacity is full", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      {invitation, _token} = invitation_fixture(owner_scope, org)
      # Over capacity: the owner, this invitation, and four members.
      for _ <- 1..4, do: member_fixture(owner_scope, org, user_fixture())

      old_hash = invitation.token_hash
      old_expires_at = invitation.expires_at

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      view |> element("#invitation-resend-#{invitation.id}") |> render_click()

      assert {:ok, %Invitation{token_hash: ^old_hash, expires_at: ^old_expires_at}} =
               Ash.get(Invitation, invitation.id, actor: owner_scope)

      html = render(view)
      assert html =~ "Could not resend that invitation"
      refute html =~ "email service accepted the handoff"
    end

    test "an unconfirmed owner cannot resend an invitation", %{conn: conn} do
      owner = user_fixture(%{confirmed: false})
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      {invitation, _token} = invitation_fixture(owner_scope, org)

      old_hash = invitation.token_hash
      old_expires_at = invitation.expires_at

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      render_click(view, "resend_invitation", %{"id" => invitation.id})

      assert {:ok, %Invitation{token_hash: ^old_hash, expires_at: ^old_expires_at}} =
               Ash.get(Invitation, invitation.id, actor: owner_scope)

      assert render(view) =~ "Confirm your email address to invite teammates."
      refute render(view) =~ "email service accepted the handoff"
    end
  end

  describe "responsive rows and timestamps" do
    test "mobile member and invitation summaries retain identity, role, status, times, and actions",
         %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      member_user = user_fixture(%{email: "mobile-member@example.com"})
      member = member_fixture_with_row(owner_scope, org, member_user)

      {invitation, _token} =
        invitation_fixture(owner_scope, org, %{
          email: "mobile-invite@example.com",
          role: "admin"
        })

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      member_mobile = render(element(view, "#member-mobile-summary-#{member.id}"))
      assert member_mobile =~ "mobile-member@example.com"
      assert member_mobile =~ "member"
      assert member_mobile =~ "Joined"
      assert member_mobile =~ "Remove"
      assert member_mobile =~ "Make owner"
      assert member_mobile =~ "sm:hidden"

      invitation_mobile = render(element(view, "#invitation-mobile-summary-#{invitation.id}"))
      assert invitation_mobile =~ "mobile-invite@example.com"
      assert invitation_mobile =~ "admin"
      assert invitation_mobile =~ "pending"
      assert invitation_mobile =~ "Resend"
      assert invitation_mobile =~ "Revoke"
      assert invitation_mobile =~ "sm:hidden"

      assert render(element(view, "#member-role-#{member.id}")) =~ "sm:table-cell"
      assert render(element(view, "#invitation-role-#{invitation.id}")) =~ "sm:table-cell"
      assert render(view) =~ ~s(datetime="#{DateTime.to_iso8601(member.inserted_at)}")
      assert render(view) =~ ~s(datetime="#{DateTime.to_iso8601(invitation.inserted_at)}")
      assert render(view) =~ ~s(datetime="#{DateTime.to_iso8601(invitation.expires_at)}")
    end

    test "team rows opt into dense density and canonical row sizing", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
      member = member_fixture_with_row(owner_scope, org, user_fixture())
      {invitation, _token} = invitation_fixture(owner_scope, org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      assert has_element?(view, "#members-panel [data-density=dense]")
      assert has_element?(view, "#invitations-panel [data-density=dense]")
      assert has_element?(view, "#member-email-#{member.id}.min-h-row")
      assert has_element?(view, "#invitation-email-#{invitation.id}.min-h-row")
    end

    test "an empty invitation list is explicit and keeps members visible", %{conn: conn} do
      owner = user_fixture()
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      assert has_element?(view, "#invitations-panel")
      assert has_element?(view, "#invitations-empty")
      assert has_element?(view, "#members-table")
      assert render(view) =~ "No pending invitations"
    end
  end

  describe "render states" do
    test "members expose loading, empty, and error states" do
      streams = %{
        members: consumable_stream(:members),
        invitations: consumable_stream(:invitations)
      }

      base = %{
        flash: %{},
        agent_connected?: false,
        org: %{id: "org-1", public_token: "org-1", name: "Example"},
        organizations: [],
        nav_projects: [],
        scope: %Alplus.Scope{org_id: "org-1", role: "owner", user_id: "user-1"},
        current_user: nil,
        invite_form: nil,
        show_invite: false,
        remove_confirm_id: nil,
        remove_confirm_text: "",
        transfer_confirm_id: nil,
        transfer_confirm_text: "",
        member_total: nil,
        admin_count: nil,
        plain_member_count: nil,
        pending_invitations_count: nil,
        members_error: nil,
        members_empty?: false,
        invitations_state: :hidden,
        invitations_error: nil,
        invitations_empty?: true,
        invite_error: nil,
        streams: streams
      }

      loading =
        base
        |> Map.put(:members_state, :loading)
        |> AlplusWeb.TeamLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert loading =~ ~s(id="members-loading")
      assert loading =~ "Loading team access."

      empty =
        base
        |> Map.merge(%{members_state: :ready, members_empty?: true})
        |> AlplusWeb.TeamLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert empty =~ ~s(id="members-empty")

      error =
        base
        |> Map.merge(%{members_state: :error, members_error: "Members unavailable"})
        |> AlplusWeb.TeamLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert error =~ ~s(id="members-error")
      assert error =~ "Members unavailable"
      assert error =~ ~s(phx-click="retry_team")
    end
  end

  describe "direct invariant events" do
    test "self role changes and last-owner removal remain rejected", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      [owner_membership] =
        Alplus.Orgs.list_memberships_for_org!(org.id,
          actor: owner_scope,
          query: Ash.Query.filter(Membership, user_id == ^owner.id)
        )

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      render_change(view, "change_role", %{
        "membership_id" => owner_membership.id,
        "role" => "member"
      })

      assert render(view) =~ "cannot change your own role"

      render_click(view, "remove", %{
        "id" => owner_membership.id,
        "confirm_text" => owner.email
      })

      assert {:ok, %{role: "owner"}} =
               Ash.get(Membership, owner_membership.id, actor: owner_scope)
    end

    test "malformed authority events return feedback instead of crashing", %{conn: conn} do
      owner = user_fixture()
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      render_click(view, "invite", %{})
      render_click(view, "confirm_transfer_ownership", %{})
      render_click(view, "transfer_ownership", %{})
      render_click(view, "confirm_remove", %{})

      assert render(view) =~ "Choose a member"
    end
  end

  describe "role-correct UI" do
    test "a member sees no invite form, no role control, and no remove/transfer buttons", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      member_user = user_fixture()
      member_scope = member_fixture(owner_scope, org, member_user, "member")

      {:ok, view, html} =
        conn
        |> log_in(member_user)
        |> live(team_path(org))

      refute has_element?(view, "#invite-form")
      refute has_element?(view, "#invitations")
      assert html =~ owner.email |> to_string()

      [owner_membership] =
        Alplus.Orgs.list_memberships_for_org!(org.id,
          actor: owner_scope,
          query: Ash.Query.filter(Membership, user_id == ^member_scope.user_id)
        )

      refute has_element?(view, "#member-remove-#{owner_membership.id}-trigger")
      refute has_element?(view, "#member-transfer-#{owner_membership.id}-trigger")
      refute has_element?(view, "#role-select-#{owner_membership.id}")
    end

    test "a member cannot invite by sending the event directly", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      {:ok, view, _html} =
        conn
        |> log_in(member_user)
        |> live(team_path(org))

      render_submit(view, "invite", %{"invitation" => %{"email" => "sneaky@example.com"}})

      invitations = Alplus.Orgs.list_invitations_for_org!(org.id, actor: owner_scope)
      refute Enum.any?(invitations, &(&1.email == "sneaky@example.com"))
    end

    test "a member cannot change a role or remove a member by sending the event directly", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      other_user = user_fixture()
      other_membership = %{id: other_membership_id} = add_admin(owner_scope, org, other_user)

      {:ok, view, _html} =
        conn
        |> log_in(member_user)
        |> live(team_path(org))

      render_change(view, "change_role", %{
        "membership_id" => other_membership_id,
        "role" => "member"
      })

      assert {:ok, %{role: "admin"}} =
               Ash.get(Membership, other_membership_id, actor: owner_scope)

      # Correct typed confirmation (the target's own email) still must not
      # bypass the Ash destroy policy — a plain `member` has no manage rights.
      render_click(view, "remove", %{
        "id" => other_membership_id,
        "confirm_text" => other_user.email
      })

      assert {:ok, _} = Ash.get(Membership, other_membership_id, actor: owner_scope)

      _ = other_membership
    end

    test "an admin sees invite/remove/role controls but not the transfer-ownership control", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      admin_user = user_fixture()
      admin_fixture(owner_scope, org, admin_user)

      member_user = user_fixture()
      member_membership = member_fixture_with_row(owner_scope, org, member_user)

      {:ok, view, _html} =
        conn
        |> log_in(admin_user)
        |> live(team_path(org))

      view |> element("#invite-toggle") |> render_click()
      assert has_element?(view, "#invite-form")
      assert has_element?(view, "#member-remove-#{member_membership.id}-trigger")
      assert has_element?(view, "#role-select-#{member_membership.id}")
      refute has_element?(view, "#member-transfer-#{member_membership.id}-trigger")

      # Correct typed confirmation still must not bypass the Ash policy — an
      # `admin` never transfers ownership, only the current `owner` can.
      render_click(view, "transfer_ownership", %{
        "id" => member_membership.id,
        "confirm_text" => member_user.email
      })

      assert {:ok, %{role: "member"}} =
               Ash.get(Membership, member_membership.id, actor: owner_scope)
    end
  end

  describe "as an owner" do
    test "invite, resend, and revoke show email/role/status, never the raw token", %{
      conn: conn
    } do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      # Created independently (not through the view) so the test holds the
      # raw token itself, to assert it never leaks into any TeamLive render
      # below — the view's own invite/resend calls return a token too, but
      # only the LiveView process ever sees it.
      {out_of_band, out_of_band_token} = invitation_fixture(owner_scope, org)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      refute render(view) =~ out_of_band_token

      view |> element("#invite-toggle") |> render_click()

      view
      |> form("#invite-form", invitation: %{email: "new@example.com", role: "member"})
      |> render_submit()

      html = render(view)
      assert html =~ "new@example.com"
      assert html =~ "member"
      refute html =~ out_of_band_token

      invitation =
        Alplus.Orgs.list_invitations_for_org!(org.id, actor: owner_scope)
        |> Enum.find(&(&1.email == "new@example.com"))

      view |> element("#invitation-resend-#{invitation.id}") |> render_click()
      assert has_element?(view, "#invitation-status-#{invitation.id}", "pending")
      refute render(view) =~ out_of_band_token

      view |> element("#invitation-revoke-#{invitation.id}") |> render_click()
      refute has_element?(view, "#invitation-resend-#{invitation.id}")
      assert has_element?(view, "#invitation-status-#{invitation.id}", "revoked")
      refute render(view) =~ out_of_band_token

      _ = out_of_band
    end

    test "change role, remove a member, and transfer ownership all work", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      target_user = user_fixture()
      target_membership = member_fixture_with_row(owner_scope, org, target_user)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      render_change(view, "change_role", %{
        "membership_id" => target_membership.id,
        "role" => "admin"
      })

      assert {:ok, %{role: "admin"}} =
               Ash.get(Membership, target_membership.id, actor: owner_scope)

      view
      |> element("#member-transfer-#{target_membership.id}-trigger")
      |> render_click()

      assert has_element?(view, "#member-transfer-#{target_membership.id}-confirm")
      assert render(view) =~ "give up the owner role"

      render_change(view, "transfer_ownership_input", %{
        "id" => target_membership.id,
        "confirm_text" => target_user.email
      })

      view
      |> form("#member-transfer-#{target_membership.id}-form", %{
        "id" => target_membership.id,
        "confirm_text" => target_user.email
      })
      |> render_submit()

      assert {:ok, %{role: "owner"}} =
               Ash.get(Membership, target_membership.id, actor: owner_scope)

      owner_row =
        Alplus.Orgs.list_memberships_for_org!(org.id,
          actor: owner_scope,
          query: Ash.Query.filter(Membership, user_id == ^owner.id)
        )
        |> hd()

      assert owner_row.role == "admin"
    end

    test "removing a member requires typing their email and drops the row", %{conn: conn} do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      target_user = user_fixture()
      target_membership = member_fixture_with_row(owner_scope, org, target_user)

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      view
      |> element("#member-remove-#{target_membership.id}-trigger")
      |> render_click()

      assert has_element?(view, "#member-remove-#{target_membership.id}-confirm")
      assert render(view) =~ "immediately loses access"

      # the submit button stays disabled until the typed text matches, so a
      # mismatched attempt must not remove the row
      render_change(view, "remove_input", %{
        "id" => target_membership.id,
        "confirm_text" => "not the email"
      })

      view
      |> form("#member-remove-#{target_membership.id}-form", %{
        "id" => target_membership.id,
        "confirm_text" => "not the email"
      })
      |> render_submit()

      assert {:ok, _} = Ash.get(Membership, target_membership.id, actor: owner_scope)

      render_change(view, "remove_input", %{
        "id" => target_membership.id,
        "confirm_text" => target_user.email
      })

      view
      |> form("#member-remove-#{target_membership.id}-form", %{
        "id" => target_membership.id,
        "confirm_text" => target_user.email
      })
      |> render_submit()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Membership, target_membership.id, actor: owner_scope)

      refute has_element?(view, "#member-remove-#{target_membership.id}-trigger")
    end
  end

  describe "confirmation gate (onboarding overhaul decision #1)" do
    test "an unconfirmed owner sees no invite form, only the confirm-first notice", %{
      conn: conn
    } do
      owner = user_fixture(%{confirmed: false})
      {org, _owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      refute has_element?(view, "#invite-form")
      assert has_element?(view, "#invite-confirm-required")
    end

    test "an unconfirmed owner cannot invite by sending the event directly", %{conn: conn} do
      owner = user_fixture(%{confirmed: false})
      {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

      {:ok, view, _html} =
        conn
        |> log_in(owner)
        |> live(team_path(org))

      render_submit(view, "invite", %{
        "invitation" => %{"email" => "x@example.com", "role" => "member"}
      })

      assert render(view) =~ "Confirm your email address to invite teammates."
      refute Alplus.Orgs.list_invitations_for_org!(org.id, actor: owner_scope) != []
    end
  end

  test "validate invite and cancel confirm panels", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    target_user = user_fixture()
    target_membership = member_fixture_with_row(owner_scope, org, target_user)

    {:ok, view, _html} = conn |> log_in(owner) |> live(team_path(org))

    view |> element("#invite-toggle") |> render_click()

    view
    |> form("#invite-form", invitation: %{email: "new@example.com", role: "member"})
    |> render_change()

    view
    |> element("#member-transfer-#{target_membership.id}-trigger")
    |> render_click()

    render_click(view, "cancel_transfer_ownership", %{})
    refute has_element?(view, "#member-transfer-#{target_membership.id}-confirm")

    view
    |> element("#member-remove-#{target_membership.id}-trigger")
    |> render_click()

    render_click(view, "cancel_remove", %{})
    refute has_element?(view, "#member-remove-#{target_membership.id}-confirm")
  end

  defp add_admin(owner_scope, org, user) do
    subscribed_fixture(org)

    Ash.create!(Membership, %{org_id: org.id, user_id: user.id, role: "admin"},
      action: :add_member,
      actor: owner_scope
    )
  end

  defp admin_fixture(owner_scope, org, user), do: add_admin(owner_scope, org, user)

  defp member_fixture_with_row(owner_scope, org, user) do
    subscribed_fixture(org)

    Ash.create!(Membership, %{org_id: org.id, user_id: user.id, role: "member"},
      action: :add_member,
      actor: owner_scope
    )
  end

  defp consumable_stream(name) do
    name
    |> LiveStream.new(0, [], [])
    |> LiveStream.mark_consumable()
  end
end
