defmodule Alplus.Monitoring.MonitorWorker do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(monitor_id),
    do: GenServer.start_link(__MODULE__, monitor_id, name: via(monitor_id))

  # A check may legitimately take the monitor's full `timeout_seconds` (up to
  # 60s) plus the outcome write. The default 5s call timeout made the caller
  # exit while the worker was still mid-check, so the reply went nowhere. Ask
  # the worker for its own bound with the maximum wait first, then wait for
  # that bound plus a margin.
  @maximum_check_timeout_ms 60_000
  @reply_margin_ms 5_000
  def run_now(monitor_id) do
    check_timeout =
      GenServer.call(
        via(monitor_id),
        :check_timeout_ms,
        @maximum_check_timeout_ms + @reply_margin_ms
      )

    GenServer.call(via(monitor_id), :run_now, check_timeout + @reply_margin_ms)
  end

  defp via(id), do: {:via, Registry, {Alplus.Monitoring.Registry, id}}

  @impl true
  def init(monitor_id) do
    case load_config(monitor_id) do
      {:ok, {type, config}} ->
        {:ok, schedule_initial(%{monitor_id: monitor_id, config: {type, config}})}

      {:error, :inactive} ->
        :ignore

      # The row is not visible yet. A create reconciles the scheduler from an
      # `after_transaction` hook, which still runs inside an enclosing
      # transaction, so this process reads a connection that cannot see the new
      # monitor. The reconcile tick starts it within one interval, so this is a
      # wait, not a failure, and logging it as one buried the real failures.
      {:error, :not_visible_yet} ->
        :ignore

      {:error, reason} ->
        {:stop, {:monitor_config_unavailable, reason}}
    end
  end

  @impl true
  def handle_info(:check, state) do
    :telemetry.execute(
      [:alplus, :monitoring, :check, :fired],
      %{fired_at: System.monotonic_time(:millisecond)},
      %{monitor_id: state.monitor_id}
    )

    case run(state) do
      {:ok, state} -> {:noreply, state}
      :stop -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call(:check_timeout_ms, _from, %{config: {_type, config}} = state),
    do: {:reply, timeout_ms(config), state}

  def handle_call(:run_now, _from, state) do
    case run(state) do
      {:ok, state} -> {:reply, :ok, state}
      :stop -> {:stop, :normal, :ok, state}
    end
  end

  defp run(state) do
    case load_config(state.monitor_id) do
      {:ok, {type, config}} ->
        run_check_and_persist(state, type, config)

      {:error, :inactive} ->
        :stop

      {:error, reason} ->
        Logger.error("monitor config load failed: #{inspect(reason)}")
        {:ok, schedule(state, retry_seconds(state.config))}
    end
  end

  defp run_check_and_persist(state, type, config) do
    state = %{state | config: {type, config}}

    task =
      Task.Supervisor.async_nolink(Alplus.Monitoring.CheckTaskSupervisor, fn ->
        run_check(type, config)
      end)

    timeout = timeout_ms(config)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> %{status: "down", status_code: nil, latency_ms: timeout, error_class: "timeout"}
      end

    case Alplus.Monitoring.ActiveCheckOutcome.record(state.monitor_id, result) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> Logger.error("monitor outcome write failed: #{inspect(reason)}")
    end

    {:ok,
     schedule(
       state,
       if(result.status == "down",
         do: config.retry_interval_seconds || config.interval_seconds,
         else: config.interval_seconds
       )
     )}
  end

  defp retry_seconds({_type, config}),
    do: config.retry_interval_seconds || config.interval_seconds

  # The first check runs within a few seconds of the worker starting, not a
  # full interval later. A newly created monitor then shows a real result
  # during onboarding instead of sitting on "waiting" for up to five minutes.
  # The 1-10s random spread keeps a mass rehydrate on boot (every active
  # monitor starts at once) from firing every worker in the same instant.
  @initial_check_window_ms 10_000
  defp schedule_initial(state) do
    delay_ms = :rand.uniform(@initial_check_window_ms)
    Process.send_after(self(), :check, delay_ms)

    :telemetry.execute(
      [:alplus, :monitoring, :check, :scheduled],
      %{scheduled_at: System.monotonic_time(:millisecond), delay_ms: delay_ms},
      %{monitor_id: state.monitor_id}
    )

    state
  end

  defp schedule(state, seconds) do
    delay_ms = trunc(seconds * 1_000 * (0.95 + :rand.uniform() * 0.1))
    Process.send_after(self(), :check, delay_ms)

    :telemetry.execute(
      [:alplus, :monitoring, :check, :scheduled],
      %{scheduled_at: System.monotonic_time(:millisecond), delay_ms: delay_ms},
      %{monitor_id: state.monitor_id}
    )

    state
  end

  defp load_config(id) do
    with {:ok, monitor} <- Ash.get(Alplus.Monitoring.Monitor, id, authorize?: false),
         {:ok, monitor} <-
           Ash.load(monitor, [:http_config, :tcp_config, :dns_config], authorize?: false),
         :ok <- active?(monitor),
         {:ok, _access} <- Alplus.Billing.Access.check(monitor.org_id) do
      config =
        case monitor.type do
          type when type in ["http", "keyword"] -> monitor.http_config
          "tcp" -> monitor.tcp_config
          "dns" -> monitor.dns_config
        end

      if config, do: {:ok, {monitor.type, config}}, else: {:error, :missing_monitor_config}
    else
      {:error, %Alplus.Billing.EntitlementError{reason: :plan_inactive}} ->
        {:error, :inactive}

      {:error, %Ash.Error.Invalid{errors: errors}} = error ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)),
          do: {:error, :not_visible_yet},
          else: error

      error ->
        error
    end
  end

  defp active?(%{status: "active"}), do: :ok
  defp active?(_monitor), do: {:error, :inactive}

  # `:monitor_check_opts` is unset in every environment but test, where it
  # injects a resolver and a request function so a check can be slow or
  # succeed without a public target.
  defp run_check(type, config) when type in ["http", "keyword"],
    do: Alplus.Monitoring.HttpExecutor.run(config, check_opts())

  defp run_check("tcp", config), do: Alplus.Monitoring.TcpExecutor.run(config, check_opts())

  defp run_check("dns", config) do
    case Keyword.fetch(check_opts(), :request) do
      {:ok, request} -> Alplus.Monitoring.DnsExecutor.run(config, request)
      :error -> Alplus.Monitoring.DnsExecutor.run(config)
    end
  end

  defp check_opts, do: Application.get_env(:alplus, :monitor_check_opts, [])

  defp timeout_ms(%{timeout_seconds: seconds}) when is_integer(seconds), do: seconds * 1_000
  defp timeout_ms(_config), do: 10_000
end
