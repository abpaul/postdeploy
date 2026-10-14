defmodule Alplus.Observe.McpAdapter do
  @moduledoc "Exposes project-scoped Observe operations to authenticated MCP callers."

  @behaviour Alplus.Mcp.Adapter

  require Ash.Query

  alias Alplus.Mcp.{Args, Cursor, Error, Principal, Tenancy, ToolSpec}

  import Alplus.Mcp.Args,
    only: [optional_enum: 3, optional_string: 2, required_string: 2, value: 2]

  import Alplus.Mcp.ToolSpec, only: [nullable_string: 0, object_schema: 1]
  alias Alplus.Observe.{Issue, IssueEvidence, Release, ReleaseHealth, SessionHealth}
  alias Alplus.Sources.Source

  @tool_prefix "observe"
  @page_default 50
  @page_min 1
  @page_max 100
  @statuses ~w(open resolved ignored)
  @levels ~w(fatal error warning info)

  @impl true
  def prefix, do: @tool_prefix

  @impl true
  def tools do
    [
      read_tool(
        "observe.list_sources",
        "List Observe sources",
        "List active Observe sources in one project. Source secrets are never returned. Use the opaque cursor for later pages.",
        %{cursor: %{type: "string"}, limit: %{type: "integer", minimum: 1, maximum: 100}},
        %{sources: %{type: "array"}, next_cursor: nullable_string()}
      ),
      read_tool(
        "observe.list_issues",
        "List Observe issues",
        "List grouped Observe issues in one project. Use filters and the opaque cursor for later pages. Merged child issues stay hidden.",
        %{
          status: %{type: "string", enum: @statuses},
          level: %{type: "string", enum: @levels},
          environment: %{type: "string"},
          source_handle: %{type: "string"},
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        },
        %{issues: %{type: "array"}, next_cursor: nullable_string()}
      ),
      read_tool(
        "observe.get_issue",
        "Get an Observe issue",
        "Get one grouped issue and safe triage metadata. Secret credentials and raw payloads never appear.",
        %{issue_handle: %{type: "string"}},
        %{issue: %{type: "object"}, summary: %{type: "object"}},
        ["issue_handle"]
      ),
      read_tool(
        "observe.list_occurrences",
        "List issue occurrences",
        "List recent sanitized evidence for one issue. Contexts, breadcrumbs, tags, user identity, storage keys, and raw payloads stay excluded.",
        %{
          issue_handle: %{type: "string"},
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: 1, maximum: 20}
        },
        %{occurrences: %{type: "array"}, next_cursor: nullable_string()},
        ["issue_handle"]
      ),
      read_tool(
        "observe.get_event",
        "Get an Observe event",
        "Get one sanitized event occurrence for an issue.",
        %{issue_handle: %{type: "string"}, event_handle: %{type: "string"}},
        %{event: %{type: "object"}},
        ["issue_handle", "event_handle"]
      ),
      read_tool(
        "observe.get_summary",
        "Get an Observe issue summary",
        "Get bounded issue evidence, affected-user count, merge information, and event count.",
        %{issue_handle: %{type: "string"}},
        %{summary: %{type: "object"}},
        ["issue_handle"]
      ),
      read_tool(
        "observe.list_releases",
        "List Observe releases",
        "List releases for one project and source. Release artifacts and source-map contents are never returned.",
        %{
          source_handle: %{type: "string"},
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        },
        %{releases: %{type: "array"}, next_cursor: nullable_string()},
        ["source_handle"]
      ),
      read_tool(
        "observe.get_release_health",
        "Get release health",
        "Read error counts, issue transitions, and crash-free session availability for one release.",
        %{release_handle: %{type: "string"}},
        %{health: %{type: "object"}},
        ["release_handle"]
      ),
      mutation_tool(
        "observe.capture_error",
        "Capture an Observe error",
        "Capture one bounded error through the same validation, grouping, deduplication, quota, alert, and redaction path as HTTP SDK ingest. Source-map upload is not supported.",
        capture_properties(),
        ["source_handle", "event_id", "timestamp", "type", "level"],
        %{
          accepted: %{type: "integer"},
          dropped: %{type: "integer"},
          dropped_reason: nullable_string(),
          event_ids: %{type: "array"}
        }
      ),
      customer_mutation_tool(
        "observe.create_source",
        "Create an Observe source",
        "Create one active Observe source for this project and return its ingest secret exactly once. The secret is never returned by reads or later operations.",
        %{
          name: %{type: "string", minLength: 1, maxLength: 120},
          environment: %{type: "string", minLength: 1, maxLength: 64}
        },
        ["name", "environment"],
        %{source: %{type: "object"}, secret: nullable_string()}
      ),
      customer_mutation_tool(
        "observe.rotate_source",
        "Rotate an Observe source secret",
        "Rotate one active Observe source credential. The replacement secret is returned exactly once; retrying the same idempotency key returns the original result.",
        %{
          source_handle: %{type: "string", minLength: 1},
          grace_period_seconds: %{type: "integer", minimum: 0, maximum: 604_800}
        },
        ["source_handle"],
        %{source: %{type: "object"}, secret: nullable_string()}
      ),
      destructive_mutation_tool(
        "observe.revoke_source",
        "Revoke an Observe source",
        "Revoke one active Observe source and permanently disable its ingest credential. This is destructive and customer-visible.",
        %{source_handle: %{type: "string", minLength: 1}},
        ["source_handle"],
        %{source: %{type: "object"}}
      ),
      mutation_tool(
        "observe.resolve_issue",
        "Resolve an Observe issue",
        "Resolve one issue after triage. Optionally attach the release that fixed it. Retry with the same idempotency key.",
        %{issue_handle: %{type: "string"}, release_handle: %{type: "string"}},
        ["issue_handle"],
        %{issue: %{type: "object"}}
      ),
      mutation_tool(
        "observe.ignore_issue",
        "Ignore an Observe issue",
        "Ignore one issue using the existing retention and expiry policy. Retry with the same idempotency key.",
        %{issue_handle: %{type: "string"}},
        ["issue_handle"],
        %{issue: %{type: "object"}}
      ),
      mutation_tool(
        "observe.reopen_issue",
        "Reopen an Observe issue",
        "Reopen one resolved or ignored issue for active triage. Retry with the same idempotency key.",
        %{issue_handle: %{type: "string"}},
        ["issue_handle"],
        %{issue: %{type: "object"}}
      ),
      mutation_tool(
        "observe.assign_issue",
        "Assign an Observe issue",
        "Assign or unassign one issue to an organization member. Retry with the same idempotency key.",
        %{issue_handle: %{type: "string"}, assignee_handle: nullable_string()},
        ["issue_handle"],
        %{issue: %{type: "object"}}
      ),
      mutation_tool(
        "observe.merge_issue",
        "Merge Observe issues",
        "Merge bounded child issues into one canonical issue. Child issues remain retained and hidden from grouped lists. Retry with the same idempotency key.",
        %{
          issue_handle: %{type: "string", minLength: 1},
          child_issue_handles: %{
            type: "array",
            minItems: 1,
            maxItems: 50,
            items: %{type: "string", minLength: 1}
          }
        },
        ["issue_handle", "child_issue_handles"],
        %{issue: %{type: "object"}, merged_handles: %{type: "array"}}
      ),
      mutation_tool(
        "observe.unmerge_issue",
        "Unmerge an Observe issue",
        "Restore one merged Observe issue to grouped triage. Retry with the same idempotency key.",
        %{issue_handle: %{type: "string"}},
        ["issue_handle"],
        %{issue: %{type: "object"}}
      ),
      mutation_tool(
        "observe.create_issue_comment",
        "Comment on an Observe issue",
        "Add one bounded operator comment to an issue. Comment content is excluded from audit metadata. Retry with the same idempotency key.",
        %{
          issue_handle: %{type: "string"},
          body: %{type: "string", minLength: 1, maxLength: 4096}
        },
        ["issue_handle", "body"],
        %{comment: %{type: "object"}}
      ),
      destructive_mutation_tool(
        "observe.delete_issue_comment",
        "Delete an Observe issue comment",
        "Delete one issue comment owned by the caller or an administrator. This is destructive and customer-visible.",
        %{comment_handle: %{type: "string", minLength: 1}},
        ["comment_handle"],
        %{deleted: %{type: "boolean"}}
      ),
      mutation_tool(
        "observe.create_issue_report",
        "Record an Observe user report",
        "Record one bounded user report on an issue. Report content is excluded from audit metadata. Retry with the same idempotency key.",
        %{
          issue_handle: %{type: "string"},
          name: %{type: "string", maxLength: 256},
          email: %{type: "string", maxLength: 256},
          comments: %{type: "string", minLength: 1, maxLength: 4096},
          event_id: %{type: "string", maxLength: 64}
        },
        ["issue_handle", "comments"],
        %{report: %{type: "object"}}
      ),
      destructive_mutation_tool(
        "observe.delete_issue_report",
        "Delete an Observe user report",
        "Delete one user report from an issue. This is destructive and customer-visible.",
        %{report_handle: %{type: "string", minLength: 1}},
        ["report_handle"],
        %{deleted: %{type: "boolean"}}
      ),
      mutation_tool(
        "observe.resolve_issue_in_release",
        "Resolve an Observe issue in a release",
        "Resolve one issue and attach the release that fixed it. Retry with the same idempotency key.",
        %{issue_handle: %{type: "string"}, release_handle: %{type: "string"}},
        ["issue_handle", "release_handle"],
        %{issue: %{type: "object"}}
      )
    ]
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch(tool, args, principal, scope) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  defp dispatch("observe.list_sources", args, principal, scope) do
    filters = %{project_handle: value(args, "project_handle"), sort: "inserted_at_desc_id_desc"}

    with {:ok, limit} <- normalize_limit(args),
         {:ok, keyset} <-
           decode_keyset(principal, args, "observe.list_sources", filters, :inserted_at),
         {:ok, sources} <- list_sources(scope, keyset, limit) do
      page = Enum.take(sources, limit)

      next =
        if length(sources) > limit,
          do:
            Cursor.encode(
              principal,
              "observe.list_sources",
              filters,
              source_keyset(List.last(page))
            )

      {:ok, %{sources: Enum.map(page, &source_payload/1), next_cursor: next}}
    end
  end

  defp dispatch("observe.list_issues", args, principal, scope) do
    with {:ok, filters} <- issue_filters(args),
         {:ok, limit} <- normalize_limit(args),
         {:ok, keyset} <-
           decode_keyset(principal, args, "observe.list_issues", filters, :last_seen_at),
         {:ok, issues} <- list_issues(scope, filters, keyset, limit) do
      page = Enum.take(issues, limit)

      next =
        if length(issues) > limit,
          do:
            Cursor.encode(
              principal,
              "observe.list_issues",
              filters,
              issue_keyset(List.last(page))
            )

      {:ok, %{issues: Enum.map(page, &issue_payload/1), next_cursor: next}}
    end
  end

  defp dispatch("observe.get_issue", args, _principal, scope) do
    with {:ok, issue_handle} <- required_string(args, "issue_handle"),
         {:ok, issue} <- get_issue(issue_handle, scope) do
      {:ok, %{issue: issue_payload(issue), summary: issue_summary(scope, issue)}}
    end
  end

  defp dispatch("observe.get_event", args, _principal, scope) do
    with {:ok, issue_handle} <- required_string(args, "issue_handle"),
         {:ok, event_handle} <- required_string(args, "event_handle"),
         {:ok, _issue} <- get_issue(issue_handle, scope),
         {:ok, occurrence} <- IssueEvidence.fetch(scope, issue_handle, event_handle) do
      {:ok, %{event: occurrence_payload(occurrence)}}
    end
  end

  defp dispatch("observe.get_summary", args, _principal, scope) do
    with {:ok, issue_handle} <- required_string(args, "issue_handle"),
         {:ok, issue} <- get_issue(issue_handle, scope) do
      {:ok, %{summary: issue_summary(scope, issue)}}
    end
  end

  defp dispatch("observe.list_occurrences", args, principal, scope) do
    with {:ok, issue_handle} <- required_string(args, "issue_handle"),
         {:ok, issue} <- get_issue(issue_handle, scope),
         {:ok, limit} <- normalize_occurrence_limit(args),
         filters <- %{
           project_handle: value(args, "project_handle"),
           issue_handle: issue.id,
           sort: "received_at_desc_event_id_desc"
         },
         {:ok, keyset} <-
           decode_keyset(principal, args, "observe.list_occurrences", filters, :received_at),
         occurrences <- IssueEvidence.recent(scope, issue.id),
         occurrences <- after_occurrence_keyset(occurrences, keyset),
         page <- Enum.take(occurrences, limit) do
      next =
        if length(occurrences) > limit,
          do:
            Cursor.encode(
              principal,
              "observe.list_occurrences",
              filters,
              occurrence_keyset(List.last(page))
            )

      {:ok, %{occurrences: Enum.map(page, &occurrence_payload/1), next_cursor: next}}
    end
  end

  defp dispatch("observe.create_source", args, _principal, scope) do
    with {:ok, name} <- required_bounded_string(args, "name", 120),
         {:ok, environment} <- required_bounded_string(args, "environment", 64),
         {:ok, source} <-
           Alplus.Sources.create_source(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               type: :observe,
               name: name,
               environment: environment
             },
             actor: scope
           ) do
      {:ok, %{source: source_payload(source), secret: Ash.Resource.get_metadata(source, :secret)}}
    end
  end

  defp dispatch("observe.rotate_source", args, _principal, scope) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_observe_source(source_handle, scope),
         {:ok, grace_period_seconds} <-
           Args.bounded_integer(
             args,
             "grace_period_seconds",
             0,
             604_800,
             86_400,
             :invalid_argument
           ),
         {:ok, rotated} <-
           Alplus.Sources.rotate_source(source, grace_period_seconds, actor: scope) do
      {:ok,
       %{source: source_payload(rotated), secret: Ash.Resource.get_metadata(rotated, :secret)}}
    end
  end

  defp dispatch("observe.revoke_source", args, _principal, scope) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_observe_source(source_handle, scope),
         {:ok, revoked} <- Alplus.Sources.revoke_source(source, actor: scope) do
      {:ok, %{source: source_payload(revoked)}}
    end
  end

  defp dispatch("observe.assign_issue", args, _principal, scope) do
    with {:ok, issue} <- issue_for_mutation(args, scope),
         {:ok, assignee_handle} <- optional_string(args, "assignee_handle"),
         {:ok, updated} <-
           Alplus.Observe.assign_issue(issue, %{assignee_id: assignee_handle}, actor: scope) do
      {:ok, %{issue: issue_payload(updated)}}
    end
  end

  defp dispatch("observe.merge_issue", args, _principal, scope) do
    with {:ok, canonical} <- issue_for_mutation(args, scope),
         {:ok, child_handles} <- bounded_handles(args, "child_issue_handles", 50),
         {:ok, children} <- issues_for_merge(child_handles, canonical, scope),
         {:ok, merged} <- merge_children(children, canonical, scope) do
      {:ok, %{issue: issue_payload(canonical), merged_handles: merged}}
    end
  end

  defp dispatch("observe.unmerge_issue", args, _principal, scope) do
    with {:ok, issue} <- issue_for_mutation(args, scope),
         {:ok, updated} <- Alplus.Observe.unmerge_issue(issue, %{}, actor: scope) do
      {:ok, %{issue: issue_payload(updated)}}
    end
  end

  defp dispatch("observe.create_issue_comment", args, _principal, scope) do
    with {:ok, issue} <- issue_for_mutation(args, scope),
         {:ok, body} <- required_bounded_string(args, "body", 4_096),
         {:ok, comment} <-
           Alplus.Observe.create_issue_comment(
             %{
               org_id: issue.org_id,
               project_id: issue.project_id,
               issue_id: issue.id,
               user_id: scope.user_id,
               body: String.trim(body)
             },
             actor: scope
           ) do
      {:ok, %{comment: comment_payload(comment)}}
    end
  end

  defp dispatch("observe.delete_issue_comment", args, _principal, scope) do
    with {:ok, handle} <- required_string(args, "comment_handle"),
         {:ok, comment} <- Alplus.Observe.get_issue_comment(handle, actor: scope),
         true <- comment.project_id == scope.project_id,
         {:ok, _deleted} <- Alplus.Observe.destroy_issue_comment(comment, actor: scope) do
      {:ok, %{deleted: true}}
    else
      false -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp dispatch("observe.create_issue_report", args, _principal, scope) do
    with {:ok, issue} <- issue_for_mutation(args, scope),
         {:ok, comments} <- required_bounded_string(args, "comments", 4_096),
         {:ok, name} <- optional_bounded_string(args, "name", 256),
         {:ok, email} <- optional_bounded_string(args, "email", 256),
         {:ok, event_id} <- optional_bounded_string(args, "event_id", 64),
         {:ok, report} <-
           Alplus.Observe.create_issue_user_report(
             %{
               org_id: issue.org_id,
               project_id: issue.project_id,
               issue_id: issue.id,
               name: name,
               email: email,
               comments: String.trim(comments),
               event_id: event_id
             },
             actor: scope
           ) do
      {:ok, %{report: report_payload(report)}}
    end
  end

  defp dispatch("observe.delete_issue_report", args, _principal, scope) do
    with {:ok, handle} <- required_string(args, "report_handle"),
         {:ok, report} <- Alplus.Observe.get_issue_user_report(handle, actor: scope),
         true <- report.project_id == scope.project_id,
         {:ok, _deleted} <- Alplus.Observe.destroy_issue_user_report(report, actor: scope) do
      {:ok, %{deleted: true}}
    else
      false -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp dispatch("observe.resolve_issue_in_release", args, _principal, scope) do
    with {:ok, issue} <- issue_for_mutation(args, scope),
         {:ok, release_handle} <- required_string(args, "release_handle"),
         {:ok, release} <- get_release(release_handle, scope),
         true <- release.source_id == issue.source_id,
         {:ok, updated} <-
           Alplus.Observe.resolve_issue(issue, %{resolved_in_release_id: release.id},
             actor: scope
           ) do
      {:ok, %{issue: issue_payload(updated)}}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp dispatch(tool, args, _principal, scope)
       when tool in ["observe.resolve_issue", "observe.ignore_issue", "observe.reopen_issue"] do
    with {:ok, issue} <- issue_for_mutation(args, scope),
         {:ok, updated} <- transition_issue(tool, issue, args, scope) do
      {:ok, %{issue: issue_payload(updated)}}
    end
  end

  defp dispatch("observe.list_releases", args, principal, scope) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_observe_source(source_handle, scope),
         {:ok, limit} <- normalize_limit(args),
         filters <- %{
           project_handle: value(args, "project_handle"),
           source_handle: source.id,
           sort: "released_at_desc_id_desc"
         },
         {:ok, keyset} <-
           decode_keyset(principal, args, "observe.list_releases", filters, :released_at),
         {:ok, releases} <- list_releases(scope, source, keyset, limit) do
      page = Enum.take(releases, limit)

      next =
        if length(releases) > limit,
          do:
            Cursor.encode(
              principal,
              "observe.list_releases",
              filters,
              release_keyset(List.last(page))
            )

      {:ok, %{releases: Enum.map(page, &release_payload/1), next_cursor: next}}
    end
  end

  defp dispatch("observe.get_release_health", args, _principal, scope) do
    with {:ok, release_handle} <- required_string(args, "release_handle"),
         {:ok, release} <- get_release(release_handle, scope) do
      counts = ReleaseHealth.counts(scope, release)
      previous = ReleaseHealth.previous_release(scope, release)

      comparison =
        ReleaseHealth.compare(counts, previous && ReleaseHealth.counts(scope, previous))

      {:ok,
       %{
         health: %{
           release: release_payload(release),
           counts: counts,
           comparison: comparison_payload(comparison),
           crash_free_sessions: crash_free_payload(scope, release)
         }
       }}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp dispatch("observe.capture_error", args, _principal, scope) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_observe_source(source_handle, scope),
         {:ok, item} <- capture_item(args),
         {:ok, result} <- capture(source, item) do
      Alplus.Ingest.OperationalMonitor.outcome(
        :errors,
        source.id,
        length(result.event_ids),
        result.dropped,
        :accepted
      )

      {:ok,
       %{
         accepted: length(result.event_ids),
         dropped: result.dropped,
         event_ids: result.event_ids,
         dropped_reason: result.dropped_reason
       }}
    end
  end

  defp dispatch(tool, args, _principal, scope)
       when tool in ["observe.resolve_issue", "observe.ignore_issue", "observe.reopen_issue"] do
    with {:ok, issue_handle} <- required_string(args, "issue_handle"),
         {:ok, issue} <- get_issue(issue_handle, scope),
         {:ok, updated} <- transition_issue(tool, issue, args, scope) do
      {:ok, %{issue: issue_payload(updated)}}
    end
  end

  defp dispatch(_tool, _args, _principal, _scope), do: {:error, :not_found}

  defp list_sources(scope, keyset, limit) do
    Source
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(type == :observe and status == :active)
    |> after_source_keyset(keyset)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read(actor: scope)
  end

  defp list_issues(scope, filters, keyset, limit) do
    Issue
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(is_nil(merged_into_issue_id))
    |> maybe_filter(:status, filters.status)
    |> maybe_filter(:level, filters.level)
    |> maybe_filter(:environment, filters.environment)
    |> maybe_filter(:source_id, filters.source_handle)
    |> after_issue_keyset(keyset)
    |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.Query.load(:source)
    |> Ash.read(actor: scope)
  end

  defp list_releases(scope, source, keyset, limit) do
    source_id = source.id

    Release
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(source_id == ^source_id)
    |> after_release_keyset(keyset)
    |> Ash.Query.sort(released_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read(actor: scope)
  end

  defp get_issue(handle, scope) do
    case Ash.get(Issue, handle, actor: scope) do
      {:ok, %Issue{project_id: project_id} = issue} when project_id == scope.project_id ->
        {:ok, issue}

      _ ->
        {:error, :not_found}
    end
  end

  defp get_release(handle, scope) do
    case Ash.get(Release, handle, actor: scope) do
      {:ok, %Release{project_id: project_id} = release} when project_id == scope.project_id ->
        {:ok, release}

      _ ->
        {:error, :not_found}
    end
  end

  defp get_observe_source(handle, scope) do
    case Ash.get(Source, handle, actor: scope) do
      {:ok, %Source{project_id: project_id, type: :observe, status: :active} = source}
      when project_id == scope.project_id ->
        {:ok, source}

      _ ->
        {:error, :not_found}
    end
  end

  defp issue_for_mutation(args, scope) do
    with {:ok, handle} <- required_string(args, "issue_handle") do
      get_issue(handle, scope)
    end
  end

  defp bounded_handles(args, key, max) do
    case value(args, key) do
      handles when is_list(handles) and handles != [] and length(handles) <= max ->
        if Enum.all?(handles, &(is_binary(&1) and byte_size(&1) in 1..128)),
          do: {:ok, Enum.uniq(handles)},
          else: {:error, {:invalid_argument, key}}

      _ ->
        {:error, {:invalid_argument, key}}
    end
  end

  defp issues_for_merge(handles, canonical, scope) do
    handles
    |> Enum.reduce_while({:ok, []}, fn handle, {:ok, issues} ->
      case get_issue(handle, scope) do
        {:ok, %{id: id, project_id: project_id, source_id: source_id} = issue}
        when id != canonical.id and project_id == canonical.project_id and
               source_id == canonical.source_id ->
          {:cont, {:ok, [issue | issues]}}

        _ ->
          {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp merge_children(children, canonical, scope) do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, merged} ->
      case Alplus.Observe.merge_issue(child, %{merged_into_issue_id: canonical.id}, actor: scope) do
        {:ok, _} -> {:cont, {:ok, [child.id | merged]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, merged} -> {:ok, Enum.reverse(merged)}
      error -> error
    end
  end

  defp required_bounded_string(args, key, max) do
    with {:ok, value} <- required_string(args, key) do
      if String.length(value) <= max, do: {:ok, value}, else: {:error, {:invalid_argument, key}}
    end
  end

  defp optional_bounded_string(args, key, max) do
    case value(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max ->
        {:ok, value}

      _ ->
        {:error, {:invalid_argument, key}}
    end
  end

  defp transition_issue("observe.resolve_issue", issue, args, scope) do
    with {:ok, release_id} <- optional_release_id(args, issue, scope) do
      Alplus.Observe.resolve_issue(issue, %{resolved_in_release_id: release_id}, actor: scope)
    end
  end

  defp transition_issue("observe.ignore_issue", issue, _args, scope),
    do: Alplus.Observe.ignore_issue(issue, %{}, actor: scope)

  defp transition_issue("observe.reopen_issue", issue, _args, scope),
    do: Alplus.Observe.reopen_issue(issue, %{}, actor: scope)

  defp optional_release_id(args, issue, scope) do
    case value(args, "release_handle") do
      nil ->
        {:ok, nil}

      handle ->
        case get_release(handle, scope) do
          {:ok, %{id: id, source_id: source_id}} when source_id == issue.source_id -> {:ok, id}
          _ -> {:error, :not_found}
        end
    end
  end

  defp capture(source, item) do
    case Alplus.Observe.Ingest.capture_item(source, item) do
      {:ok, result} -> {:ok, result}
      :malformed -> {:error, :malformed}
      {:write_failed, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp capture_item(args) do
    item = %{
      "event_id" => value(args, "event_id"),
      "type" => value(args, "type"),
      "timestamp" => value(args, "timestamp"),
      "level" => value(args, "level"),
      "message" => value(args, "message"),
      "exception" => value(args, "exception"),
      "fingerprint" => value(args, "fingerprint"),
      "release" => value(args, "release"),
      "contexts" => value(args, "contexts"),
      "tags" => value(args, "tags"),
      "breadcrumbs" => value(args, "breadcrumbs"),
      "user" => value(args, "user"),
      "mechanism" => value(args, "mechanism"),
      "sdk_name" => value(args, "sdk_name"),
      "sdk_version" => value(args, "sdk_version")
    }

    if (item["type"] == "exception" and is_map(item["exception"])) or
         (item["type"] == "message" and is_binary(item["message"])) do
      {:ok, item}
    else
      {:error, :invalid_capture}
    end
  end

  defp source_payload(source),
    do: %{
      handle: source.id,
      name: source.name,
      environment: source.environment,
      status: Atom.to_string(source.status)
    }

  defp comment_payload(comment),
    do: %{
      handle: comment.id,
      issue_handle: comment.issue_id,
      body: comment.body,
      inserted_at: datetime(comment.inserted_at)
    }

  defp report_payload(report),
    do: %{
      handle: report.id,
      issue_handle: report.issue_id,
      name: report.name,
      email: report.email,
      comments: report.comments,
      event_id: report.event_id,
      inserted_at: datetime(report.inserted_at)
    }

  defp issue_payload(issue) do
    %{
      handle: issue.id,
      title: issue.title,
      culprit: issue.culprit,
      status: Atom.to_string(issue.status),
      level: issue.level,
      environment: issue.environment,
      first_seen_at: datetime(issue.first_seen_at),
      last_seen_at: datetime(issue.last_seen_at),
      event_count: issue.event_count,
      release_first_seen: issue.release_first_seen,
      release_last_seen: issue.release_last_seen,
      source_handle: issue.source_id,
      assignee_handle: issue.assignee_id
    }
  end

  defp issue_summary(scope, issue) do
    page = IssueEvidence.page(scope, issue)

    %{
      event_count: page.group_event_count,
      affected_users: page.users_affected,
      evidence: Enum.map(page.occurrences, &occurrence_payload/1),
      merged_children: Enum.map(page.merged_children, &issue_payload/1),
      merged_parent: if(page.merged_parent, do: issue_payload(page.merged_parent)),
      issue: issue_payload(issue)
    }
  end

  defp occurrence_payload(occurrence) do
    %{
      event_id: occurrence.event_id,
      received_at: datetime(occurrence.received_at),
      occurred_at: datetime(occurrence.occurred_at),
      level: occurrence.level,
      message: safe_text(occurrence.message),
      exception_type: safe_text(occurrence.exception_type),
      exception_value: safe_text(occurrence.exception_value),
      frames: safe_frames(occurrence.frames),
      release: safe_text(occurrence.release),
      sdk_name: safe_text(occurrence.sdk_name),
      sdk_version: safe_text(occurrence.sdk_version),
      causes: Enum.map(occurrence.causes || [], &safe_cause/1)
    }
  end

  defp safe_frames(nil), do: nil

  defp safe_frames(frames),
    do:
      Enum.map(frames, fn frame ->
        frame
        |> Map.take([:file, :function, :lineno, :colno, :in_app])
        |> Map.update(:file, nil, &safe_text/1)
        |> Map.update(:function, nil, &safe_text/1)
      end)

  defp safe_cause(cause),
    do: %{
      type: safe_text(cause[:type]),
      value: safe_text(cause[:value]),
      frames: safe_frames(cause[:frames])
    }

  defp safe_text(nil), do: nil
  defp safe_text(value) when is_binary(value), do: String.slice(value, 0, 1_024)
  defp safe_text(_value), do: nil

  defp release_payload(release),
    do: %{
      handle: release.id,
      version: release.version,
      environment: release.environment,
      commit_sha: release.commit_sha,
      released_at: datetime(release.released_at),
      source_handle: release.source_id
    }

  defp comparison_payload({:ok, comparison}), do: Map.put(comparison, :availability, "available")

  defp comparison_payload({:error, :not_enough_history}),
    do: %{availability: "not_enough_history", new_issues_delta: nil, resolved_issues_delta: nil}

  defp crash_free_payload(scope, release) do
    case SessionHealth.crash_free(scope, release.version, release.source_id) do
      {:ok, result} ->
        Map.put(result, :availability, "available")

      :not_enough_data ->
        %{availability: "not_enough_data", sessions: nil, crashed: nil, crash_free_pct: nil}
    end
  end

  defp issue_filters(args) do
    with {:ok, status} <- optional_enum(args, "status", @statuses),
         {:ok, level} <- optional_enum(args, "level", @levels),
         {:ok, environment} <- optional_string(args, "environment"),
         {:ok, source_handle} <- optional_string(args, "source_handle") do
      {:ok,
       %{
         project_handle: value(args, "project_handle"),
         status: status,
         level: level,
         environment: environment,
         source_handle: source_handle,
         sort: "last_seen_at_desc_id_desc"
       }}
    end
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, :status, value) do
    status = String.to_existing_atom(value)
    Ash.Query.filter(query, status == ^status)
  end

  defp maybe_filter(query, :level, value), do: Ash.Query.filter(query, level == ^value)

  defp maybe_filter(query, :environment, value),
    do: Ash.Query.filter(query, environment == ^value)

  defp maybe_filter(query, :source_id, value), do: Ash.Query.filter(query, source_id == ^value)

  defp decode_keyset(principal, args, tool, filters, timestamp_field) do
    case value(args, "cursor") do
      nil ->
        {:ok, nil}

      cursor when is_binary(cursor) ->
        Cursor.decode(principal, tool, filters, cursor)

      _ ->
        {:error, :invalid_cursor}
    end
    |> case do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{^timestamp_field => timestamp, id: id}}
      when is_binary(timestamp) and is_binary(id) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, 0} -> {:ok, %{timestamp_field => datetime, id: id}}
          _ -> {:error, :invalid_cursor}
        end

      {:ok, _} ->
        {:error, :invalid_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_source_keyset(query, nil), do: query

  defp after_source_keyset(query, %{inserted_at: inserted_at, id: id}) do
    Ash.Query.filter(
      query,
      inserted_at < ^inserted_at or (inserted_at == ^inserted_at and id < ^id)
    )
  end

  defp after_issue_keyset(query, nil), do: query

  defp after_issue_keyset(query, %{last_seen_at: last_seen_at, id: id}) do
    Ash.Query.filter(
      query,
      last_seen_at < ^last_seen_at or (last_seen_at == ^last_seen_at and id < ^id)
    )
  end

  defp after_release_keyset(query, nil), do: query

  defp after_release_keyset(query, %{released_at: released_at, id: id}) do
    Ash.Query.filter(
      query,
      released_at < ^released_at or (released_at == ^released_at and id < ^id)
    )
  end

  defp after_occurrence_keyset(occurrences, nil), do: occurrences

  defp after_occurrence_keyset(occurrences, %{received_at: received_at, id: event_id}) do
    Enum.drop_while(occurrences, fn occurrence ->
      {datetime_iso8601(occurrence.received_at), occurrence.event_id} >=
        {DateTime.to_iso8601(received_at), event_id}
    end)
  end

  defp source_keyset(source),
    do: %{inserted_at: datetime_iso8601(source.inserted_at), id: source.id}

  defp issue_keyset(issue),
    do: %{last_seen_at: datetime_iso8601(issue.last_seen_at), id: issue.id}

  defp occurrence_keyset(occurrence),
    do: %{received_at: datetime_iso8601(occurrence.received_at), id: occurrence.event_id}

  defp release_keyset(release),
    do: %{released_at: datetime_iso8601(release.released_at), id: release.id}

  defp datetime_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp datetime_iso8601(%NaiveDateTime{} = datetime) do
    datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp normalize_limit(args),
    do: Args.bounded_integer(args, "limit", @page_min, @page_max, @page_default, :invalid_limit)

  defp normalize_occurrence_limit(args),
    do: Args.bounded_integer(args, "limit", 1, 20, 20, :invalid_limit)

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(value), do: value

  defp map_error(:invalid_limit),
    do: Error.new(:invalid_argument, "limit is outside the allowed range", %{field: "limit"})

  defp map_error(:unavailable),
    do: Error.new(:unavailable, "Observe is temporarily unavailable", %{})

  defp map_error(reason) when reason in [:malformed, :invalid_capture],
    do: Error.new(:invalid_argument, "The error payload is invalid", %{field: "capture"})

  defp map_error({:write_failed, _reason}),
    do: Error.new(:unavailable, "Observe is temporarily unavailable", %{})

  defp map_error(reason), do: Error.from(reason)

  defp read_tool(name, title, description, properties, output, required \\ []),
    do:
      ToolSpec.read_tool(
        name,
        title,
        description,
        schema(properties, required, false),
        object_schema(output)
      )

  defp mutation_tool(name, title, description, properties, required, output),
    do:
      ToolSpec.mutation_tool(
        name,
        title,
        description,
        schema(properties, required, true),
        object_schema(output),
        %{idempotentHint: true, destructiveHint: false, openWorldHint: false}
      )

  defp customer_mutation_tool(name, title, description, properties, required, output) do
    tool = mutation_tool(name, title, description, properties, required, output)
    %{tool | annotations: Map.put(tool.annotations, :openWorldHint, true)}
  end

  defp destructive_mutation_tool(name, title, description, properties, required, output) do
    tool = customer_mutation_tool(name, title, description, properties, required, output)
    %{tool | annotations: Map.put(tool.annotations, :destructiveHint, true)}
  end

  defp schema(properties, required, mutation?),
    do:
      ToolSpec.strict_object(
        properties
        |> Map.put(:project_handle, %{type: "string", minLength: 1})
        |> maybe_idempotency(mutation?),
        ["project_handle" | if(mutation?, do: ["idempotency_key" | required], else: required)]
      )

  defp maybe_idempotency(properties, true),
    do: Map.put(properties, :idempotency_key, %{type: "string", minLength: 1})

  defp maybe_idempotency(properties, false), do: properties

  defp capture_properties do
    %{
      source_handle: %{type: "string", minLength: 1},
      event_id: %{type: "string", minLength: 4, maxLength: 64},
      timestamp: %{type: "string", minLength: 1, maxLength: 64},
      type: %{type: "string", enum: ["exception", "message"]},
      level: %{type: "string", enum: @levels},
      message: %{type: "string", maxLength: 4_096},
      exception: %{type: "object"},
      release: %{type: "string", maxLength: 256},
      fingerprint: %{type: "array", maxItems: 16},
      contexts: %{type: "object"},
      tags: %{type: "object"},
      breadcrumbs: %{type: "array", maxItems: 100},
      user: %{type: "object"},
      mechanism: %{type: "string", maxLength: 64},
      sdk_name: %{type: "string", maxLength: 128},
      sdk_version: %{type: "string", maxLength: 64}
    }
  end
end
