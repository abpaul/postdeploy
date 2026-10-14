defmodule Alplus.Monitoring.StatusDraftWorkflowTest do
  use Alplus.DataCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  require Ash.Query

  import Alplus.OrgsFixtures

  alias Alplus.Monitoring.{ActiveCheckOutcome, Heartbeat, HeartbeatConfig, Monitor}
  alias Alplus.Audit.AuditLog
  alias Alplus.Scope
  alias Alplus.Status
  alias Alplus.Status.IncidentDraftWorker

  @worker Oban.Worker.to_string(IncidentDraftWorker)

  test "active checks and heartbeat failures create identical private Status drafts" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)

    active_monitor = monitor_fixture(scope, org, project, "http", "API")
    heartbeat_monitor = monitor_fixture(scope, org, project, "heartbeat", "Nightly backup")

    link_service(scope, org, project, page, active_monitor, "API")
    link_service(scope, org, project, page, heartbeat_monitor, "Backup")

    active_incident_id = open_active_incident(active_monitor)
    heartbeat_token = heartbeat_token(scope, org, heartbeat_monitor)

    assert :accepted = Heartbeat.accept(heartbeat_token, :fail)

    heartbeat_incident_id = open_incident_id(heartbeat_monitor.id, org.id, project.id)

    assert Enum.sort([
             [active_incident_id, active_monitor.id, page.id],
             [heartbeat_incident_id, heartbeat_monitor.id, page.id]
           ]) == workflow_rows(org.id, project.id)

    assert 3 == workflow_max_attempts(org.id, project.id, active_incident_id, page.id)

    Phoenix.PubSub.subscribe(Alplus.PubSub, "monitor:#{project.id}")
    expected_project_id = project.id

    assert :ok = perform_workflow(org.id, project.id, active_incident_id, page.id)

    assert_receive {:monitor_updated, ^expected_project_id}
    assert [active_incident_id] == private_draft_incident_ids(org.id, project.id, page.id)

    assert :ok = perform_workflow(org.id, project.id, heartbeat_incident_id, page.id)

    assert :ok = perform_workflow(org.id, project.id, active_incident_id, page.id)

    assert Enum.sort([active_incident_id, heartbeat_incident_id]) ==
             private_draft_incident_ids(org.id, project.id, page.id)

    assert 2 ==
             audit_count(org.id, project.id, "status_incident.draft")

    assert 2 ==
             audit_count(org.id, project.id, "status_incident_draft.create")

    assert 4 == system_audit_count(org.id, project.id)

    audit_org_id = org.id
    audit_project_id = project.id

    assert [%AuditLog{actor_id: nil, actor_kind: "system", transport: "automation"} | _] =
             AuditLog
             |> Ash.Query.filter(
               org_id == ^audit_org_id and project_id == ^audit_project_id and
                 actor_kind == "system"
             )
             |> Ash.read!(actor: scope)
  end

  test "direct draft creation rejects a cross-tenant Status page" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    incident_id = open_active_incident(monitor)

    {other_org, other_owner_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_owner_scope, other_org)
    other_scope = Scope.put_project(other_owner_scope, other_project.id)
    other_page = status_page_fixture(other_scope, other_org, other_project)

    assert {:error, {:permanent, "status_page_not_found_for_monitor_scope"}} =
             Status.create_failure_draft(
               org.id,
               project.id,
               other_page.id,
               monitor.id,
               incident_id
             )

    assert [] == private_draft_incident_ids(other_org.id, other_project.id, other_page.id)
  end

  test "a failed initial schedule preserves the incident signal for reconciliation" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    link_service(scope, org, project, page, monitor, "API")

    install_workflow_rejection()
    incident_id = open_active_incident(monitor)

    assert {"pending"} = reconciliation_state(org.id, project.id, incident_id)
    assert [] == workflow_rows(org.id, project.id)

    remove_workflow_rejection()
    assert :ok = IncidentDraftWorker.reconcile_pending()

    assert {"pending"} = reconciliation_state(org.id, project.id, incident_id)
    monitor_id = monitor.id
    page_id = page.id
    assert [[^incident_id, ^monitor_id, ^page_id]] = workflow_rows(org.id, project.id)

    Alplus.Repo.query!(
      "UPDATE oban_jobs SET state = 'discarded' WHERE worker = $1 AND args->>'incident_id' = $2",
      [@worker, incident_id]
    )

    assert :ok = IncidentDraftWorker.reconcile_pending()
    assert 1 == active_workflow_job_count(incident_id)

    Alplus.Repo.query!(
      "DELETE FROM oban_jobs WHERE worker = $1 AND args->>'incident_id' = $2",
      [@worker, incident_id]
    )

    assert :ok = IncidentDraftWorker.reconcile_pending()
    assert [[^incident_id, ^monitor_id, ^page_id]] = workflow_rows(org.id, project.id)

    assert :ok = perform_workflow(org.id, project.id, incident_id, page.id)
    assert :ok = IncidentDraftWorker.reconcile_pending()
    assert {"reconciled"} = reconciliation_state(org.id, project.id, incident_id)
  end

  test "a transient database rejection leaves the workflow pending until retry creates one draft" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    link_service(scope, org, project, page, monitor, "API")
    incident_id = open_active_incident(monitor)

    install_draft_rejection("40001")

    assert {:error, _reason} = perform_workflow(org.id, project.id, incident_id, page.id)

    assert {"pending", "database_transient_serialization_failure"} =
             workflow_state(org.id, project.id, incident_id, page.id)

    remove_draft_rejection()

    assert :ok = perform_workflow(org.id, project.id, incident_id, page.id)
    assert {"delivered", nil} = workflow_state(org.id, project.id, incident_id, page.id)
    assert [incident_id] == private_draft_incident_ids(org.id, project.id, page.id)
  end

  test "a removed page link records a permanent failure reason" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    service = link_service(scope, org, project, page, monitor, "API")
    incident_id = open_active_incident(monitor)

    Alplus.Repo.query!(
      "DELETE FROM status_component_monitors WHERE status_component_id = $1 AND monitor_id = $2 AND org_id = $3 AND project_id = $4",
      [service.id, monitor.id, org.id, project.id]
    )

    assert {:cancel, "status_page_not_linked_to_monitor_scope"} =
             perform_workflow(org.id, project.id, incident_id, page.id)

    assert {"failed", "status_page_not_linked_to_monitor_scope"} =
             workflow_state(org.id, project.id, incident_id, page.id)
  end

  test "the final transient attempt records exhaustion and prevents re-enqueue" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    link_service(scope, org, project, page, monitor, "API")
    incident_id = open_active_incident(monitor)

    install_draft_rejection("40001")

    assert {:cancel, "retry_exhausted_after_3_attempts:database_transient_serialization_failure"} =
             perform_workflow(org.id, project.id, incident_id, page.id,
               attempt: 3,
               max_attempts: 3
             )

    remove_draft_rejection()

    assert {"failed", "retry_exhausted_after_3_attempts:database_transient_serialization_failure"} =
             workflow_state(org.id, project.id, incident_id, page.id)

    Alplus.Repo.query!(
      "DELETE FROM oban_jobs WHERE worker = $1 AND args->>'incident_id' = $2",
      [@worker, incident_id]
    )

    assert {:ok, []} = IncidentDraftWorker.enqueue_for_monitor(monitor, incident_id)
  end

  test "a permanent PostgreSQL error cancels and records its SQLSTATE" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    link_service(scope, org, project, page, monitor, "API")
    incident_id = open_active_incident(monitor)

    install_draft_rejection("23514")

    assert {:cancel, "database_permanent_check_violation"} =
             perform_workflow(org.id, project.id, incident_id, page.id)

    remove_draft_rejection()

    assert {"failed", "database_permanent_check_violation"} =
             workflow_state(org.id, project.id, incident_id, page.id)
  end

  test "PostgreSQL shutdown states use the bounded transient retry path" do
    for sqlstate <- ["57P01", "57P02", "57P03"] do
      {org, owner_scope} = org_fixture(scope_fixture())
      project = project_fixture(owner_scope, org)
      scope = Scope.put_project(owner_scope, project.id)
      page = status_page_fixture(scope, org, project)
      monitor = monitor_fixture(scope, org, project, "http", "API")
      link_service(scope, org, project, page, monitor, "API")
      incident_id = open_active_incident(monitor)

      install_draft_rejection(sqlstate)

      assert {:error, reason} = perform_workflow(org.id, project.id, incident_id, page.id)

      assert reason in [
               "database_transient_#{sqlstate}",
               "database_transient_#{shutdown_name(sqlstate)}"
             ]

      assert {"pending", "database_transient_" <> _cause} =
               workflow_state(org.id, project.id, incident_id, page.id)

      remove_draft_rejection()
    end
  end

  test "a pruned job after two transient attempts uses its final global attempt" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    link_service(scope, org, project, page, monitor, "API")
    incident_id = open_active_incident(monitor)

    install_draft_rejection("40001")

    assert {:error, "database_transient_serialization_failure"} =
             perform_workflow(org.id, project.id, incident_id, page.id)

    assert {:error, "database_transient_serialization_failure"} =
             perform_workflow(org.id, project.id, incident_id, page.id)

    assert {"pending", "database_transient_serialization_failure"} =
             workflow_state(org.id, project.id, incident_id, page.id)

    Alplus.Repo.query!(
      "DELETE FROM oban_jobs WHERE worker = $1 AND args->>'incident_id' = $2",
      [@worker, incident_id]
    )

    assert :ok = IncidentDraftWorker.reconcile_pending()

    assert {:cancel, "retry_exhausted_after_3_attempts:database_transient_serialization_failure"} =
             perform_workflow(org.id, project.id, incident_id, page.id)

    assert {"failed", "retry_exhausted_after_3_attempts:database_transient_serialization_failure"} =
             workflow_state(org.id, project.id, incident_id, page.id)

    remove_draft_rejection()
  end

  test "the workflow ledger limits stored failure reasons to 2048 octets" do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    scope = Scope.put_project(owner_scope, project.id)
    page = status_page_fixture(scope, org, project)
    monitor = monitor_fixture(scope, org, project, "http", "API")
    link_service(scope, org, project, page, monitor, "API")
    incident_id = open_active_incident(monitor)

    workflow_id = workflow_id(org.id, project.id, incident_id, page.id)
    accepted_reason = String.duplicate("x", 2048)
    rejected_reason = String.duplicate("x", 2049)

    Alplus.Repo.query!(
      "UPDATE monitor_incident_status_draft_workflows SET failure_reason = $2 WHERE id = $1",
      [workflow_id, accepted_reason]
    )

    assert %{rows: [[2048]]} =
             Alplus.Repo.query!(
               "SELECT octet_length(failure_reason) FROM monitor_incident_status_draft_workflows WHERE id = $1",
               [workflow_id]
             )

    assert_raise Postgrex.Error, fn ->
      Alplus.Repo.query!(
        "UPDATE monitor_incident_status_draft_workflows SET failure_reason = $2 WHERE id = $1",
        [workflow_id, rejected_reason]
      )
    end
  end

  defp status_page_fixture(scope, org, project) do
    {:ok, page} =
      Status.create_page(scope, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "incident-draft-workflow",
        title: "Incident draft workflow"
      })

    page
  end

  defp monitor_fixture(scope, org, project, type, name) do
    Ash.create!(
      Monitor,
      %{org_id: org.id, project_id: project.id, type: type, name: name},
      action: :create,
      actor: scope
    )
  end

  defp link_service(scope, org, project, page, monitor, name) do
    assert {:ok, service} =
             Status.create_service(scope, %{
               org_id: org.id,
               project_id: project.id,
               status_page_id: page.id,
               name: name,
               monitor_ids: [monitor.id]
             })

    service
  end

  defp open_active_incident(monitor) do
    down = %{status: "down", status_code: 503, latency_ms: 10, error_class: "unexpected_status"}

    assert {:ok, %{incident_id: nil}} = ActiveCheckOutcome.record(monitor.id, down)
    assert {:ok, %{incident_id: incident_id}} = ActiveCheckOutcome.record(monitor.id, down)
    assert is_binary(incident_id)
    incident_id
  end

  defp heartbeat_token(scope, org, monitor) do
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

    Ash.Resource.get_metadata(config, :heartbeat_token)
  end

  defp open_incident_id(monitor_id, org_id, project_id) do
    %{rows: [[incident_id]]} =
      Alplus.Repo.query!(
        "SELECT id FROM incidents WHERE monitor_id = $1 AND org_id = $2 AND project_id = $3 AND status = 'open'",
        [monitor_id, org_id, project_id]
      )

    incident_id
  end

  defp workflow_rows(org_id, project_id) do
    Alplus.Repo.query!(
      """
      SELECT args->>'incident_id', args->>'monitor_id', args->>'status_page_id'
      FROM oban_jobs
      WHERE worker = $1
        AND args->>'org_id' = $2
        AND args->>'project_id' = $3
      ORDER BY args->>'incident_id'
      """,
      [@worker, org_id, project_id]
    ).rows
    |> Enum.sort()
  end

  defp private_draft_incident_ids(org_id, project_id, page_id) do
    Alplus.Repo.query!(
      """
      SELECT incident_id
      FROM status_incidents
      WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3 AND is_private = true
      ORDER BY incident_id
      """,
      [org_id, project_id, page_id]
    ).rows
    |> List.flatten()
  end

  defp workflow_max_attempts(org_id, project_id, incident_id, page_id) do
    %{rows: [[max_attempts]]} =
      Alplus.Repo.query!(
        "SELECT max_attempts FROM oban_jobs WHERE worker = $1 AND args->>'org_id' = $2 AND args->>'project_id' = $3 AND args->>'incident_id' = $4 AND args->>'status_page_id' = $5",
        [@worker, org_id, project_id, incident_id, page_id]
      )

    max_attempts
  end

  defp active_workflow_job_count(incident_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!(
        "SELECT count(*) FROM oban_jobs WHERE worker = $1 AND args->>'incident_id' = $2 AND state IN ('available', 'scheduled', 'retryable', 'executing')",
        [@worker, incident_id]
      )

    count
  end

  defp audit_count(org_id, project_id, action) do
    %{rows: [[count]]} =
      Alplus.Repo.query!(
        "SELECT count(*) FROM audit_logs WHERE org_id = $1 AND project_id = $2 AND action = $3 AND outcome = 'allowed'",
        [org_id, project_id, action]
      )

    count
  end

  defp system_audit_count(org_id, project_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!(
        "SELECT count(*) FROM audit_logs WHERE org_id = $1 AND project_id = $2 AND actor_id IS NULL AND actor_kind = 'system' AND transport = 'automation'",
        [org_id, project_id]
      )

    count
  end

  defp reconciliation_state(org_id, project_id, incident_id) do
    %{rows: [[state]]} =
      Alplus.Repo.query!(
        "SELECT state FROM monitor_incident_status_draft_reconciliations WHERE org_id = $1 AND project_id = $2 AND incident_id = $3",
        [org_id, project_id, incident_id]
      )

    {state}
  end

  defp install_workflow_rejection do
    Alplus.Repo.query!("""
    CREATE FUNCTION reject_incident_workflow() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'workflow rejection' USING ERRCODE = '40001';
    END;
    $$
    """)

    Alplus.Repo.query!(
      "CREATE TRIGGER reject_incident_workflow BEFORE INSERT ON monitor_incident_status_draft_workflows FOR EACH ROW EXECUTE FUNCTION reject_incident_workflow()"
    )
  end

  defp remove_workflow_rejection do
    Alplus.Repo.query!(
      "DROP TRIGGER reject_incident_workflow ON monitor_incident_status_draft_workflows"
    )

    Alplus.Repo.query!("DROP FUNCTION reject_incident_workflow()")
  end

  defp workflow_state(org_id, project_id, incident_id, page_id) do
    %{rows: [[state, failure_reason]]} =
      Alplus.Repo.query!(
        "SELECT state, failure_reason FROM monitor_incident_status_draft_workflows WHERE org_id = $1 AND project_id = $2 AND incident_id = $3 AND status_page_id = $4",
        [org_id, project_id, incident_id, page_id]
      )

    {state, failure_reason}
  end

  defp workflow_id(org_id, project_id, incident_id, page_id) do
    %{rows: [[id]]} =
      Alplus.Repo.query!(
        "SELECT id FROM monitor_incident_status_draft_workflows WHERE org_id = $1 AND project_id = $2 AND incident_id = $3 AND status_page_id = $4",
        [org_id, project_id, incident_id, page_id]
      )

    id
  end

  defp install_draft_rejection(sqlstate)
       when sqlstate in ["40001", "23514", "57P01", "57P02", "57P03"] do
    Alplus.Repo.query!("""
    CREATE FUNCTION reject_status_draft_once() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'status draft rejection' USING ERRCODE = '#{sqlstate}';
    END;
    $$
    """)

    Alplus.Repo.query!(
      "CREATE TRIGGER reject_status_draft_once BEFORE INSERT ON status_incidents FOR EACH ROW EXECUTE FUNCTION reject_status_draft_once()"
    )
  end

  defp shutdown_name("57P01"), do: "admin_shutdown"
  defp shutdown_name("57P02"), do: "crash_shutdown"
  defp shutdown_name("57P03"), do: "cannot_connect_now"

  defp remove_draft_rejection do
    Alplus.Repo.query!("DROP TRIGGER reject_status_draft_once ON status_incidents")
    Alplus.Repo.query!("DROP FUNCTION reject_status_draft_once()")
  end

  defp perform_workflow(org_id, project_id, incident_id, page_id, opts \\ []) do
    %{rows: [[args]]} =
      Alplus.Repo.query!(
        """
        SELECT args
        FROM oban_jobs
        WHERE worker = $1 AND args->>'org_id' = $2 AND args->>'project_id' = $3
          AND args->>'incident_id' = $4 AND args->>'status_page_id' = $5
        """,
        [@worker, org_id, project_id, incident_id, page_id]
      )

    perform_job(IncidentDraftWorker, args, opts)
  end
end
