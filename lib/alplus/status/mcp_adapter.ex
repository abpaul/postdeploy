defmodule Alplus.Status.McpAdapter do
  @moduledoc "Exposes the project-scoped Public Status workspace through shared MCP dispatch."

  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Args, Error, Principal, Tenancy, ToolSpec}

  import Alplus.Mcp.Args, only: [value: 2]
  import Alplus.Mcp.ToolSpec, only: [nullable_string: 0, object_schema: 1, string: 2]

  @stages ~w(investigating identified monitoring)
  @states ~w(outage degraded maintenance operational)

  @impl true
  def prefix, do: "status"

  @impl true
  def tools do
    [
      read_tool(
        "status.get_workspace",
        "Get Status workspace",
        "Read the singleton Status workspace and safe Public publication state.",
        %{},
        %{workspace: %{type: "object"}}
      ),
      read_tool(
        "status.get_health",
        "Get Status health",
        "Read bounded service health for the singleton Status workspace. Monitor secrets are excluded.",
        %{},
        %{services: %{type: "array"}}
      ),
      read_tool(
        "status.list_services",
        "List Status services",
        "List bounded customer-facing services, monitor handles, states, and positions.",
        %{},
        %{services: %{type: "array"}}
      ),
      read_tool(
        "status.get_service",
        "Get Status service",
        "Read one service only when it belongs to the selected project's singleton Status workspace.",
        %{service_handle: string(1, 200)},
        %{service: %{type: "object"}},
        ["service_handle"]
      ),
      read_tool(
        "status.list_incidents",
        "List Status incidents",
        "List published incidents in the selected project. Private drafts and raw draft payloads are excluded.",
        %{},
        %{incidents: %{type: "array"}}
      ),
      read_tool(
        "status.get_incident",
        "Get Status incident",
        "Read one incident timeline and affected services. Private draft bodies are excluded.",
        %{incident_handle: string(1, 200)},
        %{incident: %{type: "object"}, updates: %{type: "array"}},
        ["incident_handle"]
      ),
      read_tool(
        "status.list_history",
        "List Status history",
        "Read bounded incident history for the selected project's Public Status workspace.",
        %{},
        %{incidents: %{type: "array"}}
      ),
      read_tool(
        "status.list_announcements",
        "List Status announcements",
        "Read bounded announcement history, including unpublished records without private metadata.",
        %{},
        %{announcements: %{type: "array"}}
      ),
      read_tool(
        "status.list_maintenance",
        "List Status maintenance",
        "Read bounded scheduled maintenance windows for the selected project.",
        %{},
        %{maintenance: %{type: "array"}}
      ),
      read_tool(
        "status.get_links",
        "Get Status links",
        "Return canonical public Status, history, feed, embed, and changelog links.",
        %{},
        %{links: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.ensure_workspace",
        "Ensure Status workspace",
        "Create the singleton Status workspace and Public identity if absent. Repeated calls never create a second workspace.",
        %{title: nullable_string(), public_slug: nullable_string(), logo_url: nullable_string()},
        [],
        %{workspace: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.create_service",
        "Create Status service",
        "Create one customer-visible service and link its monitors through the authoritative Status domain.",
        %{
          name: string(1, 200),
          description: nullable_string(),
          monitor_handles: array_strings(100)
        },
        ["name"],
        %{service: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.update_service",
        "Update Status service",
        "Update one customer-visible service and synchronize its monitor links.",
        %{
          service_handle: string(1, 200),
          name: nullable_string(),
          description: nullable_string(),
          monitor_handles: array_strings(100)
        },
        ["service_handle"],
        %{service: %{type: "object"}}
      ),
      destructive_mutation_tool(
        "status.retire_service",
        "Retire Status service",
        "Retire one service when it has no open incident. This is destructive, customer-visible, and preserves audit history.",
        %{service_handle: string(1, 200)},
        ["service_handle"],
        %{service: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.order_services",
        "Order Status services",
        "Set the complete customer-visible service order for the singleton Status workspace.",
        %{service_handles: array_strings(100)},
        ["service_handles"],
        %{service_handles: %{type: "array"}}
      ),
      customer_mutation_tool(
        "status.save_incident_draft",
        "Save incident draft",
        "Save a private incident draft. Draft body content is never returned by this operation or reads.",
        %{
          title: string(1, 200),
          body: string(1, 32_768),
          next_update_at: nullable_string(),
          service_handles: array_strings(100),
          service_states: states_schema()
        },
        ["title", "body"],
        %{draft: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.create_incident",
        "Publish Status incident",
        "Publish a customer-visible incident and affected service states through the authoritative Status lifecycle.",
        incident_properties(),
        ["title", "body"],
        %{incident: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.publish_incident_draft",
        "Publish incident draft",
        "Publish an existing private incident draft and make it customer-visible. The draft body is not returned separately.",
        %{
          incident_handle: string(1, 200),
          title: nullable_string(),
          body: nullable_string(),
          next_update_at: nullable_string(),
          service_handles: array_strings(100),
          service_states: states_schema()
        },
        ["incident_handle"],
        %{incident: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.update_incident",
        "Update Status incident",
        "Update customer-visible incident narrative or next-update target through the authoritative Status domain.",
        %{
          incident_handle: string(1, 200),
          title: nullable_string(),
          body: nullable_string(),
          next_update_at: nullable_string()
        },
        ["incident_handle"],
        %{incident: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.publish_update",
        "Publish incident update",
        "Publish a customer-visible incident timeline update and preserve notification, cache, and audit effects.",
        %{
          incident_handle: string(1, 200),
          body: string(1, 32_768),
          next_update_at: nullable_string()
        },
        ["incident_handle", "body"],
        %{update: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.change_incident_stage",
        "Change incident stage",
        "Change an open incident stage. Resolving requires the dedicated recovery operation.",
        %{incident_handle: string(1, 200), stage: %{type: "string", enum: @stages}},
        ["incident_handle", "stage"],
        %{incident: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.resolve_incident",
        "Resolve incident",
        "Publish a customer-visible recovery update and resolve the incident atomically.",
        %{incident_handle: string(1, 200), body: string(1, 32_768)},
        ["incident_handle", "body"],
        %{incident: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.publish_announcement",
        "Publish announcement",
        "Publish a customer-visible announcement for the selected Public Status workspace.",
        %{title: string(1, 200), body: string(1, 32_768), expires_at: nullable_string()},
        ["title", "body"],
        %{announcement: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.update_announcement",
        "Update announcement",
        "Update one customer-visible announcement through the authoritative Status domain.",
        %{
          announcement_handle: string(1, 200),
          title: nullable_string(),
          body: nullable_string(),
          expires_at: nullable_string()
        },
        ["announcement_handle"],
        %{announcement: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.unpublish_announcement",
        "Unpublish announcement",
        "Hide one announcement from customers while retaining its history. This is customer-visible.",
        %{announcement_handle: string(1, 200)},
        ["announcement_handle"],
        %{announcement: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.republish_announcement",
        "Republish announcement",
        "Make one retained announcement visible to customers again while preserving history.",
        %{announcement_handle: string(1, 200)},
        ["announcement_handle"],
        %{announcement: %{type: "object"}}
      ),
      customer_mutation_tool(
        "status.schedule_maintenance",
        "Schedule maintenance",
        "Schedule a customer-visible maintenance window and pause selected monitors through the authoritative Status domain.",
        %{
          title: string(1, 200),
          description: nullable_string(),
          starts_at: string(1, 64),
          ends_at: string(1, 64),
          monitor_handles: array_strings(100)
        },
        ["title", "starts_at", "ends_at", "monitor_handles"],
        %{maintenance: %{type: "object"}}
      ),
      destructive_mutation_tool(
        "status.cancel_maintenance",
        "Cancel maintenance",
        "Cancel one scheduled or active maintenance window. This is destructive, customer-visible, and resumes affected monitors when required.",
        %{maintenance_handle: string(1, 200)},
        ["maintenance_handle"],
        %{maintenance: %{type: "object"}}
      )
    ]
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- Args.required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch_with_workspace(tool, args, scope) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  defp dispatch_with_workspace("status.ensure_workspace", args, scope) do
    case workspace(scope) do
      {:ok, page} -> dispatch("status.ensure_workspace", args, scope, page)
      {:error, :not_found} -> dispatch("status.ensure_workspace", args, scope, nil)
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_with_workspace(tool, args, scope) do
    with {:ok, page} <- workspace(scope), do: dispatch(tool, args, scope, page)
  end

  defp workspace(scope), do: Alplus.Status.workspace_page(scope)

  defp dispatch("status.get_workspace", _args, scope, page) do
    identity =
      case Alplus.PublicPages.get_for_scope(scope) do
        {:ok, identity} -> identity
        _ -> nil
      end

    {:ok,
     %{
       workspace: %{
         handle: page.id,
         project_handle: page.project_id,
         identity: identity && identity_payload(identity)
       }
     }}
  end

  defp dispatch("status.get_health", _args, scope, page),
    do:
      with(
        {:ok, services} <- Alplus.Status.service_overview(scope, page),
        do: {:ok, %{services: Enum.map(services, &service_payload/1)}}
      )

  defp dispatch("status.list_services", _args, scope, page),
    do:
      with(
        {:ok, services} <- Alplus.Status.service_overview(scope, page),
        do: {:ok, %{services: Enum.map(services, &service_payload/1)}}
      )

  defp dispatch("status.get_service", args, scope, page),
    do:
      with(
        {:ok, service} <- Alplus.Status.service(scope, page, value(args, "service_handle")),
        do: {:ok, %{service: service_payload(service)}}
      )

  defp dispatch("status.list_incidents", _args, scope, page),
    do:
      with(
        {:ok, incidents} <- Alplus.Status.list_incidents(scope, page.id),
        do: {:ok, %{incidents: Enum.map(incidents, &incident_payload/1)}}
      )

  defp dispatch("status.list_history", args, scope, page),
    do: dispatch("status.list_incidents", args, scope, page)

  defp dispatch("status.get_incident", args, scope, _page) do
    with {:ok, overview} <- Alplus.Status.incident_overview(scope, value(args, "incident_handle")) do
      {:ok,
       %{
         incident: incident_payload(overview.incident),
         updates: Enum.map(overview.updates, &update_payload/1),
         affected_services: overview.affected_services
       }}
    end
  end

  defp dispatch("status.list_announcements", _args, scope, page),
    do:
      with(
        {:ok, rows} <- Alplus.Status.list_announcements(scope, page),
        do: {:ok, %{announcements: Enum.map(rows, &announcement_payload/1)}}
      )

  defp dispatch("status.list_maintenance", _args, scope, page),
    do:
      with(
        {:ok, rows} <- Alplus.Status.list_maintenances(scope, page),
        do: {:ok, %{maintenance: Enum.map(rows, &maintenance_payload/1)}}
      )

  defp dispatch("status.get_links", _args, scope, _page) do
    with {:ok, identity} <- Alplus.PublicPages.get_for_scope(scope) do
      slug = identity.public_slug
      base = "/status/#{slug}"

      {:ok,
       %{
         links: %{
           status: base,
           history: base <> "/history",
           feed: base <> "/feed.xml",
           embed: base <> "/embed",
           embed_json: base <> "/embed.json",
           changelog: base <> "/changelog",
           changelog_feed: base <> "/changelog.rss",
           changelog_json: base <> "/changelog.json"
         }
       }}
    end
  end

  defp dispatch("status.ensure_workspace", args, scope, page) do
    if page do
      {:ok, %{workspace: workspace_payload(page)}}
    else
      with {:ok, page} <-
             Alplus.Status.ensure_page(
               scope,
               present_attrs(args, [:title, :public_slug, :logo_url])
             ) do
        {:ok, %{workspace: workspace_payload(page)}}
      end
    end
  end

  defp dispatch("status.create_service", args, scope, page) do
    attrs = %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      status_page_id: page.id,
      name: value(args, "name"),
      description: value(args, "description"),
      monitor_ids: List.wrap(value(args, "monitor_handles"))
    }

    with {:ok, service} <- Alplus.Status.create_service(scope, attrs),
         do: {:ok, %{service: service_payload(service)}}
  end

  defp dispatch("status.update_service", args, scope, page) do
    with {:ok, service} <- Alplus.Status.service(scope, page, value(args, "service_handle")),
         {:ok, updated} <-
           Alplus.Status.update_service(
             scope,
             service,
             present_attrs(args, [:name, :description])
           ),
         :ok <-
           Alplus.Status.connect_service_monitors(
             scope,
             updated,
             List.wrap(value(args, "monitor_handles"))
           ) do
      {:ok, %{service: service_payload(updated)}}
    end
  end

  defp dispatch("status.retire_service", args, scope, page) do
    with {:ok, service} <- Alplus.Status.service(scope, page, value(args, "service_handle")),
         {:ok, retired} <- Alplus.Status.delete_service(scope, service) do
      {:ok, %{service: service_payload(retired)}}
    end
  end

  defp dispatch("status.order_services", args, scope, page) do
    with {:ok, handles} <- required_list(args, "service_handles"),
         {:ok, handles} <- Alplus.Status.order_services(scope, page, handles) do
      {:ok, %{service_handles: handles}}
    end
  end

  defp dispatch("status.save_incident_draft", args, scope, page) do
    attrs = %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      status_page_id: page.id,
      title: value(args, "title"),
      body: value(args, "body"),
      next_update_at: parse_datetime(value(args, "next_update_at")),
      suggested_service_ids: List.wrap(value(args, "service_handles")),
      service_states: value(args, "service_states") || %{}
    }

    with {:ok, draft} <- Alplus.Status.save_page_incident_draft(scope, attrs),
         do: {:ok, %{draft: draft_payload(draft)}}
  end

  defp dispatch("status.create_incident", args, scope, page) do
    with {:ok, incident} <-
           Alplus.Status.create_incident(scope, incident_attrs(args, scope, page)),
         do: {:ok, %{incident: incident_payload(incident)}}
  end

  defp dispatch("status.publish_incident_draft", args, scope, _page) do
    with {:ok, incident} <-
           Alplus.Status.publish_incident_draft(
             scope,
             value(args, "incident_handle"),
             present_attrs(args, [
               :title,
               :body,
               :next_update_at,
               :service_handles,
               :service_states
             ])
           ) do
      {:ok, %{incident: incident_payload(incident)}}
    end
  end

  defp dispatch("status.update_incident", args, scope, _page) do
    with {:ok, incident} <-
           Alplus.Status.update_incident(
             scope,
             value(args, "incident_handle"),
             present_attrs(args, [:title, :body, :next_update_at])
           ) do
      {:ok, %{incident: incident_payload(incident)}}
    end
  end

  defp dispatch("status.publish_update", args, scope, _page) do
    attrs = %{
      status_incident_id: value(args, "incident_handle"),
      body: value(args, "body"),
      next_update_at: parse_datetime(value(args, "next_update_at"))
    }

    with {:ok, update} <- Alplus.Status.publish_incident_update(scope, attrs),
         do: {:ok, %{update: update_payload(update)}}
  end

  defp dispatch("status.change_incident_stage", args, scope, _page) do
    with {:ok, incident} <-
           Alplus.Status.change_incident_stage(
             scope,
             value(args, "incident_handle"),
             value(args, "stage")
           ),
         do: {:ok, %{incident: incident_payload(incident)}}
  end

  defp dispatch("status.resolve_incident", args, scope, _page) do
    with {:ok, incident} <-
           Alplus.Status.publish_resolved_update(scope, %{
             status_incident_id: value(args, "incident_handle"),
             body: value(args, "body")
           }),
         do: {:ok, %{incident: incident_payload(incident)}}
  end

  defp dispatch("status.publish_announcement", args, scope, page) do
    attrs = %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      status_page_id: page.id,
      title: value(args, "title"),
      body: value(args, "body"),
      expires_at: parse_datetime(value(args, "expires_at"))
    }

    with {:ok, announcement} <- Alplus.Status.publish_announcement(scope, attrs),
         do: {:ok, %{announcement: announcement_payload(announcement)}}
  end

  defp dispatch("status.update_announcement", args, scope, page) do
    with {:ok, announcement} <-
           Alplus.Status.announcement(scope, page, value(args, "announcement_handle")),
         {:ok, announcement} <-
           Alplus.Status.update_announcement(
             scope,
             announcement,
             present_attrs(args, [:title, :body, :expires_at])
           ) do
      {:ok, %{announcement: announcement_payload(announcement)}}
    end
  end

  defp dispatch(tool, args, scope, page)
       when tool in ["status.unpublish_announcement", "status.republish_announcement"] do
    with {:ok, announcement} <-
           Alplus.Status.announcement(scope, page, value(args, "announcement_handle")),
         {:ok, announcement} <-
           if(tool == "status.unpublish_announcement",
             do: Alplus.Status.unpublish_announcement(scope, announcement),
             else: Alplus.Status.republish_announcement(scope, announcement)
           ) do
      {:ok, %{announcement: announcement_payload(announcement)}}
    end
  end

  defp dispatch("status.schedule_maintenance", args, scope, page) do
    attrs = %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      status_page_id: page.id,
      title: value(args, "title"),
      description: value(args, "description"),
      starts_at: parse_datetime(value(args, "starts_at")),
      ends_at: parse_datetime(value(args, "ends_at"))
    }

    with {:ok, maintenance} <-
           Alplus.Status.schedule_maintenance(
             scope,
             attrs,
             List.wrap(value(args, "monitor_handles"))
           ),
         do: {:ok, %{maintenance: maintenance_payload(maintenance)}}
  end

  defp dispatch("status.cancel_maintenance", args, scope, page) do
    with {:ok, maintenance} <-
           Alplus.Status.maintenance(scope, page, value(args, "maintenance_handle")),
         {:ok, maintenance} <- Alplus.Status.cancel_maintenance(scope, maintenance) do
      {:ok, %{maintenance: maintenance_payload(maintenance)}}
    end
  end

  defp dispatch(_tool, _args, _scope, _page), do: {:error, :not_found}

  defp workspace_payload(page), do: %{handle: page.id, project_handle: page.project_id}

  defp identity_payload(identity),
    do: %{
      handle: identity.id,
      title: identity.title,
      public_slug: identity.public_slug,
      logo_url: identity.logo_url,
      published: not is_nil(identity.published_at),
      published_at: datetime(identity.published_at)
    }

  defp service_payload(service),
    do: %{
      handle: service.id || service[:id],
      name: service.name || service[:name],
      description: service.description || service[:description],
      position: service.position || service[:position],
      monitor_handles: service.monitor_ids || service[:monitor_ids] || [],
      state: atom_string(service.state || service[:state])
    }

  defp incident_payload(incident),
    do: %{
      handle: incident.id,
      title: incident.title,
      status: incident.status,
      stage: incident.stage,
      published_at: datetime(incident.published_at),
      closed_at: datetime(incident.closed_at),
      next_update_at: datetime(incident.next_update_at)
    }

  defp update_payload(update),
    do: %{
      handle: update.id,
      incident_handle: update.status_incident_id,
      body: update.body,
      kind: update.kind,
      inserted_at: datetime(update.inserted_at)
    }

  defp announcement_payload(row),
    do: %{
      handle: row.id,
      title: row.title,
      body: row.body,
      published_at: datetime(row.published_at),
      removed_at: datetime(row.removed_at),
      expires_at: datetime(row.expires_at)
    }

  defp maintenance_payload(row),
    do: %{
      handle: row.id,
      title: row.title,
      description: row.description,
      starts_at: datetime(row.starts_at),
      ends_at: datetime(row.ends_at),
      status: row.status
    }

  defp draft_payload(draft),
    do: %{
      handle: draft.id,
      incident_handle: draft.status_incident_id,
      private: true,
      inserted_at: datetime(draft.inserted_at),
      updated_at: datetime(draft.updated_at)
    }

  defp incident_attrs(args, scope, page),
    do: %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      status_page_id: page.id,
      title: value(args, "title"),
      body: value(args, "body"),
      next_update_at: parse_datetime(value(args, "next_update_at")),
      service_ids: List.wrap(value(args, "service_handles")),
      service_states: value(args, "service_states") || %{}
    }

  defp present_attrs(args, keys),
    do:
      Enum.reduce(keys, %{}, fn key, acc ->
        case value(args, Atom.to_string(key)) do
          nil ->
            acc

          value ->
            Map.put(
              acc,
              key,
              if(key == :next_update_at or key == :expires_at,
                do: parse_datetime(value),
                else: value
              )
            )
        end
      end)

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, result, 0} -> result
      _ -> value
    end
  end

  defp parse_datetime(value), do: value
  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(value), do: value
  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: value

  defp read_tool(name, title, description, properties, output, required \\ []),
    do:
      ToolSpec.read_tool(
        name,
        title,
        description,
        schema(properties, required, false),
        object_schema(output)
      )

  defp customer_mutation_tool(name, title, description, properties, required, output),
    do: mutation_tool(name, title, description, properties, required, output, false)

  defp destructive_mutation_tool(name, title, description, properties, required, output),
    do: mutation_tool(name, title, description, properties, required, output, true)

  defp mutation_tool(name, title, description, properties, required, output, destructive?),
    do:
      ToolSpec.mutation_tool(
        name,
        title,
        description,
        schema(properties, required, true),
        object_schema(output),
        %{idempotentHint: true, destructiveHint: destructive?, openWorldHint: true}
      )

  defp schema(properties, required, mutation?),
    do:
      ToolSpec.strict_object(
        properties |> Map.put(:project_handle, string(1, 200)) |> maybe_idempotency(mutation?),
        ["project_handle" | if(mutation?, do: ["idempotency_key" | required], else: required)]
      )

  defp maybe_idempotency(properties, true),
    do: Map.put(properties, :idempotency_key, string(1, 200))

  defp maybe_idempotency(properties, false), do: properties

  defp array_strings(max), do: %{type: "array", minItems: 0, maxItems: max, items: string(1, 200)}

  defp states_schema,
    do: %{type: "object", additionalProperties: %{type: "string", enum: @states}}

  defp incident_properties,
    do: %{
      title: string(1, 200),
      body: string(1, 32_768),
      next_update_at: nullable_string(),
      service_handles: array_strings(100),
      service_states: states_schema()
    }

  defp required_list(args, key),
    do:
      if(is_list(value(args, key)),
        do: {:ok, value(args, key)},
        else: {:error, {:invalid_argument, key}}
      )

  defp map_error(:service_required),
    do: Error.new(:invalid_argument, "A service is required before publication", %{})

  defp map_error(:service_has_active_incident),
    do: Error.new(:conflict, "The service has an active incident", %{})

  defp map_error(:status_pages_singleton),
    do: Error.new(:conflict, "The project already has a Status workspace", %{})

  defp map_error(:invalid_service_order),
    do:
      Error.new(:invalid_argument, "The service order must contain every service exactly once", %{
        field: "service_handles"
      })

  defp map_error(:maintenance_not_cancellable),
    do: Error.new(:conflict, "The maintenance window cannot be cancelled", %{})

  defp map_error(reason), do: Error.from(reason)
end
