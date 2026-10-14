defmodule Alplus.Monitoring.MonitorTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{HeartbeatConfig, HttpConfig, Incident, Monitor}
  alias Alplus.Scope

  defp project_scope(scope, project), do: Scope.put_project(scope, project.id)

  defp monitor_fixture(scope, org, project, attrs \\ %{}) do
    Ash.create!(
      Monitor,
      Map.merge(
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "Monitor #{System.unique_integer([:positive])}"
        },
        attrs
      ),
      action: :create,
      actor: project_scope(scope, project)
    )
  end

  test "an owner creates an HTTP monitor and its one-to-one config" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project)

    assert %HttpConfig{monitor_id: monitor_id, url: "https://example.test"} =
             Ash.create!(
               HttpConfig,
               %{
                 monitor_id: monitor.id,
                 org_id: org.id,
                 url: "https://example.test",
                 expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
                 interval_seconds: 300,
                 timeout_seconds: 10
               },
               action: :create,
               actor: scope
             )

    assert monitor_id == monitor.id
  end

  test "a monitor from another organization is not found" do
    {org_a, owner_a} = org_fixture(scope_fixture())
    project_a = project_fixture(owner_a, org_a)
    monitor = monitor_fixture(owner_a, org_a, project_a)

    {org_b, owner_b} = org_fixture(scope_fixture())
    project_b = project_fixture(owner_b, org_b)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.get(Monitor, monitor.id, actor: project_scope(owner_b, project_b))
  end

  test "the heartbeat schedule has exactly one interval or cron expression" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    monitor = monitor_fixture(owner_scope, org, project, %{type: "heartbeat"})

    assert_raise Postgrex.Error, ~r/monitor_heartbeat_configs_schedule_check/, fn ->
      Alplus.Repo.query!(
        """
        INSERT INTO monitor_heartbeat_configs
          (monitor_id, org_id, heartbeat_token_hash, heartbeat_token_prefix,
           grace_period_seconds, interval_seconds, cron_expression)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        """,
        [monitor.id, org.id, String.duplicate("a", 64), "abcdefgh", 60, 300, "0 6 * * *"]
      )
    end
  end

  test "a valid interval heartbeat config persists only its token hash" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project, %{type: "heartbeat"})

    assert %HeartbeatConfig{heartbeat_token_prefix: "abcdefgh"} =
             Ash.create!(
               HeartbeatConfig,
               %{
                 monitor_id: monitor.id,
                 org_id: org.id,
                 heartbeat_token_hash: String.duplicate("a", 64),
                 heartbeat_token_prefix: "abcdefgh",
                 grace_period_seconds: 60,
                 interval_seconds: 300
               },
               action: :create,
               actor: scope
             )
  end

  test "issuing a heartbeat credential returns its raw token once" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = project_scope(owner_scope, project)
    monitor = monitor_fixture(owner_scope, org, project, %{type: "heartbeat"})

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

    token = Ash.Resource.get_metadata(config, :heartbeat_token)
    assert String.starts_with?(token, "hb_")
    assert config.heartbeat_token_prefix == Alplus.Security.BearerToken.short_prefix(token)
    assert {:ok, authenticated} = HeartbeatConfig.authenticate(token)
    assert authenticated.monitor_id == monitor.id
    assert {:error, :not_found} = HeartbeatConfig.authenticate("hb_not-the-issued-token")
  end

  test "an incident transitions from open to resolved exactly once" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    monitor = monitor_fixture(owner_scope, org, project)
    started_at = ~U[2026-08-11 09:00:00.000000Z]

    incident =
      Ash.create!(
        Incident,
        %{
          org_id: org.id,
          project_id: project.id,
          monitor_id: monitor.id,
          cause: "availability",
          cause_detail: %{},
          started_at: started_at
        },
        action: :open,
        authorize?: false
      )

    assert incident.status == :open

    resolved =
      Ash.update!(
        incident,
        %{resolved_at: ~U[2026-08-11 09:02:00.000000Z], duration_seconds: 120},
        action: :resolve,
        authorize?: false
      )

    assert resolved.status == :resolved
    assert resolved.duration_seconds == 120

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(
               resolved,
               %{resolved_at: ~U[2026-08-11 09:03:00.000000Z], duration_seconds: 180},
               action: :resolve,
               authorize?: false
             )
  end
end
