defmodule Alplus.Monitoring.MonitorUpdaterTest do
  use Alplus.DataCase, async: true

  import Alplus.OrgsFixtures

  alias Alplus.Billing.EntitlementError
  alias Alplus.Monitoring.{HeartbeatConfig, Monitor, MonitorUpdater}
  alias Alplus.Scope

  test "an expired trial cannot mutate heartbeat config before the monitor update" do
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
          interval_seconds: 300
        },
        action: :issue,
        actor: scope
      )

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    assert {:error, %EntitlementError{reason: :plan_inactive}} =
             MonitorUpdater.update(
               monitor,
               config,
               %{name: "Changed"},
               %{interval_seconds: 600},
               scope
             )

    assert Ash.get!(Monitor, monitor.id, authorize?: false).name == "Backup"
    assert Ash.get!(HeartbeatConfig, monitor.id, authorize?: false).interval_seconds == 300
  end

  test "reissuing a heartbeat invalidates the old token and reveals only the new one" do
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
          interval_seconds: 300
        },
        action: :issue,
        actor: scope
      )

    original_token = Ash.Resource.get_metadata(config, :heartbeat_token)
    assert is_binary(original_token)

    assert {:ok, reissued_config} = MonitorUpdater.reissue_heartbeat_token(monitor, scope)
    reissued_token = Ash.Resource.get_metadata(reissued_config, :heartbeat_token)

    assert is_binary(reissued_token)
    refute reissued_token == original_token
    assert {:error, :not_found} = HeartbeatConfig.authenticate(original_token)
    assert {:ok, _config} = HeartbeatConfig.authenticate(reissued_token)
  end
end
