defmodule AlplusWeb.MonitorMetricsComponents do
  @moduledoc false

  use AlplusWeb, :html

  attr :metrics, :any, required: true

  @doc "Renders the concise latency readings beside the response-time plot."
  def latency_analysis(assigns) do
    ~H"""
    <div id="monitor-latency-analysis">
      <div
        :if={@metrics.state == :error}
        id="monitor-latency-error"
        class="flex min-h-11 flex-wrap items-center gap-2 rounded-control bg-status-error-bg px-3 py-2 text-body text-status-error-ink"
        role="alert"
      >
        <span class="font-semibold">No latency data</span>
        <button
          id="monitor-latency-retry"
          type="button"
          phx-click="retry_load"
          class="h-control-md rounded-control border border-status-error-border px-3 text-label font-medium focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          Retry
        </button>
      </div>

      <p
        :if={@metrics.state != :error and @metrics.latency_count == 0}
        id="latency-empty-state"
        class="text-body text-text-secondary"
        role="status"
      >
        No latency data
      </p>

      <dl
        :if={@metrics.state != :error and @metrics.latency_count > 0}
        id="monitor-latency-summary"
        class="grid grid-cols-2 gap-x-5 gap-y-3 sm:grid-cols-4"
        aria-label="Latency readings"
      >
        <.summary_value
          id="latency-sample-count"
          label="Samples"
          value={@metrics.latency_count}
        />
        <.summary_value
          id="latency-p50-value"
          label="p50"
          value={format_latency(@metrics.percentiles.p50)}
        />
        <.summary_value
          id="latency-p95-value"
          label="p95"
          value={format_latency(@metrics.percentiles.p95)}
        />
        <.summary_value
          id="latency-p99-value"
          label="p99"
          value={format_latency(@metrics.percentiles.p99)}
        />
      </dl>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp summary_value(assigns) do
    ~H"""
    <div id={@id} class="grid gap-0.5">
      <dt class="text-label text-text-tertiary">{@label}</dt>
      <dd class="text-body font-semibold tabular-nums text-text-primary">{@value}</dd>
    </div>
    """
  end

  defp format_latency(nil), do: "No value"
  defp format_latency(value) when is_integer(value), do: "#{value} ms"

  defp format_latency(value) when is_float(value),
    do: "#{:erlang.float_to_binary(value, decimals: 2)} ms"

  defp format_latency(value), do: "#{value} ms"
end
