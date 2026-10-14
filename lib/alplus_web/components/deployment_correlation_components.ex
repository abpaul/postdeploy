defmodule AlplusWeb.DeploymentCorrelationComponents do
  @moduledoc "Shared deployment-correlation evidence panel."

  use AlplusWeb, :html

  import AlplusWeb.Format

  attr :comparison, :map, required: true

  @doc "Renders one release's bounded before/after evidence and its coverage state."
  def deployment_correlation_panel(assigns) do
    ~H"""
    <.data_panel
      id="observe-deployment-correlation"
      title="Deployment correlation"
      description="Equal UTC windows around the selected release. Correlation is evidence, not causation."
    >
      <div class="space-y-4 p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p class="text-label font-medium text-text-tertiary">Release</p>
            <p id="deployment-correlation-release" class="mt-1 font-mono text-data text-text-primary">
              {@comparison.release.version}
            </p>
            <p class="mt-1 text-data text-text-secondary">
              {@comparison.environment || "Environment unavailable"}, {format_utc_seconds(
                @comparison.release.released_at
              )}
            </p>
          </div>
          <span id="deployment-correlation-state">
            <.status_badge
              tone={state_tone(@comparison.state)}
              label={state_label(@comparison.state)}
            />
          </span>
        </div>

        <p
          :if={reason_label(@comparison.reason)}
          id="deployment-correlation-reason"
          class="rounded-control bg-status-late-bg p-3 text-body text-status-late-ink"
          role="status"
        >
          {reason_label(@comparison.reason)}
        </p>

        <dl
          id="deployment-correlation-window"
          class="flex flex-wrap gap-x-5 gap-y-2 border-y border-border-default py-3 text-data"
        >
          <div>
            <dt class="text-text-tertiary">Before</dt>
            <dd class="text-text-primary">
              {format_utc_seconds(@comparison.window.before_start)} to {format_utc_seconds(
                @comparison.window.before_end
              )}
            </dd>
          </div>
          <div>
            <dt class="text-text-tertiary">After</dt>
            <dd class="text-text-primary">
              {format_utc_seconds(@comparison.window.after_start)} to {format_utc_seconds(
                @comparison.window.after_end
              )}
            </dd>
          </div>
          <div>
            <dt class="text-text-tertiary">Window state</dt>
            <dd class="text-text-primary">{window_state(@comparison.window)}</dd>
          </div>
        </dl>

        <section
          id="deployment-correlation-small-multiples"
          aria-labelledby="deployment-correlation-chart-title"
        >
          <h3
            id="deployment-correlation-chart-title"
            class="text-ui font-semibold text-text-primary"
          >
            Before and after signal scale
          </h3>
          <div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.small_multiple
              id="deployment-correlation-chart-errors"
              label="Error volume"
              metric={@comparison.errors.metric}
              state={@comparison.errors.state}
              coverage={@comparison.errors.coverage}
              incidents={[]}
              window={@comparison.window}
            />
            <.small_multiple
              :for={monitor <- @comparison.monitors}
              id={"deployment-correlation-chart-monitor-#{monitor.resource.id}"}
              label={"p95 latency, #{monitor.resource.name}"}
              metric={monitor.comparison}
              state={monitor.state}
              coverage={monitor.coverage}
              incidents={Map.get(monitor, :incident_markers, [])}
              window={@comparison.window}
            />
            <.small_multiple
              :for={source <- @comparison.measure_sources}
              id={"deployment-correlation-chart-measure-#{source.resource.id}"}
              label={"Traffic, #{source.resource.name}"}
              metric={source.comparison}
              state={source.state}
              coverage={source.coverage}
              incidents={[]}
              window={@comparison.window}
            />
          </div>
        </section>

        <div class="overflow-x-auto">
          <table id="deployment-correlation-table" class="w-full min-w-[42rem] text-left text-data">
            <caption class="sr-only">Before and after deployment evidence</caption>
            <thead class="border-b border-border-default text-text-tertiary">
              <tr>
                <th scope="col" class="px-2 py-2 font-medium">Signal</th>
                <th scope="col" class="px-2 py-2 text-right font-medium">Before</th>
                <th scope="col" class="px-2 py-2 text-right font-medium">After</th>
                <th scope="col" class="px-2 py-2 text-right font-medium">Delta</th>
                <th scope="col" class="px-2 py-2 font-medium">Result</th>
                <th scope="col" class="px-2 py-2 font-medium">Coverage / state</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-border-default">
              <.evidence_row
                id="deployment-correlation-errors"
                label="Error volume"
                metric={@comparison.errors.metric}
                coverage={@comparison.errors.coverage}
                state={@comparison.errors.state}
                direction={@comparison.errors.metric.direction}
              />
              <.evidence_row
                :for={monitor <- @comparison.monitors}
                id={"deployment-correlation-monitor-#{monitor.resource.id}"}
                label={"Monitor, #{monitor.resource.name}, p95 latency"}
                metric={monitor.comparison}
                coverage={monitor.coverage}
                state={monitor.state}
                direction={monitor.comparison.direction}
                detail={monitor.incident_overlap? && "Incident overlap"}
              />
              <.evidence_row
                :for={source <- @comparison.measure_sources}
                id={"deployment-correlation-measure-#{source.resource.id}"}
                label={"Measure, #{source.resource.name}, traffic"}
                metric={source.comparison}
                coverage={source.coverage}
                state={source.state}
                direction={
                  Map.get(source.comparison, :traffic_direction, source.comparison.direction)
                }
                detail={source.granularity}
              />
            </tbody>
          </table>
        </div>
      </div>
    </.data_panel>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :metric, :map, required: true
  attr :coverage, :map, required: true
  attr :state, :atom, required: true
  attr :incidents, :list, required: true
  attr :window, :map, required: true

  defp small_multiple(assigns) do
    values = [assigns.metric.before, assigns.metric.after] |> Enum.filter(&is_number/1)

    max_value =
      case values do
        [] -> 0
        values -> max(Enum.max(values), 0)
      end

    assigns = assign(assigns, :max_value, max_value)

    ~H"""
    <figure
      id={@id}
      class="rounded-structural border border-border-default bg-surface-raised p-3"
      aria-label={@label}
    >
      <figcaption class="text-data font-medium text-text-primary">{@label}</figcaption>
      <div class="mt-3 grid grid-cols-2 gap-3">
        <.scale_bar label="Before" value={@metric.before} max_value={@max_value} state={@state} />
        <.scale_bar label="After" value={@metric.after} max_value={@max_value} state={@state} />
      </div>
      <.ruler
        labels={["Before", "Release", "After"]}
        label="Release and incident time ruler"
        markers={ruler_markers(@window, @incidents)}
      />
      <p class="mt-2 text-label text-text-tertiary">
        {coverage_label(@coverage)}, {sample_label(@coverage)}
      </p>
    </figure>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :max_value, :any, required: true
  attr :state, :atom, required: true

  defp scale_bar(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between text-label text-text-tertiary">
        <span>{@label}</span><span>{format_value(@value, @state)}</span>
      </div>
      <div class="mt-1 h-2 rounded-dot bg-surface-sunken" role="img" aria-label={"#{@label} value"}>
        <span
          :if={is_number(@value) and @state == :ready}
          class="block h-2 rounded-dot bg-interactive-strong"
          style={"width: #{scale_width(@value, @max_value)}%"}
        ></span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :metric, :map, required: true
  attr :coverage, :map, required: true
  attr :state, :atom, required: true
  attr :direction, :atom, required: true
  attr :detail, :any, default: nil

  defp evidence_row(assigns) do
    ~H"""
    <tr id={@id}>
      <th scope="row" class="px-2 py-2 font-medium text-text-primary">
        {@label}
        <span :if={@detail} class="mt-0.5 block text-label font-normal text-text-tertiary">
          {format_detail(@detail)}
        </span>
      </th>
      <td class="px-2 py-2 text-right tabular-nums text-text-primary">
        {format_value(@metric.before, @state)}
      </td>
      <td class="px-2 py-2 text-right tabular-nums text-text-primary">
        {format_value(@metric.after, @state)}
      </td>
      <td class="px-2 py-2 text-right tabular-nums text-text-primary">
        {format_delta(@metric, @state)}
      </td>
      <td class="px-2 py-2">
        <.status_badge tone={direction_tone(@direction)} label={direction_label(@direction)} />
      </td>
      <td class="px-2 py-2">
        <.status_badge tone={state_tone(@state)} label={state_label(@state)} />
        <p class="mt-1 text-label text-text-tertiary">
          {coverage_label(@coverage)}
        </p>
      </td>
    </tr>
    """
  end

  defp state_tone(:ready), do: "success"
  defp state_tone(:partial), do: "warning"
  defp state_tone(:insufficient), do: "warning"
  defp state_tone(:confounded), do: "warning"
  defp state_tone(:ambiguous), do: "warning"
  defp state_tone(_state), do: "neutral"

  defp state_label(:ready), do: "Ready"
  defp state_label(:partial), do: "Partial"
  defp state_label(:insufficient), do: "Insufficient evidence"
  defp state_label(:confounded), do: "Confounded"
  defp state_label(:ambiguous), do: "Ambiguous environment"
  defp state_label(:unavailable), do: "Unavailable"
  defp state_label(_state), do: "Unavailable"

  defp direction_tone(:better), do: "success"
  defp direction_tone(:worse), do: "error"
  defp direction_tone(:neutral), do: "info"
  defp direction_tone(:increase), do: "info"
  defp direction_tone(:decrease), do: "info"
  defp direction_tone(_direction), do: "neutral"

  defp direction_label(:better), do: "Better"
  defp direction_label(:worse), do: "Worse"
  defp direction_label(:neutral), do: "Neutral"
  defp direction_label(:increase), do: "Increased"
  defp direction_label(:decrease), do: "Decreased"
  defp direction_label(_direction), do: "Unavailable"

  defp reason_label(:unequal_windows),
    do:
      "The after window is still collecting data. Values stay unavailable until both windows are equal."

  defp reason_label(:incident_overlap),
    do:
      "A Monitor incident overlaps this window. Latency is shown as confounded evidence, not a deployment effect."

  defp reason_label(:missing_environment),
    do: "This release has no trusted environment. Matching Monitor and Measure data is ambiguous."

  defp reason_label(:invalid_source),
    do: "This release is not linked to a valid Observe source. Evidence is unavailable."

  defp reason_label(:insufficient_evidence),
    do: "One or more signals are missing buckets or samples in an equal window."

  defp reason_label(_reason), do: nil

  defp window_state(%{equal?: true}), do: "Equal windows"

  defp window_state(%{after_seconds: after_seconds, expected_seconds: expected_seconds}),
    do: "After window #{format_seconds(after_seconds)} of #{format_seconds(expected_seconds)}"

  defp coverage_label(%{before: before, after: after_value}) do
    "#{coverage_value(before)} before, #{coverage_value(after_value)} after"
  end

  defp coverage_label(_coverage), do: "Coverage unavailable"

  defp coverage_value(%{coverage: coverage}) when is_number(coverage),
    do: "#{Float.round(coverage * 100, 1)}%"

  defp coverage_value(_coverage), do: "missing"

  defp format_value(_value, state) when state != :ready, do: "Unavailable"
  defp format_value(nil, _state), do: "Unavailable"
  defp format_value(value, _state) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value, _state) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_value(value, _state), do: to_string(value)

  defp format_delta(_metric, state) when state in [:unavailable, :insufficient],
    do: "Unavailable"

  defp format_delta(%{delta: nil}, _state), do: "Unavailable"

  defp format_delta(%{delta: delta, delta_percent: percent}, _state),
    do: "#{format_value(delta, :ready)} (#{format_percent(percent)})"

  defp format_percent(nil), do: "n/a"
  defp format_percent(value), do: "#{format_value(value, :ready)}%"

  defp sample_label(%{before: before, after: after_value}) do
    "#{sample_count(before)} samples before, #{sample_count(after_value)} after"
  end

  defp sample_label(_coverage), do: "Samples unavailable"
  defp sample_count(%{sample_count: count}) when is_integer(count), do: count
  defp sample_count(_value), do: "unavailable"

  defp scale_width(_value, 0), do: 0
  defp scale_width(value, max_value), do: Float.round(value / max_value * 100, 1)

  defp marker_position(nil, _window), do: 50

  defp marker_position(at, %{before_start: start, after_end: finish}) do
    total = DateTime.diff(finish, start, :second)
    offset = DateTime.diff(at, start, :second)
    max(min(offset / max(total, 1) * 100, 100), 0) |> Float.round(1)
  end

  defp ruler_markers(window, incidents) do
    release = %{
      position: marker_position(window.release_at, window),
      label: "Release",
      kind: :deploy
    }

    incident_markers =
      incidents
      |> Enum.filter(&match?(%{at: %DateTime{}}, &1))
      |> Enum.map(fn incident ->
        %{
          position: marker_position(incident.at, window),
          label: Map.get(incident, :label, "Incident"),
          kind: :incident
        }
      end)

    [release | incident_markers]
  end

  defp format_detail(:hour), do: "Hourly rollups"
  defp format_detail(:day), do: "Daily rollups"
  defp format_detail(value) when is_binary(value), do: value
  defp format_detail(true), do: "Incident overlap"
  defp format_detail(value), do: to_string(value)

  defp format_seconds(seconds) when seconds >= 86_400, do: "#{div(seconds, 86_400)}d"
  defp format_seconds(seconds) when seconds >= 3_600, do: "#{div(seconds, 3_600)}h"
  defp format_seconds(seconds), do: "#{div(seconds, 60)}m"
end
