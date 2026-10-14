defmodule Alplus.Monitoring.MonitorFormAttrs do
  @moduledoc """
  Builds `Monitor` + typed-config create attrs from raw form params.

  Shared by every monitor creation UI (the empty-project quick form and the
  `/monitor/new` wizard) so `Alplus.Monitoring.MonitorCreator.create/3` always
  sees the same attribute shapes, regardless of which form produced them.
  """

  @type scope :: Alplus.Scope.t()

  # Mirrors the DB `CHECK` constraints on the typed config tables
  # (`http_config.ex`, `tcp_config.ex`, `dns_config.ex`,
  # `heartbeat_config.ex` custom_statements). Validated here so a
  # too-large/out-of-range value is rejected before any write, never
  # discovered mid-transaction as a Postgrex error after the Monitor row
  # has already committed.
  @url_max_bytes 2048
  @hostname_max_bytes 2048
  @keyword_value_max_bytes 900
  @http_timeout_min_seconds 1
  @http_timeout_max_seconds 60
  @tcp_timeout_min_seconds 1
  @tcp_timeout_max_seconds 30
  @heartbeat_grace_min_seconds 0
  @heartbeat_grace_max_seconds 86_400
  @name_max_bytes 200
  @environment_max_bytes 64
  @interval_min_seconds 30
  @interval_max_seconds 31_536_000
  @port_min 1
  @port_max 65_535
  @dns_record_types ~w(A AAAA CNAME MX TXT NS)
  @dns_expected_values_max_count 20
  @dns_expected_values_max_bytes 12_288
  @slo_target_min 0.0
  @slo_target_max 1.0

  @spec monitor_create_attrs(map(), map(), scope()) :: {:ok, map(), map()} | {:error, atom()}
  def monitor_create_attrs(%{"name" => name, "type" => type} = params, config, scope)
      when type in ["http", "keyword", "heartbeat", "tcp", "dns"] and
             is_map(config) and is_map(scope) do
    with {:ok, name} <- validate_name(name),
         {:ok, environment} <- validate_environment(Map.get(params, "environment")),
         {:ok, slo_target} <- parse_slo_target(Map.get(params, "slo_target")),
         {:ok, schedule} <- validate_schedule(type, config),
         {:ok, config_attrs} <- typed_config_attrs(type, config, schedule),
         {:ok, org_id, project_id} <- scope_ids(scope) do
      monitor_attrs =
        %{org_id: org_id, project_id: project_id, name: name, type: type}
        |> put_environment(environment)
        |> maybe_put_slo_target(params, slo_target)

      {:ok, monitor_attrs, config_attrs}
    end
  end

  def monitor_create_attrs(_, _, _), do: {:error, :invalid_monitor}

  @doc """
  Builds `Monitor` update attrs plus the type-specific config update attrs
  from edit-form params. `type` is the monitor's existing, immutable type
  (never taken from the form): the edit page never lets a caller change it.
  """
  @spec monitor_update_attrs(map(), map(), String.t()) :: {:ok, map(), map()} | {:error, atom()}
  def monitor_update_attrs(%{"name" => name} = monitor_params, config_params, type)
      when is_binary(name) and is_map(config_params) and is_binary(type) do
    with {:ok, name} <- validate_name(name),
         {:ok, environment} <- validate_environment(Map.get(monitor_params, "environment")),
         {:ok, slo_target} <- parse_slo_target(Map.get(monitor_params, "slo_target")),
         {:ok, schedule} <- validate_schedule(type, config_params),
         {:ok, config_attrs} <- config_update_attrs(type, config_params, schedule) do
      monitor_attrs =
        %{name: name, environment: environment}
        |> maybe_put_slo_target(monitor_params, slo_target)

      {:ok, monitor_attrs, config_attrs}
    end
  end

  def monitor_update_attrs(_, _, _), do: {:error, :invalid_monitor}

  defp config_update_attrs("http", config, interval) when is_map(config) do
    url = Map.get(config, "url")

    with {:ok, url} <- validate_url(url) do
      {:ok, %{url: url, interval_seconds: interval}}
    end
  end

  defp config_update_attrs("http", _, _), do: {:error, :invalid_config}

  defp config_update_attrs("keyword", config, interval) when is_map(config) do
    url = Map.get(config, "url")
    keyword = Map.get(config, "keyword")

    with {:ok, url} <- validate_url(url),
         {:ok, keyword} <- validate_keyword(keyword) do
      {:ok,
       %{
         url: url,
         keyword_match: %{"mode" => "contains", "value" => keyword},
         interval_seconds: interval
       }}
    end
  end

  defp config_update_attrs("keyword", _, _), do: {:error, :invalid_config}

  defp config_update_attrs("heartbeat", _config, %{
         interval_seconds: interval,
         cron_expression: nil
       }),
       do: {:ok, %{interval_seconds: interval, cron_expression: nil}}

  defp config_update_attrs("heartbeat", _config, %{cron_expression: cron_expression}),
    do: {:ok, %{interval_seconds: nil, cron_expression: cron_expression}}

  defp config_update_attrs("tcp", %{"hostname" => hostname, "port" => port}, interval) do
    with {:ok, hostname} <- validate_hostname(hostname),
         {:ok, port} <- validate_port(port) do
      {:ok, %{hostname: hostname, port: port, interval_seconds: interval}}
    end
  end

  defp config_update_attrs("tcp", _, _), do: {:error, :invalid_config}

  defp config_update_attrs("dns", config, interval) when is_map(config) do
    hostname = Map.get(config, "hostname")
    record_type = Map.get(config, "record_type")

    with {:ok, hostname} <- validate_hostname(hostname),
         {:ok, record_type} <- validate_record_type(record_type),
         {:ok, expected_values} <- validate_expected_values(parse_expected_values(config)),
         {:ok, match_mode} <- validate_match_mode(config["match_mode"]) do
      {:ok,
       %{
         hostname: hostname,
         record_type: record_type,
         expected_values: expected_values,
         match_mode: match_mode,
         interval_seconds: interval
       }}
    end
  end

  defp config_update_attrs("dns", _, _), do: {:error, :invalid_config}

  defp config_update_attrs(_, _, _), do: {:error, :invalid_config}

  defp put_environment(monitor_attrs, nil), do: monitor_attrs

  defp put_environment(monitor_attrs, environment),
    do: Map.put(monitor_attrs, :environment, environment)

  defp maybe_put_slo_target(monitor_attrs, params, slo_target) do
    if Map.has_key?(params, "slo_target") or Map.has_key?(params, :slo_target) do
      Map.put(monitor_attrs, :slo_target, slo_target)
    else
      monitor_attrs
    end
  end

  @doc "Parses an optional SLO target as a ratio between zero and one."
  @spec parse_slo_target(term()) :: {:ok, float() | nil} | {:error, :invalid_slo_target}
  def parse_slo_target(value) when value in [nil, ""], do: {:ok, nil}

  def parse_slo_target(value) when is_binary(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {target, ""} ->
        validate_slo_target(target)

      _ ->
        if String.ends_with?(value, "%") do
          case Float.parse(String.trim_trailing(value, "%")) do
            {percentage, ""} -> validate_slo_target(percentage / 100)
            _ -> {:error, :invalid_slo_target}
          end
        else
          {:error, :invalid_slo_target}
        end
    end
  end

  def parse_slo_target(value) when is_integer(value), do: validate_slo_target(value / 1)
  def parse_slo_target(value) when is_float(value), do: validate_slo_target(value)
  def parse_slo_target(_value), do: {:error, :invalid_slo_target}

  defp validate_slo_target(target)
       when is_number(target) and target > @slo_target_min and target <= @slo_target_max,
       do: {:ok, Float.round(target * 1.0, 6)}

  defp validate_slo_target(_target), do: {:error, :invalid_slo_target}

  defp typed_config_attrs("http", config, interval) when is_map(config) do
    url = Map.get(config, "url")

    with {:ok, url} <- validate_url(url),
         {:ok, timeout} <-
           bounded_integer_or_default(
             Map.get(config, "timeout_seconds"),
             10,
             @http_timeout_min_seconds,
             @http_timeout_max_seconds
           ) do
      {:ok,
       %{
         url: url,
         method: "GET",
         expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
         interval_seconds: interval,
         timeout_seconds: timeout
       }}
    end
  end

  defp typed_config_attrs("http", _, _), do: {:error, :invalid_config}

  defp typed_config_attrs("keyword", config, interval) when is_map(config) do
    url = Map.get(config, "url")
    keyword = Map.get(config, "keyword")

    with {:ok, url} <- validate_url(url),
         {:ok, keyword} <- validate_keyword(keyword),
         {:ok, timeout} <-
           bounded_integer_or_default(
             Map.get(config, "timeout_seconds"),
             10,
             @http_timeout_min_seconds,
             @http_timeout_max_seconds
           ) do
      {:ok,
       %{
         url: url,
         method: "GET",
         expected_status: %{"kind" => "range", "min" => 200, "max" => 399},
         keyword_match: %{"mode" => "contains", "value" => keyword},
         interval_seconds: interval,
         timeout_seconds: timeout
       }}
    end
  end

  defp typed_config_attrs("keyword", _, _), do: {:error, :invalid_config}

  defp typed_config_attrs("heartbeat", config, schedule) when is_map(config) do
    with {:ok, grace} <-
           bounded_integer_or_default(
             Map.get(config, "grace_period_seconds"),
             60,
             @heartbeat_grace_min_seconds,
             @heartbeat_grace_max_seconds
           ) do
      {:ok,
       Map.merge(schedule, %{
         grace_period_seconds: grace,
         timezone: "UTC"
       })}
    end
  end

  defp typed_config_attrs("tcp", config, interval) when is_map(config) do
    hostname = Map.get(config, "hostname")
    port = Map.get(config, "port")

    with {:ok, hostname} <- validate_hostname(hostname),
         {:ok, port} <- validate_port(port),
         {:ok, timeout} <-
           bounded_integer_or_default(
             Map.get(config, "timeout_seconds"),
             10,
             @tcp_timeout_min_seconds,
             @tcp_timeout_max_seconds
           ) do
      {:ok,
       %{
         hostname: hostname,
         port: port,
         timeout_seconds: timeout,
         interval_seconds: interval
       }}
    end
  end

  defp typed_config_attrs("tcp", _, _), do: {:error, :invalid_config}

  defp typed_config_attrs("dns", config, interval) when is_map(config) do
    hostname = Map.get(config, "hostname")
    record_type = Map.get(config, "record_type")

    with {:ok, hostname} <- validate_hostname(hostname),
         {:ok, record_type} <- validate_record_type(record_type),
         {:ok, expected_values} <- validate_expected_values(parse_expected_values(config)),
         {:ok, match_mode} <- validate_match_mode(config["match_mode"]) do
      {:ok,
       %{
         hostname: hostname,
         record_type: record_type,
         expected_values: expected_values,
         match_mode: match_mode,
         interval_seconds: interval
       }}
    end
  end

  defp typed_config_attrs(_, _, _), do: {:error, :invalid_config}

  defp parse_expected_values(config) do
    case Map.get(config, "expected_values", "") do
      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        :invalid
    end
  end

  # Mirrors `monitor_http_configs_url_check` / `monitor_tcp_configs_hostname_check`
  # / `monitor_dns_configs_hostname_check` (`octet_length BETWEEN 1 AND 2048`).
  defp validate_url(url) do
    with {:ok, url} <- validate_text(url, @url_max_bytes),
         true <- valid_http_url?(url) do
      {:ok, url}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp validate_hostname(hostname), do: validate_text(hostname, @hostname_max_bytes)
  defp validate_keyword(keyword), do: validate_text(keyword, @keyword_value_max_bytes)

  defp validate_text(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in 1..max_bytes, do: {:ok, value}, else: {:error, :invalid_config}
  end

  defp validate_text(_value, _max_bytes), do: {:error, :invalid_config}

  defp valid_http_url?(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo)
  rescue
    URI.Error -> false
  end

  defp validate_name(name), do: validate_text(name, @name_max_bytes)

  defp validate_environment(nil), do: {:ok, nil}
  defp validate_environment(""), do: {:ok, nil}

  defp validate_environment(environment) when is_binary(environment) do
    environment = String.trim(environment)

    cond do
      environment == "" -> {:ok, nil}
      byte_size(environment) <= @environment_max_bytes -> {:ok, environment}
      true -> {:error, :invalid_monitor}
    end
  end

  defp validate_environment(_environment), do: {:error, :invalid_monitor}

  defp scope_ids(scope) do
    case {Map.get(scope, :org_id), Map.get(scope, :project_id)} do
      {org_id, project_id} when is_binary(org_id) and is_binary(project_id) ->
        {:ok, org_id, project_id}

      _ ->
        {:error, :invalid_monitor}
    end
  end

  defp validate_schedule("heartbeat", config) do
    cron_expression =
      case Map.get(config, "cron_expression") do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    interval = Map.get(config, "interval_seconds")

    cond do
      cron_expression != "" and not is_nil(interval) ->
        {:error, :invalid_schedule}

      cron_expression != "" ->
        validate_cron_schedule(cron_expression)

      true ->
        with {:ok, interval} <- validate_interval(interval) do
          {:ok, %{interval_seconds: interval, cron_expression: nil}}
        end
    end
  end

  defp validate_schedule(_type, config),
    do: validate_interval(Map.get(config, "interval_seconds"))

  defp validate_cron_schedule(expression) when byte_size(expression) <= 100 do
    fields = String.split(expression, ~r/\s+/, trim: true)

    if length(fields) == 5 and Enum.all?(fields, &Regex.match?(~r/^[0-9*?,\/-]+$/, &1)) do
      {:ok, %{interval_seconds: nil, cron_expression: expression}}
    else
      {:error, :invalid_schedule}
    end
  end

  defp validate_cron_schedule(_expression), do: {:error, :invalid_schedule}

  defp bounded_integer_or_default(nil, default, _min, _max), do: {:ok, default}

  defp bounded_integer_or_default(value, _default, min, max) do
    with {:ok, value} <- nonnegative_integer(value) do
      if value in min..max, do: {:ok, value}, else: {:error, :invalid_config}
    end
  end

  # Mirrors `monitor_*_configs_port_check` (`BETWEEN 1 AND 65535`).
  defp validate_port(port) do
    with {:ok, port} <- positive_integer(port) do
      if port in @port_min..@port_max, do: {:ok, port}, else: {:error, :invalid_config}
    end
  end

  # Mirrors every typed config's `_interval_check`
  # (`BETWEEN 30 AND 31536000`). The interval dropdown already only offers
  # values in range, but a tampered request bypasses the dropdown, not this.
  defp validate_interval(interval) do
    with {:ok, interval} <- positive_integer(interval) do
      if interval in @interval_min_seconds..@interval_max_seconds,
        do: {:ok, interval},
        else: {:error, :invalid_config}
    end
  end

  # Mirrors `monitor_dns_configs_record_type_check`.
  defp validate_record_type(record_type) when is_binary(record_type) do
    upcased = String.upcase(record_type)
    if upcased in @dns_record_types, do: {:ok, upcased}, else: {:error, :invalid_config}
  end

  defp validate_record_type(_record_type), do: {:error, :invalid_config}

  # Mirrors `monitor_dns_configs_expected_values_check`
  # (`cardinality BETWEEN 0 AND 20`, joined length `<= 12288`). An empty
  # list is valid: it means "just needs to resolve" (see `DnsExecutor.run/2`).
  defp validate_expected_values(values) do
    if values == :invalid do
      {:error, :invalid_dns_values}
    else
      within_count? = length(values) <= @dns_expected_values_max_count
      within_bytes? = values |> Enum.join(",") |> byte_size() <= @dns_expected_values_max_bytes

      if within_count? and within_bytes? do
        {:ok, values}
      else
        {:error, :invalid_dns_values}
      end
    end
  end

  # No `String.to_atom/1` on user input: map only the two known strings.
  defp validate_match_mode("all"), do: {:ok, :all}
  defp validate_match_mode("any"), do: {:ok, :any}
  defp validate_match_mode(nil), do: {:ok, :all}
  defp validate_match_mode(_other), do: {:error, :invalid_dns_values}

  @spec positive_integer(term()) :: {:ok, pos_integer()} | {:error, :invalid_integer}
  def positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_integer}
    end
  end

  def positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  def positive_integer(_), do: {:error, :invalid_integer}

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, :invalid_integer}
    end
  end

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp nonnegative_integer(_value), do: {:error, :invalid_integer}
end
