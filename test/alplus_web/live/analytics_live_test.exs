defmodule AlplusWeb.AnalyticsLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    subscribed_fixture(org)
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :analytics})

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    %{conn: conn, org: org, scope: scope, project: project, source: source, owner: owner}
  end

  defp analytics_path(org, project, suffix \\ "", params \\ %{}) do
    base = "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/analytics"
    query = if params == %{}, do: "", else: "?" <> URI.encode_query(params)
    base <> suffix <> query
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

  describe "overview" do
    test "shows the first-run instructions before any event arrives", context do
      {:ok, _view, html} = live(context.conn, analytics_path(context.org, context.project))

      assert html =~ "Start sending analytics events"
      assert html =~ "/v1/events"
      assert html =~ "Waiting for your first event"
    end

    test "shows the headline readings once events exist", context do
      event(context.source, "first_open", "a", 60)
      event(context.source, "meal_logged", "a", 30)
      event(context.source, "first_open", "b", 20)

      {:ok, _view, html} = live(context.conn, analytics_path(context.org, context.project))

      assert html =~ "2 users in the last 30 days"
      assert html =~ "Top events"
      assert html =~ "first_open"
      refute html =~ "Start sending analytics events"
    end

    test "compares the period with the one before it", context do
      # Two users this period, one in the period before it.
      event(context.source, "first_open", "a", 60)
      event(context.source, "first_open", "b", 60)
      event(context.source, "first_open", "c", 60 * 24 * 40)

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "", %{"window" => "30d"}))

      assert html =~ "+100.0% on the period before"
    end

    test "reports an activation change in percentage points", context do
      # Previous period: one of two activated. This period: both activated.
      event(context.source, "first_open", "old_a", 60 * 24 * 40)
      event(context.source, "meal_logged", "old_a", 60 * 24 * 39)
      event(context.source, "first_open", "old_b", 60 * 24 * 40)

      event(context.source, "first_open", "new_a", 120)
      event(context.source, "meal_logged", "new_a", 60)
      event(context.source, "first_open", "new_b", 120)
      event(context.source, "meal_logged", "new_b", 60)

      scope = Alplus.Scope.put_project(context.scope, context.project.id)

      {:ok, _settings} =
        Alplus.Analytics.configure_settings(
          %{
            org_id: context.org.id,
            project_id: context.project.id,
            activation_start_event: "first_open",
            activation_event: "meal_logged"
          },
          actor: scope
        )

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "", %{"window" => "30d"}))

      assert html =~ "percentage points on the period before"
    end

    test "states that activation is not set until the project defines it", context do
      event(context.source, "first_open", "a", 60)

      {:ok, _view, html} = live(context.conn, analytics_path(context.org, context.project))

      assert html =~ "Activation"
      assert html =~ "Not set"
    end

    test "offers no create, edit or delete control", context do
      event(context.source, "first_open", "a", 60)

      {:ok, view, _html} = live(context.conn, analytics_path(context.org, context.project))

      # Scoped to the page, not the shell: the organization rail keeps its
      # own "New project" affordance, which is a human-only exception.
      refute has_element?(view, "#analytics-page form")
      refute has_element?(view, "#analytics-page a[href$='/new']")
    end
  end

  describe "events explorer" do
    test "ranks events and links to each one", context do
      event(context.source, "meal_logged", "a", 30)
      event(context.source, "meal_logged", "b", 20)
      event(context.source, "paywall_viewed", "a", 10)

      {:ok, view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/events"))

      assert html =~ "meal_logged"
      assert html =~ "paywall_viewed"
      assert has_element?(view, "a[href*='/analytics/events/meal_logged']")
    end

    test "searching narrows the list", context do
      event(context.source, "meal_logged", "a", 30)
      event(context.source, "paywall_viewed", "a", 10)

      {:ok, view, _html} =
        live(context.conn, analytics_path(context.org, context.project, "/events"))

      html =
        view
        |> element("form[phx-change='search']")
        |> render_change(%{"search" => "paywall"})

      assert html =~ "paywall_viewed"
      refute html =~ "meal_logged"
    end

    test "says so plainly when the range holds nothing", context do
      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/events"))

      assert html =~ "No events in this range"
    end
  end

  describe "event detail" do
    test "reports totals and breaks down by a property", context do
      event(context.source, "paywall_viewed", "a", 30, %{"source" => "onboarding"})
      event(context.source, "paywall_viewed", "b", 20, %{"source" => "settings"})
      event(context.source, "paywall_viewed", "a", 10, %{"source" => "onboarding"})

      {:ok, view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/events/paywall_viewed"))

      assert html =~ "paywall_viewed"
      assert html =~ "Events per user"

      breakdown =
        view
        |> element("form[phx-change='pick_property']")
        |> render_change(%{"property" => "source"})

      assert breakdown =~ "onboarding"
      assert breakdown =~ "settings"
    end

    test "renders a property value as text, never as markup", context do
      event(context.source, "paywall_viewed", "a", 10, %{"variant" => "<script>alert(1)</script>"})

      {:ok, _view, html} =
        live(
          context.conn,
          analytics_path(context.org, context.project, "/events/paywall_viewed", %{
            "property" => "variant"
          })
        )

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "funnels" do
    test "prompts for the first funnel through the agent", context do
      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/funnels"))

      assert html =~ "Save your first funnel"
      refute html =~ "<form"
    end

    test "draws a saved funnel with its conversion and largest drop", context do
      scope = Alplus.Scope.put_project(context.scope, context.project.id)

      {:ok, _funnel} =
        Alplus.Analytics.create_funnel(
          %{
            org_id: context.org.id,
            project_id: context.project.id,
            name: "Onboarding",
            steps: ["first_open", "onboarding_completed"]
          },
          actor: scope
        )

      event(context.source, "first_open", "a", 60)
      event(context.source, "first_open", "b", 60)
      event(context.source, "onboarding_completed", "a", 50)

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/funnels"))

      assert html =~ "Onboarding"
      assert html =~ "50.0%"
      assert html =~ "Largest drop in this funnel"
    end
  end

  describe "retention" do
    test "reports each period against a finished cohort", context do
      event(context.source, "meal_logged", "a", 60 * 24 * 5)
      event(context.source, "meal_logged", "a", 60 * 24 * 4)

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/retention"))

      assert html =~ "Retention"
      assert html =~ "Day 0"
      assert html =~ "Day 1"
    end

    test "says there is nothing to measure before any event", context do
      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/retention"))

      assert html =~ "No events to measure yet"
    end
  end

  describe "live events" do
    test "shows a recent event with its properties", context do
      event(context.source, "onboarding_started", "anon_7", 2, %{"step" => 1})

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/live"))

      assert html =~ "onboarding_started"
      assert html =~ "anon_7"
      assert html =~ "step"
    end

    test "waits plainly when nothing has arrived", context do
      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/live"))

      assert html =~ "Waiting for your first event"
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

    test "offers an App picker once a project has more than one app", context do
      event(context.ios, "meal_logged", "person_a", 30)

      {:ok, view, html} = live(context.conn, analytics_path(context.org, context.project))

      assert html =~ "All apps"
      assert html =~ "iOS app"
      assert has_element?(view, "form[phx-change='pick_app']")
    end

    test "draws no App picker for a project with one app", context do
      # The setup project's own key plus the two above make three, so revoke
      # two to get back to one.
      scope = Alplus.Scope.put_project(context.scope, context.project.id)
      Alplus.Sources.revoke_source!(context.ios, actor: scope)
      Alplus.Sources.revoke_source!(context.web, actor: scope)

      event(context.source, "meal_logged", "person_a", 30)

      {:ok, view, _html} = live(context.conn, analytics_path(context.org, context.project))

      refute has_element?(view, "form[phx-change='pick_app']")
    end

    test "narrows the screen to the chosen app", context do
      event(context.ios, "meal_logged", "person_a", 30)
      event(context.web, "paywall_viewed", "person_b", 20)

      {:ok, _view, html} =
        live(
          context.conn,
          analytics_path(context.org, context.project, "/events", %{"source" => context.ios.id})
        )

      assert html =~ "meal_logged"
      refute html =~ "paywall_viewed"
    end

    test "counts both apps together by default", context do
      event(context.ios, "meal_logged", "person_a", 30)
      event(context.web, "paywall_viewed", "person_b", 20)

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, context.project, "/events"))

      assert html =~ "meal_logged"
      assert html =~ "paywall_viewed"
    end

    test "ignores an app reference from another project", context do
      other_project = project_fixture(context.scope, context.org, %{name: "Other"})

      {foreign, _secret} =
        source_fixture(context.scope, context.org, other_project, %{
          type: :analytics,
          name: "Foreign app"
        })

      event(context.ios, "meal_logged", "person_a", 30)

      {:ok, _view, html} =
        live(
          context.conn,
          analytics_path(context.org, context.project, "/events", %{"source" => foreign.id})
        )

      # Falls back to every app rather than an inexplicably empty screen.
      assert html =~ "meal_logged"
    end
  end

  describe "tenant isolation" do
    test "another organization's project is a 404, never a 403", context do
      other_owner = user_fixture()
      {other_org, other_scope} = org_fixture(Alplus.Scope.for_user(other_owner.id))
      other_project = project_fixture(other_scope, other_org)
      agent_audit_fixture(other_scope, other_project)

      assert_raise AlplusWeb.NotFoundError, fn ->
        live(context.conn, analytics_path(other_org, other_project))
      end
    end

    test "one project's events never appear on another project's screen", context do
      other_project = project_fixture(context.scope, context.org, %{name: "Other"})
      agent_audit_fixture(context.scope, other_project)

      event(context.source, "meal_logged", "a", 10)

      {:ok, _view, html} =
        live(context.conn, analytics_path(context.org, other_project, "/events"))

      refute html =~ "meal_logged"
    end
  end
end
