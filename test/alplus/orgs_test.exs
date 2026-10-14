defmodule Alplus.OrgsTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Orgs
  alias Alplus.Orgs.Membership
  alias Alplus.Orgs.Organization
  alias Alplus.Scope

  describe "create_organization/2" do
    test "creates the owner membership and starts the registry-sized trial" do
      scope = scope_fixture()
      {org, owner_scope} = org_fixture(scope)

      assert owner_scope.role == "owner"

      assert {:ok, membership} =
               Membership
               |> Ash.Query.filter(org_id == ^org.id and user_id == ^scope.user_id)
               |> Ash.read_one(actor: owner_scope)

      assert membership.role == "owner"
      assert org.billing_status == :trialing

      assert_in_delta(
        DateTime.diff(org.trial_ends_at, org.inserted_at, :second),
        Alplus.Billing.Package.trial_days() * 86_400,
        2
      )
    end

    test "an organization replacement keeps the account's first trial deadline" do
      scope = scope_fixture()

      assert {:ok, first} = Orgs.create_organization(%{name: "First"}, actor: scope)
      {:ok, first_owner_scope} = Orgs.build_scope(scope, first.id)
      assert :ok = Orgs.destroy_organization(first, actor: first_owner_scope)

      assert {:ok, replacement} =
               Orgs.create_organization(%{name: "Replacement"}, actor: scope)

      assert replacement.billing_status == :trialing
      assert DateTime.compare(replacement.trial_ends_at, first.trial_ends_at) == :eq
    end
  end

  describe "apply_billing_status/2" do
    test "updates the Stripe-derived billing status through the Orgs code interface" do
      {org, _owner_scope} = org_fixture(scope_fixture())

      assert :ok = Orgs.apply_billing_status(org.id, "active")

      assert {:ok, updated} = Ash.get(Organization, org.id, authorize?: false)
      assert updated.billing_status == :active
    end

    test "rejects an invalid status without changing the Organization" do
      {org, _owner_scope} = org_fixture(scope_fixture())

      assert {:error, :invalid_billing_status} =
               Orgs.apply_billing_status(org.id, "not-a-stripe-status")

      assert {:ok, unchanged} = Ash.get(Organization, org.id, authorize?: false)
      assert unchanged.billing_status == :trialing
    end

    test "returns not found for an unknown Organization" do
      assert {:error, :organization_not_found} =
               Orgs.apply_billing_status("org_01j2x3z4a5b6c7d8e9f0g1h2i3", "active")
    end
  end

  describe "exactly one owner per org (DB-enforced)" do
    test "a second owner membership is rejected" do
      scope = scope_fixture()
      {org, _owner_scope} = org_fixture(scope)
      other_user = user_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Membership,
                 %{org_id: org.id, user_id: other_user.id},
                 action: :create_owner,
                 authorize?: false
               )
    end
  end

  describe "one membership per (user, org) (DB-enforced)" do
    test "adding the same user twice is rejected" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      member = user_fixture()
      subscribed_fixture(org)

      assert {:ok, _} =
               Ash.create(Membership, %{org_id: org.id, user_id: member.id},
                 action: :add_member,
                 actor: owner_scope
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Membership, %{org_id: org.id, user_id: member.id},
                 action: :add_member,
                 actor: owner_scope
               )
    end
  end

  describe "promote_to_owner/2" do
    test "atomically demotes the old owner and promotes the target" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      new_owner_user = user_fixture()
      new_owner_scope = member_fixture(owner_scope, org, new_owner_user, "admin")

      target_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^new_owner_user.id)
        |> Ash.read_one!(actor: owner_scope)

      assert {:ok, promoted} =
               Ash.update(target_membership, %{}, action: :promote_to_owner, actor: owner_scope)

      assert promoted.role == "owner"

      old_owner_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^owner.user_id)
        |> Ash.read_one!(actor: new_owner_scope)

      assert old_owner_membership.role == "admin"

      owners =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and role == "owner")
        |> Ash.read!(authorize?: false)

      assert length(owners) == 1
    end

    test "the current owner cannot transfer ownership to themselves" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      own_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^owner.user_id)
        |> Ash.read_one!(actor: owner_scope)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(own_membership, %{}, action: :promote_to_owner, actor: owner_scope)
    end
  end

  describe "change_role/2 — no self role-change" do
    test "the owner cannot change their own role" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      own_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^owner.user_id)
        |> Ash.read_one!(actor: owner_scope)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(own_membership, %{role: "admin"},
                 action: :change_role,
                 actor: owner_scope
               )
    end

    test "an admin cannot change their own role" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_user = user_fixture()
      admin_scope = member_fixture(owner_scope, org, admin_user, "admin")

      own_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^admin_user.id)
        |> Ash.read_one!(actor: admin_scope)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(own_membership, %{role: "member"},
                 action: :change_role,
                 actor: admin_scope
               )
    end

    test "the owner's role cannot be changed via change_role" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_user = user_fixture()
      admin_scope = member_fixture(owner_scope, org, admin_user, "admin")

      owner_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^owner.user_id)
        |> Ash.read_one!(actor: admin_scope)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(owner_membership, %{role: "admin"},
                 action: :change_role,
                 actor: admin_scope
               )
    end

    test "an admin can change another member's role" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_user = user_fixture()
      admin_scope = member_fixture(owner_scope, org, admin_user, "admin")
      member_user = user_fixture()
      member_fixture(owner_scope, org, member_user, "member")

      member_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^member_user.id)
        |> Ash.read_one!(actor: admin_scope)

      assert {:ok, updated} =
               Ash.update(member_membership, %{role: "admin"},
                 action: :change_role,
                 actor: admin_scope
               )

      assert updated.role == "admin"
    end
  end

  describe "cross-tenant isolation (real auth path)" do
    test "a foreign org id returns not-found, never forbidden" do
      org_a_owner = scope_fixture()
      {org_a, org_a_owner_scope} = org_fixture(org_a_owner)
      org_b_owner = scope_fixture()
      {org_b, _org_b_owner_scope} = org_fixture(org_b_owner)

      assert {:error, :not_found} = Orgs.build_scope(org_a_owner_scope, org_b.id)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Organization, org_b.id, actor: org_a_owner_scope)

      # A user with no membership anywhere gets the same not-found shape.
      stranger = scope_fixture()
      assert {:error, %Ash.Error.Invalid{}} = Ash.get(Organization, org_a.id, actor: stranger)

      assert {:error, :not_found} = Orgs.build_scope(stranger, org_a.id)
    end

    test "an org admin cannot read or write another org's memberships" do
      {org_a, org_a_owner_scope} = org_fixture(scope_fixture())
      {_org_b, org_b_owner_scope} = org_fixture(scope_fixture())

      org_a_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org_a.id)
        |> Ash.read_one!(actor: org_a_owner_scope)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Membership, org_a_membership.id, actor: org_b_owner_scope)
    end
  end

  describe "authorization matrix — Organization" do
    setup do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)
      admin_user = user_fixture()
      admin_scope = member_fixture(owner_scope, org, admin_user, "admin")
      member_user = user_fixture()
      member_scope = member_fixture(owner_scope, org, member_user, "member")
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

    for {role, can_read?, can_update?, can_destroy?} <- [
          {:owner, true, true, true},
          {:admin, true, true, false},
          {:member, true, false, false},
          {:outsider, false, false, false}
        ] do
      test "#{role}: read=#{can_read?} update=#{can_update?} destroy=#{can_destroy?}", %{
        org: org,
        scopes: scopes
      } do
        scope = scopes[unquote(role)]

        case Ash.get(Organization, org.id, actor: scope) do
          {:ok, _} -> assert unquote(can_read?)
          {:error, _} -> refute unquote(can_read?)
        end

        case Ash.update(org, %{name: "Renamed"}, action: :update, actor: scope) do
          {:ok, _} -> assert unquote(can_update?)
          {:error, _} -> refute unquote(can_update?)
        end

        case Ash.destroy(org, actor: scope) do
          :ok -> assert unquote(can_destroy?)
          {:error, _} -> refute unquote(can_destroy?)
        end
      end
    end
  end

  describe "org member and invitation reads" do
    test "list_org_members returns members oldest first with :user loaded" do
      owner = user_fixture()
      {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
      member = user_fixture()
      member_fixture(owner_scope, org, member)

      assert {:ok, [first, second]} = Orgs.list_org_members(owner_scope, org.id)
      assert first.user_id == owner.id
      assert first.user.id == owner.id
      assert second.user_id == member.id
    end

    test "list_org_invitations returns the org's invitations newest first" do
      {org, owner_scope} = org_fixture(scope_fixture())
      {older, _} = invitation_fixture(owner_scope, org)
      {newer, _} = invitation_fixture(owner_scope, org)

      assert {:ok, [first, second]} = Orgs.list_org_invitations(owner_scope, org.id)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "fetch_org_member and fetch_org_invitation stay inside the org" do
      {org, owner_scope} = org_fixture(scope_fixture())
      {invitation, _} = invitation_fixture(owner_scope, org)
      {:ok, [membership]} = Orgs.list_org_members(owner_scope, org.id)

      assert {:ok, found} = Orgs.fetch_org_member(owner_scope, org.id, membership.id)
      assert found.user.id == owner_scope.user_id

      assert {:ok, found_invitation} =
               Orgs.fetch_org_invitation(owner_scope, org.id, invitation.id)

      assert found_invitation.id == invitation.id

      {other_org, other_scope} = org_fixture(scope_fixture())
      assert {:ok, nil} = Orgs.fetch_org_member(other_scope, other_org.id, membership.id)
      assert {:ok, nil} = Orgs.fetch_org_invitation(other_scope, other_org.id, invitation.id)
    end
  end
end
