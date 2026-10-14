defmodule Alplus.Measure.GoalTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Measure.Goal
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp goal_fixture(scope, org, project, attrs \\ %{}) do
    Ash.create!(
      Goal,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          name: "Signup",
          kind: "event",
          event_name: "signup"
        },
        attrs
      ),
      action: :create,
      actor: project_scope(scope, project)
    )
  end

  describe "create" do
    test "an owner creates a pageview goal" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)

      assert %Goal{name: "Pricing", kind: "pageview", path: "/pricing"} =
               Ash.create!(
                 Goal,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   name: "Pricing",
                   kind: "pageview",
                   path: "/pricing"
                 },
                 action: :create,
                 actor: project_scope(owner, project)
               )
    end

    test "an admin creates an event goal" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      admin = member_fixture(owner, org, user_fixture(), "admin")

      assert %Goal{} = goal_fixture(admin, org, project)
    end

    test "a member is denied create" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      member = member_fixture(owner, org, user_fixture(), "member")

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(
                 Goal,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   name: "Signup",
                   kind: "event",
                   event_name: "signup"
                 },
                 action: :create,
                 actor: project_scope(member, project)
               )
    end

    test "an invalid event name is rejected" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(
                 Goal,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   name: "Bad",
                   kind: "event",
                   event_name: "Not A Valid Name!"
                 },
                 action: :create,
                 actor: project_scope(owner, project)
               )
    end

    test "the package goal cap is enforced at create time" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      subscribed_fixture(org)
      limit = Alplus.Billing.Package.limit(:goals_per_project)

      Enum.each(1..limit, fn n ->
        goal_fixture(owner, org, project, %{name: "Goal #{n}", event_name: "goal-#{n}"})
      end)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.create(
                 Goal,
                 %{
                   org_id: org.id,
                   project_id: project.id,
                   name: "One too many",
                   kind: "event",
                   event_name: "over-limit"
                 },
                 action: :create,
                 actor: project_scope(owner, project)
               )

      assert Exception.message(error) =~ "includes #{limit} goals per project"

      assert %{rows: [[^limit]]} =
               Alplus.Repo.query!("SELECT count(*) FROM goals WHERE project_id = $1", [
                 project.id
               ])
    end

    test "the goal cap is scoped per project, not per org" do
      {org, owner} = org_fixture(scope_fixture())
      project_a = project_fixture(owner, org)
      subscribed_fixture(org)
      project_b = project_fixture(owner, org)
      limit = Alplus.Billing.Package.limit(:goals_per_project)

      # Fill project_a to the cap. A goal on project_b proves the count used
      # for capacity is scoped to one project, not shared org-wide.
      Enum.each(1..limit, fn n ->
        goal_fixture(owner, org, project_a, %{name: "Goal #{n}", event_name: "goal-#{n}"})
      end)

      assert %Goal{} = goal_fixture(owner, org, project_b)
    end
  end

  describe "update" do
    test "an owner renames a goal and changes its event name" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      goal = goal_fixture(owner, org, project)

      assert %Goal{name: "Renamed", event_name: "renamed"} =
               Ash.update!(goal, %{name: "Renamed", event_name: "renamed"},
                 action: :update,
                 actor: project_scope(owner, project)
               )
    end

    test "GoalShape is re-validated on update" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      goal = goal_fixture(owner, org, project)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(goal, %{event_name: "Not Valid!"},
                 action: :update,
                 actor: project_scope(owner, project)
               )
    end

    test "a member is denied update" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      goal = goal_fixture(owner, org, project)
      member = member_fixture(owner, org, user_fixture(), "member")

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(goal, %{name: "Hijacked"},
                 action: :update,
                 actor: project_scope(member, project)
               )
    end

    test "an expired trial cannot update a goal" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      goal = goal_fixture(owner, org, project)

      Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
        ~U[2000-01-01 00:00:00.000000Z],
        org.id
      ])

      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.update(goal, %{name: "Blocked"},
                 action: :update,
                 actor: project_scope(owner, project)
               )

      assert Exception.message(error) =~ "no longer active"
      assert {:ok, unchanged} = Ash.get(Goal, goal.id, actor: project_scope(owner, project))
      assert unchanged.name == "Signup"
    end
  end

  describe "destroy" do
    test "an owner deletes a goal" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      goal = goal_fixture(owner, org, project)

      assert :ok = Ash.destroy(goal, action: :destroy, actor: project_scope(owner, project))

      assert %{rows: [[0]]} =
               Alplus.Repo.query!("SELECT count(*) FROM goals WHERE id = $1", [goal.id])
    end

    test "a member is denied destroy" do
      {org, owner} = org_fixture(scope_fixture())
      project = project_fixture(owner, org)
      goal = goal_fixture(owner, org, project)
      member = member_fixture(owner, org, user_fixture(), "member")

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(goal, action: :destroy, actor: project_scope(member, project))

      assert %{rows: [[1]]} =
               Alplus.Repo.query!("SELECT count(*) FROM goals WHERE id = $1", [goal.id])
    end
  end

  describe "tenant isolation" do
    test "a goal from another organization is not found, never forbidden" do
      {org_a, owner_a} = org_fixture(scope_fixture())
      project_a = project_fixture(owner_a, org_a)
      goal = goal_fixture(owner_a, org_a, project_a)

      {org_b, owner_b} = org_fixture(scope_fixture())
      project_b = project_fixture(owner_b, org_b)

      # Matches the LiveView call path (`Ash.get` scoped by actor, then
      # act on the result) rather than calling update/destroy directly on
      # an already-loaded struct, so this exercises the same "not found,
      # never forbidden" guarantee the UI relies on.
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Goal, goal.id, actor: project_scope(owner_b, project_b))

      # Direct update/destroy on the loaded struct is still denied, in
      # depth, even though the UI never reaches this path.
      assert {:error, _} =
               Ash.update(goal, %{name: "Stolen"},
                 action: :update,
                 actor: project_scope(owner_b, project_b)
               )

      assert {:error, _} =
               Ash.destroy(goal, action: :destroy, actor: project_scope(owner_b, project_b))

      assert %{rows: [[1]]} =
               Alplus.Repo.query!("SELECT count(*) FROM goals WHERE id = $1", [goal.id])
    end
  end
end
