defmodule Alplus.Monitoring.ExpiryScan do
  @moduledoc """
  Daily SSL and domain-expiry warning calculation.

  It creates deterministic warning events, rather than dispatching effects.
  A notification router can persist the event's `idempotency_key` in its
  delivery ledger, which makes the daily maintenance job safe to retry.
  """

  alias Alplus.Monitoring.ExpiryScanner.Native

  @default_thresholds [14, 7, 1]
  @task_timeout 30_000

  @type warning_kind :: :ssl_expiring | :domain_expiring
  @type warning :: %{
          kind: warning_kind(),
          monitor_id: String.t(),
          org_id: String.t(),
          project_id: String.t(),
          expires_at: DateTime.t(),
          days_remaining: integer(),
          threshold_days: pos_integer(),
          idempotency_key: String.t()
        }

  @doc "Scans one HTTP config and returns deterministic alert-routing events."
  @spec scan(map(), keyword()) :: {:ok, [warning()]} | {:error, term()}
  def scan(config, opts \\ []) when is_map(config) do
    scanner = Keyword.get(opts, :scanner, Native)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    timeout = Keyword.get(opts, :timeout, 5_000)

    with :ok <- valid_config(config),
         {:ok, expiry} <- scanner.scan(Map.fetch!(config, :url), timeout: timeout) do
      warnings =
        [
          warnings_for(
            config,
            :ssl_expiring,
            Map.get(expiry, :ssl_expires_at),
            :ssl_expiry_warn_days,
            now
          ),
          warnings_for(
            config,
            :domain_expiring,
            Map.get(expiry, :domain_expires_at),
            :domain_expiry_warn_days,
            now
          )
        ]
        |> List.flatten()

      {:ok, warnings}
    end
  end

  @doc "Lists active HTTP configs. This is the maintenance read escape hatch."
  @spec active_http_configs() :: [map()]
  def active_http_configs do
    # Direct SQL is justified for this maintenance scan: it streams only active
    # candidates and avoids loading tenant data through an interactive action.
    Alplus.Repo.query!("""
    SELECT m.id, m.org_id, m.project_id, c.url, c.ssl_expiry_warn_days, c.domain_expiry_warn_days
    FROM monitors AS m
    INNER JOIN monitor_http_configs AS c ON c.monitor_id = m.id
    WHERE m.status = 'active' AND m.type IN ('http', 'keyword')
    """).rows
    |> Enum.map(fn [monitor_id, org_id, project_id, url, ssl_thresholds, domain_thresholds] ->
      %{
        monitor_id: monitor_id,
        org_id: org_id,
        project_id: project_id,
        url: url,
        ssl_expiry_warn_days: ssl_thresholds,
        domain_expiry_warn_days: domain_thresholds
      }
    end)
  end

  @doc "Scans active HTTP configurations and returns routing-ready outcomes."
  @spec scan_active(keyword()) :: %{warnings: [warning()], failures: [{String.t(), term()}]}
  def scan_active(opts \\ []) do
    task_timeout = Keyword.get(opts, :task_timeout, @task_timeout)

    active_http_configs()
    |> Task.async_stream(
      fn config -> {config.monitor_id, scan(config, opts)} end,
      ordered: false,
      timeout: task_timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reduce(%{warnings: [], failures: []}, fn
      {:ok, {_monitor_id, {:ok, warnings}}}, result ->
        %{result | warnings: warnings ++ result.warnings}

      {:ok, {monitor_id, {:error, reason}}}, result ->
        %{result | failures: [{monitor_id, reason} | result.failures]}

      {:exit, {%{monitor_id: monitor_id}, reason}}, result ->
        %{result | failures: [{monitor_id, reason} | result.failures]}

      {:exit, reason}, result ->
        %{result | failures: [{"unknown", reason} | result.failures]}
    end)
  end

  defp valid_config(%{monitor_id: id, org_id: org_id, project_id: project_id, url: url})
       when is_binary(id) and is_binary(org_id) and is_binary(project_id) and is_binary(url),
       do: :ok

  defp valid_config(_), do: {:error, :invalid_monitor_config}

  defp warnings_for(_config, _kind, nil, _field, _now), do: []

  defp warnings_for(config, kind, %DateTime{} = expires_at, field, now) do
    days_remaining = Date.diff(DateTime.to_date(expires_at), DateTime.to_date(now))

    config
    |> Map.get(field)
    |> thresholds()
    |> Enum.filter(&(days_remaining <= &1))
    |> Enum.map(fn threshold_days ->
      %{
        kind: kind,
        monitor_id: config.monitor_id,
        org_id: config.org_id,
        project_id: config.project_id,
        expires_at: expires_at,
        days_remaining: days_remaining,
        threshold_days: threshold_days,
        idempotency_key: idempotency_key(kind, config.monitor_id, expires_at, threshold_days)
      }
    end)
  end

  defp thresholds(nil), do: @default_thresholds

  defp thresholds(values) when is_list(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  defp thresholds(_), do: @default_thresholds

  defp idempotency_key(kind, monitor_id, expires_at, threshold_days) do
    material =
      Enum.join(
        [Atom.to_string(kind), monitor_id, DateTime.to_iso8601(expires_at), threshold_days],
        ":"
      )

    "expiry:" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end
end
