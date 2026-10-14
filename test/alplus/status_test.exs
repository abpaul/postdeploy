defmodule Alplus.StatusTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor
  alias Alplus.PublicPages
  alias Alplus.Scope
  alias Alplus.Status

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    %{org: org, project: project, scope: scope}
  end

  test "an owner creates and publishes a page", context do
    assert {:ok, page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "acme",
               title: "Acme status"
             })

    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert is_nil(identity.published_at)

    assert %Status.StatusComponent{} = create_linked_component(context, page, "API")

    assert {:ok, published} = Status.publish_page(context.scope, page)
    assert published.id == page.id
    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert %DateTime{} = identity.published_at
    assert {:ok, resolved} = Status.resolve("acme")
    assert resolved.page.id == page.id
  end

  test "reserved and unpublished slugs resolve as not found", context do
    assert {:error, _error} =
             PublicPages.ensure_identity(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "admin",
               title: "Admin"
             })

    assert {:ok, page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "private",
               title: "Private"
             })

    assert {:error, :not_found} = PublicPages.resolve("private")
    assert {:ok, _page} = Status.unpublish_page(context.scope, page)
    assert {:error, :not_found} = PublicPages.resolve("private")
  end

  test "public slug lookup requires the scoped public actor", context do
    assert {:ok, _page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "private-lookup",
               title: "Private lookup"
             })

    assert {:ok, identity} = PublicPages.get_for_project(context.scope, context.project.id)
    assert {:error, :not_found} = PublicPages.resolve(identity.public_slug)
  end

  test "page creation keeps one workspace without a status-page capacity", context do
    assert {:ok, _page} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "first-page",
               title: "First"
             })

    assert {:error, error} =
             Status.create_page(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "second-page",
               title: "Second"
             })

    assert inspect(error) =~ "status_pages_singleton"
  end

  test "members cannot create a Public identity through Status setup", context do
    member = member_fixture(context.scope, context.org, user_fixture(), "member")
    member_scope = Scope.put_project(member, context.project.id)

    assert {:error, %Ash.Error.Forbidden.Policy{}} =
             Status.create_page(member_scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               public_slug: "member-status",
               title: "Member status"
             })

    assert {:error, :not_found} =
             PublicPages.get_for_project(member_scope, context.project.id)
  end

  test "a different tenant cannot read or publish the page", context do
    {:ok, page} =
      Status.create_page(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        public_slug: "private",
        title: "Private"
      })

    {_other_org, other_scope} = org_fixture(scope_fixture())
    other_project_scope = Scope.put_project(other_scope, context.project.id)

    assert {:error, _error} = Ash.get(Alplus.Status.StatusPage, page.id, actor: other_scope)
    assert {:error, _error} = Status.publish_page(other_scope, page)
    assert {:error, _error} = Status.workspace_page(other_project_scope)
  end

  test "public incidents include human updates", context do
    {:ok, page} =
      Status.create_page(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        public_slug: "acme",
        title: "Acme status"
      })

    component = create_linked_component(context, page, "API")

    assert component.name == "API"
    {:ok, page} = Status.publish_page(context.scope, page)

    {:ok, incident} =
      Status.publish_incident(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        title: "API outage",
        body: "We are investigating."
      })

    {:ok, _update} =
      Status.publish_incident_update(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_incident_id: incident.id,
        body: "The team is working on a fix."
      })

    assert {:ok, snapshot} = Status.load_public("acme")

    assert [%{title: "API outage", updates: [%{body: "The team is working on a fix."}]}] =
             snapshot.incidents
  end

  test "published incidents reject a linked incident from another project", context do
    {:ok, page} =
      Status.create_page(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        public_slug: "tenant-check",
        title: "Tenant check"
      })

    _component = create_linked_component(context, page, "API")
    {:ok, page} = Status.publish_page(context.scope, page)
    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)
    other_scope = Scope.put_project(other_scope, other_project.id)

    monitor =
      Ash.create!(
        Alplus.Monitoring.Monitor,
        %{
          org_id: other_scope.org_id,
          project_id: other_project.id,
          type: "http",
          name: "Other API"
        },
        action: :create,
        actor: other_scope
      )

    incident =
      Ash.create!(
        Alplus.Monitoring.Incident,
        %{
          org_id: other_scope.org_id,
          project_id: other_project.id,
          monitor_id: monitor.id,
          cause: "availability",
          cause_detail: %{},
          started_at: DateTime.utc_now(),
          checks_failed_count: 1
        },
        action: :open,
        authorize?: false,
        actor: other_scope
      )

    assert {:error, error} =
             Status.publish_incident(context.scope, %{
               org_id: context.org.id,
               project_id: context.project.id,
               status_page_id: page.id,
               incident_id: incident.id,
               title: "Wrong tenant",
               body: "Must fail."
             })

    assert inspect(error) =~ "does not exist in this project"
  end

  defp create_linked_component(context, page, name) do
    {:ok, component} =
      Status.create_component(context.scope, %{
        org_id: context.org.id,
        project_id: context.project.id,
        status_page_id: page.id,
        name: name
      })

    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: context.org.id,
          project_id: context.project.id,
          type: "http",
          name: "#{name} monitor"
        },
        action: :create,
        actor: context.scope
      )

    Ash.Seed.update!(monitor, %{last_known_status: "up"})
    :ok = Status.link_monitor(context.scope, component, monitor.id)
    component
  end

  test "aggregate health preserves empty public and workspace states" do
    assert Status.aggregate_health([], false, nil, :unknown) == :unknown
    assert Status.aggregate_health([], false, nil, :unconfigured) == :unconfigured
    assert Status.aggregate_health([], true, nil, :unconfigured) == :maintenance
  end

  test "aggregate health uses one precedence for public and workspace service rows" do
    services = [%{state: :operational}, %{state: :down}, %{state: :degraded}]
    assert Status.aggregate_health(services, false, nil, :unknown) == :partial_outage
    assert Status.aggregate_health([%{state: :degraded}], false, nil, :unknown) == :degraded
  end
end
