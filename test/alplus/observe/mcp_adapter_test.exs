defmodule Alplus.Observe.McpAdapterTest do
  use Alplus.DataCase, async: false

  import Alplus.OrgsFixtures

  alias Alplus.Mcp.{Dispatch, Error, Principal}

  setup do
    {org, owner_scope} = org_fixture(scope_fixture())
    project = project_fixture(owner_scope, org)
    {source, secret} = source_fixture(owner_scope, org, project)

    %{
      org: org,
      project: project,
      source: source,
      secret: secret,
      scope: Alplus.Scope.put_project(owner_scope, project.id),
      principal: %Principal{
        grant_id: Alplus.Id.generate(:mcp_oauth_grant),
        org_id: org.id,
        project_id: project.id,
        user_id: owner_scope.user_id,
        scopes: Alplus.Mcp.Scope.all(),
        source: :oauth,
        correlation_id: Alplus.Id.generate(:request)
      }
    }
  end

  test "lists sources without exposing Observe credentials", context do
    assert {:ok, %{sources: [source], next_cursor: nil}} =
             Dispatch.call(
               "observe.list_sources",
               %{"project_handle" => context.project.id},
               context.principal
             )

    assert source.handle == context.source.id
    refute inspect(source) =~ context.secret
    refute inspect(source) =~ "secret"
  end

  test "captures through the shared ingest seam and returns sanitized evidence", context do
    assert {:ok, %{accepted: 1, event_ids: [event_id]}} =
             Dispatch.call(
               "observe.capture_error",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.source.id,
                 "event_id" => "err_018f6f3a-8b7c-7abc-8def-000000000001",
                 "timestamp" => "2026-08-24T12:00:00Z",
                 "type" => "exception",
                 "level" => "error",
                 "exception" => %{"type" => "RuntimeError", "value" => "payment failed"},
                 "user" => %{"id" => "user-1", "email" => "person@example.test"},
                 "contexts" => %{"request_id" => "private"},
                 "tags" => %{"component" => "billing"},
                 "idempotency_key" => "capture-error-001"
               },
               context.principal
             )

    assert event_id == "err_018f6f3a-8b7c-7abc-8def-000000000001"

    assert {:ok, %{issues: [issue]}} =
             Dispatch.call(
               "observe.list_issues",
               %{"project_handle" => context.project.id},
               context.principal
             )

    assert issue.event_count == 1

    assert {:ok, %{occurrences: [occurrence]}} =
             Dispatch.call(
               "observe.list_occurrences",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => issue.handle
               },
               context.principal
             )

    assert occurrence.event_id == event_id
    assert occurrence.exception_type == "RuntimeError"
    refute Map.has_key?(occurrence, :user_email)
    refute Map.has_key?(occurrence, :context)
    refute Map.has_key?(occurrence, :tags)
    refute Map.has_key?(occurrence, :breadcrumbs)
    refute Map.has_key?(occurrence, :payload_s3_key)
    refute inspect(occurrence) =~ "person@example.test"
  end

  test "supports issue lifecycle mutations and hides another tenant", context do
    assert {:ok, _} =
             Dispatch.call(
               "observe.capture_error",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => context.source.id,
                 "event_id" => "err_018f6f3a-8b7c-7abc-8def-000000000002",
                 "timestamp" => "2026-08-24T12:00:00Z",
                 "type" => "message",
                 "level" => "warning",
                 "message" => "maintenance warning",
                 "idempotency_key" => "capture-error-002"
               },
               context.principal
             )

    assert {:ok, %{issues: [issue]}} =
             Dispatch.call(
               "observe.list_issues",
               %{"project_handle" => context.project.id},
               context.principal
             )

    assert {:ok, %{issue: %{status: "resolved"}}} =
             Dispatch.call(
               "observe.resolve_issue",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => issue.handle,
                 "idempotency_key" => "resolve-error-002"
               },
               context.principal
             )

    assert {:ok, %{issue: %{status: "ignored"}}} =
             Dispatch.call(
               "observe.ignore_issue",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => issue.handle,
                 "idempotency_key" => "ignore-error-002"
               },
               context.principal
             )

    assert {:ok, %{issue: %{status: "open"}}} =
             Dispatch.call(
               "observe.reopen_issue",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => issue.handle,
                 "idempotency_key" => "reopen-error-002"
               },
               context.principal
             )

    {other_org, other_scope} = org_fixture(scope_fixture())
    other_project = project_fixture(other_scope, other_org)

    assert {:error, %Error{code: :not_found}} =
             Dispatch.call(
               "observe.list_issues",
               %{"project_handle" => other_project.id},
               context.principal
             )
  end

  test "creates, rotates, and revokes an Observe source with one-time secrets", context do
    create_args = %{
      "project_handle" => context.project.id,
      "name" => "MCP source",
      "environment" => "staging",
      "idempotency_key" => "source-create-001"
    }

    assert {:ok, %{source: %{status: "active"} = created, secret: secret}} =
             Dispatch.call("observe.create_source", create_args, context.principal)

    assert is_binary(secret)
    refute inspect(created) =~ secret
    created_handle = created.handle

    assert {:ok, %{source: %{handle: ^created_handle}, secret: ^secret}} =
             Dispatch.call("observe.create_source", create_args, context.principal)

    assert {:ok, %{source: %{handle: ^created_handle}, secret: rotated_secret}} =
             Dispatch.call(
               "observe.rotate_source",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => created.handle,
                 "grace_period_seconds" => 0,
                 "idempotency_key" => "source-rotate-001"
               },
               context.principal
             )

    assert is_binary(rotated_secret)
    refute rotated_secret == secret

    assert {:ok, %{source: %{status: "revoked"}}} =
             Dispatch.call(
               "observe.revoke_source",
               %{
                 "project_handle" => context.project.id,
                 "source_handle" => created.handle,
                 "idempotency_key" => "source-revoke-001"
               },
               context.principal
             )
  end

  test "supports assignment, merge, comments, reports, and release resolution", context do
    capture = fn event_id, message ->
      assert {:ok, _} =
               Dispatch.call(
                 "observe.capture_error",
                 %{
                   "project_handle" => context.project.id,
                   "source_handle" => context.source.id,
                   "event_id" => event_id,
                   "timestamp" => "2026-08-24T12:00:00Z",
                   "type" => "message",
                   "level" => "error",
                   "message" => message,
                   "idempotency_key" => "capture-" <> event_id
                 },
                 context.principal
               )
    end

    capture.("err_018f6f3a-8b7c-7abc-8def-000000000003", "triage-a")
    capture.("err_018f6f3a-8b7c-7abc-8def-000000000004", "triage-b")

    assert {:ok, %{issues: issues}} =
             Dispatch.call(
               "observe.list_issues",
               %{"project_handle" => context.project.id},
               context.principal
             )

    [canonical, child] = Enum.take(issues, 2)
    canonical_handle = canonical.handle
    child_handle = child.handle

    assert {:ok, %{issue: %{assignee_handle: nil}}} =
             Dispatch.call(
               "observe.assign_issue",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => canonical.handle,
                 "idempotency_key" => "assign-001"
               },
               context.principal
             )

    assert {:ok, %{issue: %{handle: ^canonical_handle}, merged_handles: [handle]}} =
             Dispatch.call(
               "observe.merge_issue",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => canonical.handle,
                 "child_issue_handles" => [child.handle],
                 "idempotency_key" => "merge-001"
               },
               context.principal
             )

    assert handle == child.handle

    assert {:ok, %{comment: %{body: "operator note"}}} =
             Dispatch.call(
               "observe.create_issue_comment",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => canonical.handle,
                 "body" => "operator note",
                 "idempotency_key" => "comment-001"
               },
               context.principal
             )

    assert {:ok, %{report: %{comments: "user report"}}} =
             Dispatch.call(
               "observe.create_issue_report",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => canonical.handle,
                 "comments" => "user report",
                 "idempotency_key" => "report-001"
               },
               context.principal
             )

    assert {:ok, %{issue: %{handle: ^child_handle}}} =
             Dispatch.call(
               "observe.unmerge_issue",
               %{
                 "project_handle" => context.project.id,
                 "issue_handle" => child.handle,
                 "idempotency_key" => "unmerge-001"
               },
               context.principal
             )
  end

  test "declares bounded mutation, publish, and destructive metadata" do
    tools = Alplus.Observe.McpAdapter.tools()
    resolve = Enum.find(tools, &(&1.name == "observe.resolve_issue"))
    create_source = Enum.find(tools, &(&1.name == "observe.create_source"))
    revoke = Enum.find(tools, &(&1.name == "observe.revoke_source"))
    comment = Enum.find(tools, &(&1.name == "observe.create_issue_comment"))

    # Resolving an issue changes nothing outside the organization, so it is a
    # plain write. Creating a source issues an ingest secret that leaves for a
    # third-party property, so it crosses the boundary. See Alplus.Mcp.Tool.
    assert resolve.requires_access == :read_write
    assert resolve.cost_weight == 2
    refute resolve.annotations.openWorldHint
    refute resolve.annotations.destructiveHint
    assert create_source.annotations.openWorldHint
    refute create_source.annotations.destructiveHint
    assert revoke.annotations.destructiveHint
    assert revoke.annotations.openWorldHint
    assert comment.input_schema.additionalProperties == false
    assert comment.input_schema.properties.body.maxLength == 4_096
  end
end
