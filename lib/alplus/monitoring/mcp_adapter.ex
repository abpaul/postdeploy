defmodule Alplus.Monitoring.McpAdapter do
  @moduledoc "Exposes project-scoped monitor operations to authenticated MCP callers."

  @behaviour Alplus.Mcp.Adapter

  require Ash.Query

  alias Alplus.Mcp.{Args, Cursor, Error, Principal, Tenancy, ToolSpec}

  import Alplus.Mcp.Args, only: [value: 2]
  import Alplus.Mcp.ToolSpec, only: [object_schema: 1]

  alias Alplus.Monitoring.{
    Heartbeat,
    Incident,
    Monitor,
    MonitorCheck,
    MonitorCreator,
    MonitorDestroyer,
    MonitorFormAttrs,
    MonitorUpdater
  }

  @tool_prefix "monitor"
  @page_default 50
  @page_min 1
  @page_max 100

  @impl true
  def prefix, do: @tool_prefix

  @impl true
  def tools do
    [
      read_tool(
        "monitor.list",
        "List monitors",
        "List the monitors in one project. Use the opaque cursor for later pages. This read is safe to retry.",
        %{
          status: %{type: "string", enum: ["active", "paused"]},
          type: %{type: "string", enum: ["http", "keyword", "heartbeat", "tcp", "dns"]},
          environment: %{type: "string"},
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        },
        %{
          monitors: %{type: "array", items: monitor_schema()},
          next_cursor: %{type: ["string", "null"]}
        }
      ),
      read_tool(
        "monitor.get",
        "Get a monitor",
        "Get one monitor and its safe configuration. Heartbeat secrets never appear in this result.",
        %{monitor_handle: %{type: "string"}},
        %{monitor: monitor_schema()},
        ["monitor_handle"]
      ),
      create_tool(),
      mutation_tool(
        "monitor.update",
        "Update a monitor",
        "Update a monitor name, environment, and typed configuration. Supply the current required fields for its type. Retry with the same idempotency key.",
        update_properties(),
        ["monitor_handle", "name"],
        %{monitor: monitor_schema()}
      ),
      mutation_tool(
        "monitor.pause",
        "Pause or resume a monitor",
        "Pause or resume scheduled checks for one monitor. Set paused to true to pause, or false to resume. Retry with the same idempotency key.",
        %{monitor_handle: %{type: "string"}, paused: %{type: "boolean"}},
        ["monitor_handle", "paused"],
        %{monitor: monitor_schema()}
      ),
      destructive_tool(
        "monitor.delete",
        "Delete a monitor",
        "Permanently delete one monitor, its typed configuration, checks, incidents, and scheduler registration. Retry with the same idempotency key.",
        %{monitor_handle: %{type: "string"}},
        ["monitor_handle"],
        %{deleted: %{type: "boolean"}, monitor_handle: %{type: "string"}}
      ),
      destructive_tool(
        "monitor.reissue_heartbeat_secret",
        "Reissue a heartbeat secret",
        "Invalidate the current heartbeat secret and return a replacement exactly once. The secret cannot be read later. Retry with the same idempotency key.",
        %{monitor_handle: %{type: "string"}},
        ["monitor_handle"],
        %{monitor_handle: %{type: "string"}, heartbeat_secret: %{type: "string"}}
      ),
      read_tool(
        "monitor.list_checks",
        "List monitor checks",
        "List recent checks for one monitor. The result excludes internal detail and heartbeat secrets. Use the opaque cursor for later pages.",
        %{
          monitor_handle: %{type: "string"},
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        },
        %{
          checks: %{type: "array", items: check_schema()},
          next_cursor: %{type: ["string", "null"]}
        },
        ["monitor_handle"]
      ),
      read_tool(
        "monitor.list_incidents",
        "List monitor incidents",
        "List incidents for one monitor. This read is safe to retry.",
        %{
          monitor_handle: %{type: "string"},
          cursor: %{type: "string"},
          limit: %{type: "integer", minimum: 1, maximum: 100}
        },
        %{
          incidents: %{type: "array", items: incident_schema()},
          next_cursor: %{type: ["string", "null"]}
        },
        ["monitor_handle"]
      ),
      mutation_tool(
        "monitor.acknowledge_incident",
        "Acknowledge an incident",
        "Acknowledge one open incident. This requires an owner or admin credential. Retry with the same idempotency key.",
        %{incident_handle: %{type: "string"}},
        ["incident_handle"],
        %{incident: incident_schema()}
      ),
      mutation_tool(
        "monitor.heartbeat",
        "Record a heartbeat",
        "Record a start, finish, or fail event for a heartbeat monitor without exposing its heartbeat URL or token. Retry with the same idempotency key.",
        %{
          monitor_handle: %{type: "string"},
          state: %{type: "string", enum: ["start", "finish", "fail"]}
        },
        ["monitor_handle", "state"],
        %{accepted: %{type: "boolean"}, state: %{type: "string"}}
      )
    ]
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch(tool, args, principal, scope) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason, tool)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  defp dispatch("monitor.list", args, principal, scope) do
    with {:ok, filters} <- list_filters(args),
         {:ok, limit} <- normalize_limit(args),
         {:ok, cursor} <- decode_cursor(principal, args, "monitor.list", filters),
         {:ok, monitors} <- list_monitors(scope, filters, cursor, limit) do
      page = Enum.take(monitors, limit)

      next =
        if length(monitors) > limit,
          do: Cursor.encode(principal, "monitor.list", filters, monitor_cursor(List.last(page)))

      {:ok, %{monitors: Enum.map(page, &monitor_payload/1), next_cursor: next}}
    end
  end

  defp dispatch("monitor.get", args, _principal, scope) do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, monitor} <- get_monitor(monitor_handle, scope) do
      {:ok, %{monitor: monitor_payload(monitor)}}
    end
  end

  defp dispatch("monitor.create", args, _principal, scope) do
    with {:ok, params} <- create_params(args),
         {:ok, monitor_attrs, config_attrs} <-
           MonitorFormAttrs.monitor_create_attrs(params.monitor, params.config, scope),
         {:ok, %{monitor: monitor, heartbeat_token: heartbeat_token}} <-
           MonitorCreator.create(monitor_attrs, config_attrs, scope),
         {:ok, monitor} <- get_monitor(monitor.id, scope) do
      create_result(monitor, heartbeat_token)
    end
  end

  defp dispatch("monitor.update", args, _principal, scope) do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, monitor} <- get_monitor(monitor_handle, scope),
         {:ok, config} <- config_for(monitor),
         {:ok, monitor_params, config_params} <- update_params(args, monitor, config),
         {:ok, monitor_attrs, config_attrs} <-
           MonitorFormAttrs.monitor_update_attrs(monitor_params, config_params, monitor.type),
         {:ok, _updated} <-
           MonitorUpdater.update(monitor, config, monitor_attrs, config_attrs, scope),
         {:ok, updated} <- get_monitor(monitor.id, scope) do
      {:ok, %{monitor: monitor_payload(updated)}}
    end
  end

  defp dispatch("monitor.pause", args, _principal, scope) do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, paused} <- required_boolean(args, "paused"),
         {:ok, monitor} <- get_monitor(monitor_handle, scope),
         {:ok, updated} <-
           MonitorUpdater.update_status(monitor, if(paused, do: "paused", else: "active"), scope),
         {:ok, updated} <- get_monitor(updated.id, scope) do
      {:ok, %{monitor: monitor_payload(updated)}}
    end
  end

  defp dispatch("monitor.delete", args, _principal, scope) do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, monitor} <- get_monitor(monitor_handle, scope),
         :ok <- MonitorDestroyer.destroy(monitor, scope) do
      {:ok, %{deleted: true, monitor_handle: monitor.id}}
    end
  end

  defp dispatch("monitor.reissue_heartbeat_secret", args, _principal, scope) do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, monitor} <- get_monitor(monitor_handle, scope),
         {:ok, config} <- MonitorUpdater.reissue_heartbeat_token(monitor, scope),
         secret when is_binary(secret) <-
           Ash.Resource.get_metadata(config, :heartbeat_token) || {:error, :secret_not_issued} do
      {:ok, %{monitor_handle: monitor.id, heartbeat_secret: secret}}
    end
  end

  defp dispatch(tool, args, principal, scope)
       when tool in ["monitor.list_checks", "monitor.list_incidents"] do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, monitor} <- get_monitor(monitor_handle, scope),
         {:ok, limit} <- normalize_limit(args),
         filters <- %{project_handle: value(args, "project_handle"), monitor_handle: monitor.id},
         {:ok, cursor} <- decode_cursor(principal, args, tool, filters),
         {:ok, rows} <- list_activity(tool, monitor, scope, cursor, limit) do
      {key, mapper} =
        if tool == "monitor.list_checks",
          do: {:checks, &check_payload/1},
          else: {:incidents, &incident_payload/1}

      page = Enum.take(rows, limit)

      next =
        if length(rows) > limit,
          do: Cursor.encode(principal, tool, filters, activity_cursor(tool, List.last(page)))

      {:ok, %{key => Enum.map(page, mapper), next_cursor: next}}
    end
  end

  defp dispatch("monitor.acknowledge_incident", args, _principal, scope) do
    with {:ok, incident_handle} <- required_string(args, "incident_handle"),
         {:ok, incident} <- Alplus.Monitoring.get_incident(incident_handle, actor: scope),
         %Incident{} <- incident,
         {:ok, acknowledged} <-
           Alplus.Monitoring.acknowledge_incident(incident, actor: scope) do
      {:ok, %{incident: incident_payload(acknowledged)}}
    end
  end

  defp dispatch("monitor.heartbeat", args, _principal, scope) do
    with {:ok, monitor_handle} <- required_string(args, "monitor_handle"),
         {:ok, state} <- heartbeat_state(value(args, "state")),
         {:ok, monitor} <- get_monitor(monitor_handle, scope),
         true <- monitor.type == "heartbeat" or {:error, :invalid_monitor_type},
         :accepted <- Heartbeat.accept_for_monitor(monitor, state) do
      {:ok, %{accepted: true, state: Atom.to_string(state)}}
    else
      :paused -> {:error, :monitor_paused}
      :unknown -> {:error, :heartbeat_not_accepted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(_tool, _args, _principal, _scope), do: {:error, :not_found}

  defp list_monitors(scope, filters, cursor, limit) do
    query =
      Monitor
      |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
      |> maybe_filter(:status, filters.status)
      |> maybe_filter(:type, filters.type)
      |> maybe_filter(:environment, filters.environment)
      |> maybe_after_monitor(cursor)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit + 1)

    with {:ok, monitors} <- Ash.read(query, actor: scope) do
      Ash.load(
        monitors,
        [
          :http_config,
          :heartbeat_config,
          :tcp_config,
          :dns_config,
          :latest_check,
          :open_incident
        ],
        actor: scope
      )
    end
  end

  defp list_activity("monitor.list_checks", monitor, scope, cursor, limit) do
    MonitorCheck
    |> Ash.Query.for_read(:list_for_monitor, %{monitor_id: monitor.id}, actor: scope)
    |> maybe_after_check(cursor)
    |> Ash.Query.sort(checked_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read(actor: scope)
  end

  defp list_activity("monitor.list_incidents", monitor, scope, cursor, limit) do
    Incident
    |> Ash.Query.filter(monitor_id == ^monitor.id)
    |> maybe_after_incident(cursor)
    |> Ash.Query.sort(started_at: :desc, id: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read(actor: scope)
  end

  defp maybe_after_monitor(query, nil), do: query

  defp maybe_after_monitor(query, {timestamp, id}),
    do:
      Ash.Query.filter(
        query,
        inserted_at < ^timestamp or (inserted_at == ^timestamp and id < ^id)
      )

  defp maybe_after_check(query, nil), do: query

  defp maybe_after_check(query, {timestamp, id}),
    do:
      Ash.Query.filter(query, checked_at < ^timestamp or (checked_at == ^timestamp and id < ^id))

  defp maybe_after_incident(query, nil), do: query

  defp maybe_after_incident(query, {timestamp, id}),
    do:
      Ash.Query.filter(query, started_at < ^timestamp or (started_at == ^timestamp and id < ^id))

  defp monitor_cursor(nil), do: nil
  defp monitor_cursor(%Monitor{inserted_at: timestamp, id: id}), do: {timestamp, id}

  defp activity_cursor("monitor.list_checks", %MonitorCheck{checked_at: timestamp, id: id}),
    do: {timestamp, id}

  defp activity_cursor("monitor.list_incidents", %Incident{started_at: timestamp, id: id}),
    do: {timestamp, id}

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :status, value), do: Ash.Query.filter(query, status == ^value)
  defp maybe_filter(query, :type, value), do: Ash.Query.filter(query, type == ^value)

  defp maybe_filter(query, :environment, value),
    do: Ash.Query.filter(query, environment == ^value)

  defp get_monitor(id, scope) do
    case Ash.get(Monitor, id, actor: scope) do
      {:ok, %Monitor{project_id: project_id} = monitor} when project_id == scope.project_id ->
        case Ash.load(
               monitor,
               [
                 :http_config,
                 :heartbeat_config,
                 :tcp_config,
                 :dns_config,
                 :latest_check,
                 :open_incident
               ],
               actor: scope
             ) do
          {:ok, loaded} -> {:ok, loaded}
          {:error, _} -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp config_for(%Monitor{type: type} = monitor) when type in ["http", "keyword"],
    do: {:ok, monitor.http_config}

  defp config_for(%Monitor{type: "heartbeat"} = monitor), do: {:ok, monitor.heartbeat_config}
  defp config_for(%Monitor{type: "tcp"} = monitor), do: {:ok, monitor.tcp_config}
  defp config_for(%Monitor{type: "dns"} = monitor), do: {:ok, monitor.dns_config}

  defp create_params(args) do
    with {:ok, name} <- required_string(args, "name"),
         {:ok, type} <- required_type(args),
         {:ok, config} <- config_map(args, type) do
      monitor = %{"name" => name, "type" => type}
      monitor = put_if_present(monitor, "environment", value(args, "environment"))
      {:ok, %{monitor: monitor, config: config}}
    end
  end

  defp update_params(args, monitor, config) do
    with {:ok, name} <- required_string(args, "name"),
         true <- valid_expected_values?(args) do
      monitor_params = %{"name" => name}

      monitor_params =
        put_if_present(
          monitor_params,
          "environment",
          value(args, "environment") || monitor.environment
        )

      {:ok, monitor_params, merge_config(config_params(config, monitor.type), args, monitor.type)}
    else
      false -> {:error, :invalid_expected_values}
    end
  end

  defp config_map(args, type) do
    case valid_expected_values?(args) do
      true -> {:ok, type_fields(args, type)}
      false -> {:error, :invalid_expected_values}
    end
  end

  defp valid_expected_values?(args) do
    case value(args, "expected_values") do
      nil ->
        true

      values when is_list(values) ->
        length(values) <= 20 and Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 256))

      _ ->
        false
    end
  end

  defp type_fields(args, type) do
    fields = %{}
    fields = put_if_present(fields, "url", value(args, "url"))
    fields = put_if_present(fields, "keyword", value(args, "keyword"))
    fields = put_if_present(fields, "hostname", value(args, "hostname"))
    fields = put_if_present(fields, "port", value(args, "port"))
    fields = put_if_present(fields, "timeout_seconds", value(args, "timeout_seconds"))
    fields = put_if_present(fields, "interval_seconds", value(args, "interval_seconds"))

    fields =
      put_if_present(fields, "retry_interval_seconds", value(args, "retry_interval_seconds"))

    fields = put_if_present(fields, "grace_period_seconds", value(args, "grace_period_seconds"))
    fields = put_if_present(fields, "record_type", value(args, "record_type"))
    fields = put_if_present(fields, "expected_values", expected_values_value(args))
    fields = put_if_present(fields, "match_mode", value(args, "match_mode"))
    Map.take(fields, type_keys(type))
  end

  defp type_keys("http"), do: ~w(url timeout_seconds interval_seconds retry_interval_seconds)

  defp type_keys("keyword"),
    do: ~w(url keyword timeout_seconds interval_seconds retry_interval_seconds)

  defp type_keys("heartbeat"), do: ~w(interval_seconds grace_period_seconds)

  defp type_keys("tcp"),
    do: ~w(hostname port timeout_seconds interval_seconds retry_interval_seconds)

  defp type_keys("dns"),
    do:
      ~w(hostname record_type expected_values match_mode interval_seconds retry_interval_seconds)

  defp merge_config(current, args, type), do: Map.merge(current, type_fields(args, type))

  defp config_params(
         %{url: url, keyword_match: keyword_match, interval_seconds: interval},
         "keyword"
       ),
       do: %{
         "url" => url,
         "keyword" => get_in(keyword_match, ["value"]),
         "interval_seconds" => interval
       }

  defp config_params(%{url: url, interval_seconds: interval}, "http"),
    do: %{"url" => url, "interval_seconds" => interval}

  defp config_params(%{interval_seconds: interval}, "heartbeat"),
    do: %{"interval_seconds" => interval}

  defp config_params(%{hostname: hostname, port: port, interval_seconds: interval}, "tcp"),
    do: %{"hostname" => hostname, "port" => port, "interval_seconds" => interval}

  defp config_params(
         %{
           hostname: hostname,
           record_type: type,
           expected_values: values,
           match_mode: mode,
           interval_seconds: interval
         },
         "dns"
       ),
       do: %{
         "hostname" => hostname,
         "record_type" => type,
         "expected_values" => Enum.join(values, ","),
         "match_mode" => to_string(mode),
         "interval_seconds" => interval
       }

  defp monitor_payload(%Monitor{} = monitor) do
    %{
      handle: monitor.id,
      name: monitor.name,
      type: monitor.type,
      environment: monitor.environment,
      status: monitor.status,
      last_known_status: monitor.last_known_status,
      last_check_at: datetime(monitor.last_check_at),
      failure_threshold: monitor.failure_threshold,
      resend_after_failed_checks: monitor.resend_after_failed_checks,
      config: config_payload(monitor.type, config_for_value(monitor)),
      latest_check: present_payload(monitor.latest_check, &check_payload/1),
      open_incident: present_payload(monitor.open_incident, &incident_payload/1)
    }
  end

  defp create_result(%Monitor{type: "heartbeat"} = monitor, heartbeat_token)
       when is_binary(heartbeat_token),
       do: {:ok, %{monitor: monitor_payload(monitor), heartbeat_secret: heartbeat_token}}

  defp create_result(%Monitor{type: "heartbeat"}, _), do: {:error, :secret_not_issued}
  defp create_result(%Monitor{} = monitor, _), do: {:ok, %{monitor: monitor_payload(monitor)}}

  defp config_for_value(%Monitor{type: type} = monitor) when type in ["http", "keyword"],
    do: monitor.http_config

  defp config_for_value(%Monitor{type: "heartbeat"} = monitor), do: monitor.heartbeat_config
  defp config_for_value(%Monitor{type: "tcp"} = monitor), do: monitor.tcp_config
  defp config_for_value(%Monitor{type: "dns"} = monitor), do: monitor.dns_config

  defp config_payload(_type, %Ash.NotLoaded{}), do: nil
  defp config_payload(_type, nil), do: nil

  defp config_payload("http", config),
    do:
      Map.take(config, [
        :url,
        :method,
        :expected_status,
        :interval_seconds,
        :timeout_seconds,
        :response_time_threshold_ms
      ])
      |> stringify_map()

  defp config_payload("keyword", config),
    do:
      Map.take(config, [:url, :method, :keyword_match, :interval_seconds, :timeout_seconds])
      |> stringify_map()

  defp config_payload("heartbeat", config),
    do:
      Map.take(config, [
        :interval_seconds,
        :cron_expression,
        :timezone,
        :grace_period_seconds,
        :track_duration,
        :expected_duration_seconds
      ])
      |> stringify_map()

  defp config_payload("tcp", config),
    do:
      Map.take(config, [
        :hostname,
        :port,
        :interval_seconds,
        :retry_interval_seconds,
        :timeout_seconds
      ])
      |> stringify_map()

  defp config_payload("dns", config),
    do:
      Map.take(config, [
        :hostname,
        :record_type,
        :expected_values,
        :match_mode,
        :interval_seconds,
        :retry_interval_seconds
      ])
      |> stringify_map()

  defp check_payload(check),
    do: %{
      handle: check.id,
      status: check.status,
      status_code: check.status_code,
      latency_ms: check.latency_ms,
      error_class: check.error_class,
      checked_at: datetime(check.checked_at)
    }

  defp present_payload(%Ash.NotLoaded{}, _mapper), do: nil
  defp present_payload(nil, _mapper), do: nil
  defp present_payload(value, mapper), do: mapper.(value)

  defp incident_payload(incident),
    do: %{
      handle: incident.id,
      status: to_string(incident.status),
      cause: incident.cause,
      started_at: datetime(incident.started_at),
      resolved_at: datetime(incident.resolved_at),
      duration_seconds: incident.duration_seconds,
      checks_failed_count: incident.checks_failed_count,
      acknowledged_at: datetime(incident.acknowledged_at)
    }

  defp stringify_map(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), normalize_value(value)} end)

  defp normalize_value(nil), do: nil
  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value
  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime(%NaiveDateTime{} = value),
    do: DateTime.from_naive!(value, "Etc/UTC") |> DateTime.to_iso8601()

  defp required_type(args) do
    case value(args, "type") do
      type when type in ["http", "keyword", "heartbeat", "tcp", "dns"] -> {:ok, type}
      _ -> {:error, :invalid_monitor_type}
    end
  end

  defp heartbeat_state("start"), do: {:ok, :start}
  defp heartbeat_state("finish"), do: {:ok, :finish}
  defp heartbeat_state("fail"), do: {:ok, :fail}
  defp heartbeat_state(_), do: {:error, :invalid_heartbeat_state}

  defp expected_values_value(args) do
    case value(args, "expected_values") do
      values when is_list(values) -> Enum.join(values, ",")
      values -> values
    end
  end

  defp decode_cursor(principal, args, tool, filters) do
    case value(args, "cursor") do
      nil ->
        {:ok, nil}

      cursor when is_binary(cursor) ->
        case Cursor.decode(principal, tool, filters, cursor) do
          {:ok, cursor} when is_tuple(cursor) and tuple_size(cursor) == 2 -> {:ok, cursor}
          {:ok, _cursor} -> {:error, :invalid_cursor}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp normalize_limit(args),
    do: Args.bounded_integer(args, "limit", @page_min, @page_max, @page_default, :invalid_limit)

  defp list_filters(args) do
    with {:ok, status} <- enum_filter(args, "status", ["active", "paused"]),
         {:ok, type} <-
           enum_filter(args, "type", ["http", "keyword", "heartbeat", "tcp", "dns"]),
         {:ok, environment} <- optional_filter(args, "environment") do
      {:ok,
       %{
         project_handle: value(args, "project_handle"),
         status: status,
         type: type,
         environment: environment
       }}
    end
  end

  defp enum_filter(args, key, allowed) do
    case value(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, {:invalid_filter, key}}

      _ ->
        {:error, {:invalid_filter, key}}
    end
  end

  defp optional_filter(args, key) do
    case value(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_filter, key}}
    end
  end

  defp required_string(args, key) do
    with {:error, {:missing_argument, _key}} <- Args.required_string(args, key) do
      {:error, :invalid_argument}
    end
  end

  defp required_boolean(args, key) do
    case value(args, key) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_argument}
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp map_error({:error, reason}), do: map_error(reason)

  defp map_error(%Ash.Error.Invalid{} = error) do
    message = error |> Exception.message() |> String.downcase()

    if String.contains?(message, "plan") and String.contains?(message, "inactive") do
      Error.new(:plan_inactive, "The organization plan is inactive", %{})
    else
      Error.new(:invalid_argument, "The request is invalid", %{})
    end
  rescue
    _ -> Error.from(:invalid_argument)
  end

  defp map_error(:invalid_limit),
    do:
      Error.new(:invalid_argument, "limit must be an integer between 1 and 100", %{
        field: "limit",
        minimum: 1,
        maximum: 100
      })

  defp map_error(:invalid_heartbeat_state),
    do: Error.new(:invalid_argument, "state must be start, finish, or fail", %{field: "state"})

  defp map_error({:invalid_filter, field}),
    do: Error.new(:invalid_argument, "The filter is invalid", %{field: field})

  defp map_error(:invalid_monitor_type),
    do: Error.new(:invalid_argument, "The monitor type is not supported", %{field: "type"})

  defp map_error(:invalid_expected_values),
    do:
      Error.new(
        :invalid_argument,
        "expected_values must contain at most 20 strings of 256 bytes",
        %{field: "expected_values"}
      )

  defp map_error(:monitor_paused),
    do: Error.new(:conflict, "The heartbeat monitor is paused", %{})

  defp map_error(:heartbeat_not_accepted),
    do: Error.new(:conflict, "The heartbeat was not accepted", %{})

  defp map_error(reason), do: Error.from(reason)

  defp map_error(%Ash.Error.Forbidden{}, tool)
       when tool in [
              "monitor.list",
              "monitor.get",
              "monitor.list_checks",
              "monitor.list_incidents"
            ],
       do: Error.from(:not_found)

  defp map_error(reason, _tool), do: map_error(reason)

  defp read_tool(name, title, description, properties, output),
    do: read_tool(name, title, description, properties, output, [])

  defp read_tool(name, title, description, properties, output, required),
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
        %{idempotentHint: true}
      )

  defp destructive_tool(name, title, description, properties, required, output) do
    tool = mutation_tool(name, title, description, properties, required, output)
    %{tool | annotations: Map.put(tool.annotations, :destructiveHint, true)}
  end

  defp create_tool do
    tool =
      mutation_tool(
        "monitor.create",
        "Create a monitor",
        "Create a typed monitor in the selected project. Supply the fields for the selected type. Heartbeat creation returns a setup secret exactly once; it cannot be read later. Retry with the same idempotency key.",
        create_properties(),
        create_required(),
        %{monitor: monitor_schema()}
      )

    one_of = [
      create_branch("http", ~w(url timeout_seconds retry_interval_seconds), [
        "url",
        "timeout_seconds"
      ]),
      create_branch("keyword", ~w(url keyword timeout_seconds retry_interval_seconds), [
        "url",
        "keyword",
        "timeout_seconds"
      ]),
      create_branch("heartbeat", ~w(grace_period_seconds), ["grace_period_seconds"]),
      create_branch("tcp", ~w(hostname port timeout_seconds retry_interval_seconds), [
        "hostname",
        "port",
        "timeout_seconds"
      ]),
      create_branch(
        "dns",
        ~w(hostname record_type expected_values match_mode retry_interval_seconds),
        ["hostname", "record_type"]
      )
    ]

    heartbeat_result =
      object_schema(%{
        monitor: monitor_schema(),
        heartbeat_secret: %{type: "string", minLength: 1}
      })

    output_schema = %{
      type: "object",
      additionalProperties: false,
      properties: %{
        monitor: monitor_schema(),
        heartbeat_secret: %{type: "string", minLength: 1}
      },
      oneOf: [tool.output_schema, heartbeat_result]
    }

    %{
      tool
      | input_schema: Map.put(tool.input_schema, :oneOf, one_of),
        output_schema: output_schema
    }
  end

  defp create_branch(type, type_keys, required) do
    properties = create_properties()

    common_properties = %{
      project_handle: %{type: "string"},
      idempotency_key: %{type: "string", minLength: 1},
      name: properties.name,
      type: %{const: type},
      environment: properties.environment,
      interval_seconds: properties.interval_seconds
    }

    branch_properties =
      type_keys
      |> Enum.map(&String.to_existing_atom/1)
      |> then(&Map.take(properties, &1))

    %{
      type: "object",
      additionalProperties: false,
      properties: Map.merge(common_properties, branch_properties),
      required: [
        "project_handle",
        "idempotency_key",
        "name",
        "type",
        "interval_seconds" | required
      ]
    }
  end

  defp schema(properties, required, mutation?),
    do:
      ToolSpec.strict_object(
        properties
        |> Map.put(:project_handle, %{type: "string"})
        |> maybe_idempotency_property(mutation?),
        ["project_handle" | if(mutation?, do: ["idempotency_key" | required], else: required)]
      )

  defp maybe_idempotency_property(properties, true),
    do: Map.put(properties, :idempotency_key, %{type: "string", minLength: 1})

  defp maybe_idempotency_property(properties, false), do: properties

  defp monitor_schema do
    object_schema(%{
      handle: %{type: "string"},
      name: %{type: "string"},
      type: %{type: "string"},
      environment: %{type: ["string", "null"]},
      status: %{type: "string"},
      last_known_status: %{type: ["string", "null"]},
      last_check_at: %{type: ["string", "null"]},
      failure_threshold: %{type: "integer"},
      resend_after_failed_checks: %{type: "integer"},
      config: config_schema(),
      latest_check: %{
        type: ["object", "null"],
        additionalProperties: false,
        properties: check_schema()[:properties]
      },
      open_incident: %{
        type: ["object", "null"],
        additionalProperties: false,
        properties: incident_schema()[:properties]
      }
    })
  end

  defp config_schema do
    %{
      type: ["object", "null"],
      additionalProperties: false,
      properties: %{
        url: %{type: "string"},
        method: %{type: "string"},
        expected_status: expected_status_schema(),
        keyword_match: keyword_match_schema(),
        interval_seconds: %{type: "integer"},
        timeout_seconds: %{type: "integer"},
        response_time_threshold_ms: %{type: ["integer", "null"]},
        grace_period_seconds: %{type: "integer"},
        cron_expression: %{type: ["string", "null"]},
        timezone: %{type: "string"},
        track_duration: %{type: "boolean"},
        expected_duration_seconds: %{type: ["integer", "null"]},
        hostname: %{type: "string"},
        port: %{type: "integer"},
        retry_interval_seconds: %{type: ["integer", "null"]},
        record_type: %{type: "string"},
        expected_values: %{type: "array", items: %{type: "string", maxLength: 256}},
        match_mode: %{type: "string"}
      }
    }
  end

  defp expected_status_schema do
    %{
      anyOf: [
        %{
          type: "object",
          additionalProperties: false,
          properties: %{
            kind: %{const: "list"},
            values: %{type: "array", items: %{type: "integer"}}
          },
          required: ["kind", "values"]
        },
        %{
          type: "object",
          additionalProperties: false,
          properties: %{
            kind: %{const: "range"},
            min: %{type: "integer"},
            max: %{type: "integer"}
          },
          required: ["kind", "min", "max"]
        }
      ]
    }
  end

  defp keyword_match_schema do
    %{
      type: ["object", "null"],
      additionalProperties: false,
      properties: %{
        mode: %{type: "string", enum: ["contains", "not_contains"]},
        value: %{type: "string"},
        scanBytes: %{type: "integer"},
        scan_bytes: %{type: "integer"}
      },
      required: ["mode", "value"]
    }
  end

  defp check_schema,
    do:
      object_schema(%{
        handle: %{type: "string"},
        status: %{type: "string"},
        status_code: %{type: ["integer", "null"]},
        latency_ms: %{type: ["integer", "null"]},
        error_class: %{type: ["string", "null"]},
        checked_at: %{type: ["string", "null"]}
      })

  defp incident_schema,
    do:
      object_schema(%{
        handle: %{type: "string"},
        status: %{type: "string"},
        cause: %{type: ["string", "null"]},
        started_at: %{type: ["string", "null"]},
        resolved_at: %{type: ["string", "null"]},
        duration_seconds: %{type: ["integer", "null"]},
        checks_failed_count: %{type: "integer"},
        acknowledged_at: %{type: ["string", "null"]}
      })

  defp create_properties do
    %{
      name: %{type: "string"},
      type: %{type: "string", enum: ["http", "keyword", "heartbeat", "tcp", "dns"]},
      environment: %{type: "string"},
      url: %{type: "string"},
      keyword: %{type: "string"},
      hostname: %{type: "string"},
      port: %{type: "integer"},
      timeout_seconds: %{type: "integer", minimum: 1},
      interval_seconds: %{type: "integer", minimum: 30, maximum: 31_536_000},
      retry_interval_seconds: %{type: "integer"},
      grace_period_seconds: %{type: "integer"},
      record_type: %{type: "string", enum: ["A", "AAAA", "CNAME", "MX", "TXT", "NS"]},
      expected_values: %{
        type: "array",
        minItems: 1,
        maxItems: 20,
        items: %{type: "string", maxLength: 256}
      },
      match_mode: %{type: "string", enum: ["all", "any"]}
    }
  end

  defp create_required, do: ["name", "type", "interval_seconds"]

  defp update_properties do
    create_properties() |> Map.put(:monitor_handle, %{type: "string"})
  end
end
