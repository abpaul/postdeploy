defmodule Alplus.Billing.DataPurgeWorkerTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  import Alplus.OrgsFixtures

  alias Alplus.Billing.{DataPurgeObjectWorker, DataPurgeWorker}
  alias Alplus.Measure.{Goal, Ingest}
  alias Alplus.Monitoring.{ActiveCheckOutcome, Monitor, Rollup}

  alias Alplus.Observe.{
    EventWriter,
    Release,
    ReleaseArtifact,
    SessionRollupWriter
  }

  alias Alplus.Projects.ProjectDomain
  alias Alplus.Repo
  alias Alplus.Scope

  @history_tables ~w(analytics_hours analytics_days analytics_dimensions goal_conversions incidents monitor_pause_intervals monitor_checks monitor_daily_rollups issue_comments issue_user_reports error_events issues release_artifacts releases observe_session_rollups)

  setup do
    Application.put_env(:alplus, :observe_payload_store_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:alplus, :observe_payload_store_test_pid)
      Application.delete_env(:alplus, :observe_payload_store_test_deletes)
    end)
  end

  test "purges only organizations inactive beyond the retention window" do
    old = product_data_fixture(31)
    recent = product_data_fixture(29)

    old_memberships = count("memberships", old.org.id)
    old_audits = count("audit_logs", old.org.id)
    old_payload_key = old.payload_key
    old_artifact_key = old.artifact_key
    recent_payload_key = recent.payload_key
    recent_artifact_key = recent.artifact_key
    recent_counts = Map.new(@history_tables, &{&1, count(&1, recent.org.id)})

    assert :ok = perform_job(DataPurgeWorker, %{})

    for table <- @history_tables do
      assert count(table, old.org.id) == 0
      assert count(table, recent.org.id) == recent_counts[table]
      assert recent_counts[table] > 0
    end

    assert organization_count(old.org.id) == 1
    assert count("memberships", old.org.id) == old_memberships
    assert count("audit_logs", old.org.id) == old_audits

    object_jobs = all_enqueued(worker: DataPurgeObjectWorker)

    assert Enum.map(object_jobs, & &1.args["key"]) |> Enum.sort() ==
             Enum.sort([old_payload_key, old_artifact_key])

    assert Enum.all?(object_jobs, fn job ->
             job.args["org_id"] == old.org.id and job.args["project_id"] == old.project.id
           end)

    Enum.each(object_jobs, fn job ->
      assert :ok = perform_job(DataPurgeObjectWorker, job.args)
      assert :ok = perform_job(DataPurgeObjectWorker, job.args)
    end)

    assert_received {:observe_payload_deleted, ^old_payload_key}
    assert_received {:observe_payload_deleted, ^old_payload_key}
    assert_received {:observe_payload_deleted, ^old_artifact_key}
    assert_received {:observe_payload_deleted, ^old_artifact_key}
    refute_received {:observe_payload_deleted, ^recent_payload_key}
    refute_received {:observe_payload_deleted, ^recent_artifact_key}

    assert :ok = perform_job(DataPurgeWorker, %{})

    assert length(all_enqueued(worker: DataPurgeObjectWorker)) == length(object_jobs)

    refute_received {:observe_payload_deleted, ^old_payload_key}
    refute_received {:observe_payload_deleted, ^old_artifact_key}
  end

  test "removes stale MCP idempotency records but keeps recent records" do
    {org, _scope} = org_fixture(scope_fixture())

    attrs = %{
      org_id: org.id,
      tool: "projects.list",
      request_hash: String.duplicate("c", 64),
      result: %{"projects" => []}
    }

    stale =
      Ash.create!(
        Alplus.Mcp.IdempotencyRecord,
        Map.put(attrs, :idempotency_key, "stale"),
        authorize?: false
      )

    recent =
      Ash.create!(
        Alplus.Mcp.IdempotencyRecord,
        attrs
        |> Map.put(:idempotency_key, "recent")
        |> Map.put(:request_hash, String.duplicate("d", 64)),
        authorize?: false
      )

    Repo.query!(
      "UPDATE mcp_idempotency_records SET inserted_at = now() - interval '8 days' WHERE id = $1",
      [stale.id]
    )

    assert :ok = perform_job(DataPurgeWorker, %{})

    ids =
      Repo.query!("SELECT id FROM mcp_idempotency_records WHERE org_id = $1", [org.id]).rows
      |> List.flatten()

    refute stale.id in ids
    assert recent.id in ids
  end

  test "an object job cannot delete another organization's project key" do
    old = product_data_fixture(31)
    other = product_data_fixture(29)

    assert :ok = perform_job(DataPurgeWorker, %{})

    assert {:cancel, {:invalid_object_scope, key}} =
             perform_job(DataPurgeObjectWorker, %{
               "key" => other.payload_key,
               "kind" => "events",
               "org_id" => old.org.id,
               "project_id" => other.project.id
             })

    assert key == other.payload_key
    refute_received {:observe_payload_deleted, ^key}
  end

  test "does not delete an object that still has a database reference" do
    recent = product_data_fixture(0)
    payload_key = recent.payload_key
    artifact_key = recent.artifact_key

    assert {:snooze, 5} =
             perform_job(DataPurgeObjectWorker, %{
               "key" => recent.payload_key,
               "kind" => "events",
               "org_id" => recent.org.id,
               "project_id" => recent.project.id
             })

    assert {:snooze, 5} =
             perform_job(DataPurgeObjectWorker, %{
               "key" => recent.artifact_key,
               "kind" => "artifacts",
               "org_id" => recent.org.id,
               "project_id" => recent.project.id
             })

    refute_received {:observe_payload_deleted, ^payload_key}
    refute_received {:observe_payload_deleted, ^artifact_key}
  end

  test "a pre-delete object check stays retryable until its reference is removed" do
    recent = product_data_fixture(0)
    key = recent.payload_key

    args = %{
      "key" => key,
      "kind" => "events",
      "org_id" => recent.org.id,
      "project_id" => recent.project.id
    }

    assert {:snooze, 5} = perform_job(DataPurgeObjectWorker, args)

    Repo.query!(
      "DELETE FROM error_events WHERE org_id = $1 AND payload_s3_key = $2",
      [recent.org.id, key]
    )

    assert :ok = perform_job(DataPurgeObjectWorker, args)
    assert_received {:observe_payload_deleted, ^key}
  end

  test "retries a failed object deletion outside the database purge" do
    old = product_data_fixture(31)

    Application.put_env(:alplus, :observe_payload_store_test_deletes, %{
      old.payload_key => {:error, :timeout}
    })

    assert :ok = perform_job(DataPurgeWorker, %{})

    job =
      all_enqueued(worker: DataPurgeObjectWorker)
      |> Enum.find(&(&1.args["key"] == old.payload_key))

    assert {:error, {:payload_delete_failed, key, :timeout}} =
             perform_job(DataPurgeObjectWorker, job.args)

    assert key == old.payload_key
    assert count("error_events", old.org.id) == 0
    assert count("analytics_hours", old.org.id) == 0
    assert count("monitor_checks", old.org.id) == 0
  end

  defp product_data_fixture(days_inactive) do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    project_scope = Scope.put_project(owner_scope, project.id)

    {measure_source, _secret} =
      source_fixture(owner_scope, org, project, %{type: :measure})

    {observe_source, _secret} =
      source_fixture(owner_scope, org, project, %{type: :observe})

    Ash.create!(
      ProjectDomain,
      %{org_id: org.id, project_id: project.id, hostname: "app.example.test"},
      action: :create,
      actor: project_scope
    )

    goal =
      Ash.create!(
        Goal,
        %{
          org_id: org.id,
          project_id: project.id,
          name: "Pricing",
          kind: "pageview",
          path: "/pricing"
        },
        action: :create,
        actor: project_scope
      )

    monitor =
      Ash.create!(
        Monitor,
        %{
          org_id: org.id,
          project_id: project.id,
          type: "http",
          name: "Production",
          failure_threshold: 1
        },
        action: :create,
        actor: project_scope
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hour = DateTime.truncate(now, :second)
    record_measure_history(org, project, measure_source, goal, hour, now)
    record_monitor_history(project_scope, monitor)
    record_session_rollup(org, project, observe_source, now)

    {payload_key, artifact_key} =
      record_observe_history(
        org,
        project,
        observe_source,
        project_scope,
        owner_scope.user_id,
        now
      )

    org =
      org
      |> Ash.Changeset.for_update(:update, %{}, actor: owner_scope)
      |> Ash.Changeset.force_change_attribute(
        :trial_ends_at,
        DateTime.add(now, -days_inactive, :day)
      )
      |> Ash.update!()

    %{org: org, project: project, payload_key: payload_key, artifact_key: artifact_key}
  end

  defp record_measure_history(org, project, source, goal, hour, now) do
    assert :accepted =
             Ingest.record(
               source,
               "https://app.example.test",
               %{"url" => "https://app.example.test/pricing"},
               {203, 0, 113, 10},
               "purge-worker-test",
               nil,
               now
             )

    # Goal conversion storage has no production create action yet. Use one
    # fixed, parameterized row to prove the purge covers this retained table.
    Repo.query!(
      """
      INSERT INTO goal_conversions
        (id, org_id, project_id, goal_id, environment, hour, conversions, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'production', $5, 1, now(), now())
      """,
      [Ecto.UUID.generate() |> Ecto.UUID.dump!(), org.id, project.id, goal.id, hour]
    )
  end

  defp record_monitor_history(scope, monitor) do
    assert {:ok, %{incident_id: incident_id}} =
             ActiveCheckOutcome.record(monitor.id, %{
               status: "down",
               status_code: 503,
               latency_ms: 25,
               error_class: "http_status"
             })

    assert is_binary(incident_id)

    assert {:ok, _monitor} =
             Alplus.Monitoring.update_monitor(monitor, %{status: "paused"}, actor: scope)

    previous_day = Date.add(Date.utc_today(), -1)
    assert {:ok, _rollup} = Rollup.finalize(scope, monitor.id, previous_day)
  end

  defp record_observe_history(org, project, source, scope, user_id, now) do
    event_id = "evt_#{System.unique_integer([:positive])}"
    payload_key = "events/#{project.id}/#{event_id}.json"

    assert {:ok, %{issue_id: issue_id}} =
             EventWriter.record(%{
               event_id: event_id,
               org_id: org.id,
               project_id: project.id,
               source_id: source.id,
               environment: source.environment,
               occurred_at: now,
               received_at: now,
               level: "error",
               sdk_name: "purge-worker-test",
               sdk_version: "1.0.0",
               exception_type: "RuntimeError",
               exception_value: "Boom",
               frames: [%{file: "/app/example.ex", function: "run", lineno: 10}],
               payload_s3_key: payload_key
             })

    assert {:ok, _comment} =
             Alplus.Observe.create_issue_comment(
               %{
                 org_id: org.id,
                 project_id: project.id,
                 issue_id: issue_id,
                 user_id: user_id,
                 body: "Investigating"
               },
               actor: scope
             )

    assert {:ok, _report} =
             Alplus.Observe.create_issue_user_report(
               %{
                 org_id: org.id,
                 project_id: project.id,
                 issue_id: issue_id,
                 name: "Customer",
                 comments: "Broken page",
                 event_id: event_id
               },
               actor: scope
             )

    assert {:ok, %Release{} = release} =
             Alplus.Observe.create_release(
               %{
                 org_id: org.id,
                 project_id: project.id,
                 source_id: source.id,
                 environment: source.environment,
                 version: "1.0.0",
                 released_at: now
               },
               actor: scope
             )

    artifact_key = "artifacts/#{project.id}/#{release.id}/app.js.map"

    assert {:ok, %ReleaseArtifact{}} =
             Alplus.Observe.create_release_artifact(
               %{
                 org_id: org.id,
                 project_id: project.id,
                 release_id: release.id,
                 name: "app.js.map",
                 type: "source_map",
                 storage_key: artifact_key,
                 sha256: String.duplicate("a", 64),
                 byte_size: 1
               },
               actor: scope
             )

    {payload_key, artifact_key}
  end

  defp record_session_rollup(org, project, source, now) do
    assert :claimed =
             SessionRollupWriter.record!(%{
               session_id: "session_#{System.unique_integer([:positive])}",
               org_id: org.id,
               project_id: project.id,
               source_id: source.id,
               environment: source.environment,
               status: "healthy",
               release: "1.0.0",
               received_at: now
             })
  end

  defp count(table, org_id) do
    Repo.query!("SELECT count(*) FROM #{table} WHERE org_id = $1", [org_id]).rows
    |> then(fn [[value]] -> value end)
  end

  defp organization_count(org_id) do
    Repo.query!("SELECT count(*) FROM organizations WHERE id = $1", [org_id]).rows
    |> then(fn [[value]] -> value end)
  end
end
