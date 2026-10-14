defmodule Alplus.Analytics.McpAdapterTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Analytics.Queries
  alias Alplus.Mcp.{Dispatch, Principal}
  alias Alplus.Repo

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    subscribed_fixture(org)
    project = project_fixture(owner_scope, org)
    {source, _secret} = source_fixture(owner_scope, org, project, %{type: :analytics})
    scope = Alplus.Scope.put_project(owner_scope, project.id)

    principal = %Principal{
      grant_id: Alplus.Id.generate(:mcp_oauth_grant),
      org_id: org.id,
      project_id: project.id,
      user_id: owner_scope.user_id,
      scopes: Alplus.Mcp.Scope.all(),
      source: :oauth,
      correlation_id: Alplus.Id.generate(:request)
    }

    %{org: org, project: project, scope: scope, source: source, principal: principal}
  end

  defp call(tool, args, context) do
    args =
      args
      |> Map.put("project_handle", context.project.id)
      |> Map.put_new("idempotency_key", Alplus.Id.generate(:request))

    Dispatch.call(tool, args, context.principal)
  end

  defp event(source, name, distinct_id, minutes_ago, properties \\ %{}) do
    at = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    Repo.query!(
      """
      INSERT INTO product_events
        (id, org_id, project_id, source_id, environment, event_name, distinct_id,
         occurred_at, received_at, properties)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8,$9)
      """,
      [
        Alplus.Id.generate(:product_event),
        source.org_id,
        source.project_id,
        source.id,
        source.environment,
        name,
        distinct_id,
        at,
        properties
      ]
    )
  end

  describe "reads" do
    test "the overview reports users, events, and the top events", context do
      event(context.source, "first_open", "a", 60)
      event(context.source, "meal_logged", "a", 50)
      event(context.source, "meal_logged", "b", 40)

      assert {:ok, result} = call("analytics.overview", %{"window" => "24h"}, context)

      assert result.users == 2
      assert result.events == 3
      assert [%{event: "meal_logged", events: 2, users: 2} | _rest] = result.top_events
    end

    test "the overview reports activation once it is configured", context do
      event(context.source, "first_open", "a", 60)
      event(context.source, "meal_logged", "a", 30)
      event(context.source, "first_open", "b", 60)

      assert {:ok, _settings} =
               call(
                 "analytics.set_activation",
                 %{"start_event" => "first_open", "activation_event" => "meal_logged"},
                 context
               )

      assert {:ok, %{activation: activation}} =
               call("analytics.overview", %{"window" => "24h"}, context)

      assert activation.started == 2
      assert activation.activated == 1
      assert activation.rate == 50.0
    end

    test "an event reads its totals and a property breakdown", context do
      event(context.source, "paywall_viewed", "a", 10, %{"source" => "onboarding"})
      event(context.source, "paywall_viewed", "b", 9, %{"source" => "settings"})
      event(context.source, "paywall_viewed", "a", 8, %{"source" => "onboarding"})

      assert {:ok, result} =
               call(
                 "analytics.get_event",
                 %{
                   "event" => "paywall_viewed",
                   "window" => "24h",
                   "breakdown_property" => "source"
                 },
                 context
               )

      assert result.events == 3
      assert result.users == 2
      assert result.events_per_user == 1.5

      assert [%{value: "onboarding", events: 2}, %{value: "settings", events: 1}] =
               result.breakdown
    end

    test "an ad-hoc funnel reports per-step users and the largest drop", context do
      event(context.source, "first_open", "a", 60)
      event(context.source, "onboarding_completed", "a", 50)
      event(context.source, "first_open", "b", 60)
      event(context.source, "first_open", "c", 60)

      assert {:ok, result} =
               call(
                 "analytics.get_funnel",
                 %{"steps" => ["first_open", "onboarding_completed"], "window" => "24h"},
                 context
               )

      assert [entry] = result.results
      assert entry.entered == 3
      assert entry.converted == 1
      assert entry.largest_drop_event == "onboarding_completed"
    end

    test "retention reports each period against a finished cohort", context do
      event(context.source, "meal_logged", "a", 60 * 24 * 5)
      event(context.source, "meal_logged", "a", 60 * 24 * 4)

      assert {:ok, result} =
               call(
                 "analytics.get_retention",
                 %{"start_event" => "meal_logged", "window" => "30d"},
                 context
               )

      assert result.return_event == "meal_logged"
      assert Enum.find(result.periods, &(&1.period == 0)).retained == 1
      assert Enum.find(result.periods, &(&1.period == 1)).retained == 1
    end

    test "compare reports one event across a property, with no claim of cause", context do
      event(context.source, "onboarding_completed", "a", 10, %{"app_version" => "1.8.0"})
      event(context.source, "onboarding_completed", "b", 9, %{"app_version" => "1.8.0"})
      event(context.source, "onboarding_completed", "c", 8, %{"app_version" => "1.9.0"})

      assert {:ok, result} =
               call(
                 "analytics.compare",
                 %{
                   "event" => "onboarding_completed",
                   "property" => "app_version",
                   "window" => "24h"
                 },
                 context
               )

      assert [%{value: "1.8.0", events: 2}, %{value: "1.9.0", events: 1}] = result.values
    end

    test "live events return the most recent events with their properties", context do
      event(context.source, "onboarding_started", "a", 2, %{"step" => 1})

      assert {:ok, %{events: [live]}} = call("analytics.list_live_events", %{}, context)

      assert live.event == "onboarding_started"
      assert live.properties == %{"step" => 1}
    end
  end

  describe "several apps in one project" do
    setup context do
      {ios, _secret} =
        source_fixture(context.scope, context.org, context.project, %{
          type: :analytics,
          name: "iOS app"
        })

      {web, _secret} =
        source_fixture(context.scope, context.org, context.project, %{
          type: :analytics,
          name: "Web app"
        })

      %{ios: ios, web: web}
    end

    test "reads every app together when no app is named", context do
      event(context.ios, "meal_logged", "person_a", 10)
      event(context.web, "meal_logged", "person_b", 9)

      assert {:ok, %{users: 2, events: 2}} = call("analytics.overview", %{}, context)
    end

    test "narrows every read to one app when one is named", context do
      event(context.ios, "meal_logged", "person_a", 10)
      event(context.web, "paywall_viewed", "person_b", 9)

      assert {:ok, %{users: 1, events: 1, top_events: [%{event: "meal_logged"}]}} =
               call("analytics.overview", %{"source_handle" => context.ios.id}, context)
    end

    test "refuses an app handle from another project", context do
      other_project = project_fixture(context.scope, context.org, %{name: "Other"})

      {foreign, _secret} =
        source_fixture(context.scope, context.org, other_project, %{
          type: :analytics,
          name: "Foreign app"
        })

      assert {:error, _error} =
               call("analytics.overview", %{"source_handle" => foreign.id}, context)
    end
  end

  describe "configuration" do
    test "creating a source returns the write key exactly once", context do
      assert {:ok, result} =
               call(
                 "analytics.create_source",
                 %{"name" => "iOS app", "environment" => "production"},
                 context
               )

      assert String.starts_with?(result.secret, "pda_")

      assert {:ok, %{sources: sources}} = call("analytics.list_sources", %{}, context)
      refute inspect(sources) =~ result.secret
    end

    test "saving, running, updating and deleting a funnel", context do
      event(context.source, "first_open", "a", 60)
      event(context.source, "onboarding_completed", "a", 50)

      assert {:ok, %{funnel: funnel}} =
               call(
                 "analytics.create_funnel",
                 %{
                   "name" => "Onboarding",
                   "steps" => ["first_open", "onboarding_completed"],
                   "window_hours" => 24
                 },
                 context
               )

      assert funnel.steps == ["first_open", "onboarding_completed"]

      assert {:ok, %{results: [entry]}} =
               call(
                 "analytics.get_funnel",
                 %{"funnel_handle" => funnel.handle, "window" => "24h"},
                 context
               )

      assert entry.converted == 1

      assert {:ok, %{funnel: updated}} =
               call(
                 "analytics.update_funnel",
                 %{"funnel_handle" => funnel.handle, "name" => "Onboarding v2"},
                 context
               )

      assert updated.name == "Onboarding v2"
      assert updated.steps == funnel.steps

      assert {:ok, %{deleted: true}} =
               call("analytics.delete_funnel", %{"funnel_handle" => funnel.handle}, context)

      assert {:ok, %{funnels: []}} = call("analytics.list_funnels", %{}, context)
    end

    test "a funnel with a repeated adjacent step is refused", context do
      assert {:error, _error} =
               call(
                 "analytics.create_funnel",
                 %{"name" => "Bad", "steps" => ["meal_logged", "meal_logged"]},
                 context
               )
    end

    test "changing the event names keeps the primary funnel and the window", context do
      assert {:ok, %{funnel: funnel}} =
               call(
                 "analytics.create_funnel",
                 %{"name" => "Onboarding", "steps" => ["first_open", "meal_logged"]},
                 context
               )

      assert {:ok, _settings} =
               call(
                 "analytics.set_activation",
                 %{
                   "start_event" => "first_open",
                   "activation_event" => "meal_logged",
                   "window_hours" => 48,
                   "primary_funnel_handle" => funnel.handle
                 },
                 context
               )

      assert {:ok, %{settings: settings}} =
               call(
                 "analytics.set_activation",
                 %{"start_event" => "app_installed", "activation_event" => "report_exported"},
                 context
               )

      assert settings.activation_start_event == "app_installed"
      assert settings.activation_event == "report_exported"
      assert settings.primary_funnel_handle == funnel.handle
      assert settings.activation_window_hours == 48
    end

    test "activation needs both event names or neither", context do
      assert {:error, _error} =
               call("analytics.set_activation", %{"start_event" => "first_open"}, context)
    end
  end

  describe "deleting analytics data" do
    test "removes every event once the project handle is repeated", context do
      event(context.source, "meal_logged", "a", 10)

      assert {:ok, %{deleted_events: 1}} =
               call(
                 "analytics.delete_data",
                 %{"confirm_project_handle" => context.project.id},
                 context
               )

      assert %{events: 0} = Queries.totals(context.scope, Queries.range("24h"))
    end

    test "refuses when the confirmation does not match", context do
      event(context.source, "meal_logged", "a", 10)

      assert {:error, _error} =
               call("analytics.delete_data", %{"confirm_project_handle" => "wrong"}, context)

      assert %{events: 1} = Queries.totals(context.scope, Queries.range("24h"))
    end
  end

  describe "tenant isolation" do
    test "a principal cannot read another organization's project", context do
      {other_org, other_owner} = org_fixture(scope_fixture())
      other_project = project_fixture(other_owner, other_org)

      assert {:error, _error} =
               Dispatch.call(
                 "analytics.overview",
                 %{"project_handle" => other_project.id, "window" => "24h"},
                 context.principal
               )
    end
  end
end
