defmodule Alplus.Measure.McpAdapter do
  @moduledoc "Exposes privacy-safe Measure reads and configuration tools to MCP callers."

  @behaviour Alplus.Mcp.Adapter

  require Ash.Query

  alias Alplus.Measure.{CustomEventDefinition, Dashboard, DashboardShare, Goal, SiteCreator}
  alias Alplus.Mcp.{Args, Cursor, Error, Principal, Tenancy, ToolSpec}

  import Alplus.Mcp.Args,
    only: [optional_string: 2, required_enum: 3, required_string: 2, value: 2]

  import Alplus.Mcp.ToolSpec, only: [nullable_string: 0, strict_object: 2]
  alias Alplus.Sources.Source

  @tool_prefix "measure"
  @page_default 50
  @page_min 1
  @page_max 100
  @panel_page_max 25
  @windows ~w(24h 7d 30d 90d)
  @dimensions ~w(path referrer event country browser)

  @impl true
  def prefix, do: @tool_prefix

  @impl true
  def tools do
    [
      read_tool(
        "measure.list_sites",
        "List Measure sites",
        "List active Measure sites in one project. Source tokens are never returned. Use the opaque cursor for later pages.",
        %{
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: @page_min, maximum: @page_max}
        },
        strict_object(
          %{sites: %{type: "array", items: source_schema()}, next_cursor: nullable_string()},
          ["sites", "next_cursor"]
        ),
        []
      ),
      read_tool(
        "measure.get_site",
        "Inspect a Measure site",
        "Inspect one active Measure site and its allowed hostname. Credentials are returned only by create or rotate.",
        %{source_handle: %{type: "string", minLength: 1}},
        strict_object(%{site: source_schema()}, ["site"]),
        ["source_handle"]
      ),
      read_tool(
        "measure.list_goals",
        "List Measure goals",
        "List bounded goals configured in one project. Use the opaque cursor for later pages.",
        %{
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: @page_min, maximum: @page_max}
        },
        strict_object(
          %{goals: %{type: "array", items: goal_item_schema()}, next_cursor: nullable_string()},
          ["goals", "next_cursor"]
        ),
        []
      ),
      read_tool(
        "measure.list_event_definitions",
        "List Measure event definitions",
        "List bounded custom event names configured in one project. Use the opaque cursor for later pages.",
        %{
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: @page_min, maximum: @page_max}
        },
        strict_object(
          %{
            event_definitions: %{type: "array", items: event_definition_item_schema()},
            next_cursor: nullable_string()
          },
          ["event_definitions", "next_cursor"]
        ),
        []
      ),
      read_tool(
        "measure.get_dashboard_share",
        "Inspect a dashboard share",
        "Inspect one source's public dashboard share. The raw share token is never returned after create or rotate.",
        %{source_handle: %{type: "string", minLength: 1}},
        strict_object(%{share: share_schema()}, ["share"]),
        ["source_handle"]
      ),
      read_tool(
        "measure.get_metrics",
        "Get Measure metrics",
        "Read privacy-safe totals, headline comparisons, and trend buckets for one Measure site. Recent windows use the configured recent path with durable rollup fallback. The result always states availability and its data source.",
        %{
          source_handle: %{type: "string", minLength: 1},
          window: %{type: "string", enum: @windows}
        },
        metrics_schema(),
        ["source_handle", "window"]
      ),
      read_tool(
        "measure.get_breakdown",
        "Get a Measure breakdown",
        "Read one bounded page of a Measure path, referrer, event, country, or browser breakdown. The existing cardinality cap and (other) bucket remain in force.",
        %{
          source_handle: %{type: "string", minLength: 1},
          window: %{type: "string", enum: @windows},
          dimension: %{type: "string", enum: @dimensions},
          page: %{type: "integer", minimum: 1, maximum: @panel_page_max},
          cursor: %{type: "string"}
        },
        breakdown_schema(),
        ["source_handle", "window", "dimension"]
      ),
      source_create_tool(),
      mutation_tool(
        "measure.configure_hostname",
        "Configure a Measure hostname",
        "Set one normalized, bounded allowed hostname for a Measure source. The operation preserves origin matching and project tenancy.",
        %{source_handle: %{type: "string", minLength: 1}, hostname: hostname_schema()},
        strict_object(%{site: source_schema(), hostname: %{type: "string"}}, ["site", "hostname"]),
        ["source_handle", "hostname"],
        false
      ),
      external_mutation_tool(
        "measure.rotate_source",
        "Rotate a Measure source credential",
        "Rotate a Measure source token immediately. The new credential appears once in this response and never in later reads or audit data.",
        %{source_handle: %{type: "string", minLength: 1}},
        secret_source_schema(),
        ["source_handle"]
      ),
      mutation_tool(
        "measure.revoke_source",
        "Revoke a Measure source",
        "Revoke a Measure source and invalidate its browser token and public share. This is destructive and customer-visible.",
        %{source_handle: %{type: "string", minLength: 1}},
        strict_object(%{site: source_schema(), revoked: %{type: "boolean"}}, ["site", "revoked"]),
        ["source_handle"],
        true
      ),
      goal_tool(),
      mutation_tool(
        "measure.update_goal",
        "Update a Measure goal",
        "Update one bounded goal while preserving its pageview or event shape and plan capacity rules.",
        %{
          goal_handle: %{type: "string", minLength: 1},
          name: %{type: "string", minLength: 1, maxLength: 120},
          kind: %{type: "string", enum: ["pageview", "event"]},
          path: %{type: "string", minLength: 1, maxLength: 2048},
          event_name: %{type: "string", pattern: "^[a-z0-9_-]{1,64}$"}
        },
        goal_schema(),
        ["goal_handle", "name", "kind"],
        false
      ),
      mutation_tool(
        "measure.delete_goal",
        "Delete a Measure goal",
        "Delete a Measure goal. This is destructive and customer-visible.",
        %{goal_handle: %{type: "string", minLength: 1}},
        strict_object(%{deleted: %{type: "boolean"}}, ["deleted"]),
        ["goal_handle"],
        true
      ),
      mutation_tool(
        "measure.create_event_definition",
        "Create a Measure event definition",
        "Register one bounded custom-event name through the existing Measure policy boundary. Event properties are never stored. Retry with the same idempotency key.",
        %{name: %{type: "string", pattern: "^[a-z0-9_-]{1,64}$"}},
        event_definition_schema(),
        ["name"]
      ),
      mutation_tool(
        "measure.delete_event_definition",
        "Delete a Measure event definition",
        "Delete one custom-event definition. This is destructive and customer-visible.",
        %{event_definition_handle: %{type: "string", minLength: 1}},
        strict_object(%{deleted: %{type: "boolean"}}, ["deleted"]),
        ["event_definition_handle"],
        true
      ),
      external_mutation_tool(
        "measure.create_dashboard_share",
        "Create a Measure dashboard share",
        "Create one panel-scoped public dashboard share. The raw token appears once in this response and never in later reads or audit data.",
        %{source_handle: %{type: "string", minLength: 1}, panels: panels_schema()},
        secret_share_schema(),
        ["source_handle"]
      ),
      external_mutation_tool(
        "measure.update_dashboard_share",
        "Update a Measure dashboard share",
        "Replace the bounded panel set enabled by one public dashboard share. The raw token is never returned.",
        %{source_handle: %{type: "string", minLength: 1}, panels: panels_schema()},
        strict_object(%{share: share_schema()}, ["share"]),
        ["source_handle", "panels"]
      ),
      external_mutation_tool(
        "measure.rotate_dashboard_share",
        "Rotate a Measure dashboard share",
        "Rotate a public dashboard share token immediately. The new token appears once in this response and invalidates the prior token.",
        %{source_handle: %{type: "string", minLength: 1}},
        secret_share_schema(),
        ["source_handle"]
      ),
      mutation_tool(
        "measure.revoke_dashboard_share",
        "Revoke a Measure dashboard share",
        "Revoke a public dashboard share and invalidate its token. This is destructive and customer-visible.",
        %{source_handle: %{type: "string", minLength: 1}},
        strict_object(%{revoked: %{type: "boolean"}}, ["revoked"]),
        ["source_handle"],
        true
      )
    ]
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch(tool, args, scope, principal) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  defp dispatch("measure.list_sites", args, scope, principal) do
    filters = %{
      project_handle: value(args, "project_handle"),
      status: "active",
      sort: "inserted_at_desc,id_desc"
    }

    with {:ok, limit} <- normalize_limit(args),
         {:ok, keyset} <- decode_keyset(principal, args, "measure.list_sites", filters),
         {:ok, sources} <- list_sites(scope, keyset, limit) do
      page = Enum.take(sources, limit)

      next =
        if length(sources) > limit,
          do:
            Cursor.encode(principal, "measure.list_sites", filters, site_keyset(List.last(page)))

      {:ok, %{sites: Enum.map(page, &source_payload/1), next_cursor: next}}
    end
  end

  defp dispatch("measure.get_site", args, scope, _principal) do
    with {:ok, handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_source(handle, scope) do
      {:ok, %{site: source_payload(source)}}
    end
  end

  defp dispatch("measure.list_goals", args, scope, principal) do
    list_resource_page(
      args,
      scope,
      principal,
      "measure.list_goals",
      Goal,
      :goals,
      &goal_payload/1
    )
  end

  defp dispatch("measure.list_event_definitions", args, scope, principal) do
    list_resource_page(
      args,
      scope,
      principal,
      "measure.list_event_definitions",
      CustomEventDefinition,
      :event_definitions,
      &event_definition_payload/1
    )
  end

  defp dispatch("measure.get_dashboard_share", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, share} <- Alplus.Measure.get_dashboard_share_for_source(source.id, actor: scope) do
      {:ok, %{share: share_payload(share)}}
    else
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch("measure.create_source", args, scope, _principal) do
    attrs = %{
      hostname: value(args, "hostname"),
      name: value(args, "name"),
      environment: value(args, "environment")
    }

    with {:ok, %{source: source, domain: domain}} <- SiteCreator.create(attrs, scope) do
      {:ok,
       %{
         site: source_payload(source),
         hostname: domain.hostname,
         secret: Ash.Resource.get_metadata(source, :secret)
       }}
    end
  end

  defp dispatch("measure.configure_hostname", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, hostname} <- required_string(args, "hostname"),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, %{source: source, domain: domain}} <-
           SiteCreator.configure(source, hostname, scope) do
      {:ok, %{site: source_payload(source), hostname: domain.hostname}}
    end
  end

  defp dispatch("measure.rotate_source", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, rotated} <- Alplus.Sources.rotate_source(source, 0, actor: scope) do
      {:ok, %{site: source_payload(rotated), secret: Ash.Resource.get_metadata(rotated, :secret)}}
    end
  end

  defp dispatch("measure.revoke_source", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, revoked} <- Alplus.Sources.revoke_source(source, actor: scope) do
      {:ok, %{site: source_payload(revoked), revoked: true}}
    end
  end

  defp dispatch("measure.update_goal", args, scope, _principal) do
    with {:ok, handle} <- required_string(args, "goal_handle"),
         {:ok, goal} <- Alplus.Measure.get_goal(handle, actor: scope),
         {:ok, attrs} <- goal_attrs(args),
         {:ok, updated} <-
           Alplus.Measure.update_goal(goal, Map.put(attrs, :name, value(args, "name")),
             actor: scope
           ) do
      {:ok, %{goal: goal_payload(updated)}}
    end
  end

  defp dispatch("measure.delete_goal", args, scope, _principal) do
    with {:ok, handle} <- required_string(args, "goal_handle"),
         {:ok, goal} <- Alplus.Measure.get_goal(handle, actor: scope),
         :ok <- Alplus.Measure.destroy_goal(goal, actor: scope) do
      {:ok, %{deleted: true}}
    end
  end

  defp dispatch("measure.delete_event_definition", args, scope, _principal) do
    with {:ok, handle} <- required_string(args, "event_definition_handle"),
         {:ok, definition} <- Alplus.Measure.get_event_definition(handle, actor: scope),
         :ok <- Alplus.Measure.destroy_event_definition(definition, actor: scope) do
      {:ok, %{deleted: true}}
    end
  end

  defp dispatch("measure.create_dashboard_share", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, panels} <- panels(args),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, share} <-
           Alplus.Measure.create_dashboard_share(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               source_id: source.id,
               panels: panels
             },
             actor: scope
           ) do
      {:ok, %{share: share_payload(share), secret: Ash.Resource.get_metadata(share, :token)}}
    end
  end

  defp dispatch("measure.update_dashboard_share", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, panels} <- panels(args),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, share} <- Alplus.Measure.get_dashboard_share_for_source(source.id, actor: scope),
         {:ok, updated} <-
           Alplus.Measure.update_dashboard_share(share, %{panels: panels}, actor: scope) do
      {:ok, %{share: share_payload(updated)}}
    end
  end

  defp dispatch("measure.rotate_dashboard_share", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, share} <- Alplus.Measure.get_dashboard_share_for_source(source.id, actor: scope),
         {:ok, rotated} <- Alplus.Measure.rotate_dashboard_share(share, actor: scope) do
      {:ok, %{share: share_payload(rotated), secret: Ash.Resource.get_metadata(rotated, :token)}}
    end
  end

  defp dispatch("measure.revoke_dashboard_share", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, share} <- Alplus.Measure.get_dashboard_share_for_source(source.id, actor: scope),
         :ok <- Alplus.Measure.revoke_dashboard_share(share, actor: scope) do
      {:ok, %{revoked: true}}
    end
  end

  defp dispatch("measure.get_metrics", args, scope, _principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, window} <- supported_window(args),
         {:ok, source} <- get_source(source_handle, scope) do
      case read_metrics(source, window, scope) do
        {:ok, metrics} -> {:ok, %{metrics: metrics}}
        {:error, :unavailable} -> {:ok, %{metrics: unavailable_metrics(source, window)}}
      end
    end
  end

  defp dispatch("measure.get_breakdown", args, scope, principal) do
    with {:ok, source_handle} <- required_string(args, "source_handle"),
         {:ok, window} <- supported_window(args),
         {:ok, dimension} <- supported_dimension(args),
         {:ok, page} <-
           normalize_breakdown_cursor(principal, args, source_handle, window, dimension),
         {:ok, source} <- get_source(source_handle, scope),
         {:ok, panel} <- read_panel(source, window, dimension, page, scope) do
      filters = %{
        project_handle: value(args, "project_handle"),
        source_handle: source_handle,
        window: window,
        dimension: dimension,
        sort: "count_desc,value_asc"
      }

      next_cursor =
        if panel.next? and List.last(panel.rows) do
          Cursor.encode(principal, "measure.get_breakdown", filters, %{
            page: page + 1,
            last: breakdown_row(List.last(panel.rows))
          })
        end

      {:ok,
       %{
         breakdown: %{
           source: source_payload(source),
           window: window,
           dimension: dimension,
           rows: Enum.map(panel.rows, &breakdown_row/1),
           page: panel.page,
           total_pages: panel.total_pages,
           distinct_values: panel.distinct_values,
           capped?: panel.capped?,
           previous?: panel.previous?,
           next?: panel.next?,
           next_cursor: next_cursor
         }
       }}
    end
  end

  defp dispatch("measure.create_goal", args, scope, _principal) do
    with {:ok, attrs} <- goal_attrs(args),
         {:ok, goal} <-
           Alplus.Measure.create_goal(
             Map.merge(attrs, %{org_id: scope.org_id, project_id: scope.project_id}),
             actor: scope
           ) do
      {:ok, %{goal: goal_payload(goal)}}
    end
  end

  defp dispatch("measure.create_event_definition", args, scope, _principal) do
    with {:ok, name} <- required_string(args, "name"),
         {:ok, definition} <-
           Alplus.Measure.create_event_definition(
             %{org_id: scope.org_id, project_id: scope.project_id, name: name},
             actor: scope
           ) do
      {:ok, %{event_definition: event_definition_payload(definition)}}
    end
  end

  defp dispatch(_tool, _args, _scope, _principal), do: {:error, :not_found}

  defp list_sites(scope, nil, limit) do
    Source
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(status == :active and type == :measure)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read(actor: scope)
  end

  defp list_sites(scope, %{inserted_at: inserted_at, id: id}, limit) do
    Source
    |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
    |> Ash.Query.filter(status == :active and type == :measure)
    |> Ash.Query.filter(inserted_at < ^inserted_at or (inserted_at == ^inserted_at and id < ^id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read(actor: scope)
  end

  defp list_resource_page(args, scope, principal, tool, resource, key, payload_fun) do
    filters = %{project_handle: value(args, "project_handle"), sort: "inserted_at_desc,id_desc"}

    with {:ok, limit} <- normalize_limit(args),
         {:ok, offset} <- decode_offset(principal, args, tool, filters),
         {:ok, records} <-
           resource
           |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
           |> Ash.Query.sort(inserted_at: :desc, id: :desc)
           |> Ash.Query.offset(offset)
           |> Ash.Query.limit(limit + 1)
           |> Ash.read(actor: scope) do
      page = Enum.take(records, limit)

      next =
        if length(records) > limit, do: Cursor.encode(principal, tool, filters, offset + limit)

      {:ok, %{key => Enum.map(page, payload_fun), next_cursor: next}}
    end
  end

  defp decode_offset(principal, args, tool, filters) do
    case value(args, "cursor") do
      nil ->
        {:ok, 0}

      "" ->
        {:ok, 0}

      cursor when is_binary(cursor) ->
        case Cursor.decode(principal, tool, filters, cursor) do
          {:ok, offset} when is_integer(offset) and offset >= 0 and offset <= 1_000_000 ->
            {:ok, offset}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp get_source(handle, scope) do
    case Ash.get(Source, handle, actor: scope) do
      {:ok,
       %Source{
         org_id: org_id,
         project_id: project_id,
         type: :measure,
         status: :active
       } = source}
      when org_id == scope.org_id and project_id == scope.project_id ->
        {:ok, source}

      _ ->
        {:error, :not_found}
    end
  end

  defp read_metrics(source, window, scope) do
    try do
      {totals, data_source, unavailable?} = Dashboard.totals(source, window, scope)
      headlines = Dashboard.headlines(source, window, scope)
      trend = Dashboard.trend(source, window, scope) |> Enum.map(&trend_point/1)

      metrics_result(
        unavailable?,
        source,
        window,
        data_source,
        totals,
        headlines,
        trend
      )
    rescue
      exception ->
        require Logger
        Logger.error("Measure MCP metrics read failed: #{Exception.message(exception)}")
        {:error, :unavailable}
    end
  end

  defp metrics_result(unavailable?, source, window, data_source, totals, headlines, trend) do
    case to_string(unavailable?) do
      "true" ->
        {:error, :unavailable}

      _ ->
        totals = if partial_metrics?(totals, headlines), do: nil, else: totals
        headlines = mcp_headlines(headlines)

        {:ok,
         %{
           source: source_payload(source),
           window: window,
           availability: "available",
           data_source: data_source,
           totals: totals,
           headlines: headlines,
           trend: trend
         }}
    end
  end

  defp partial_metrics?(%{coverage: :partial}, _headlines), do: true
  defp partial_metrics?(_totals, _headlines), do: false

  defp mcp_headlines(headlines) do
    headlines
    |> Map.update!(:data_source_key, &to_string/1)
    |> Map.new(fn {metric, value} ->
      {metric,
       if is_map(value) and Map.has_key?(value, :coverage) do
         Map.update!(value, :coverage, &to_string/1)
       else
         value
       end}
    end)
  end

  defp read_panel(source, window, dimension, page, scope) do
    try do
      {:ok, Dashboard.panel(source, window, dimension, page, scope)}
    rescue
      exception ->
        require Logger
        Logger.error("Measure MCP breakdown read failed: #{Exception.message(exception)}")
        {:error, :unavailable}
    end
  end

  defp unavailable_metrics(source, window) do
    %{
      source: source_payload(source),
      window: window,
      availability: "unavailable",
      data_source: nil,
      totals: nil,
      headlines: nil,
      trend: []
    }
  end

  defp source_payload(%Source{} = source) do
    %{
      handle: source.id,
      name: source.name,
      environment: source.environment,
      hostname: source.hostname,
      status: Atom.to_string(source.status)
    }
  end

  defp trend_point(point) do
    Map.update!(point, :bucket, &bucket/1)
  end

  defp bucket(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp bucket(%Date{} = value), do: Date.to_iso8601(value)
  defp bucket(value), do: value

  defp breakdown_row(row) do
    %{
      value: row.value,
      label: row.label,
      count: row.count,
      share: row.share,
      capped?: row.capped?
    }
  end

  defp goal_payload(%Goal{} = goal) do
    %{
      handle: goal.id,
      name: goal.name,
      kind: goal.kind,
      path: goal.path,
      event_name: goal.event_name
    }
  end

  defp event_definition_payload(%CustomEventDefinition{} = definition) do
    %{handle: definition.id, name: definition.name}
  end

  defp share_payload(%DashboardShare{} = share) do
    %{
      handle: share.id,
      source_handle: share.source_id,
      panels: Enum.map(share.panels, &to_string/1),
      token_prefix: share.token_prefix
    }
  end

  defp panels(args) do
    case value(args, "panels") do
      nil ->
        {:ok, [:headline_cards, :chart, :pages]}

      values when is_list(values) and length(values) in 1..7 ->
        atoms = Enum.map(values, &panel_atom/1)
        if Enum.all?(atoms, &is_atom/1), do: {:ok, atoms}, else: {:error, :invalid_panels}

      _ ->
        {:error, :invalid_panels}
    end
  end

  defp panel_atom(value) do
    case value do
      "headline_cards" ->
        :headline_cards

      "chart" ->
        :chart

      "pages" ->
        :pages

      "sources" ->
        :sources

      "events" ->
        :events

      "countries" ->
        :countries

      "browsers" ->
        :browsers

      value
      when is_atom(value) and
             value in [:headline_cards, :chart, :pages, :sources, :events, :countries, :browsers] ->
        value

      _ ->
        nil
    end
  end

  defp goal_attrs(args) do
    with {:ok, name} <- required_string(args, "name"),
         {:ok, kind} <- required_enum(args, "kind", ["pageview", "event"]),
         {:ok, path} <- optional_string(args, "path"),
         {:ok, event_name} <- optional_string(args, "event_name") do
      case {kind, path, event_name} do
        {"pageview", path, nil} when is_binary(path) ->
          {:ok, %{name: name, kind: kind, path: path}}

        {"event", nil, event_name} when is_binary(event_name) ->
          {:ok, %{name: name, kind: kind, event_name: event_name}}

        _ ->
          {:error, :invalid_goal_shape}
      end
    end
  end

  defp supported_window(args), do: required_enum(args, "window", @windows)
  defp supported_dimension(args), do: required_enum(args, "dimension", @dimensions)

  defp normalize_panel_page(args) do
    case value(args, "page") do
      nil -> {:ok, 1}
      page when is_integer(page) and page in 1..@panel_page_max -> {:ok, page}
      page when is_binary(page) -> parse_bounded_integer(page, 1, @panel_page_max, :invalid_page)
      _ -> {:error, :invalid_page}
    end
  end

  defp normalize_breakdown_cursor(principal, args, source_handle, window, dimension) do
    filters = %{
      project_handle: value(args, "project_handle"),
      source_handle: source_handle,
      window: window,
      dimension: dimension,
      sort: "count_desc,value_asc"
    }

    case value(args, "cursor") do
      nil ->
        normalize_panel_page(args)

      cursor when is_binary(cursor) ->
        with {:ok, %{page: page}} <-
               Cursor.decode(principal, "measure.get_breakdown", filters, cursor),
             true <- is_integer(page) and page in 1..@panel_page_max do
          {:ok, page}
        else
          false -> {:error, :invalid_cursor}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp normalize_limit(args),
    do: Args.bounded_integer(args, "limit", @page_min, @page_max, @page_default, :invalid_limit)

  defp parse_bounded_integer(value, minimum, maximum, error) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= minimum and parsed <= maximum -> {:ok, parsed}
      _ -> {:error, error}
    end
  end

  defp decode_keyset(principal, args, tool, filters) do
    case value(args, "cursor") do
      nil ->
        {:ok, nil}

      cursor when is_binary(cursor) ->
        case Cursor.decode(principal, tool, filters, cursor) do
          {:ok, %{inserted_at: inserted_at, id: id}}
          when is_binary(inserted_at) and is_binary(id) ->
            with {:ok, datetime, 0} <- DateTime.from_iso8601(inserted_at) do
              {:ok, %{inserted_at: datetime, id: id}}
            else
              _ -> {:error, :invalid_cursor}
            end

          {:ok, _value} ->
            {:error, :invalid_cursor}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp site_keyset(%{inserted_at: inserted_at, id: id}) do
    %{inserted_at: DateTime.to_iso8601(inserted_at), id: id}
  end

  defp map_error(:invalid_panels),
    do: Error.new(:invalid_argument, "panels are invalid", %{field: "panels"})

  defp map_error(:invalid_hostname),
    do: Error.new(:invalid_argument, "hostname is invalid", %{field: "hostname"})

  defp map_error(:unavailable),
    do: Error.new(:unavailable, "Measure data is temporarily unavailable", %{})

  defp map_error(:invalid_limit),
    do:
      Error.new(:invalid_argument, "limit must be an integer between 1 and 100", %{
        field: "limit",
        minimum: 1,
        maximum: 100
      })

  defp map_error(%Ash.Error.Invalid{} = error) do
    message = error |> Exception.message() |> String.downcase()

    if String.contains?(message, "plan") and
         (String.contains?(message, "inactive") or String.contains?(message, "no longer active")) do
      Error.new(:plan_inactive, "The organization plan is inactive", %{})
    else
      Error.new(:invalid_argument, "The request is invalid", %{})
    end
  rescue
    _ -> Error.from(:invalid_argument)
  end

  defp map_error(reason), do: Error.from(reason)

  defp read_tool(name, title, description, properties, output, required),
    do:
      ToolSpec.read_tool(
        name,
        title,
        description,
        schema(properties, required, false),
        output
      )

  defp mutation_tool(name, title, description, properties, output, required),
    do: mutation_tool(name, title, description, properties, output, required, false)

  defp mutation_tool(name, title, description, properties, output, required, destructive?) do
    properties =
      properties
      |> Map.put(:project_handle, %{type: "string", minLength: 1})
      |> Map.put(:idempotency_key, %{type: "string", minLength: 1, maxLength: 256})

    ToolSpec.mutation_tool(
      name,
      title,
      description,
      schema(properties, ["project_handle", "idempotency_key" | required], true),
      output,
      %{idempotentHint: true, destructiveHint: destructive?, openWorldHint: destructive?}
    )
  end

  defp external_mutation_tool(name, title, description, properties, output, required) do
    tool = mutation_tool(name, title, description, properties, output, required)
    %{tool | annotations: Map.put(tool.annotations, :openWorldHint, true)}
  end

  defp source_create_tool do
    external_mutation_tool(
      "measure.create_source",
      "Create a Measure site",
      "Create a Measure source and allow-list its normalized hostname. The browser token appears once in this response and never in later reads or audit data.",
      %{
        name: %{type: "string", minLength: 1, maxLength: 120},
        environment: %{type: "string", minLength: 1, maxLength: 64},
        hostname: hostname_schema()
      },
      strict_object(
        %{site: source_schema(), hostname: %{type: "string"}, secret: %{type: "string"}},
        ["site", "hostname", "secret"]
      ),
      ["name", "environment", "hostname"]
    )
  end

  defp hostname_schema, do: %{type: "string", minLength: 1, maxLength: 255}

  defp panels_schema do
    %{
      type: "array",
      minItems: 1,
      maxItems: 7,
      items: %{
        type: "string",
        enum: ~w(headline_cards chart pages sources events countries browsers)
      }
    }
  end

  defp secret_source_schema do
    strict_object(%{site: source_schema(), secret: %{type: "string"}}, ["site", "secret"])
  end

  defp secret_share_schema do
    strict_object(%{share: share_schema(), secret: %{type: "string"}}, ["share", "secret"])
  end

  defp goal_item_schema do
    strict_object(
      %{
        handle: %{type: "string"},
        name: %{type: "string"},
        kind: %{type: "string"},
        path: nullable_string(),
        event_name: nullable_string()
      },
      ["handle", "name", "kind", "path", "event_name"]
    )
  end

  defp event_definition_item_schema do
    strict_object(%{handle: %{type: "string"}, name: %{type: "string"}}, ["handle", "name"])
  end

  defp share_schema do
    strict_object(
      %{
        handle: %{type: "string"},
        source_handle: %{type: "string"},
        panels: %{type: "array", items: %{type: "string"}},
        token_prefix: %{type: "string"}
      },
      ["handle", "source_handle", "panels", "token_prefix"]
    )
  end

  defp goal_tool do
    tool =
      mutation_tool(
        "measure.create_goal",
        "Create a Measure goal",
        "Create one bounded pageview or custom-event goal through the existing Measure policy and plan boundary. Retry with the same idempotency key.",
        %{
          name: %{type: "string", minLength: 1, maxLength: 120},
          kind: %{type: "string", enum: ["pageview", "event"]},
          path: %{type: "string", minLength: 1, maxLength: 2048},
          event_name: %{type: "string", pattern: "^[a-z0-9_-]{1,64}$"}
        },
        goal_schema(),
        ["name", "kind"]
      )

    one_of = [
      %{
        properties: %{
          kind: %{const: "pageview"},
          path: %{type: "string", minLength: 1, maxLength: 2048}
        },
        required: ["kind", "path"]
      },
      %{
        properties: %{
          kind: %{const: "event"},
          event_name: %{type: "string", pattern: "^[a-z0-9_-]{1,64}$"}
        },
        required: ["kind", "event_name"]
      }
    ]

    %{tool | input_schema: Map.put(tool.input_schema, :oneOf, one_of)}
  end

  defp schema(properties, required, mutation?) do
    properties =
      if mutation?,
        do: properties,
        else: Map.put(properties, :project_handle, %{type: "string", minLength: 1})

    strict_object(properties, required ++ if(mutation?, do: [], else: ["project_handle"]))
  end

  defp source_schema do
    strict_object(
      %{
        handle: %{type: "string"},
        name: %{type: "string"},
        environment: %{type: "string"},
        hostname: nullable_string(),
        status: %{type: "string", enum: ["active", "revoked"]}
      },
      ["handle", "name", "environment", "hostname", "status"]
    )
  end

  defp metrics_schema do
    totals =
      strict_object(
        %{
          pageviews: %{type: "integer"},
          visitors: %{type: "integer"},
          visits: %{type: "integer"},
          bounces: %{type: "integer"},
          duration_seconds: %{type: "integer"},
          bounce_rate: %{type: ["string", "number", "null"]}
        },
        ["pageviews", "visitors", "visits", "bounces", "duration_seconds", "bounce_rate"]
      )

    comparison =
      strict_object(
        %{
          value: %{type: ["number", "integer", "string", "null"]},
          previous: %{type: ["number", "integer", "string", "null"]},
          change: %{type: ["number", "integer", "string", "null"]},
          known_value: %{type: ["number", "integer", "string", "null"]},
          coverage: %{type: ["string", "null"]}
        },
        ["value", "previous", "change"]
      )

    headlines =
      strict_object(
        %{
          visits: comparison,
          visitors: comparison,
          pageviews: comparison,
          bounce_rate: comparison,
          avg_duration: comparison,
          unavailable?: %{type: "boolean"},
          data_source: %{type: "string"},
          data_source_key: %{type: "string"},
          partial?: %{type: "boolean"}
        },
        [
          "visits",
          "visitors",
          "pageviews",
          "bounce_rate",
          "avg_duration",
          "unavailable?",
          "data_source",
          "data_source_key",
          "partial?"
        ]
      )

    trend_point =
      strict_object(
        %{
          bucket: %{type: "string"},
          pageviews: %{type: "integer"},
          visitors: %{type: "integer"},
          visits: %{type: "integer"},
          bounce_rate: %{type: ["number", "null"]},
          avg_duration: %{type: ["number", "null"]}
        },
        ["bucket", "pageviews", "visitors", "visits", "bounce_rate", "avg_duration"]
      )

    metrics =
      strict_object(
        %{
          source: source_schema(),
          window: %{type: "string", enum: @windows},
          availability: %{type: "string", enum: ["available", "unavailable"]},
          data_source: %{type: ["string", "null"]},
          totals: %{anyOf: [totals, %{type: "null"}]},
          headlines: %{anyOf: [headlines, %{type: "null"}]},
          trend: %{type: "array", items: trend_point}
        },
        ["source", "window", "availability", "data_source", "totals", "headlines", "trend"]
      )

    strict_object(%{metrics: metrics}, ["metrics"])
  end

  defp breakdown_schema do
    row =
      strict_object(
        %{
          value: %{type: "string"},
          label: %{type: "string"},
          count: %{type: "integer"},
          share: %{type: "number"},
          capped?: %{type: "boolean"}
        },
        ["value", "label", "count", "share", "capped?"]
      )

    breakdown =
      strict_object(
        %{
          source: source_schema(),
          window: %{type: "string", enum: @windows},
          dimension: %{type: "string", enum: @dimensions},
          rows: %{type: "array", items: row},
          page: %{type: "integer"},
          total_pages: %{type: "integer"},
          distinct_values: %{type: "integer"},
          capped?: %{type: "boolean"},
          previous?: %{type: "boolean"},
          next?: %{type: "boolean"},
          next_cursor: nullable_string()
        },
        [
          "source",
          "window",
          "dimension",
          "rows",
          "page",
          "total_pages",
          "distinct_values",
          "capped?",
          "previous?",
          "next?",
          "next_cursor"
        ]
      )

    strict_object(%{breakdown: breakdown}, ["breakdown"])
  end

  defp goal_schema do
    goal =
      strict_object(
        %{
          handle: %{type: "string"},
          name: %{type: "string"},
          kind: %{type: "string"},
          path: %{type: ["string", "null"]},
          event_name: %{type: ["string", "null"]}
        },
        ["handle", "name", "kind", "path", "event_name"]
      )

    strict_object(%{goal: goal}, ["goal"])
  end

  defp event_definition_schema do
    definition =
      strict_object(%{handle: %{type: "string"}, name: %{type: "string"}}, ["handle", "name"])

    strict_object(%{event_definition: definition}, ["event_definition"])
  end
end
