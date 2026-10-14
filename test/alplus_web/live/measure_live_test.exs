defmodule AlplusWeb.MeasureLiveTest do
  use AlplusWeb.ConnCase, async: false

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp measure_path(org, project, params \\ %{}) do
    ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/measure?#{params}"
  end

  defp detail_path(org, project, source) do
    ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/measure/#{source.id}"
  end

  defp record_pageviews!(org, project, source, pageviews) do
    Alplus.Measure.Rollups.record!(
      %{id: project.id, org_id: org.id},
      source.id,
      "production",
      %{type: "pageview", path: "/", hostname: "example.com"},
      %{pageviews: pageviews, visitors: 2, visits: 2, bounces: 1, duration_seconds: 10},
      DateTime.utc_now()
    )
  end

  defp refute_mutation_controls(view) do
    mutation_events = ~w(
      create_site toggle_create_site cancel_create_site validate_site
      rotate_measure_source confirm_revoke_measure_source cancel_revoke_measure_source
      revoke_measure_source_input revoke_measure_source
      generate_measure_share validate_measure_share save_measure_share rotate_measure_share
    )

    refute has_element?(view, "form")

    for attribute <- ~w(phx-click phx-submit phx-change), event <- mutation_events do
      refute has_element?(view, "[#{attribute}='#{event}']")
    end

    mutation_actions =
      ~w(create edit publish unpublish pause resume acknowledge reissue archive restore rotate revoke retire resolve schedule cancel delete lifecycle)

    for action <- mutation_actions do
      refute has_element?(view, "[id*='#{action}']")
      refute has_element?(view, "a[href$='/#{action}']")
    end

    refute has_element?(view, "a[href$='/new']")
    refute has_element?(view, "a[href$='/edit']")
  end

  test "the index is one title, one chart and one list, with no intro prose", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {_source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project))

    refute_mutation_controls(view)

    # The title is the answer for this range, not the product name.
    assert has_element?(view, "h1", "No traffic in the last 24 hours yet")
    assert has_element?(view, "#breadcrumbs-2[aria-current='page']", "Traffic")
    refute has_element?(view, "#breadcrumbs", "Measure")
    assert length(Regex.scan(~r/<h1\b/, html)) == 1
    refute html =~ "See how people use your sites"
    refute html =~ "Times in UTC."
    refute html =~ "cookies"
  end

  test "the panel leads with pageviews, then visits and sending sites", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})
    record_pageviews!(org, project, source, 3)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "30d"}))

    assert has_element?(view, "#measure-traffic-readings", "Pageviews")
    assert has_element?(view, "#measure-traffic-pageviews", "3")
    assert has_element?(view, "#measure-traffic-visits", "2")
    assert has_element?(view, "#measure-traffic-sites", "1 of 1")
    assert has_element?(view, "#measure-traffic-readings", "Sites with traffic")

    # The site was connected today, so the 30 days before this one cannot be
    # compared and the change line stays away instead of explaining itself.
    refute has_element?(view, "#measure-traffic-change")
    refute render(view) =~ "not fully covered"

    # The site is named in its own row in the rail, never in the readings.
    refute has_element?(view, "#measure-traffic-readings", source.name)
    assert has_element?(view, "#measure-sites", source.name)
  end

  test "one hero chart on the screen, and one plain row per site under it", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})
    record_pageviews!(org, project, source, 3)

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "30d"}))

    html = render(view)

    assert has_element?(view, "#measure-traffic-chart")
    assert has_element?(view, "#measure-traffic-chart[data-display-kind='line']")
    assert html =~ "h-40 lg:h-[248px]"
    assert length(Regex.scan(~r/data-display-kind=/, html)) == 1

    assert has_element?(
             view,
             "#measure-sites #measure-site-#{source.id}",
             source.name
           )

    assert has_element?(view, "#measure-site-#{source.id} [aria-label='Collecting traffic']")
    refute has_element?(view, "#measure-sites-header")
    refute has_element?(view, "#measure-sites-table")
    refute has_element?(view, "[data-site-sparkline]")
  end

  test "the site name navigates to that site's detail", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project))

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#measure-site-name-#{source.id}") |> render_click()

    assert to == detail_path(org, project, source)
  end

  test "sites that need attention come first", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {older, _secret} = source_fixture(scope, org, project, %{type: :measure, name: "Older"})
    {newer, _secret} = source_fixture(scope, org, project, %{type: :measure, name: "Newer"})
    {busy, _secret} = source_fixture(scope, org, project, %{type: :measure, name: "Busy"})
    record_pageviews!(org, project, busy, 9)

    project_scope = %{scope | project_id: project.id}
    {:ok, older} = Ash.update(older, %{}, action: :revoke, actor: project_scope)

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "30d"}))

    assert has_element?(view, "#measure-site-#{older.id} [aria-label='No longer collecting']")
    assert has_element?(view, "#measure-site-#{newer.id} [aria-label='Not sending yet']")
    assert has_element?(view, "#measure-site-#{busy.id} [aria-label='Collecting traffic']")

    # Stopped, then never started, then the site that is simply collecting.
    [older_index, newer_index, busy_index] =
      Enum.map([older, newer, busy], &(:binary.match(html, "measure-site-#{&1.id}") |> elem(0)))

    assert older_index < newer_index
    assert newer_index < busy_index
  end

  test "a cross-tenant project token 404s, never 403", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    _own_project = project_fixture(owner_scope, org)
    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)

    assert_raise AlplusWeb.NotFoundError, fn ->
      conn
      |> log_in(owner)
      |> live(measure_path(org, other_project))
    end
  end

  test "a member sees the list read-only, with no create/rotate/revoke controls", %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _secret} = source_fixture(owner_scope, org, project, %{type: :measure})

    member_user = user_fixture()
    member_fixture(owner_scope, org, member_user, "member")

    {:ok, view, _html} =
      conn
      |> log_in(member_user)
      |> live(measure_path(org, project))

    assert has_element?(view, "#measure-site-#{source.id}", source.name)
    refute has_element?(view, "#new-site-button")
    refute has_element?(view, "#measure-site-create-form")
    refute has_element?(view, "#rotate-measure-site-#{source.id}")
    refute has_element?(view, "#revoke-measure-site-#{source.id}")
  end

  test "the window selector rides the URL and only offers three ranges", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {_source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project))

    render_change(view, "pick_window", %{"window" => "30d"})

    assert_patch(view, measure_path(org, project, %{window: "30d"}))

    # A 90-day deep link would draw 90 slots this screen never describes, so
    # it falls back to the default range rather than being accepted.
    {:ok, deep_linked, html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "90d"}))

    assert html =~ "last 24 hours"
    refute html =~ "last 90 days"
    assert has_element?(deep_linked, "[phx-value-window='24h'][aria-pressed='true']")
    refute has_element?(deep_linked, "[phx-value-window='90d']")
  end

  test "traffic arriving for a project with zero pageviews flashes a success transition", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "30d"}))

    refute render(view) =~ "Traffic is arriving"

    record_pageviews!(org, project, source, 1)

    render_change(view, "pick_window", %{"window" => "7d"})

    assert render(view) =~ "Traffic is arriving. Measure is now live for this project."

    reloaded = Ash.get!(Alplus.Projects.Project, project.id, actor: scope)
    assert reloaded.measure_activated_at

    {:ok, remounted_view, remounted_html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "7d"}))

    refute remounted_html =~ "Traffic is arriving"
    refute render(remounted_view) =~ "Traffic is arriving"
  end

  test "a project that already had traffic before this change never flashes retroactively", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, _secret} = source_fixture(scope, org, project, %{type: :measure})
    record_pageviews!(org, project, source, 1)

    project = Ash.get!(Alplus.Projects.Project, project.id, actor: scope)
    {:ok, project} = Alplus.Projects.activate_measure(project, actor: scope)
    assert project.measure_activated_at

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project, %{window: "7d"}))

    refute html =~ "Traffic is arriving"
    refute render(view) =~ "Traffic is arriving"
  end

  test "the index keeps analysis navigation but exposes no source mutations or secrets", %{
    conn: conn
  } do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)
    {source, secret} = source_fixture(scope, org, project, %{type: :measure})

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project))

    refute_mutation_controls(view)

    assert has_element?(view, "#measure-site-name-#{source.id}")
    refute has_element?(view, "#new-site-button")
    refute has_element?(view, "#measure-site-create-form")
    refute has_element?(view, "[phx-click='rotate_measure_source']")
    refute has_element?(view, "[phx-click='revoke_measure_source']")
    refute html =~ secret
    refute html =~ source.measure_token
    refute html =~ "measure-share"
  end

  test "a project with no site keeps the chart frame and gives one agent task", %{conn: conn} do
    owner = user_fixture()
    {org, scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(scope, org)
    agent_audit_fixture(scope, project)

    {:ok, view, html} =
      conn
      |> log_in(owner)
      |> live(measure_path(org, project))

    # The hero chart is already on the screen, empty, in the caller's words.
    assert has_element?(view, "#measure-traffic-chart[data-display-state='empty']")
    assert html =~ "Pageviews appear here once a site starts sending them."
    assert has_element?(view, "#measure-traffic-sites", "0 of 0")

    assert has_element?(view, "#measure-sites-empty")
    assert has_element?(view, "#measure-sites-empty-task", "project #{project.id}")
    assert has_element?(view, "#measure-sites-empty-action[href$='/connect']")
    assert has_element?(view, "#copy-measure-sites-empty-task", "Copy task")
    assert has_element?(view, "#topbar-agent-connection", "Agent connected")
    refute has_element?(view, "#measure-sites-empty", "Agent connection")
    refute has_element?(view, "#measure-sites")
    refute has_element?(view, "#measure-site-create-form")
    refute html =~ "New site"
    refute html =~ "measure_token"
  end
end
