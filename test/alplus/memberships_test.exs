defmodule Alplus.MembershipsTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  require Ash.Query

  alias Alplus.Orgs.Membership

  describe "authorization matrix — Membership" do
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

    for {role, can_add_member?, can_change_role?, can_promote?, can_remove?} <- [
          {:owner, true, true, true, true},
          {:admin, true, true, false, true},
          {:member, false, false, false, false},
          {:outsider, false, false, false, false}
        ] do
      test "#{role}: add=#{can_add_member?} change_role=#{can_change_role?} promote=#{can_promote?} remove=#{can_remove?}",
           %{org: org, scopes: scopes} do
        scope = scopes[unquote(role)]

        # add_member
        add_result =
          Ash.create(Membership, %{org_id: org.id, user_id: user_fixture().id},
            action: :add_member,
            actor: scope
          )

        case add_result do
          {:ok, _} -> assert unquote(can_add_member?)
          {:error, _} -> refute unquote(can_add_member?)
        end

        # change_role — target is a fresh, unrelated member so this never
        # collides with the "no self role-change" rule.
        target_user = user_fixture()
        target = member_fixture(scopes.owner, org, target_user, "member")

        target_membership =
          Membership
          |> Ash.Query.filter(org_id == ^org.id and user_id == ^target_user.id)
          |> Ash.read_one!(actor: scopes.owner)

        change_result =
          Ash.update(target_membership, %{role: "admin"}, action: :change_role, actor: scope)

        case change_result do
          {:ok, _} -> assert unquote(can_change_role?)
          {:error, _} -> refute unquote(can_change_role?)
        end

        # promote_to_owner — fresh target again
        promote_target_user = user_fixture()
        member_fixture(scopes.owner, org, promote_target_user, "admin")

        promote_target =
          Membership
          |> Ash.Query.filter(org_id == ^org.id and user_id == ^promote_target_user.id)
          |> Ash.read_one!(actor: scopes.owner)

        promote_result = Ash.update(promote_target, %{}, action: :promote_to_owner, actor: scope)

        case promote_result do
          {:ok, _} -> assert unquote(can_promote?)
          {:error, _} -> refute unquote(can_promote?)
        end

        # remove — fresh target
        removable_user = user_fixture()
        removable = member_fixture(scopes.owner, org, removable_user, "member")

        removable_membership =
          Membership
          |> Ash.Query.filter(org_id == ^org.id and user_id == ^removable_user.id)
          |> Ash.read_one!(actor: scopes.owner)

        remove_result = Ash.destroy(removable_membership, actor: scope)

        case remove_result do
          :ok -> assert unquote(can_remove?)
          {:error, _} -> refute unquote(can_remove?)
        end

        _ = target
        _ = removable
      end
    end
  end

  describe "no removing the owner" do
    test "an owner's own membership cannot be destroyed via remove_member" do
      owner = scope_fixture()
      {org, owner_scope} = org_fixture(owner)

      owner_membership =
        Membership
        |> Ash.Query.filter(org_id == ^org.id and user_id == ^owner.user_id)
        |> Ash.read_one!(actor: owner_scope)

      assert {:error, %Ash.Error.Invalid{}} = Ash.destroy(owner_membership, actor: owner_scope)
    end
  end
end
