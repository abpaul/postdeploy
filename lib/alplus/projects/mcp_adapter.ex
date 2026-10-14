defmodule Alplus.Projects.McpAdapter do
  @moduledoc """
  Exposes project discovery and project creation to authenticated MCP
  callers.

  Creating a project is organization work, not project work, so both tools
  carry `tenancy: :organization` and take no `project_handle`. A
  project-pinned grant is refused outright: its consent named one project,
  and a new one is outside what the person agreed to.

  Everything else about a project still goes through the pillar adapters.
  This creates the empty container; `analytics.create_source`,
  `observe.create_source` and the monitor tools fill it.
  """

  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Billing.EntitlementError
  alias Alplus.Mcp.{Args, Cursor, Error, Principal, Tool}
  alias Alplus.Projects.Project

  @impl true
  def prefix, do: "projects"

  @impl true
  def tools do
    [
      %Tool{
        name: "projects.list",
        title: "List projects",
        description:
          "List projects in the granted organization. Use each returned project's exact prefixed id as the project_handle on every changelog tool.",
        input_schema: %{
          type: "object",
          properties: %{
            cursor: %{type: "string"},
            limit: %{type: "integer", minimum: 1, maximum: 100}
          }
        },
        output_schema: %{
          type: "object",
          properties: %{
            projects: %{type: "array"},
            next_cursor: %{type: ["string", "null"]}
          },
          required: ["projects", "next_cursor"]
        },
        annotations: %{readOnlyHint: true},
        cost_weight: 1,
        requires_access: :read,
        tenancy: :organization
      },
      %Tool{
        name: "projects.create",
        title: "Create a project",
        description:
          "Create an empty project in the granted organization. A project is the tenant boundary: monitors, error sources, analytics keys and public pages all belong to exactly one. Returns the project_handle every other tool takes. Creating a project consumes one of the organization's plan project slots.",
        input_schema: %{
          type: "object",
          properties: %{
            name: %{type: "string", minLength: 1, maxLength: 120},
            idempotency_key: %{type: "string", minLength: 1, maxLength: 256}
          },
          required: ["name", "idempotency_key"],
          additionalProperties: false
        },
        output_schema: %{
          type: "object",
          properties: %{
            project: %{
              type: "object",
              properties: %{
                handle: %{type: "string"},
                name: %{type: "string"},
                public_token: %{type: "string"}
              },
              required: ["handle", "name", "public_token"],
              additionalProperties: false
            }
          },
          required: ["project"],
          additionalProperties: false
        },
        annotations: %{idempotentHint: true},
        cost_weight: 2,
        requires_access: :read_write,
        tenancy: :organization
      }
    ]
  end

  @impl true
  def call("projects.list", args, %Principal{} = principal) do
    filters = %{}

    with {:ok, limit} <- normalize_limit(args),
         {:ok, offset} <- decode_offset(principal, args, filters),
         {:ok, projects} <- list(principal),
         page <- projects |> Enum.drop(offset) |> Enum.take(limit),
         next_cursor <-
           next_cursor(principal, filters, offset + length(page), length(projects), limit) do
      {:ok, %{projects: Enum.map(page, &project/1), next_cursor: next_cursor}}
    else
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  def call("projects.create", args, %Principal{} = principal) do
    with :ok <- organization_grant(principal),
         {:ok, name} <- Args.required_string(args, "name"),
         :ok <- capacity(principal.org_id),
         {:ok, scope} <- org_scope(principal),
         {:ok, project} <-
           Ash.create(Project, %{org_id: principal.org_id, name: name},
             action: :create,
             actor: scope
           ) do
      {:ok,
       %{
         project: %{
           handle: project.id,
           name: project.name,
           public_token: project.public_token
         }
       }}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:not_found)}

  # A project-pinned grant consented to one named project. Creating another
  # is outside that consent, so it is refused here rather than silently
  # widening what the grant reaches.
  defp organization_grant(%Principal{scope_mode: :organization}), do: :ok

  defp organization_grant(%Principal{}),
    do:
      {:error,
       Error.new(
         :not_found,
         "This connection is pinned to one project. Reconnect with organization access to create a project.",
         %{}
       )}

  defp org_scope(principal) do
    principal.user_id
    |> Alplus.Scope.for_user()
    |> Alplus.Orgs.build_scope(principal.org_id)
    |> case do
      {:ok, scope} -> {:ok, scope}
      _ -> {:error, :not_found}
    end
  end

  # Read the same gate the create action enforces, before calling it, so the
  # caller gets the code it can act on. `Alplus.Billing.Access` returns a
  # structured reason; Ash flattens it to a message string, and prose is not
  # something to branch on.
  #
  # This is not the authority. `EnforceCapacity` runs inside the create
  # transaction and holds the organization lock, so two concurrent creates
  # still cannot both take the last slot.
  defp capacity(org_id) do
    case Alplus.Billing.Access.allow_create(org_id, :projects) do
      :ok ->
        :ok

      {:error, %EntitlementError{code: :capacity_reached, details: details, message: message}} ->
        {:error, Error.new(:resource_exhausted, message, Map.take(details, [:current, :limit]))}

      {:error, %EntitlementError{reason: :plan_inactive, message: message}} ->
        {:error, Error.new(:plan_inactive, message, %{})}

      {:error, _reason} ->
        {:error, Error.from(:not_found)}
    end
  end

  defp map_error(%Error{} = error), do: error

  defp map_error(%Ash.Error.Invalid{}),
    do: Error.new(:invalid_argument, "The project could not be created", %{field: "name"})

  defp map_error(reason), do: Error.from(reason)

  defp list(principal) do
    with {:ok, scope} <-
           principal.user_id
           |> Alplus.Scope.for_user()
           |> Alplus.Orgs.build_scope(principal.org_id),
         {:ok, projects} <-
           Project
           |> Ash.Query.for_read(:list_for_org, %{org_id: principal.org_id}, actor: scope)
           |> Ash.Query.sort(inserted_at: :desc, id: :desc)
           |> Ash.read(actor: scope) do
      {:ok, pinned_projects(principal, projects)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp pinned_projects(%Principal{project_id: project_id}, projects) when is_binary(project_id),
    do: Enum.filter(projects, &(&1.id == project_id))

  defp pinned_projects(_principal, projects), do: projects

  defp project(project), do: %{handle: project.id, name: project.name}

  defp normalize_limit(args) do
    case Args.value(args, "limit") do
      nil ->
        {:ok, 50}

      value when is_integer(value) and value in 1..100 ->
        {:ok, value}

      value ->
        {:error,
         Error.new(:invalid_argument, "limit must be an integer between 1 and 100", %{
           field: "limit",
           value: Args.detail_value(value),
           minimum: 1,
           maximum: 100
         })}
    end
  end

  defp decode_offset(_principal, args, _filters) when map_size(args) == 0, do: {:ok, 0}

  defp decode_offset(principal, args, filters) do
    case Args.value(args, "cursor") do
      nil ->
        {:ok, 0}

      cursor ->
        case Cursor.decode(principal, "projects.list", filters, cursor) do
          {:ok, offset} when is_integer(offset) and offset >= 0 -> {:ok, offset}
          {:ok, _value} -> {:error, :invalid_cursor}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp next_cursor(_principal, _filters, offset, total, _limit) when offset >= total, do: nil

  defp next_cursor(principal, filters, offset, _total, _limit),
    do: Cursor.encode(principal, "projects.list", filters, offset)
end
