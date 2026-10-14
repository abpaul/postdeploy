defmodule AlplusWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    case :telemetry.attach_many(
           {__MODULE__, :oban_job_logger},
           [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]],
           &__MODULE__.oban_job_logger/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      counter("phoenix.endpoint.stop.count", tags: [:status_class], tag_values: &endpoint_tags/1),
      summary("phoenix.endpoint.stop.duration",
        tags: [:status_class],
        tag_values: &endpoint_tags/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # LiveView Metrics
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        tag_values: &live_view_tags/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        tag_values: &live_view_event_tags/1,
        unit: {:native, :millisecond}
      ),

      # Oban Metrics
      summary("oban.job.stop.duration",
        tags: [:queue, :state],
        tag_values: &oban_tags/1,
        unit: {:native, :millisecond}
      ),
      summary("oban.job.exception.duration",
        tags: [:queue, :state],
        tag_values: &oban_tags/1,
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("alplus.repo.query.total_time",
        tags: [:repo],
        tag_values: &repo_tags/1,
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("alplus.repo.query.decode_time",
        tags: [:repo],
        tag_values: &repo_tags/1,
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("alplus.repo.query.query_time",
        tags: [:repo],
        tag_values: &repo_tags/1,
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("alplus.repo.query.queue_time",
        tags: [:repo],
        tag_values: &repo_tags/1,
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("alplus.repo.query.idle_time",
        tags: [:repo],
        tag_values: &repo_tags/1,
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Req Metrics
      summary("req.request.stop.duration", unit: {:native, :millisecond}),

      # Ingestion overload metrics. Source ids remain event metadata, never
      # exporter tags, so one metric cannot create unbounded cardinality.
      counter("alplus.http.response.count", tags: [:status_class]),
      counter("alplus.ingest.admission.accepted.count", tags: [:lane, :scope]),
      counter("alplus.ingest.admission.rejected.count", tags: [:lane, :scope]),
      last_value("alplus.ingest.admission.accepted.concurrent", tags: [:lane, :scope]),
      counter("alplus.ingest.analytics_engine.dropped.count", tags: [:reason]),
      counter("alplus.ingest.visitor_state.dropped.count", tags: [:reason]),
      counter("alplus.ingest.notification.suppressed.count", tags: [:reason]),
      last_value("alplus.ingest.analytics_engine.depth.depth"),
      sum("alplus.ingest.outcome.accepted", tags: [:lane, :status]),
      sum("alplus.ingest.outcome.rejected", tags: [:lane, :status]),
      last_value("alplus.ingest.tenant_rate.events_per_window", tags: [:lane]),
      last_value("alplus.ingest.runtime.memory_bytes", unit: :byte),
      last_value("alplus.ingest.runtime.process_count"),
      last_value("alplus.ingest.runtime.run_queue"),
      last_value("alplus.ingest.runtime.visitor_state_mailbox"),
      last_value("alplus.ingest.runtime.visitor_state_entries"),
      last_value("alplus.ingest.runtime.visitor_state_memory_bytes", unit: :byte),
      last_value("alplus.ingest.runtime.visitor_state_available"),
      last_value("alplus.ingest.runtime.analytics_batcher_mailbox"),
      last_value("alplus.ingest.runtime.analytics_buffer_depth"),
      last_value("alplus.ingest.runtime.admission_concurrent"),
      last_value("alplus.ingest.runtime.accepted"),
      last_value("alplus.ingest.runtime.rejected_events"),
      last_value("alplus.ingest.runtime.notification_backlog"),
      last_value("alplus.ingest.runtime.db_queue_time_native", unit: :native),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @doc false
  # A job that exhausts its attempts is discarded, and `Oban.Plugins.Pruner`
  # deletes the row a week later. Nothing else records that a password reset
  # or an invitation was never sent, so the final failure logs at error with
  # enough keys to find the job. A retry stays quiet; the next attempt may
  # succeed.
  def oban_job_logger(
        [:oban, :job, :exception],
        _measurements,
        %{job: %{id: id} = job, state: :discard} = metadata,
        _config
      ) do
    Logger.metadata(job_id: id)
    arg_keys = job.args |> Map.keys() |> Enum.sort() |> Enum.join(",")

    Logger.error(
      "oban job discarded after #{job.attempt} of #{job.max_attempts} attempts " <>
        "queue=#{job.queue} worker=#{job.worker} arg_keys=#{arg_keys}: " <>
        Exception.format(
          metadata[:kind] || :error,
          metadata[:reason],
          metadata[:stacktrace] || []
        )
    )

    :ok
  end

  def oban_job_logger(_event, _measurements, %{job: %{id: id}}, _config) do
    Logger.metadata(job_id: id)
    :ok
  end

  def oban_job_logger(_event, _measurements, _metadata, _config), do: :ok

  defp endpoint_tags(%{conn: %{status: status}}), do: %{status_class: status_class(status)}
  defp endpoint_tags(_metadata), do: %{status_class: :unknown}

  defp status_class(status) when is_integer(status), do: "#{div(status, 100)}xx"
  defp status_class(_status), do: :unknown

  defp live_view_tags(%{socket: %{view: view}}), do: %{view: view}
  defp live_view_tags(_metadata), do: %{view: :unknown}

  defp live_view_event_tags(%{socket: %{view: view}, event: event}),
    do: %{view: view, event: event}

  defp live_view_event_tags(_metadata), do: %{view: :unknown, event: :unknown}

  defp oban_tags(%{job: %{queue: queue}, state: state}), do: %{queue: queue, state: state}
  defp oban_tags(_metadata), do: %{queue: :unknown, state: :unknown}

  defp repo_tags(%{repo: repo}), do: %{repo: repo}
  defp repo_tags(_metadata), do: %{repo: :unknown}

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {AlplusWeb, :count_users, []}
    ]
  end
end
