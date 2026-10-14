defmodule Alplus.Monitoring.AsyncLifecycleTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{Heartbeat, HeartbeatConfig, Monitor}
  alias Alplus.Notifications.{AlertRule, DeliveryWorker}
  alias Alplus.Scope

  test "an expired trial heartbeat writes no check or incident" do
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

    heartbeat =
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

    token = Ash.Resource.get_metadata(heartbeat, :heartbeat_token)

    Alplus.Repo.query!("UPDATE organizations SET trial_ends_at = $1 WHERE id = $2", [
      ~U[2000-01-01 00:00:00.000000Z],
      org.id
    ])

    assert :paused = Heartbeat.accept(token, :finish)

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM monitor_checks WHERE org_id = $1", [org.id]).rows

    assert [[0]] =
             Alplus.Repo.query!("SELECT count(*) FROM incidents WHERE org_id = $1", [org.id]).rows
  end

  test "heartbeat failure persists a check and incident, then delivers the queued alert" do
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
          name: "Nightly backup"
        },
        action: :create,
        actor: scope
      )

    heartbeat =
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

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Operations",
          config: %{"to" => "operations@example.test"}
        },
        scope
      )

    Ash.create!(
      AlertRule,
      %{
        org_id: org.id,
        project_id: project.id,
        module: "monitor",
        trigger_type: "check_down",
        channel_id: channel.id
      },
      action: :create,
      actor: scope
    )

    token = Ash.Resource.get_metadata(heartbeat, :heartbeat_token)
    Phoenix.PubSub.subscribe(Alplus.PubSub, "monitor:#{project.id}")
    assert :accepted = Heartbeat.accept(token, :fail)
    assert_receive {:monitor_updated, project_id}
    assert project_id == project.id

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM monitor_checks WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3 AND status = 'down'",
               [org.id, project.id, monitor.id]
             )

    assert %{rows: [[1]]} =
             Alplus.Repo.query!(
               "SELECT count(*) FROM incidents WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3 AND status = 'open'",
               [org.id, project.id, monitor.id]
             )

    args = %{
      "org_id" => org.id,
      "alert_rule_id" => :_,
      "channel_id" => channel.id,
      "channel_type" => "email",
      "trigger" => "check_down",
      "subject_type" => "incident",
      "subject_id" => :_,
      "repeat_index" => "1"
    }

    assert_enqueued(worker: DeliveryWorker, args: args)

    [job] = all_enqueued(worker: DeliveryWorker)
    assert :ok = perform_job(DeliveryWorker, job.args)

    assert %{rows: [["sent"]]} =
             Alplus.Repo.query!(
               "SELECT status FROM notification_deliveries WHERE org_id = $1 AND channel_id = $2",
               [org.id, channel.id]
             )
  end
end
