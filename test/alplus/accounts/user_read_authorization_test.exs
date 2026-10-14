defmodule Alplus.Accounts.UserReadAuthorizationTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Accounts.User
  alias Alplus.Scope

  test "a same-org member can read another member" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))

    actor_user = user_fixture()
    actor_scope = member_fixture(owner_scope, org, actor_user)

    target_user = user_fixture()
    member_fixture(owner_scope, org, target_user)

    assert {:ok, %User{id: target_id}} = Ash.get(User, target_user.id, actor: actor_scope)
    assert target_id == target_user.id
  end

  test "a forged victim org scope cannot read a victim member" do
    victim_owner = user_fixture()
    {victim_org, victim_owner_scope} = org_fixture(Scope.for_user(victim_owner.id))

    victim_user = user_fixture()
    member_fixture(victim_owner_scope, victim_org, victim_user)

    attacker = user_fixture()
    {_attacker_org, attacker_scope} = org_fixture(Scope.for_user(attacker.id))

    forged_scope = %{attacker_scope | org_id: victim_org.id}

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(User, victim_user.id, actor: forged_scope)
  end
end
