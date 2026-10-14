defmodule Alplus.Monitoring.StatusDraftWorkflowConcurrencyTest do
  use Alplus.ConcurrencyCase, async: false
  use Oban.Testing, repo: Alplus.Repo

  alias Alplus.Monitoring.{ActiveCheckOutcome, Monitor}
  alias Alplus.Scope
  alias Alplus.Status
  alias Alplus.Status.IncidentDraftWorker

  test "publication followed by replay creates no new private draft" do
    context = workflow_fixture()

    assert :ok = perform_job(IncidentDraftWorker, context.job_args)

    status_incident = status_incident(context.org.id, context.project.id, context.page.id)
    assert {:ok, _published} = Status.publish_incident_draft(context.scope, status_incident)

    assert :ok = perform_job(IncidentDraftWorker, context.job_args)
    assert 0 == private_draft_count(context.org.id, context.project.id, context.page.id)
    assert 1 == status_incident_count(context.org.id, context.project.id, context.page.id)
  end

  test "concurrent workflow execution creates one incident and one composer draft" do
    context = workflow_fixture()

    results =
      race_for_workflow(context.workflow_id, 2, fn _index ->
        perform_job(IncidentDraftWorker, context.job_args)
      end)

    assert [:ok, :ok] == Enum.sort(results)
    assert 1 == status_incident_count(context.org.id, context.project.id, context.page.id)
    assert 1 == composer_draft_count(context.org.id, context.project.id, context.page.id)
  end

  defp workflow_fixture do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])

    project = project_fixture(owner_scope, org)
    actor = Scope.put_project(owner_scope, project.id)

    {:ok, page} =
      Status.create_page(actor, %{
        org_id: org.id,
        project_id: project.id,
        public_slug: "workflow-race",
        title: "Workflow race"
      })

    monitor =
      Ash.create!(
        Monitor,
        %{org_id: org.id, project_id: project.id, type: "http", name: "API"},
        action: :create,
        actor: actor
      )

    {:ok, _service} =
      Status.create_service(actor, %{
        org_id: org.id,
        project_id: project.id,
        status_page_id: page.id,
        name: "API",
        monitor_ids: [monitor.id]
      })

    down = %{status: "down", status_code: 503, latency_ms: 10, error_class: "unexpected_status"}
    assert {:ok, %{incident_id: nil}} = ActiveCheckOutcome.record(monitor.id, down)
    assert {:ok, %{incident_id: incident_id}} = ActiveCheckOutcome.record(monitor.id, down)

    %{rows: [[args]]} =
      Alplus.Repo.query!(
        "SELECT args FROM oban_jobs WHERE worker = $1 AND args->>'incident_id' = $2",
        [Oban.Worker.to_string(IncidentDraftWorker), incident_id]
      )

    %{
      org: org,
      project: project,
      scope: actor,
      page: page,
      job_args: args,
      workflow_id: args["workflow_id"]
    }
  end

  defp status_incident(org_id, project_id, page_id) do
    %{rows: [[id]]} =
      Alplus.Repo.query!(
        "SELECT id FROM status_incidents WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3",
        [org_id, project_id, page_id]
      )

    Ash.get!(Status.StatusIncident, id, authorize?: false)
  end

  defp private_draft_count(org_id, project_id, page_id) do
    count(
      "SELECT count(*) FROM status_incidents WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3 AND is_private = true",
      [org_id, project_id, page_id]
    )
  end

  defp status_incident_count(org_id, project_id, page_id) do
    count(
      "SELECT count(*) FROM status_incidents WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3",
      [org_id, project_id, page_id]
    )
  end

  defp composer_draft_count(org_id, project_id, page_id) do
    count(
      "SELECT count(*) FROM status_incident_drafts WHERE org_id = $1 AND project_id = $2 AND status_page_id = $3",
      [org_id, project_id, page_id]
    )
  end

  defp count(sql, params) do
    %{rows: [[count]]} = Alplus.Repo.query!(sql, params)
    count
  end
end
