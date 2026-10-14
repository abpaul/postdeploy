defmodule Alplus.Measure.ConfigurationTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Measure.{CustomEventDefinition, Goal}
  alias Alplus.Scope

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    %{org: org, project: project, scope: Scope.put_project(owner_scope, project.id)}
  end

  test "owners create page and event goals with their bounded shapes", %{
    org: org,
    project: project,
    scope: scope
  } do
    assert {:ok, page_goal} =
             Ash.create(
               Goal,
               %{
                 org_id: org.id,
                 project_id: project.id,
                 name: "Pricing",
                 kind: "pageview",
                 path: "/pricing"
               },
               actor: scope
             )

    assert page_goal.path == "/pricing"

    assert {:ok, event_goal} =
             Ash.create(
               Goal,
               %{
                 org_id: org.id,
                 project_id: project.id,
                 name: "Signup",
                 kind: "event",
                 event_name: "signup"
               },
               actor: scope
             )

    assert event_goal.event_name == "signup"

    assert {:error, _} =
             Ash.create(
               Goal,
               %{org_id: org.id, project_id: project.id, name: "Bad", kind: "event", path: "/x"},
               actor: scope
             )
  end

  test "custom event names are scoped and constrained", %{
    org: org,
    project: project,
    scope: scope
  } do
    attributes = %{org_id: org.id, project_id: project.id, name: "cta_click"}
    assert {:ok, _event} = Ash.create(CustomEventDefinition, attributes, actor: scope)
    assert {:error, _} = Ash.create(CustomEventDefinition, attributes, actor: scope)

    assert {:error, _} =
             Ash.create(CustomEventDefinition, %{attributes | name: "invalid name"}, actor: scope)
  end
end
