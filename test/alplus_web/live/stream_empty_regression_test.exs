defmodule AlplusWeb.StreamEmptyRegressionTest do
  @moduledoc """
  Locks the `@streams.x.inserts == []` false-empty bug (issue #8): a stream's
  `inserts` list holds only the last render's delta, not the stream's
  contents, so branching an empty state on it flips to a false "all clear"
  the moment an unrelated event re-renders the page. The fix in
  `monitor_live.ex` and `observe_live.ex` uses `only:block` inside the
  `phx-update="stream"` container (CSS reacts to DOM child count) or an
  explicit assign recomputed from the real query — never the delta.

  This file has two guards: a source-level check that the anti-pattern
  never comes back in any stream-using LiveView, and a behavior-level check
  that an unrelated re-render does not drop existing stream rows.
  """

  use AlplusWeb.ConnCase, async: true

  import Alplus.AuditFixtures
  import Alplus.OrgsFixtures
  import Phoenix.LiveViewTest

  alias Alplus.Monitoring.{Incident, Monitor, MonitorCheck}
  alias Alplus.Observe.Issue

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp project_scope(scope, project), do: Alplus.Scope.put_project(scope, project.id)

  # Strips HEEx comments (`<%!-- ... --%>`, used to document the anti-pattern
  # by name right next to its fix) and `#` line comments, so the source
  # guard below only ever matches real code.
  defp strip_comments(source) do
    source
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      trimmed = String.trim(line)
      if String.starts_with?(trimmed, "#"), do: "", else: trimmed
    end)
  end

  test "no LiveView branches an empty state on @streams.<name>.inserts" do
    live_files = Path.wildcard(Path.join(File.cwd!(), "lib/**/*_live.ex"))
    assert live_files != []

    offenders =
      for file <- live_files,
          source = File.read!(file),
          code = strip_comments(source),
          Regex.match?(~r/@streams\.\w+\.inserts/, code),
          do: file

    assert offenders == [],
           "these LiveViews branch on the stream delta instead of the real " <>
             "contents, reintroducing the false-empty bug: #{inspect(offenders)}"
  end

  test "monitor: an unrelated re-render never drops open incident rows or shows a false empty state",
       %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)

    monitor_a =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "Status page"},
        action: :create,
        actor: project_scope(owner_scope, project)
      )

    monitor_b =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
        action: :create,
        actor: project_scope(owner_scope, project)
      )

    Ash.create!(
      MonitorCheck,
      %{
        org_id: org.id,
        project_id: project.id,
        monitor_id: monitor_a.id,
        status: "up",
        checked_at: DateTime.utc_now()
      },
      action: :record,
      authorize?: false
    )

    # One open incident per monitor — `incidents_one_open_monitor_index`
    # forbids a second concurrent open incident on the same monitor.
    incident_a =
      Ash.create!(
        Incident,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor_a.id,
          cause: "availability",
          cause_detail: %{},
          started_at: DateTime.utc_now()
        },
        action: :open,
        authorize?: false
      )

    incident_b =
      Ash.create!(
        Incident,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor_b.id,
          cause: "heartbeat",
          cause_detail: %{},
          started_at: DateTime.utc_now()
        },
        action: :open,
        authorize?: false
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/monitor?view=incidents"
      )

    assert has_element?(view, "#incident-cause-#{incident_a.id}")
    assert has_element?(view, "#incident-cause-#{incident_b.id}")

    # A project-scoped monitor update refreshes analytical monitor data and
    # resets the incidents stream. It does not change either incident, so both
    # rows inserted by the reload must remain and the empty state must not appear.
    Phoenix.PubSub.broadcast(
      Alplus.PubSub,
      "monitor:#{project.id}",
      {:monitor_updated, project.id}
    )

    assert has_element?(view, "#incident-cause-#{incident_a.id}")
    assert has_element?(view, "#incident-cause-#{incident_b.id}")
    assert has_element?(view, "#recent-incidents")
    refute has_element?(view, "#incidents-empty")
  end

  test "observe: an analysis filter rerender keeps open issues rendered, not falsely empty",
       %{conn: conn} do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    project = project_fixture(owner_scope, org)
    agent_audit_fixture(owner_scope, project)
    {source, _secret} = source_fixture(owner_scope, org, project)
    now = DateTime.utc_now()

    issue_a =
      Ash.create!(
        Issue,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: "production",
          fingerprint: "sha256:" <> String.duplicate("a", 64),
          level: "error",
          title: "Database timeout",
          first_seen_at: now,
          last_seen_at: now
        },
        action: :record,
        authorize?: false
      )

    issue_b =
      Ash.create!(
        Issue,
        %{
          org_id: org.id,
          project_id: project.id,
          source_id: source.id,
          environment: "production",
          fingerprint: "sha256:" <> String.duplicate("b", 64),
          level: "error",
          title: "Cache miss storm",
          first_seen_at: now,
          last_seen_at: now
        },
        action: :record,
        authorize?: false
      )

    {:ok, view, _html} =
      conn
      |> log_in(owner)
      |> live(
        "/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/observe/#{source.id}"
      )

    assert has_element?(view, "#observe-detail-issue-title-#{issue_a.id}")
    assert has_element?(view, "#observe-detail-issue-title-#{issue_b.id}")

    # Reapplying the current analysis filter reloads the issue stream without
    # mutating either issue. Both rows must survive the reset and the empty
    # state must remain absent.
    render_change(view, "filter_issues", %{"q" => "", "level" => "all", "status" => "open"})

    assert has_element?(view, "#observe-detail-issue-title-#{issue_a.id}")
    assert has_element?(view, "#observe-detail-issue-title-#{issue_b.id}")
    refute has_element?(view, "#observe-detail-issues-empty")
  end
end
