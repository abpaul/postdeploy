defmodule Alplus.Monitoring.MaintenanceWorkerTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.Monitor

  test "daily maintenance removes expired heartbeat claims but preserves active claims" do
    {org, scope} = org_fixture(scope_fixture())
    project = project_fixture(scope, org)
    project_scope = Alplus.Scope.put_project(scope, project.id)

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Nightly"},
        action: :create,
        actor: project_scope
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Alplus.Repo.query!(
      """
      INSERT INTO heartbeat_ping_deduplications (monitor_id, ping_id, expires_at)
      VALUES ($1, $2, $3), ($1, $4, $5)
      """,
      [
        monitor.id,
        "expired",
        DateTime.add(now, -1, :second),
        "active",
        DateTime.add(now, 3600, :second)
      ]
    )

    assert :ok =
             Alplus.Monitoring.MaintenanceWorker.perform(%Oban.Job{
               args: %{"mode" => "daily"}
             })

    assert [["active"]] =
             Alplus.Repo.query!(
               "SELECT ping_id FROM heartbeat_ping_deduplications WHERE monitor_id = $1",
               [monitor.id]
             ).rows
  end

  test "hourly and daily perform clauses return :ok" do
    assert :ok = Alplus.Monitoring.MaintenanceWorker.perform(%Oban.Job{args: %{}})

    assert :ok =
             Alplus.Monitoring.MaintenanceWorker.perform(%Oban.Job{args: %{"mode" => "daily"}})
  end
end
