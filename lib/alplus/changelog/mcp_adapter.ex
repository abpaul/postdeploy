defmodule Alplus.Changelog.McpAdapter do
  @moduledoc "Exposes agent-managed changelog tools to authenticated MCP callers."

  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Changelog
  alias Alplus.Changelog.Revision
  alias Alplus.Mcp.{Args, Cursor, Error, Principal, Tenancy, ToolSpec}

  import Alplus.Mcp.Args, only: [value: 2]
  alias Alplus.PublicPages

  @tool_prefix "changelog"
  @page_default 50
  @page_min 1
  @page_max 100

  @impl true
  def prefix, do: @tool_prefix

  @impl true
  def tools do
    [
      read_tool(
        "changelog.get_settings",
        "Get changelog settings",
        "Call this tool when you need the public changelog title, slug, enabled state, or URLs. This read is safe to retry.",
        %{},
        [],
        %{settings: %{type: "object"}}
      ),
      ToolSpec.read_tool(
        "changelog.list_entries",
        "List changelog entries",
        "Call this tool when you need the newest changelog entries, optionally filtered by status. Pass the cursor for later pages. This read is safe to retry.",
        page_schema(%{status: %{type: "string"}}),
        page_output_schema("entries")
      ),
      ToolSpec.read_tool(
        "changelog.get_entry",
        "Get a changelog entry",
        "Call this tool when you need one changelog entry. Pass entry_handle or external_id; at least one is required. This read is safe to retry.",
        %{entry_handle: %{type: "string"}, external_id: %{type: "string"}}
        |> resource_schema([])
        |> Map.put(:anyOf, [%{required: ["entry_handle"]}, %{required: ["external_id"]}]),
        object_schema(%{entry: %{type: "object"}})
      ),
      ToolSpec.read_tool(
        "changelog.list_revisions",
        "List entry revisions",
        "Call this tool when you need the newest revisions for one entry. Pass the cursor for later pages. This read is safe to retry.",
        page_schema(%{entry_handle: %{type: "string"}}, ["entry_handle"]),
        page_output_schema("revisions")
      ),
      read_tool(
        "changelog.get_revision",
        "Get a changelog revision",
        "Call this tool when you need the Markdown source and metadata for one revision. This read is safe to retry.",
        %{revision_handle: %{type: "string"}},
        ["revision_handle"],
        %{revision: %{type: "object"}}
      ),
      read_tool(
        "changelog.preview_entry",
        "Preview a changelog entry",
        "Call this tool when you need sanitized HTML for the current draft revision without changing stored content. This read is safe to retry.",
        %{entry_handle: %{type: "string"}},
        ["entry_handle"],
        %{html: %{type: "string"}}
      ),
      mutation_tool(
        "changelog.upsert_draft",
        "Upsert a changelog draft",
        "Create or revise a draft by external_id within this grant. Pass entry_handle to revise an existing entry after grant rotation; the handle is scoped to this project. Published entries keep serving current content until the new revision is published. Retry with the same idempotency key.",
        %{
          entry_handle: %{type: "string"},
          external_id: %{type: "string"},
          markdown: %{
            type: "string",
            description:
              "Markdown document. Front matter requires a plain-string title and may include summary (500 characters), area (monitor, observe, measure, or platform), version (80 characters), media/media_url (http or https), media_alt (required when media is present), and media_caption (300 characters). Unknown or duplicate keys, unsafe media URLs, and raw HTML in the body are rejected. Existing title-only documents remain valid."
          },
          sources: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                kind: %{
                  type: "string",
                  enum: ["pull_request", "issue", "release", "deployment", "commit", "other"]
                },
                url: %{type: "string"},
                label: %{type: "string"}
              },
              required: ["kind", "url"]
            }
          }
        },
        ["external_id", "markdown", "sources"],
        %{entry: %{type: "object"}}
      ),
      publish_tool(
        "changelog.publish_entry",
        "Publish a changelog entry",
        "Call this tool to publish a draft after checking its revision and evidence. Retry with the same idempotency key.",
        %{entry_handle: %{type: "string"}, expected_revision: %{type: ["string", "integer"]}},
        ["entry_handle", "expected_revision"],
        %{entry: %{type: "object"}}
      ),
      mutation_tool(
        "changelog.archive_entry",
        "Archive a changelog entry",
        "Call this tool to hide a published entry from active changelog listings. Retry with the same idempotency key.",
        %{entry_handle: %{type: "string"}},
        ["entry_handle"],
        %{entry: %{type: "object"}}
      ),
      mutation_tool(
        "changelog.restore_entry",
        "Restore a changelog entry",
        "Call this tool to move an archived entry back to draft. This creates a new draft revision with a higher revision number than the one you had. Retry with the same idempotency key.",
        %{entry_handle: %{type: "string"}},
        ["entry_handle"],
        %{entry: %{type: "object"}}
      ),
      ToolSpec.mutation_tool(
        "changelog.delete_entry",
        "Delete a changelog entry",
        "Call this tool only when permanent deletion is required. This operation is destructive. Retry only with the same idempotency key.",
        mutation_schema(%{entry_handle: %{type: "string"}}, ["entry_handle"]),
        object_schema(%{deleted: %{type: "boolean"}}),
        %{destructiveHint: true, idempotentHint: true}
      )
    ]
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch(tool, args, principal, scope, project_handle) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason, error_mode(tool))}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  defp dispatch("changelog.get_settings", _args, _principal, scope, _project_handle) do
    with {:ok, public_page} <- PublicPages.get_for_project(scope, scope.project_id) do
      {:ok, %{settings: settings(public_page)}}
    end
  end

  defp dispatch("changelog.list_entries", args, principal, scope, project_handle) do
    status = normalize_status(value(args, "status"))
    filters = %{project_handle: project_handle, status: status}

    with {:ok, limit} <- normalize_limit(args),
         {:ok, offset} <- decode_cursor(principal, args, "changelog.list_entries", filters),
         {:ok, entries} <-
           Changelog.list_entries(scope.project_id,
             actor: scope,
             status: status,
             limit: offset + limit + 1
           ) do
      page = entries |> Enum.drop(offset) |> Enum.take(limit)

      next_cursor =
        next_cursor(principal, "changelog.list_entries", filters, offset, entries, limit)

      {:ok, %{entries: Enum.map(page, &entry/1), next_cursor: next_cursor}}
    end
  end

  defp dispatch("changelog.get_entry", args, principal, scope, _project_handle) do
    with {:ok, entry} <- find_entry(args, scope, principal) do
      {:ok, %{entry: entry(entry)}}
    end
  end

  defp dispatch("changelog.list_revisions", args, principal, scope, project_handle) do
    with {:ok, entry} <- required_entry(args, scope),
         filters <- %{project_handle: project_handle, entry_handle: entry.id},
         {:ok, limit} <- normalize_limit(args),
         {:ok, offset} <- decode_cursor(principal, args, "changelog.list_revisions", filters),
         {:ok, revisions} <-
           Changelog.list_revisions(entry, actor: scope, limit: offset + limit + 1) do
      page = revisions |> Enum.drop(offset) |> Enum.take(limit)

      next_cursor =
        next_cursor(principal, "changelog.list_revisions", filters, offset, revisions, limit)

      {:ok, %{revisions: Enum.map(page, &revision_summary/1), next_cursor: next_cursor}}
    end
  end

  defp dispatch("changelog.get_revision", args, _principal, scope, _project_handle) do
    with {:ok, revision_handle} <- required_string(args, "revision_handle"),
         {:ok, revision} <- Changelog.get_revision(revision_handle, actor: scope) do
      {:ok, %{revision: revision(revision)}}
    end
  end

  defp dispatch("changelog.preview_entry", args, _principal, scope, _project_handle) do
    with {:ok, entry} <- required_entry(args, scope),
         {:ok, html} <- Changelog.preview_entry(entry, actor: scope) do
      {:ok, %{html: html}}
    end
  end

  defp dispatch("changelog.upsert_draft", args, principal, scope, _project_handle) do
    with {:ok, external_id} <- required_string(args, "external_id"),
         {:ok, markdown} <- required_string(args, "markdown"),
         {:ok, sources} <- required_list(args, "sources"),
         {:ok, entry_handle} <- optional_string(args, "entry_handle") do
      attrs = %{
        project_id: scope.project_id,
        grant_id: principal.grant_id,
        external_id: external_id,
        markdown: markdown,
        sources: Enum.map(sources, &source_attrs/1)
      }

      attrs = if entry_handle, do: Map.put(attrs, :entry_handle, entry_handle), else: attrs

      with {:ok, entry} <- Changelog.upsert_draft(attrs, actor: scope) do
        {:ok, %{entry: entry(entry)}}
      end
    end
  end

  defp dispatch("changelog.publish_entry", args, _principal, scope, _project_handle) do
    with {:ok, entry} <- required_entry(args, scope),
         {:ok, expected_revision} <- required_value(args, "expected_revision"),
         result <-
           Changelog.publish_entry(entry, normalize_revision(expected_revision), actor: scope) do
      publish_result(result, entry, scope)
    end
  end

  defp dispatch("changelog.archive_entry", args, _principal, scope, _project_handle) do
    with {:ok, entry} <- required_entry(args, scope),
         {:ok, archived} <- Changelog.archive_entry(entry, actor: scope) do
      {:ok, %{entry: entry(archived)}}
    end
  end

  defp dispatch("changelog.restore_entry", args, _principal, scope, _project_handle) do
    with {:ok, entry} <- required_entry(args, scope),
         {:ok, restored} <- Changelog.restore_to_draft(entry, actor: scope) do
      {:ok, %{entry: entry(restored)}}
    end
  end

  defp dispatch("changelog.delete_entry", args, _principal, scope, _project_handle) do
    with {:ok, entry} <- required_entry(args, scope),
         :ok <- Changelog.delete_permanently(entry, actor: scope) do
      {:ok, %{deleted: true}}
    end
  end

  defp dispatch(_tool, _args, _principal, _scope, _project_handle), do: {:error, :not_found}

  defp publish_result({:ok, published}, _entry, _scope),
    do: {:ok, %{entry: entry(published)}}

  defp publish_result({:error, :stale_revision}, entry, scope) do
    case Changelog.list_revisions(entry, actor: scope, limit: 1) do
      {:ok, [current | _]} -> {:error, {:stale_revision, current.revision_number}}
      _ -> {:error, :stale_revision}
    end
  end

  defp publish_result({:error, reason}, _entry, _scope), do: {:error, reason}

  defp find_entry(args, scope, principal) do
    cond do
      is_binary(value(args, "entry_handle")) ->
        Changelog.get_entry(value(args, "entry_handle"), actor: scope)

      is_binary(value(args, "external_id")) ->
        find_external_entry(scope, principal.grant_id, value(args, "external_id"))

      true ->
        {:error, :invalid_argument}
    end
  end

  defp required_entry(args, scope) do
    case required_string(args, "entry_handle") do
      {:ok, entry_handle} -> Changelog.get_entry(entry_handle, actor: scope)
      error -> error
    end
  end

  defp find_external_entry(scope, grant_id, external_id) do
    Changelog.get_entry_by_external_id(
      scope.project_id,
      grant_id,
      external_id,
      actor: scope
    )
  end

  defp decode_cursor(principal, args, tool, filters) do
    case value(args, "cursor") do
      nil ->
        {:ok, 0}

      cursor when is_binary(cursor) ->
        case Cursor.decode(principal, tool, filters, cursor) do
          {:ok, offset} when is_integer(offset) and offset >= 0 -> {:ok, offset}
          {:ok, _} -> {:error, :invalid_cursor}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp normalize_limit(args) do
    with {:error, :invalid_limit} <-
           Args.bounded_integer(
             args,
             "limit",
             @page_min,
             @page_max,
             @page_default,
             :invalid_limit
           ) do
      {:error, {:invalid_limit, value(args, "limit")}}
    end
  end

  defp optional_string(args, key) do
    with {:error, {:invalid_argument, _key}} <- Args.optional_string(args, key) do
      {:error, :invalid_argument}
    end
  end

  defp required_string(args, key) do
    with {:error, {:missing_argument, _key}} <- Args.required_string(args, key) do
      {:error, :invalid_argument}
    end
  end

  defp required_list(args, key) do
    case value(args, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, :invalid_argument}
    end
  end

  defp required_value(args, key) do
    case value(args, key) do
      nil -> {:error, :invalid_argument}
      value -> {:ok, value}
    end
  end

  defp next_cursor(principal, tool, filters, offset, entries, limit)
       when length(entries) > offset + limit,
       do: Cursor.encode(principal, tool, filters, offset + limit)

  defp next_cursor(_principal, _tool, _filters, _offset, _entries, _limit), do: nil

  defp source_attrs(source) when is_map(source) do
    %{kind: value(source, "kind"), url: value(source, "url"), label: value(source, "label")}
  end

  defp source_attrs(_source), do: %{}

  defp normalize_revision(value) when is_integer(value), do: value

  defp normalize_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp entry(entry) do
    %{
      handle: Map.get(entry, :id),
      external_id: Map.get(entry, :external_id),
      title: Map.get(entry, :title),
      summary: Map.get(entry, :summary),
      area: Map.get(entry, :area),
      version: Map.get(entry, :version),
      media_url: Map.get(entry, :media_url),
      media_alt: Map.get(entry, :media_alt),
      media_caption: Map.get(entry, :media_caption),
      public_slug: Map.get(entry, :public_slug),
      status: Map.get(entry, :status),
      published_at: Map.get(entry, :published_at)
    }
  end

  defp revision_summary(%Revision{} = revision) do
    %{
      handle: revision.id,
      entry_handle: revision.entry_id,
      revision_number: revision.revision_number,
      status: revision.status,
      published_at: revision.published_at,
      inserted_at: revision.inserted_at
    }
  end

  defp revision(%Revision{} = revision),
    do: Map.put(revision_summary(revision), :markdown, revision.markdown)

  defp settings(public_page) do
    slug = public_page.public_slug

    %{
      public_title: public_page.title,
      public_slug: slug,
      enabled: not is_nil(public_page.published_at),
      activated_at: public_page.published_at,
      public_url: "/status/#{slug}/changelog",
      rss_url: "/status/#{slug}/changelog.rss",
      json_url: "/status/#{slug}/changelog.json"
    }
  end

  defp error_mode("changelog.get_settings"), do: :settings
  defp error_mode("changelog.delete_entry"), do: :delete

  defp error_mode(tool)
       when tool in [
              "changelog.upsert_draft",
              "changelog.publish_entry",
              "changelog.archive_entry",
              "changelog.restore_entry"
            ],
       do: :mutation

  defp error_mode(_tool), do: :read
  defp normalize_status("draft"), do: :draft
  defp normalize_status("published"), do: :published
  defp normalize_status("archived"), do: :archived
  defp normalize_status(status), do: status

  defp map_error(%Error{} = error, _mode), do: error

  defp map_error({:error, %Error{} = error}, _mode), do: error

  defp map_error({:stale_revision, current_revision}, _mode) do
    Error.new(
      :stale_revision,
      "The expected revision is stale",
      %{current_revision: current_revision}
    )
  end

  defp map_error({:error, {:stale_revision, current_revision}}, mode),
    do: map_error({:stale_revision, current_revision}, mode)

  defp map_error({:invalid_limit, value}, _mode) do
    Error.new(:invalid_argument, "The request is invalid", %{
      field: "limit",
      value: Args.detail_value(value),
      minimum: @page_min,
      maximum: @page_max
    })
  end

  defp map_error({:error, {:invalid_limit, value}}, mode),
    do: map_error({:invalid_limit, value}, mode)

  defp map_error(:not_found, :settings) do
    Error.new(
      :not_found,
      "This project has no changelog yet. Call changelog.upsert_draft to create one.",
      %{bootstrap_tool: "changelog.upsert_draft"}
    )
  end

  defp map_error(reason, mode) do
    {code, message} = classify_error(reason, mode)
    Error.new(code, message, error_details(reason))
  end

  defp error_details({:error, reason}), do: error_details(reason)

  defp error_details(reason)
       when reason in [
              :malformed_yaml,
              :unknown_key,
              :duplicate_key,
              :missing_title,
              :invalid_title,
              :empty_title,
              :non_scalar_title,
              :nested_value,
              :invalid_summary,
              :invalid_area,
              :invalid_version,
              :invalid_media_url,
              :invalid_media_alt,
              :invalid_media_caption
            ],
       do: %{rule: front_matter_rule(reason)}

  defp error_details(_reason), do: %{}

  defp front_matter_rule(:malformed_yaml), do: "malformed_yaml"
  defp front_matter_rule(:unknown_key), do: "unknown_key"
  defp front_matter_rule(:duplicate_key), do: "duplicate_key"
  defp front_matter_rule(:missing_title), do: "missing_title"
  defp front_matter_rule(:empty_title), do: "empty_title"
  defp front_matter_rule(:nested_value), do: "non_scalar_title"
  defp front_matter_rule(:invalid_title), do: "non_scalar_title"
  defp front_matter_rule(:invalid_summary), do: "invalid_summary"
  defp front_matter_rule(:invalid_area), do: "invalid_area"
  defp front_matter_rule(:invalid_version), do: "invalid_version"
  defp front_matter_rule(:invalid_media_url), do: "invalid_media_url"
  defp front_matter_rule(:invalid_media_alt), do: "invalid_media_alt"
  defp front_matter_rule(:invalid_media_caption), do: "invalid_media_caption"

  defp classify_error({:error, reason}, mode), do: classify_error(reason, mode)
  defp classify_error(%Error{} = error, _mode), do: {error.code, error.message}

  defp classify_error(%Ash.Error.Forbidden{}, :read),
    do: {:not_found, "The requested resource was not found"}

  defp classify_error(%Ash.Error.Forbidden{}, _mode),
    do: {:forbidden_role, "The caller cannot perform this action"}

  defp classify_error(reason, mode) when is_atom(reason) do
    case reason do
      :not_found ->
        {:not_found, "The requested resource was not found"}

      reason when reason in [:forbidden, :forbidden_role] ->
        classify_error(%Ash.Error.Forbidden{}, mode)

      :missing_idempotency_key ->
        {:missing_idempotency_key, "An idempotency key is required"}

      :idempotency_key_conflict ->
        {:idempotency_key_conflict,
         "The idempotency key was already used with different arguments"}

      :invalid_cursor ->
        {:invalid_cursor, "The cursor is invalid"}

      :cursor_expired ->
        {:cursor_expired, "The cursor has expired"}

      :missing_evidence ->
        {:missing_evidence, "At least one evidence source is required"}

      :invalid_source_kind ->
        {:invalid_source_kind, "The evidence source kind is invalid"}

      :stale_revision ->
        {:stale_revision, "The expected revision is stale"}

      :invalid_state_transition ->
        {:invalid_state_transition, "The entry cannot make that state transition"}

      :already_published ->
        {:already_published, "The entry is already published"}

      :plan_inactive ->
        {:plan_inactive, "The organization plan is inactive"}

      reason
      when reason in [
             :malformed_yaml,
             :unknown_key,
             :duplicate_key,
             :missing_title,
             :invalid_title,
             :empty_title,
             :non_scalar_title,
             :nested_value,
             :invalid_summary,
             :invalid_area,
             :invalid_version,
             :invalid_media_url,
             :invalid_media_alt,
             :invalid_media_caption
           ] ->
        {:invalid_front_matter, "The Markdown front matter is invalid"}

      :raw_html_forbidden ->
        {:raw_html_forbidden, "Raw HTML is not allowed"}

      _ ->
        {:invalid_argument, "The request is invalid"}
    end
  end

  defp classify_error(%Ash.Error.Invalid{} = error, _mode) do
    message = error |> Exception.message() |> String.downcase()

    cond do
      String.contains?(message, "plan") and String.contains?(message, "inactive") ->
        {:plan_inactive, "The organization plan is inactive"}

      String.contains?(message, "already published") ->
        {:already_published, "The entry is already published"}

      true ->
        {:invalid_argument, "The request is invalid"}
    end
  rescue
    _ -> {:invalid_argument, "The request is invalid"}
  end

  defp classify_error(_reason, :read), do: {:not_found, "The requested resource was not found"}
  defp classify_error(_reason, _mode), do: {:invalid_argument, "The request is invalid"}

  defp object_schema(properties),
    do: %{type: "object", properties: properties, required: schema_keys(properties)}

  defp schema_keys(properties), do: Enum.map(Map.keys(properties), &to_string/1)

  defp resource_schema(extra, required) do
    %{
      type: "object",
      properties:
        Map.merge(
          %{
            project_handle: %{
              type: "string",
              description: "Use the exact prefixed project id returned by projects.list."
            }
          },
          extra
        ),
      required: ["project_handle" | required]
    }
  end

  defp page_schema(extra, required \\ []) do
    %{
      type: "object",
      properties:
        Map.merge(
          %{
            project_handle: %{
              type: "string",
              description: "Use the exact prefixed project id returned by projects.list."
            },
            cursor: %{type: "string"},
            limit: %{type: "integer", minimum: @page_min, maximum: @page_max}
          },
          extra
        ),
      required: ["project_handle" | required]
    }
  end

  defp page_output_schema(key),
    do: object_schema(%{key => %{type: "array"}, next_cursor: %{type: ["string", "null"]}})

  defp mutation_schema(extra, required) do
    %{
      type: "object",
      properties:
        Map.merge(
          %{
            project_handle: %{
              type: "string",
              description: "Use the exact prefixed project id returned by projects.list."
            },
            idempotency_key: %{type: "string"}
          },
          extra
        ),
      required: ["project_handle", "idempotency_key" | required]
    }
  end

  defp read_tool(name, title, description, extra, required, output),
    do:
      ToolSpec.read_tool(
        name,
        title,
        description,
        resource_schema(extra, required),
        object_schema(output)
      )

  defp mutation_tool(name, title, description, extra, required, output),
    do:
      ToolSpec.mutation_tool(
        name,
        title,
        description,
        mutation_schema(extra, required),
        object_schema(output),
        %{idempotentHint: true}
      )

  defp publish_tool(name, title, description, extra, required, output) do
    tool = mutation_tool(name, title, description, extra, required, output)
    %{tool | annotations: Map.put(tool.annotations, :openWorldHint, true)}
  end
end
