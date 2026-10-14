defmodule Alplus.Notifications.RuleScopeTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Notifications.{AlertRule}
  alias Alplus.Scope

  defp channel(org, scope, name) do
    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: name,
          config: %{"to" => "alerts@example.test"}
        },
        scope
      )

    channel
  end

  defp rule_attrs(org, project, channel) do
    %{
      org_id: org.id,
      project_id: project.id,
      module: "monitor",
      trigger_type: "check_down",
      channel_id: channel.id
    }
  end

  test "create rejects a project from another organization before persistence" do
    owner = user_fixture()
    {org_a, scope_a} = org_fixture(Scope.for_user(owner.id))
    {org_b, scope_b} = org_fixture(Scope.for_user(owner.id))
    project_a = project_fixture(scope_a, org_a)
    project_b = project_fixture(scope_b, org_b)
    channel_a = channel(org_a, scope_a, "A")

    forged_scope = Scope.put_project(scope_a, project_b.id)

    assert {:error, :project_not_found} =
             Alplus.Notifications.create_rule(
               rule_attrs(org_a, project_b, channel_a),
               forged_scope
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(
               AlertRule,
               rule_attrs(org_a, project_b, channel_a),
               action: :create,
               actor: forged_scope
             )

    assert [[0]] =
             Alplus.Repo.query!(
               "SELECT count(*) FROM alert_rules WHERE org_id = $1",
               [org_a.id]
             ).rows

    # Keep the first project referenced so the fixture exercises both sides of
    # the tenant boundary rather than relying on an empty organization.
    assert project_a.org_id == org_a.id
  end

  test "create rejects a channel from another organization before persistence" do
    owner = user_fixture()
    {org_a, scope_a} = org_fixture(Scope.for_user(owner.id))
    {org_b, scope_b} = org_fixture(Scope.for_user(owner.id))
    project_a = project_fixture(scope_a, org_a)
    channel_a = channel(org_a, scope_a, "A")
    channel_b = channel(org_b, scope_b, "B")

    project_scope = Scope.put_project(scope_a, project_a.id)

    assert {:error, :channel_not_found} =
             Alplus.Notifications.create_rule(
               rule_attrs(org_a, project_a, channel_b),
               project_scope
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(
               AlertRule,
               rule_attrs(org_a, project_a, channel_b),
               action: :create,
               actor: project_scope
             )

    assert [[0]] =
             Alplus.Repo.query!(
               "SELECT count(*) FROM alert_rules WHERE org_id = $1",
               [org_a.id]
             ).rows

    assert channel_a.name == "A"
  end

  test "same-organization forged project scopes cannot create or update another project rule" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project_a = project_fixture(owner_scope, org, %{name: "A"})
    project_b = project_fixture(owner_scope, org, %{name: "B"})
    channel = channel(org, owner_scope, "Operations")
    project_a_scope = Scope.put_project(owner_scope, project_a.id)
    project_b_scope = Scope.put_project(owner_scope, project_b.id)

    assert {:ok, rule} =
             Alplus.Notifications.create_rule(
               rule_attrs(org, project_a, channel),
               project_a_scope
             )

    assert {:error, :scope_mismatch} =
             Alplus.Notifications.create_rule(
               rule_attrs(org, project_a, channel),
               project_b_scope
             )

    assert {:error, :not_found} =
             Alplus.Notifications.update_rule(
               rule.id,
               %{channel_id: channel.id, enabled: false},
               project_b_scope
             )

    unchanged = Ash.get!(AlertRule, rule.id, actor: project_a_scope)
    assert unchanged.project_id == project_a.id
    assert unchanged.enabled
  end

  test "a member cannot create a rule even with a valid project and channel" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    channel = channel(org, owner_scope, "Operations")
    member = user_fixture()
    member_scope = member_fixture(owner_scope, org, member)
    member_project_scope = Scope.put_project(member_scope, project.id)

    assert {:error, _error} =
             Alplus.Notifications.create_rule(
               rule_attrs(org, project, channel),
               member_project_scope
             )

    assert [[0]] =
             Alplus.Repo.query!(
               "SELECT count(*) FROM alert_rules WHERE org_id = $1",
               [org.id]
             ).rows
  end
end
