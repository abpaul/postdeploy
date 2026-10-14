defmodule Alplus.Analytics.McpAdapter do
  @moduledoc """
  Exposes product analytics to MCP callers (ADR 0007).

  The console is read-only, so this adapter is where analytics is
  configured: it creates the write key, saves funnels, sets the activation
  definition, and deletes analytics data. Reads answer the questions an
  agent is actually asked — how onboarding is performing, where people stop,
  whether a release changed behaviour.

  It exposes no general query interface. Every tool takes named arguments
  with bounded shapes, so no caller can reach the event table directly.
  """

  @behaviour Alplus.Mcp.Adapter

  require Ash.Query

  alias Alplus.Analytics.{Funnel, Limits, Queries, Settings}
  alias Alplus.Mcp.{Error, Principal, Tenancy, ToolSpec}
  alias Alplus.Sources.Source

  import Alplus.Mcp.Args,
    only: [optional_enum: 3, optional_string: 2, required_string: 2, value: 2]

  import Alplus.Mcp.ToolSpec, only: [nullable_string: 0, strict_object: 2]

  @tool_prefix "analytics"
  @windows Queries.windows()
  @granularities ~w(daily weekly)

  @impl true
  def prefix, do: @tool_prefix

  @impl true
  def tools do
    [
      read_tool(
        "analytics.overview",
        "Get the analytics overview",
        "Read one project's product analytics headline for a window: unique users, events, activation rate, and the top events. Use this first when asked how a product is doing.",
        %{window: window_schema(), source_handle: source_handle_schema()},
        overview_schema(),
        []
      ),
      read_tool(
        "analytics.list_events",
        "List product events",
        "List the event names seen in a window with their event count, unique users, and when each was last seen. Ordered by event count.",
        %{
          window: window_schema(),
          source_handle: source_handle_schema(),
          search: %{type: "string", minLength: 1, maxLength: 120},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        },
        strict_object(%{events: %{type: "array", items: event_summary_schema()}}, ["events"]),
        []
      ),
      read_tool(
        "analytics.get_event",
        "Inspect one product event",
        "Read one event's totals, its trend over time, and a breakdown by one property. Use the property breakdown to compare variants, platforms, or app versions.",
        %{
          event: event_name_schema(),
          window: window_schema(),
          source_handle: source_handle_schema(),
          breakdown_property: property_schema(),
          filters: filters_schema()
        },
        event_detail_schema(),
        ["event"]
      ),
      read_tool(
        "analytics.list_funnels",
        "List saved funnels",
        "List the funnels saved on one project, with their steps and conversion window.",
        %{},
        strict_object(%{funnels: %{type: "array", items: funnel_schema()}}, ["funnels"]),
        []
      ),
      read_tool(
        "analytics.get_funnel",
        "Run a funnel",
        "Run a saved funnel by handle, or an ad-hoc funnel by naming its steps. Returns per-step users, conversion against step one, conversion against the previous step, and where the largest drop happens.",
        %{
          funnel_handle: %{type: "string", minLength: 1},
          steps: steps_schema(),
          window: window_schema(),
          source_handle: source_handle_schema(),
          window_hours: %{type: "integer", minimum: 1, maximum: 2160},
          breakdown_property: property_schema(),
          filters: filters_schema()
        },
        funnel_result_schema(),
        []
      ),
      read_tool(
        "analytics.get_retention",
        "Get retention",
        "Read exact-period retention: of the people who first did the starting event, how many did the return event during each later day or week.",
        %{
          start_event: event_name_schema(),
          return_event: event_name_schema(),
          window: window_schema(),
          source_handle: source_handle_schema(),
          granularity: %{type: "string", enum: @granularities}
        },
        retention_schema(),
        ["start_event"]
      ),
      read_tool(
        "analytics.compare",
        "Compare one event across a property",
        "Compare how one event behaves across the values of a property, such as app_version or platform. Reports counts per value, never a cause.",
        %{
          event: event_name_schema(),
          property: property_schema(),
          window: window_schema(),
          source_handle: source_handle_schema(),
          filters: filters_schema()
        },
        strict_object(
          %{
            event: %{type: "string"},
            property: %{type: "string"},
            window: %{type: "string"},
            values: %{type: "array", items: breakdown_row_schema()}
          },
          ["event", "property", "window", "values"]
        ),
        ["event", "property"]
      ),
      read_tool(
        "analytics.list_live_events",
        "List recent events",
        "List the events received in the last hour, newest first, with their properties. Use this to verify instrumentation, never as an analytics query.",
        %{
          limit: %{type: "integer", minimum: 1, maximum: 100},
          source_handle: source_handle_schema()
        },
        strict_object(%{events: %{type: "array", items: live_event_schema()}}, ["events"]),
        []
      ),
      read_tool(
        "analytics.list_property_keys",
        "List property names",
        "List the property names seen on one event, for use as a filter or a breakdown.",
        %{event: event_name_schema()},
        strict_object(%{properties: %{type: "array", items: %{type: "string"}}}, ["properties"]),
        []
      ),
      read_tool(
        "analytics.get_settings",
        "Read the analytics configuration",
        "Read one project's activation definition and its primary funnel.",
        %{},
        strict_object(%{settings: settings_schema()}, ["settings"]),
        []
      ),
      external_mutation_tool(
        "analytics.create_source",
        "Create an analytics write key",
        "Create a product analytics source and mint its write-only key. The key appears once in this response and never in later reads or audit data. It can write events into this project and nothing else, so it is safe to publish inside a mobile or browser application.",
        %{
          name: %{type: "string", minLength: 1, maxLength: 120},
          environment: %{type: "string", minLength: 1, maxLength: 64}
        },
        strict_object(%{source: source_schema(), secret: %{type: "string"}}, ["source", "secret"]),
        ["name", "environment"]
      ),
      read_tool(
        "analytics.list_sources",
        "List analytics write keys",
        "List the product analytics sources on one project. Keys are never returned; only create and rotate return a key.",
        %{},
        strict_object(%{sources: %{type: "array", items: source_schema()}}, ["sources"]),
        []
      ),
      external_mutation_tool(
        "analytics.rotate_source",
        "Rotate an analytics write key",
        "Rotate one product analytics write key. The new key appears once in this response. Applications still sending the old key keep working until the grace period ends.",
        %{
          source_handle: %{type: "string", minLength: 1},
          grace_period_seconds: %{type: "integer", minimum: 0, maximum: 604_800}
        },
        strict_object(%{source: source_schema(), secret: %{type: "string"}}, ["source", "secret"]),
        ["source_handle"]
      ),
      mutation_tool(
        "analytics.revoke_source",
        "Revoke an analytics write key",
        "Revoke one product analytics write key. Applications still sending it stop being recorded immediately. Events already stored are untouched. This is destructive and customer-visible.",
        %{source_handle: %{type: "string", minLength: 1}},
        strict_object(%{source: source_schema(), revoked: %{type: "boolean"}}, [
          "source",
          "revoked"
        ]),
        ["source_handle"],
        true
      ),
      mutation_tool(
        "analytics.create_funnel",
        "Save a funnel",
        "Save an ordered funnel of two to eight event names. Conversion is measured from each person's first step-one event, inside the conversion window.",
        %{
          name: %{type: "string", minLength: 1, maxLength: 120},
          steps: steps_schema(),
          window_hours: %{type: "integer", minimum: 1, maximum: 2160},
          breakdown_property: property_schema(),
          filters: filters_schema()
        },
        strict_object(%{funnel: funnel_schema()}, ["funnel"]),
        ["name", "steps"],
        false
      ),
      mutation_tool(
        "analytics.update_funnel",
        "Update a saved funnel",
        "Replace a saved funnel's name, steps, conversion window, filters, or breakdown property.",
        %{
          funnel_handle: %{type: "string", minLength: 1},
          name: %{type: "string", minLength: 1, maxLength: 120},
          steps: steps_schema(),
          window_hours: %{type: "integer", minimum: 1, maximum: 2160},
          breakdown_property: property_schema(),
          filters: filters_schema()
        },
        strict_object(%{funnel: funnel_schema()}, ["funnel"]),
        ["funnel_handle"],
        false
      ),
      mutation_tool(
        "analytics.delete_funnel",
        "Delete a saved funnel",
        "Delete one saved funnel. Event data is untouched. This is destructive and customer-visible.",
        %{funnel_handle: %{type: "string", minLength: 1}},
        strict_object(%{deleted: %{type: "boolean"}}, ["deleted"]),
        ["funnel_handle"],
        true
      ),
      mutation_tool(
        "analytics.set_activation",
        "Set the activation definition",
        "Set the starting event and the activation event the overview measures, with the window between them. Send both names together. Anything you leave out keeps the value already stored, so changing the event names never clears the primary funnel.",
        %{
          start_event: event_name_schema(),
          activation_event: event_name_schema(),
          window_hours: %{type: "integer", minimum: 1, maximum: 2160},
          primary_funnel_handle: %{type: "string", minLength: 1}
        },
        strict_object(%{settings: settings_schema()}, ["settings"]),
        [],
        false
      ),
      mutation_tool(
        "analytics.delete_data",
        "Delete every analytics event",
        "Delete every product analytics event stored for one project. Funnels and the activation definition survive. This cannot be undone and it is customer-visible.",
        %{confirm_project_handle: %{type: "string", minLength: 1}},
        strict_object(%{deleted_events: %{type: "integer"}}, ["deleted_events"]),
        ["confirm_project_handle"],
        true
      )
    ]
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch(tool, args, scope) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  # ---- Reads ----------------------------------------------------------

  defp dispatch("analytics.overview", args, scope) do
    window = window(args)
    range = Queries.range(window)

    with {:ok, opts} <- source_opts(args, scope) do
      totals = Queries.totals(scope, range, opts)
      settings = settings_for(scope)

      {:ok,
       %{
         window: window,
         users: totals.users,
         events: totals.events,
         activation: Queries.activation(scope, range, settings, opts),
         top_events:
           scope
           |> Queries.list_events(range, Keyword.put(opts, :limit, 10))
           |> Enum.map(&event_summary_payload/1)
       }}
    end
  end

  defp dispatch("analytics.list_events", args, scope) do
    window = window(args)

    with {:ok, search} <- optional_string(args, "search"),
         {:ok, limit} <- limit(args, 100),
         {:ok, opts} <- source_opts(args, scope) do
      events =
        scope
        |> Queries.list_events(
          Queries.range(window),
          opts ++ [search: search, limit: limit]
        )
        |> Enum.map(&event_summary_payload/1)

      {:ok, %{events: events}}
    end
  end

  defp dispatch("analytics.get_event", args, scope) do
    window = window(args)
    range = Queries.range(window)

    with {:ok, event} <- event_name(args, "event"),
         {:ok, filters} <- filters(args),
         {:ok, source} <- source_opts(args, scope),
         {:ok, property} <- property(args, "breakdown_property") do
      opts = source ++ [event_name: event, filters: filters]
      totals = Queries.totals(scope, range, opts)

      breakdown =
        if property,
          do: Enum.map(Queries.breakdown(scope, range, property, opts), &breakdown_payload/1),
          else: []

      {:ok,
       %{
         event: event,
         window: window,
         events: totals.events,
         users: totals.users,
         events_per_user: per_user(totals),
         series:
           scope
           |> Queries.time_series(
             range,
             Keyword.put(opts, :interval, Queries.interval_for(window))
           )
           |> Enum.map(&series_payload/1),
         breakdown_property: property,
         breakdown: breakdown
       }}
    end
  end

  defp dispatch("analytics.list_funnels", _args, scope) do
    funnels = Alplus.Analytics.list_funnels_for_project!(scope.project_id, actor: scope)
    {:ok, %{funnels: Enum.map(funnels, &funnel_payload/1)}}
  end

  defp dispatch("analytics.get_funnel", args, scope) do
    window = window(args)

    with {:ok, definition} <- funnel_definition(args, scope),
         {:ok, filters} <- filters(args),
         {:ok, opts} <- source_opts(args, scope),
         {:ok, property} <- property(args, "breakdown_property") do
      filters = if filters == %{}, do: definition.filters, else: filters
      property = property || definition.breakdown_property

      results =
        scope
        |> Queries.funnel(
          Queries.range(window),
          definition.steps,
          opts ++
            [
              window_hours: definition.window_hours,
              filters: filters,
              breakdown: property
            ]
        )
        |> Enum.map(&Queries.with_conversions/1)
        |> Enum.map(&funnel_result_payload/1)

      {:ok,
       %{
         name: definition.name,
         window: window,
         window_hours: definition.window_hours,
         breakdown_property: property,
         results: results
       }}
    end
  end

  defp dispatch("analytics.get_retention", args, scope) do
    window = window(args)

    with {:ok, start_event} <- event_name(args, "start_event"),
         {:ok, granularity} <- optional_enum(args, "granularity", @granularities),
         {:ok, opts} <- source_opts(args, scope),
         {:ok, return_event} <- optional_event_name(args, "return_event") do
      result =
        Queries.retention(
          scope,
          Queries.range(window),
          start_event,
          return_event || start_event,
          Keyword.put(opts, :granularity, granularity || "daily")
        )

      {:ok,
       %{
         start_event: start_event,
         return_event: return_event || start_event,
         window: window,
         granularity: result.granularity,
         periods: Enum.map(result.periods, &retention_payload/1)
       }}
    end
  end

  defp dispatch("analytics.compare", args, scope) do
    window = window(args)

    with {:ok, event} <- event_name(args, "event"),
         {:ok, property} <- property(args, "property"),
         {:ok, opts} <- source_opts(args, scope),
         {:ok, filters} <- filters(args) do
      if is_nil(property) do
        {:error, {:missing_argument, "property"}}
      else
        values =
          scope
          |> Queries.breakdown(
            Queries.range(window),
            property,
            opts ++ [event_name: event, filters: filters]
          )
          |> Enum.map(&breakdown_payload/1)

        {:ok, %{event: event, property: property, window: window, values: values}}
      end
    end
  end

  defp dispatch("analytics.list_live_events", args, scope) do
    with {:ok, limit} <- limit(args, Limits.live_events_limit()),
         {:ok, opts} <- source_opts(args, scope) do
      events =
        scope
        |> Queries.live_events(Keyword.put(opts, :limit, limit))
        |> Enum.map(&live_event_payload/1)

      {:ok, %{events: events}}
    end
  end

  defp dispatch("analytics.list_property_keys", args, scope) do
    with {:ok, event} <- optional_event_name(args, "event") do
      {:ok, %{properties: Queries.property_keys(scope, event)}}
    end
  end

  defp dispatch("analytics.get_settings", _args, scope) do
    {:ok, %{settings: settings_payload(settings_for(scope), scope)}}
  end

  defp dispatch("analytics.list_sources", _args, scope) do
    {:ok, %{sources: Enum.map(analytics_sources(scope), &source_payload/1)}}
  end

  # ---- Writes ---------------------------------------------------------

  defp dispatch("analytics.create_source", args, scope) do
    with {:ok, name} <- required_string(args, "name"),
         {:ok, environment} <- required_string(args, "environment"),
         {:ok, source} <-
           Alplus.Sources.create_source(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               type: :analytics,
               name: name,
               environment: environment
             },
             actor: scope
           ) do
      {:ok, %{source: source_payload(source), secret: Ash.Resource.get_metadata(source, :secret)}}
    end
  end

  defp dispatch("analytics.rotate_source", args, scope) do
    with {:ok, handle} <- required_string(args, "source_handle"),
         {:ok, source} <- analytics_source(handle, scope),
         grace <- value(args, "grace_period_seconds") || 86_400,
         {:ok, rotated} <- Alplus.Sources.rotate_source(source, grace, actor: scope) do
      {:ok,
       %{source: source_payload(rotated), secret: Ash.Resource.get_metadata(rotated, :secret)}}
    end
  end

  defp dispatch("analytics.revoke_source", args, scope) do
    with {:ok, handle} <- required_string(args, "source_handle"),
         {:ok, source} <- analytics_source(handle, scope),
         {:ok, revoked} <- Alplus.Sources.revoke_source(source, actor: scope) do
      {:ok, %{source: source_payload(revoked), revoked: true}}
    end
  end

  defp dispatch("analytics.create_funnel", args, scope) do
    with {:ok, name} <- required_string(args, "name"),
         {:ok, steps} <- steps(args),
         {:ok, filters} <- filters(args),
         {:ok, property} <- property(args, "breakdown_property"),
         {:ok, funnel} <-
           Alplus.Analytics.create_funnel(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               name: name,
               steps: steps,
               window_hours: value(args, "window_hours") || 168,
               filters: filters,
               breakdown_property: property
             },
             actor: scope
           ) do
      {:ok, %{funnel: funnel_payload(funnel)}}
    end
  end

  defp dispatch("analytics.update_funnel", args, scope) do
    with {:ok, handle} <- required_string(args, "funnel_handle"),
         {:ok, funnel} <- saved_funnel(handle, scope),
         {:ok, attrs} <- funnel_updates(args, funnel),
         {:ok, updated} <- Alplus.Analytics.update_funnel(funnel, attrs, actor: scope) do
      {:ok, %{funnel: funnel_payload(updated)}}
    end
  end

  defp dispatch("analytics.delete_funnel", args, scope) do
    with {:ok, handle} <- required_string(args, "funnel_handle"),
         {:ok, funnel} <- saved_funnel(handle, scope),
         :ok <- Alplus.Analytics.destroy_funnel(funnel, actor: scope) do
      {:ok, %{deleted: true}}
    end
  end

  # Merge with what is stored. Writing every field on every call erased the
  # primary funnel and reset the window whenever a caller changed only the
  # event names, and nothing in the tool description warned them.
  defp dispatch("analytics.set_activation", args, scope) do
    current = settings_for(scope)

    with {:ok, start_event} <- optional_event_name(args, "start_event"),
         {:ok, activation_event} <- optional_event_name(args, "activation_event"),
         {:ok, primary_funnel_id} <- primary_funnel_id(args, scope),
         {:ok, settings} <-
           Alplus.Analytics.configure_settings(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               activation_start_event: start_event || stored(current, :activation_start_event),
               activation_event: activation_event || stored(current, :activation_event),
               activation_window_hours:
                 value(args, "window_hours") || stored(current, :activation_window_hours) ||
                   168,
               primary_funnel_id: primary_funnel_id || stored(current, :primary_funnel_id)
             },
             actor: scope
           ) do
      {:ok, %{settings: settings_payload(settings, scope)}}
    end
  end

  # The project handle must be typed a second time. A delete that only needed
  # a project the caller already selected would be one confused tool call away
  # from erasing the wrong project's history.
  defp dispatch("analytics.delete_data", args, scope) do
    with {:ok, confirmation} <- required_string(args, "confirm_project_handle"),
         :ok <- confirm_project(confirmation, args, scope) do
      {:ok, %{deleted_events: Queries.delete_project_data(scope)}}
    end
  end

  defp dispatch(_tool, _args, _scope), do: {:error, :not_found}

  # ---- Argument handling ----------------------------------------------

  defp window(args), do: args |> value("window") |> Queries.valid_window()

  # A project holds one write key per application. Naming one narrows the
  # read to that application; omitting it reads every application together,
  # which is what makes a cross-application funnel possible.
  defp source_opts(args, scope) do
    case optional_string(args, "source_handle") do
      {:ok, nil} ->
        {:ok, []}

      {:ok, handle} ->
        with {:ok, source} <- analytics_source(handle, scope), do: {:ok, [source_id: source.id]}

      error ->
        error
    end
  end

  defp limit(args, default) do
    case value(args, "limit") do
      nil -> {:ok, default}
      limit when is_integer(limit) and limit >= 1 and limit <= 100 -> {:ok, limit}
      _other -> {:error, :invalid_limit}
    end
  end

  defp event_name(args, key) do
    case required_string(args, key) do
      {:ok, name} -> validate_event_name(name, key)
      error -> error
    end
  end

  defp optional_event_name(args, key) do
    case optional_string(args, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, name} -> validate_event_name(name, key)
      error -> error
    end
  end

  defp validate_event_name(name, key) do
    if Limits.valid_event_name?(name),
      do: {:ok, name},
      else: {:error, {:invalid_argument, key}}
  end

  defp property(args, key) do
    case optional_string(args, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, name} ->
        if Limits.valid_property_key?(name),
          do: {:ok, name},
          else: {:error, {:invalid_argument, key}}

      error ->
        error
    end
  end

  defp filters(args) do
    case value(args, "filters") do
      nil ->
        {:ok, %{}}

      filters when is_map(filters) ->
        if map_size(filters) <= Limits.property_max_count() and
             Enum.all?(filters, fn {key, val} ->
               Limits.valid_property_key?(key) and scalar?(val)
             end),
           do: {:ok, filters},
           else: {:error, {:invalid_argument, "filters"}}

      _other ->
        {:error, {:invalid_argument, "filters"}}
    end
  end

  defp scalar?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp scalar?(_value), do: false

  defp steps(args) do
    bounds = Funnel.step_bounds()

    case value(args, "steps") do
      steps when is_list(steps) ->
        if length(steps) in bounds and Enum.all?(steps, &Limits.valid_event_name?/1),
          do: {:ok, steps},
          else: {:error, {:invalid_argument, "steps"}}

      _other ->
        {:error, {:missing_argument, "steps"}}
    end
  end

  # A funnel is either saved or named inline. Both produce the same shape, so
  # everything downstream stops caring which it was.
  defp funnel_definition(args, scope) do
    case optional_string(args, "funnel_handle") do
      {:ok, nil} ->
        with {:ok, steps} <- steps(args) do
          {:ok,
           %{
             name: nil,
             steps: steps,
             window_hours: value(args, "window_hours") || 168,
             filters: %{},
             breakdown_property: nil
           }}
        end

      {:ok, handle} ->
        with {:ok, funnel} <- saved_funnel(handle, scope) do
          {:ok,
           %{
             name: funnel.name,
             steps: funnel.steps,
             window_hours: value(args, "window_hours") || funnel.window_hours,
             filters: funnel.filters,
             breakdown_property: funnel.breakdown_property
           }}
        end

      error ->
        error
    end
  end

  defp funnel_updates(args, funnel) do
    with {:ok, name} <- optional_string(args, "name"),
         {:ok, property} <- property(args, "breakdown_property"),
         {:ok, filters} <- filters(args),
         {:ok, steps} <- optional_steps(args, funnel) do
      {:ok,
       %{
         name: name || funnel.name,
         steps: steps,
         window_hours: value(args, "window_hours") || funnel.window_hours,
         filters: if(map_size(filters) == 0, do: funnel.filters, else: filters),
         breakdown_property: property || funnel.breakdown_property
       }}
    end
  end

  defp optional_steps(args, funnel) do
    case value(args, "steps") do
      nil -> {:ok, funnel.steps}
      _steps -> steps(args)
    end
  end

  defp primary_funnel_id(args, scope) do
    case optional_string(args, "primary_funnel_handle") do
      {:ok, nil} -> {:ok, nil}
      {:ok, handle} -> with {:ok, funnel} <- saved_funnel(handle, scope), do: {:ok, funnel.id}
      error -> error
    end
  end

  defp confirm_project(confirmation, args, scope) do
    supplied = value(args, "project_handle")

    if confirmation == supplied or confirmation == scope.project_id,
      do: :ok,
      else: {:error, :confirmation_mismatch}
  end

  # ---- Resource lookups -----------------------------------------------

  defp saved_funnel(handle, scope) do
    Funnel
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^handle)
    |> Ash.read_one(actor: scope)
    |> case do
      {:ok, %Funnel{} = funnel} -> {:ok, funnel}
      _ -> {:error, :not_found}
    end
  end

  defp analytics_sources(scope) do
    scope.project_id
    |> Alplus.Sources.list_sources_for_project!(actor: scope)
    |> Enum.filter(&(&1.type == :analytics))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  defp analytics_source(handle, scope) do
    case Enum.find(analytics_sources(scope), &(&1.id == handle)) do
      %Source{} = source -> {:ok, source}
      nil -> {:error, :not_found}
    end
  end

  defp stored(nil, _field), do: nil
  defp stored(%Settings{} = settings, field), do: Map.fetch!(settings, field)

  defp settings_for(scope) do
    case Alplus.Analytics.get_settings_for_project(scope.project_id, actor: scope) do
      {:ok, %Settings{} = settings} -> settings
      _ -> nil
    end
  end

  # ---- Payloads -------------------------------------------------------

  defp event_summary_payload(event) do
    %{
      event: event.event_name,
      events: event.events,
      users: event.users,
      first_seen: iso(event.first_seen),
      last_seen: iso(event.last_seen)
    }
  end

  defp breakdown_payload(row),
    do: %{value: row.value, events: row.events, users: row.users}

  defp series_payload(point),
    do: %{at: iso(point.at), events: point.events, users: point.users}

  defp retention_payload(period),
    do: %{
      period: period.period,
      cohort: period.cohort,
      retained: period.retained,
      rate: period.rate
    }

  defp live_event_payload(event) do
    %{
      event: event.event_name,
      distinct_id: event.distinct_id,
      occurred_at: iso(event.occurred_at),
      received_at: iso(event.received_at),
      properties: event.properties
    }
  end

  defp funnel_payload(funnel) do
    %{
      handle: funnel.id,
      name: funnel.name,
      steps: funnel.steps,
      window_hours: funnel.window_hours,
      filters: funnel.filters,
      breakdown_property: funnel.breakdown_property
    }
  end

  defp funnel_result_payload(entry) do
    %{
      breakdown_value: entry.breakdown_value,
      entered: entry.entered,
      converted: entry.converted,
      overall_rate: entry.overall_rate,
      largest_drop_event: entry.largest_drop_event,
      steps:
        Enum.map(entry.steps, fn step ->
          %{
            event: step.event_name,
            users: step.users,
            overall_rate: step.overall_rate,
            step_rate: step.step_rate,
            lost: step.lost
          }
        end)
    }
  end

  defp settings_payload(nil, _scope),
    do: %{
      activation_start_event: nil,
      activation_event: nil,
      activation_window_hours: nil,
      primary_funnel_handle: nil
    }

  defp settings_payload(%Settings{} = settings, _scope),
    do: %{
      activation_start_event: settings.activation_start_event,
      activation_event: settings.activation_event,
      activation_window_hours: settings.activation_window_hours,
      primary_funnel_handle: settings.primary_funnel_id
    }

  defp source_payload(%Source{} = source) do
    %{
      handle: source.id,
      name: source.name,
      environment: source.environment,
      status: to_string(source.status),
      key_prefix: source.secret_prefix
    }
  end

  defp per_user(%{events: _events, users: 0}), do: nil
  defp per_user(%{events: events, users: users}), do: events / users

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  # ---- Errors ---------------------------------------------------------

  defp map_error(:invalid_limit),
    do:
      Error.new(:invalid_argument, "limit must be an integer between 1 and 100", %{
        field: "limit",
        minimum: 1,
        maximum: 100
      })

  defp map_error(:confirmation_mismatch),
    do:
      Error.new(
        :invalid_argument,
        "confirm_project_handle must repeat the project handle exactly",
        %{field: "confirm_project_handle"}
      )

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

  # ---- Schemas --------------------------------------------------------

  defp read_tool(name, title, description, properties, output, required),
    do:
      ToolSpec.read_tool(
        name,
        title,
        description,
        schema(properties, required, false),
        output
      )

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
    tool = mutation_tool(name, title, description, properties, output, required, false)
    %{tool | annotations: Map.put(tool.annotations, :openWorldHint, true)}
  end

  defp schema(properties, required, mutation?) do
    properties =
      if mutation?,
        do: properties,
        else: Map.put(properties, :project_handle, %{type: "string", minLength: 1})

    strict_object(properties, required ++ if(mutation?, do: [], else: ["project_handle"]))
  end

  defp window_schema, do: %{type: "string", enum: @windows}

  defp source_handle_schema, do: %{type: "string", minLength: 1}

  defp event_name_schema,
    do: %{type: "string", minLength: 1, maxLength: Limits.event_name_max_bytes()}

  defp property_schema,
    do: %{type: "string", minLength: 1, maxLength: Limits.property_key_max_bytes()}

  defp filters_schema,
    do: %{
      type: "object",
      additionalProperties: %{type: ["string", "number", "boolean"]},
      maxProperties: Limits.property_max_count()
    }

  defp steps_schema do
    bounds = Funnel.step_bounds()

    %{
      type: "array",
      minItems: bounds.first,
      maxItems: bounds.last,
      items: event_name_schema()
    }
  end

  defp event_summary_schema do
    strict_object(
      %{
        event: %{type: "string"},
        events: %{type: "integer"},
        users: %{type: "integer"},
        first_seen: nullable_string(),
        last_seen: nullable_string()
      },
      ["event", "events", "users", "first_seen", "last_seen"]
    )
  end

  defp breakdown_row_schema do
    strict_object(
      %{
        value: %{type: "string"},
        events: %{type: "integer"},
        users: %{type: ["integer", "null"]}
      },
      ["value", "events", "users"]
    )
  end

  defp series_point_schema do
    strict_object(
      %{at: %{type: "string"}, events: %{type: "integer"}, users: %{type: "integer"}},
      ["at", "events", "users"]
    )
  end

  defp live_event_schema do
    strict_object(
      %{
        event: %{type: "string"},
        distinct_id: %{type: "string"},
        occurred_at: %{type: "string"},
        received_at: %{type: "string"},
        properties: %{type: "object"}
      },
      ["event", "distinct_id", "occurred_at", "received_at", "properties"]
    )
  end

  defp activation_schema do
    %{
      type: ["object", "null"],
      properties: %{
        start_event: %{type: "string"},
        activation_event: %{type: "string"},
        window_hours: %{type: "integer"},
        started: %{type: "integer"},
        activated: %{type: "integer"},
        rate: %{type: ["number", "null"]}
      },
      additionalProperties: false
    }
  end

  defp overview_schema do
    strict_object(
      %{
        window: %{type: "string"},
        users: %{type: "integer"},
        events: %{type: "integer"},
        activation: activation_schema(),
        top_events: %{type: "array", items: event_summary_schema()}
      },
      ["window", "users", "events", "activation", "top_events"]
    )
  end

  defp event_detail_schema do
    strict_object(
      %{
        event: %{type: "string"},
        window: %{type: "string"},
        events: %{type: "integer"},
        users: %{type: "integer"},
        events_per_user: %{type: ["number", "null"]},
        series: %{type: "array", items: series_point_schema()},
        breakdown_property: nullable_string(),
        breakdown: %{type: "array", items: breakdown_row_schema()}
      },
      [
        "event",
        "window",
        "events",
        "users",
        "events_per_user",
        "series",
        "breakdown_property",
        "breakdown"
      ]
    )
  end

  defp funnel_schema do
    strict_object(
      %{
        handle: %{type: "string"},
        name: %{type: "string"},
        steps: %{type: "array", items: %{type: "string"}},
        window_hours: %{type: "integer"},
        filters: %{type: "object"},
        breakdown_property: nullable_string()
      },
      ["handle", "name", "steps", "window_hours", "filters", "breakdown_property"]
    )
  end

  defp funnel_step_result_schema do
    strict_object(
      %{
        event: %{type: "string"},
        users: %{type: "integer"},
        overall_rate: %{type: ["number", "null"]},
        step_rate: %{type: ["number", "null"]},
        lost: %{type: "integer"}
      },
      ["event", "users", "overall_rate", "step_rate", "lost"]
    )
  end

  defp funnel_result_schema do
    entry =
      strict_object(
        %{
          breakdown_value: nullable_string(),
          entered: %{type: "integer"},
          converted: %{type: "integer"},
          overall_rate: %{type: ["number", "null"]},
          largest_drop_event: nullable_string(),
          steps: %{type: "array", items: funnel_step_result_schema()}
        },
        ["breakdown_value", "entered", "converted", "overall_rate", "largest_drop_event", "steps"]
      )

    strict_object(
      %{
        name: nullable_string(),
        window: %{type: "string"},
        window_hours: %{type: "integer"},
        breakdown_property: nullable_string(),
        results: %{type: "array", items: entry}
      },
      ["name", "window", "window_hours", "breakdown_property", "results"]
    )
  end

  defp retention_schema do
    period =
      strict_object(
        %{
          period: %{type: "integer"},
          cohort: %{type: "integer"},
          retained: %{type: "integer"},
          rate: %{type: ["number", "null"]}
        },
        ["period", "cohort", "retained", "rate"]
      )

    strict_object(
      %{
        start_event: %{type: "string"},
        return_event: %{type: "string"},
        window: %{type: "string"},
        granularity: %{type: "string"},
        periods: %{type: "array", items: period}
      },
      ["start_event", "return_event", "window", "granularity", "periods"]
    )
  end

  defp settings_schema do
    strict_object(
      %{
        activation_start_event: nullable_string(),
        activation_event: nullable_string(),
        activation_window_hours: %{type: ["integer", "null"]},
        primary_funnel_handle: nullable_string()
      },
      [
        "activation_start_event",
        "activation_event",
        "activation_window_hours",
        "primary_funnel_handle"
      ]
    )
  end

  defp source_schema do
    strict_object(
      %{
        handle: %{type: "string"},
        name: %{type: "string"},
        environment: %{type: "string"},
        status: %{type: "string"},
        key_prefix: nullable_string()
      },
      ["handle", "name", "environment", "status", "key_prefix"]
    )
  end
end
