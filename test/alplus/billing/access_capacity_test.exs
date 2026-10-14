defmodule Alplus.Billing.AccessCapacityTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Billing.Access
  alias Alplus.{Orgs.Membership, Projects.Project, Repo}

  describe "project capacity" do
    test "rejects a project past the package limit" do
      {org, owner_scope} = org_fixture(scope_fixture())
      subscribe(org)
      limit = Alplus.Billing.Package.limit(:projects)

      for _ <- 1..limit, do: project_fixture(owner_scope, org)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               Ash.create(Project, %{org_id: org.id, name: "One more", slug: "one-more"},
                 action: :create,
                 actor: owner_scope
               )

      assert message =~ "includes #{limit} projects"
      assert {:ok, ^limit} = count("projects", org.id)
    end

    test "does not count archived projects" do
      {org, owner_scope} = org_fixture(scope_fixture())
      subscribe(org)
      project = project_fixture(owner_scope, org)
      assert :ok = Ash.destroy(project, action: :archive, actor: owner_scope)

      assert {:ok, _project} =
               Ash.create(Project, %{org_id: org.id, name: "Replacement", slug: "replacement"},
                 action: :create,
                 actor: owner_scope
               )
    end
  end

  describe "seat capacity" do
    test "rejects a membership past the registry seat limit" do
      {org, owner_scope} = org_fixture(scope_fixture())
      subscribe(org)

      for _ <- 1..4 do
        user = user_fixture()

        assert {:ok, _membership} =
                 Ash.create(Membership, %{org_id: org.id, user_id: user.id, role: "member"},
                   action: :add_member,
                   actor: owner_scope
                 )
      end

      assert {:error, %{code: :capacity_reached, details: %{limit: 5, current: 5}}} =
               Access.allow_seat(org.id)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               Ash.create(
                 Membership,
                 %{org_id: org.id, user_id: user_fixture().id, role: "member"},
                 action: :add_member,
                 actor: owner_scope
               )

      assert message =~ "all seats are taken"
    end

    # A direct add used to count memberships only, so it could take the seat a
    # pending invitation had reserved. The invited person then hit "Could not
    # accept that invitation." with nothing to act on.
    test "a direct add cannot take a seat a pending invitation reserved" do
      {org, owner_scope} = org_fixture(scope_fixture())
      joiner = user_fixture()
      subscribed_fixture(org)

      # The plan seats five: the owner plus four pending invitations fill them.
      for _ <- 1..4, do: invite!(org, owner_scope)
      subscribed_fixture(org)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               Ash.create(Membership, %{org_id: org.id, user_id: joiner.id, role: "member"},
                 action: :add_member,
                 actor: owner_scope
               )

      assert message =~ "all seats are taken"
      assert {:ok, 1} = count("memberships", org.id)
    end

    # The invitation being accepted is still `pending` while its membership is
    # created, in the same transaction. Counting it would refuse every accept
    # that fills the last seat.
    test "accepting an invitation redeems its own reserved seat" do
      {org, owner_scope} = org_fixture(scope_fixture())
      joiner = user_fixture()
      subscribed_fixture(org)

      # The plan seats five: the owner, three other pending invitations, and the
      # invitation being accepted here.
      for _ <- 1..3, do: invite!(org, owner_scope)

      {_invitation, token} =
        invitation_fixture(owner_scope, org, %{email: to_string(joiner.email)})

      subscribed_fixture(org)

      assert {:ok, _accepted} =
               Alplus.Orgs.accept_invitation(Alplus.Scope.for_user(joiner.id), token)

      assert {:ok, 2} = count("memberships", org.id)
    end
  end

  defp invite!(org, owner_scope) do
    Ash.create!(
      Alplus.Orgs.Invitation,
      %{org_id: org.id, email: unique_email(), role: "member"},
      action: :invite,
      actor: owner_scope
    )
  end

  defp subscribe(org) do
    Repo.query!(
      "UPDATE organizations SET plan_status = 'active', plan_id = 'postdeploy' WHERE id = $1",
      [org.id]
    )
  end

  defp count(table, org_id) do
    case Repo.query!("SELECT count(id) FROM #{table} WHERE org_id = $1", [org_id]).rows do
      [[value]] -> {:ok, value}
    end
  end
end
