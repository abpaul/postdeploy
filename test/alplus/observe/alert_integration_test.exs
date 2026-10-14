defmodule Alplus.Observe.AlertIntegrationTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  alias Alplus.Notifications.{AlertRule, DeliveryWorker}
  alias Alplus.Observe.{AlertWorker, EventWriter}
  alias Alplus.Scope

  setup do
    :ets.delete_all_objects(Alplus.Notifications.AlertRateLimiter)
    :ets.insert(Alplus.Ingest.OperationalMonitor, {:notification_backlog, 0})
    :ok
  end

  test "fans out new issue, regression, and configured error spike after event persistence" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    {source, _} = source_fixture(owner_scope, org, project)

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Observe alerts",
          config: %{"to" => "alerts@example.test"}
        },
        scope
      )

    for {trigger, condition} <- [
          {"new_issue", nil},
          {"issue_regression", nil},
          {"error_spike", %{"threshold" => 1}}
        ] do
      Ash.create!(
        AlertRule,
        %{
          org_id: org.id,
          project_id: project.id,
          module: "observe",
          trigger_type: trigger,
          condition: condition,
          channel_id: channel.id
        },
        action: :create,
        actor: scope
      )
    end

    first = event(source, "err_018f2b3c4d5e7f8090123456789a1001")

    assert {:ok, %{new_issue?: true, regression?: false, issue_id: issue_id}} =
             EventWriter.record(first)

    assert_enqueued(
      worker: AlertWorker,
      args: %{
        "event_id" => first.event_id,
        "received_at" => DateTime.to_iso8601(first.received_at)
      }
    )

    Alplus.Repo.query!(
      "UPDATE issues SET status = 'resolved', resolved_at = now() WHERE id = $1",
      [
        issue_id
      ]
    )

    second = %{
      first
      | event_id: "err_018f2b3c4d5e7f8090123456789a1002",
        received_at: DateTime.add(first.received_at, 1, :second)
    }

    assert {:ok, %{new_issue?: false, regression?: true, issue_id: ^issue_id}} =
             EventWriter.record(second)

    assert_enqueued(
      worker: AlertWorker,
      args: %{
        "event_id" => second.event_id,
        "received_at" => DateTime.to_iso8601(second.received_at)
      }
    )
  end

  test "records an Observe quota delivery with a project subject" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)

    {:ok, channel} =
      Alplus.Notifications.create_channel(
        %{
          org_id: org.id,
          type: "email",
          name: "Quota alerts",
          config: %{"to" => "quota@example.test"}
        },
        owner_scope
      )

    project_scope = Scope.put_project(owner_scope, project.id)

    Ash.create!(
      AlertRule,
      %{
        org_id: org.id,
        project_id: project.id,
        module: "observe",
        trigger_type: "quota",
        channel_id: channel.id
      },
      action: :create,
      actor: project_scope
    )

    assert :ok = Alplus.Observe.AlertRouter.fanout_quota(org.id, project.id)
    [job] = all_enqueued(worker: DeliveryWorker)
    assert job.args["subject_type"] == "project"
    assert job.args["subject_id"] == project.id

    assert :ok = perform_job(DeliveryWorker, job.args)

    assert %{rows: [["sent", "project", subject_id]]} =
             Alplus.Repo.query!(
               "SELECT status, subject_type, subject_id FROM notification_deliveries WHERE dedup_key = $1",
               [DeliveryWorker.dedup_key(job.args)]
             )

    assert subject_id == project.id
  end

  defp event(source, event_id) do
    # `error_spike` queries the database's rolling five-minute window. Use a
    # timestamp in that window so this fixture exercises the production rule.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      event_id: event_id,
      org_id: source.org_id,
      project_id: source.project_id,
      source_id: source.id,
      environment: source.environment,
      occurred_at: now,
      received_at: now,
      level: "error",
      sdk_name: "@alplus/sdk",
      sdk_version: "0.3.0",
      exception_type: "TypeError",
      exception_value: "Cannot read property",
      frames: [%{file: "/src/checkout.ts", function: "processOrder", lineno: 9}]
    }
  end
end
