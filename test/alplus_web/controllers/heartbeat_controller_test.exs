defmodule AlplusWeb.HeartbeatControllerTest do
  use AlplusWeb.ConnCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{HeartbeatConfig, Monitor}
  alias Alplus.Scope

  defp heartbeat_fixture do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Nightly backup"},
        action: :create,
        actor: scope
      )

    config =
      Ash.create!(
        HeartbeatConfig,
        %{
          monitor_id: monitor.id,
          org_id: org.id,
          grace_period_seconds: 60,
          interval_seconds: 300
        },
        action: :issue,
        actor: scope
      )

    {monitor, Ash.Resource.get_metadata(config, :heartbeat_token)}
  end

  defp count(table, monitor_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!("SELECT count(*) FROM #{table} WHERE monitor_id = $1", [monitor_id])

    count
  end

  test "an active heartbeat finish returns 202 and persists an up check", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()

    conn = get(conn, "/h/#{token}")

    assert response(conn, 202) == ""
    assert count("monitor_checks", monitor.id) == 1
    assert {:ok, %{last_known_status: "up"}} = Ash.get(Monitor, monitor.id, authorize?: false)
  end

  test "a paused heartbeat returns 202 without a check row", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()
    Ash.update!(monitor, %{status: "paused"}, action: :update, authorize?: false)

    conn = post(conn, "/h/#{token}")

    assert response(conn, 202) == ""
    assert count("monitor_checks", monitor.id) == 0
    assert count("incidents", monitor.id) == 0
  end

  test "an unknown token returns 404 without persistence", %{conn: conn} do
    conn = get(conn, "/h/hb_unknown-token")

    assert response(conn, 404) == ""
    %{rows: [[count]]} = Alplus.Repo.query!("SELECT count(*) FROM monitor_checks")
    assert count == 0
  end

  test "a repeated ping_id is accepted without repeating the transition", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()
    path = "/h/#{token}?state=fail&ping_id=retry-123"

    assert response(get(conn, path), 202) == ""
    assert response(get(build_conn(), path), 202) == ""
    assert count("monitor_checks", monitor.id) == 1
    assert count("incidents", monitor.id) == 1
  end

  test "an expired ping_id can be claimed again", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()
    path = "/h/#{token}?ping_id=retry-123"

    assert response(get(conn, path), 202) == ""

    Alplus.Repo.query!(
      "UPDATE heartbeat_ping_deduplications SET expires_at = now() - interval '1 second' WHERE monitor_id = $1 AND ping_id = $2",
      [monitor.id, "retry-123"]
    )

    assert response(get(build_conn(), path), 202) == ""
    assert count("monitor_checks", monitor.id) == 2
  end

  describe "exit-code path form" do
    # `@alplus/sdk`'s `exitCode` option and the crontab one-liner in its
    # README both ping `/h/:token/:exit_code`. The server had no such route,
    # so every one of those pings 404'd and the job looked silent.

    test "exit code 0 records a passing check", %{conn: conn} do
      {monitor, token} = heartbeat_fixture()

      assert response(get(conn, "/h/#{token}/0"), 202) == ""

      assert count("monitor_checks", monitor.id) == 1
      assert {:ok, %{last_known_status: "up"}} = Ash.get(Monitor, monitor.id, authorize?: false)
    end

    test "a non-zero exit code fails the check and opens an incident", %{conn: conn} do
      {monitor, token} = heartbeat_fixture()

      assert response(get(conn, "/h/#{token}/1"), 202) == ""

      assert count("monitor_checks", monitor.id) == 1
      assert count("incidents", monitor.id) == 1
      assert {:ok, %{last_known_status: "down"}} = Ash.get(Monitor, monitor.id, authorize?: false)
    end

    test "a malformed exit code is treated as a failure, not a 404", %{conn: conn} do
      {monitor, token} = heartbeat_fixture()

      assert response(get(conn, "/h/#{token}/not-a-number"), 202) == ""

      assert {:ok, %{last_known_status: "down"}} = Ash.get(Monitor, monitor.id, authorize?: false)
    end

    test "POST works the same as GET", %{conn: conn} do
      {monitor, token} = heartbeat_fixture()

      assert response(post(conn, "/h/#{token}/0"), 202) == ""
      assert count("monitor_checks", monitor.id) == 1
    end

    test "an unknown token still 404s on the exit-code form", %{conn: conn} do
      assert response(get(conn, "/h/hb_unknown-token/0"), 404) == ""
    end

    test "a paused monitor writes no check row", %{conn: conn} do
      {monitor, token} = heartbeat_fixture()
      Ash.update!(monitor, %{status: "paused"}, action: :update, authorize?: false)

      assert response(get(conn, "/h/#{token}/1"), 202) == ""
      assert count("monitor_checks", monitor.id) == 0
      assert count("incidents", monitor.id) == 0
    end
  end

  test "a hung heartbeat is detected without crashing on a naive pending_start_at", %{
    conn: conn
  } do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Backup"},
        action: :create,
        actor: scope
      )

    config =
      Ash.create!(
        HeartbeatConfig,
        %{
          monitor_id: monitor.id,
          org_id: org.id,
          grace_period_seconds: 60,
          interval_seconds: 300,
          expected_duration_seconds: 1
        },
        action: :issue,
        actor: scope
      )

    token = Ash.Resource.get_metadata(config, :heartbeat_token)

    assert response(get(conn, "/h/#{token}?state=start"), 202) == ""

    # Simulates time passing without a `sleep`: pushes `pending_start_at`
    # into the past directly in Postgres, so the column round-trips through
    # `Repo.query!` as a raw `timestamp` (a `NaiveDateTime` in Postgrex),
    # exactly like it does in production once the heartbeat is truly hung.
    Alplus.Repo.query!(
      "UPDATE heartbeat_runtime_states SET pending_start_at = now() - interval '10 seconds' WHERE monitor_id = $1",
      [monitor.id]
    )

    assert response(get(build_conn(), "/h/#{token}?state=start"), 202) == ""

    assert count("monitor_checks", monitor.id) == 1

    %{rows: [[status, error_class]]} =
      Alplus.Repo.query!(
        "SELECT status, error_class FROM monitor_checks WHERE monitor_id = $1",
        [monitor.id]
      )

    assert status == "down"
    assert error_class == "heartbeat_hung"
  end

  test "an explicit failure opens once and two passes resolve it", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()

    assert response(get(conn, "/h/#{token}?state=fail"), 202) == ""
    assert count("incidents", monitor.id) == 1

    assert response(get(build_conn(), "/h/#{token}"), 202) == ""

    %{rows: [[status]]} =
      Alplus.Repo.query!("SELECT status FROM incidents WHERE monitor_id = $1", [monitor.id])

    assert status == "open"

    assert response(get(build_conn(), "/h/#{token}"), 202) == ""

    %{rows: [[status]]} =
      Alplus.Repo.query!("SELECT status FROM incidents WHERE monitor_id = $1", [monitor.id])

    assert status == "resolved"
  end

  test "start pings between fail and two finishes still resolve the incident", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()

    assert response(get(conn, "/h/#{token}?state=fail"), 202) == ""
    assert count("incidents", monitor.id) == 1

    assert response(get(build_conn(), "/h/#{token}?state=start"), 202) == ""
    assert response(get(build_conn(), "/h/#{token}?state=finish"), 202) == ""

    %{rows: [[status]]} =
      Alplus.Repo.query!("SELECT status FROM incidents WHERE monitor_id = $1", [monitor.id])

    assert status == "open"

    assert response(get(build_conn(), "/h/#{token}?state=start"), 202) == ""
    assert response(get(build_conn(), "/h/#{token}?state=finish"), 202) == ""

    %{rows: [[status]]} =
      Alplus.Repo.query!("SELECT status FROM incidents WHERE monitor_id = $1", [monitor.id])

    assert status == "resolved"
  end

  test "a start between two finishes keeps the pass streak intact", %{conn: conn} do
    {monitor, token} = heartbeat_fixture()

    assert response(get(conn, "/h/#{token}?state=finish"), 202) == ""
    assert response(get(build_conn(), "/h/#{token}?state=start"), 202) == ""
    assert response(get(build_conn(), "/h/#{token}?state=finish"), 202) == ""

    %{rows: [[passes, failures]]} =
      Alplus.Repo.query!(
        "SELECT consecutive_passes, consecutive_failures FROM heartbeat_runtime_states WHERE monitor_id = $1",
        [monitor.id]
      )

    assert passes == 2
    assert failures == 0
    assert count("monitor_checks", monitor.id) == 2
  end

  test "two hung start pings at threshold two open an incident and mark the monitor down", %{
    conn: conn
  } do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "heartbeat",
          name: "Backup",
          failure_threshold: 2
        },
        action: :create,
        actor: scope
      )

    config =
      Ash.create!(
        HeartbeatConfig,
        %{
          monitor_id: monitor.id,
          org_id: org.id,
          grace_period_seconds: 60,
          interval_seconds: 300,
          expected_duration_seconds: 1
        },
        action: :issue,
        actor: scope
      )

    token = Ash.Resource.get_metadata(config, :heartbeat_token)

    assert response(get(conn, "/h/#{token}?state=start"), 202) == ""

    push_pending_start_into_past(monitor.id)
    assert response(get(build_conn(), "/h/#{token}?state=start"), 202) == ""
    assert count("incidents", monitor.id) == 0

    push_pending_start_into_past(monitor.id)
    assert response(get(build_conn(), "/h/#{token}?state=start"), 202) == ""

    assert count("incidents", monitor.id) == 1

    %{rows: [[failures]]} =
      Alplus.Repo.query!(
        "SELECT consecutive_failures FROM heartbeat_runtime_states WHERE monitor_id = $1",
        [monitor.id]
      )

    assert failures == 2

    assert {:ok, %{last_known_status: "down"}} =
             Ash.get(Monitor, monitor.id, authorize?: false)
  end

  defp push_pending_start_into_past(monitor_id) do
    Alplus.Repo.query!(
      "UPDATE heartbeat_runtime_states SET pending_start_at = now() - interval '10 seconds' WHERE monitor_id = $1",
      [monitor_id]
    )
  end
end
