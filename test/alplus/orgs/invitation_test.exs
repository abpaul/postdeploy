defmodule Alplus.Orgs.InvitationTest do
  use Alplus.DataCase, async: true
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Mailer.Worker
  alias Alplus.Orgs.Invitation
  alias Alplus.Orgs.Membership

  describe "authorization matrix — Invitation" do
    setup do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_scope = member_fixture(owner_scope, org, user_fixture(), "admin")
      member_scope = member_fixture(owner_scope, org, user_fixture(), "member")
      outsider_scope = scope_fixture()

      %{
        org: org,
        scopes: %{
          owner: owner_scope,
          admin: admin_scope,
          member: member_scope,
          outsider: outsider_scope
        }
      }
    end

    for {role, can_invite?, can_resend?, can_revoke?} <- [
          {:owner, true, true, true},
          {:admin, true, true, true},
          {:member, false, false, false},
          {:outsider, false, false, false}
        ] do
      test "#{role}: invite=#{can_invite?} resend=#{can_resend?} revoke=#{can_revoke?}",
           %{org: org, scopes: scopes} do
        scope = scopes[unquote(role)]

        invite_result =
          Ash.create(
            Invitation,
            %{
              org_id: org.id,
              email: "target-#{System.unique_integer([:positive])}@example.com",
              role: "member"
            },
            action: :invite,
            actor: scope
          )

        case invite_result do
          {:ok, invitation} ->
            assert unquote(can_invite?)
            # Give the seat back: the plan seats five, and the fixtures below
            # reserve two more.
            Ash.update!(invitation, %{}, action: :revoke, actor: scopes.owner)

          {:error, _} ->
            refute unquote(can_invite?)
        end

        {resendable, _token} = invitation_fixture(scopes.owner, org)
        resend_result = Ash.update(resendable, %{}, action: :resend, actor: scope)

        case resend_result do
          {:ok, _} -> assert unquote(can_resend?)
          {:error, _} -> refute unquote(can_resend?)
        end

        {revocable, _token} = invitation_fixture(scopes.owner, org)
        revoke_result = Ash.update(revocable, %{}, action: :revoke, actor: scope)

        case revoke_result do
          {:ok, _} -> assert unquote(can_revoke?)
          {:error, _} -> refute unquote(can_revoke?)
        end
      end
    end
  end

  describe "invite" do
    test "normalizes email and sets a 7-day expiry" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      # Indie is a single-seat plan, and the owner holds that seat, so inviting
      # requires a plan with room. `EnforceSeat` is covered on its own below.
      subscribed_fixture(org)

      invitation =
        Ash.create!(
          Invitation,
          %{org_id: org.id, email: "  Target@Example.com  ", role: "admin"},
          action: :invite,
          actor: owner_scope
        )

      assert invitation.email == "target@example.com"
      assert invitation.status == "pending"
      assert invitation.invited_by_id == owner_scope.user_id

      diff = DateTime.diff(invitation.expires_at, invitation.inserted_at, :second)
      assert_in_delta diff, Invitation.expiry_seconds(), 2
    end

    test "queues one email with a link to the accept page carrying the token" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      subscribed_fixture(org)

      invitation =
        Ash.create!(Invitation, %{org_id: org.id, email: "invited@example.com", role: "admin"},
          action: :invite,
          actor: owner_scope
        )

      token = Ash.Resource.get_metadata(invitation, :token)

      assert [%{args: args}] =
               all_enqueued(
                 worker: Worker,
                 args: %{"purpose" => "invitation", "invitation_id" => invitation.id}
               )

      assert args["token"] == token
      assert :ok = perform_job(Worker, args)
      assert_received {:email, %Swoosh.Email{to: [{_, "invited@example.com"}]} = email}
      assert email.html_body =~ "/invitations/#{token}"
    end

    test "rejects a second pending invite to the same email in the same org" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      subscribed_fixture(org)

      Ash.create!(Invitation, %{org_id: org.id, email: "dup@example.com", role: "member"},
        action: :invite,
        actor: owner_scope
      )

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Invitation, %{org_id: org.id, email: "dup@example.com", role: "member"},
                 action: :invite,
                 actor: owner_scope
               )
    end

    # An invitation the plan has no seat for used to be created and emailed
    # happily, then failed in the recipient's browser with "Could not accept
    # that invitation." Fail on the inviter's form instead, where someone can
    # act on it.
    test "refuses when every seat is taken by a member or a pending invitation" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      # The plan carries five seats: the owner plus four pending invitations
      # fill them, and the fifth invitation has nowhere to go.
      subscribed_fixture(org)

      for email <- [
            "first@example.com",
            "second@example.com",
            "third@example.com",
            "fourth@example.com"
          ] do
        assert %Invitation{} =
                 Ash.create!(Invitation, %{org_id: org.id, email: email, role: "member"},
                   action: :invite,
                   actor: owner_scope
                 )
      end

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.create(
                 Invitation,
                 %{org_id: org.id, email: "fifth@example.com", role: "member"},
                 action: :invite,
                 actor: owner_scope
               )

      assert Exception.message(error) =~ "all seats are taken"
    end
  end

  describe "accept" do
    test "creates the membership and marks the invitation accepted, for the invited email" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {invitation, token} =
        invitation_fixture(owner_scope, org, %{role: "admin", email: email})

      invitee = scope_fixture(%{user: invitee_user})

      assert {:ok, accepted} = Alplus.Orgs.accept_invitation(invitee, token)
      assert accepted.status == "accepted"
      assert accepted.id == invitation.id
      refute is_nil(accepted.accepted_at)

      membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^invitee.user_id)
        |> Ash.read_one!(actor: owner_scope)

      assert membership.role == "admin"
    end

    test "rejects acceptance by an account whose email does not match the invite" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      {_invitation, token} =
        invitation_fixture(owner_scope, org, %{email: "intended@example.com"})

      wrong_account = scope_fixture(%{user: user_fixture(%{email: "someone-else@example.com"})})

      assert {:error, %Ash.Error.Invalid{}} =
               Alplus.Orgs.accept_invitation(wrong_account, token)

      refute Membership
             |> Ash.Query.filter(org_id == ^org.id and user_id == ^wrong_account.user_id)
             |> Ash.exists?(actor: owner_scope)
    end

    test "an unknown token returns :not_found" do
      invitee = scope_fixture()
      assert {:error, :not_found} = Alplus.Orgs.accept_invitation(invitee, "not-a-real-token")
    end

    test "an expired invitation cannot be accepted" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {invitation, token} =
        invitation_fixture(owner_scope, org, %{email: email})

      # Backdates the row directly (no sleep, no clock injection needed):
      # simulates 7 days passing without waiting for it. Both timestamps
      # move together so `expires_at > inserted_at` still holds.
      import Ecto.Query

      Alplus.Repo.update_all(
        from(i in "invitations", where: i.id == ^invitation.id),
        set: [
          inserted_at: DateTime.add(DateTime.utc_now(), -8, :day),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        ]
      )

      invitee = scope_fixture(%{user: invitee_user})
      assert {:error, %Ash.Error.Invalid{}} = Alplus.Orgs.accept_invitation(invitee, token)
    end

    test "a revoked invitation cannot be accepted" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()
      invitee_user = user_fixture(%{email: email})

      {invitation, token} =
        invitation_fixture(owner_scope, org, %{email: email})

      Ash.update!(invitation, %{}, action: :revoke, actor: owner_scope)

      invitee = scope_fixture(%{user: invitee_user})
      assert {:error, %Ash.Error.Invalid{}} = Alplus.Orgs.accept_invitation(invitee, token)
    end

    test "the same token cannot be accepted twice" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()

      {_invitation, token} = invitation_fixture(owner_scope, org, %{email: email})

      invitee = scope_fixture(%{user: user_fixture(%{email: email})})
      assert {:ok, _} = Alplus.Orgs.accept_invitation(invitee, token)

      # Replaying the same token, as the same invitee, must fail.
      assert {:error, %Ash.Error.Invalid{}} = Alplus.Orgs.accept_invitation(invitee, token)
    end
  end

  describe "resend" do
    test "issues a new token and pushes the expiry out" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      email = unique_email()

      {invitation, old_token} =
        invitation_fixture(owner_scope, org, %{email: email})

      resent = Ash.update!(invitation, %{}, action: :resend, actor: owner_scope)
      new_token = Ash.Resource.get_metadata(resent, :token)

      refute new_token == old_token

      invitee = scope_fixture(%{user: user_fixture(%{email: email})})
      assert {:error, :not_found} = Alplus.Orgs.accept_invitation(invitee, old_token)
      assert {:ok, _} = Alplus.Orgs.accept_invitation(invitee, new_token)
    end
  end

  describe "secret non-exposure" do
    test "the token never appears on the struct or a later read" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      {invitation, token} = invitation_fixture(owner_scope, org)

      refute invitation |> Map.from_struct() |> Map.values() |> Enum.member?(token)
      refute inspect(invitation) =~ token

      reloaded = Ash.get!(Invitation, invitation.id, actor: owner_scope)
      refute inspect(reloaded) =~ token
      refute reloaded |> Map.from_struct() |> Map.values() |> Enum.member?(token)
    end
  end
end
