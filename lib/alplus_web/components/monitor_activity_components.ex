defmodule AlplusWeb.MonitorActivityComponents do
  @moduledoc false

  use AlplusWeb, :html

  import AlplusWeb.DataDisplayComponents
  import AlplusWeb.Format

  alias Alplus.Monitoring.{Monitor, MonitorOverview, UptimeTracer}

  @doc """
  Renders a precomputed monitor timeline.

  The caller owns aggregation. This component owns plain user wording,
  accessible point labels, and the compact/full visual treatment.
  """
  attr :id, :string, required: true
  attr :buckets, :list, required: true
  attr :range, :string, required: true
  attr :variant, :atom, default: :compact, values: [:compact, :full]
  attr :scope, :atom, required: true, values: [:fleet, :monitor]
  attr :title, :string, default: "Availability"
  attr :class, :string, default: nil
  attr :legend, :boolean, default: false
  attr :table, :atom, default: :assistive, values: [:assistive, :disclosure]

  def monitor_timeline(assigns) do
    points = Enum.map(assigns.buckets, &timeline_point(&1, assigns.scope))
    state = if(points == [], do: :empty, else: :ready)

    assigns =
      assign(assigns,
        points: points,
        state: state,
        columns: timeline_columns(assigns.scope),
        legend_entries: timeline_legend()
      )

    ~H"""
    <.data_display
      id={@id}
      title={@title}
      heading={if(@variant == :compact, do: :assistive, else: :visible)}
      kind={:ticks}
      variant={@variant}
      state={@state}
      data={@points}
      preserve_points={true}
      unit="status"
      range={window_axis(@range)}
      legend={if(@legend, do: @legend_entries, else: [])}
      table={@table}
      table_columns={@columns}
      empty_label="No checks in this range."
      description={"Monitor status for the last #{window_words(@range)}."}
      class={@class}
    />
    """
  end

  defp timeline_point(bucket, :fleet) do
    tooltip = fleet_bucket_words(bucket)

    bucket
    |> Map.put(:tooltip, tooltip)
    |> Map.put(:aria_label, tooltip)
    |> Map.put(:table_cells, [
      timeline_period(bucket),
      Integer.to_string(Map.get(bucket, :monitor_count, 0)),
      Integer.to_string(Map.get(bucket, :healthy, 0)),
      Integer.to_string(Map.get(bucket, :down, 0)),
      Integer.to_string(Map.get(bucket, :degraded, 0)),
      Integer.to_string(Map.get(bucket, :unknown, 0))
    ])
  end

  defp timeline_point(bucket, :monitor) do
    state = monitor_bucket_label(Map.get(bucket, :state))
    checks = Map.get(bucket, :check_count, 0)
    missing = Map.get(bucket, :missing_interval_count, 0)

    tooltip =
      [
        timeline_period(bucket),
        state,
        count_phrase(checks, "check"),
        missing_phrase(missing),
        if(Map.get(bucket, :in_progress?, false), do: "in progress")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    bucket
    |> Map.put(:tooltip, tooltip)
    |> Map.put(:aria_label, tooltip)
    |> Map.put(:table_cells, [
      timeline_period(bucket),
      state,
      Integer.to_string(checks),
      if(missing > 0, do: Integer.to_string(missing), else: "None")
    ])
  end

  defp fleet_bucket_words(bucket) do
    [
      timeline_period(bucket),
      count_phrase(Map.get(bucket, :monitor_count, 0), "monitor"),
      positive_count_phrase(Map.get(bucket, :healthy, 0), "healthy"),
      positive_count_phrase(Map.get(bucket, :down, 0), "down"),
      positive_count_phrase(Map.get(bucket, :degraded, 0), "late"),
      fleet_no_data_phrase(bucket),
      fleet_missing_phrase(bucket),
      if(Map.get(bucket, :in_progress?, false), do: "in progress")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp fleet_no_data_phrase(%{unknown: count}) when count > 0,
    do: "#{count} with no data"

  defp fleet_no_data_phrase(_bucket), do: nil

  defp fleet_missing_phrase(%{missing_checks: count}) when count > 0,
    do: count_phrase(count, "check") <> " missing"

  defp fleet_missing_phrase(_bucket), do: nil

  defp timeline_period(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}) do
    if DateTime.diff(end_at, start_at, :second) <= 3_600 do
      "#{Calendar.strftime(start_at, "%H:%M")} to #{Calendar.strftime(end_at, "%H:%M")} UTC"
    else
      Calendar.strftime(start_at, "%b %-d UTC")
    end
  end

  defp timeline_period(_bucket), do: "Time unavailable"

  defp positive_count_phrase(0, _word), do: nil
  defp positive_count_phrase(count, word), do: "#{count} #{word}"
  defp count_phrase(1, noun), do: "1 #{noun}"
  defp count_phrase(count, noun), do: "#{count} #{noun}s"
  defp missing_phrase(0), do: nil
  defp missing_phrase(count), do: "#{count_phrase(count, "check")} missing"

  defp monitor_bucket_label(:up), do: "Healthy"
  defp monitor_bucket_label(:down), do: "Down"
  defp monitor_bucket_label(state) when state in [:slow, :anomaly], do: "Late"
  defp monitor_bucket_label(:paused), do: "Paused"
  defp monitor_bucket_label(:partial), do: "Partial data"
  defp monitor_bucket_label(:missing), do: "No data"
  defp monitor_bucket_label(_state), do: "No data"

  defp timeline_columns(:fleet),
    do: ["Time", "Monitors", "Healthy", "Down", "Late", "No data"]

  defp timeline_columns(:monitor), do: ["Time", "Status", "Checks", "Missing checks"]

  defp timeline_legend,
    do: [
      %{label: "Healthy", tone: "live", class: "bg-status-live"},
      %{label: "Late", tone: "late", class: "bg-status-late"},
      %{label: "Down", tone: "error", class: "bg-status-error"},
      %{label: "No data", tone: "neutral", class: "bg-status-neutral"}
    ]

  @doc "Renders the one shared availability key above a monitor collection."
  def monitor_timeline_legend(assigns) do
    assigns = assign(assigns, :entries, timeline_legend())

    ~H"""
    <div
      id="monitor-availability-key"
      class="flex min-h-11 flex-wrap items-center gap-x-4 gap-y-1 border-b border-border-subtle px-5 py-2"
      aria-label="Availability key"
    >
      <span
        :for={entry <- @entries}
        class="inline-flex items-center gap-1.5 text-caption text-text-secondary"
      >
        <span class={["size-2.5 rounded-dot", entry.class]} aria-hidden="true"></span>
        {entry.label}
      </span>
    </div>
    """
  end

  attr :org_token, :string, required: true
  attr :project, :any, required: true
  attr :environments, :list, required: true
  attr :environment, :string, default: nil
  attr :window, :string, required: true
  attr :query, :string, default: nil
  attr :status, :string, default: nil
  attr :type, :string, default: nil
  attr :focus, :string, default: nil
  attr :view, :string, required: true

  def filter_bar(assigns) do
    ~H"""
    <form
      id="monitor-filters"
      phx-change="filter_monitors"
      phx-submit="filter_monitors"
      class="flex min-w-0 max-w-full flex-wrap items-center gap-2"
    >
      <input :if={@focus} type="hidden" name="focus" value={@focus} />
      <input type="hidden" name="view" value={@view} />
      <%!-- The time range is the page header's control now (design source §04),
            so this form carries the current window rather than offering a
            second, differently-shaped way to change the same thing. --%>
      <input type="hidden" name="window" value={@window} />
      <%!-- One filter grammar across Monitor, Changelog and Observe: a named
            control at `h-control-sm` (which a coarse pointer scales back to
            the 44px touch floor), with the name carried by the placeholder or
            the "All ..." option rather than a printed label. --%>
      <label class="min-w-0 w-full sm:w-56">
        <span class="sr-only">Search monitors</span>
        <input
          type="search"
          name="query"
          value={@query}
          placeholder="Name or target"
          maxlength="200"
          class="h-control-sm w-full min-w-0 rounded-input border border-border-default bg-surface-raised px-2 text-body text-text-primary"
        />
      </label>
      <.filter_select
        label="Environment"
        name="environment"
        value={@environment}
        options={[{"All environments", ""} | Enum.map(@environments, &{&1, &1})]}
      />
      <.filter_select
        label="Status"
        name="status"
        value={@status}
        options={[
          {"All statuses", ""},
          {"Active", "active"},
          {"Up", "up"},
          {"Down", "down"},
          {"Degraded", "degraded"},
          {"Late", "late"},
          {"No recent checks", "missing"},
          {"Paused", "paused"},
          {"Waiting", "waiting"}
        ]}
      />
      <.filter_select
        label="Type"
        name="type"
        value={@type}
        options={[{"All types", ""} | monitor_types()]}
      />
      <%!-- This form still reloads the page, so a submit control has to stay:
            without it the selects could only be applied with a mouse-driven
            auto-submit. It is the one primary on the Monitor workspace; the
            per-monitor "Open monitor" actions are inspection, so they are
            secondary. --%>
    </form>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :options, :list, required: true

  def filter_select(assigns) do
    ~H"""
    <label class="min-w-0 max-w-full">
      <span class="sr-only">{@label}</span>
      <select
        name={@name}
        class="h-control-sm min-w-0 max-w-full rounded-input border border-border-default bg-surface-raised px-2 text-body text-text-primary"
      >
        <option :for={{label, value} <- @options} value={value} selected={value == (@value || "")}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  @doc """
  One monitor as a compact index row: state dot and word, the monitor name,
  one availability strip, and the windowed uptime percentage.

  The index answers exactly one question, "is it up?", so it draws exactly
  one visual per row. Response time, its threshold line, and the typed
  configuration are detail-page evidence and are not restated here.
  """
  attr :row, :any, required: true
  attr :activity, :any, required: true
  attr :org_token, :string, required: true
  attr :project, :any, required: true
  attr :window, :string, required: true

  def monitor_row(assigns) do
    state =
      Map.get(assigns.activity, :state) || assigns.row.state ||
        fallback_state(assigns.row.monitor)

    uptime_measurement = Map.get(assigns.activity, :uptime)

    assigns =
      assign(assigns,
        state: state,
        uptime: Map.get(assigns.activity, :uptime_trace) || UptimeTracer.empty(),
        uptime_measurement: uptime_measurement,
        uptime_available?: match?(%{uptime: ratio} when is_number(ratio), uptime_measurement)
      )

    ~H"""
    <div
      id={"monitor-row-#{@row.monitor.id}"}
      class={[
        "grid min-h-14 min-w-0 items-center gap-x-5 gap-y-3 px-5 py-3",
        "md:grid-cols-[minmax(0,1fr)_minmax(5rem,auto)]",
        "lg:grid-cols-[minmax(0,1fr)_minmax(0,20rem)_minmax(5rem,auto)] lg:py-0",
        @row.monitor.status == "paused" && "opacity-75"
      ]}
      role="group"
      aria-label={@row.monitor.name}
    >
      <div class="min-w-0">
        <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
          <span id={"monitor-state-#{@row.monitor.id}"}>
            <.status_dot tone={state_tone(@state)} label={state_label(@state)} />
          </span>
          <.link
            id={"monitor-name-#{@row.monitor.id}"}
            navigate={monitor_detail_path(@org_token, @project, @row.monitor)}
            class="inline-flex h-control-md min-w-0 items-center truncate text-body font-semibold text-text-primary hover:text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            {@row.monitor.name}
          </.link>
          <.link
            :if={@row.open_incident}
            id={"incident-flag-#{@row.monitor.id}"}
            navigate={incidents_path(@org_token, @project)}
            aria-label={"Open active incident for #{@row.monitor.name}"}
          >
            <.status_badge tone="error" label="Active incident" />
          </.link>
        </div>
        <%!-- The row's context stays visible at every width: on a phone it
              is the only place the kind, environment, interval and last check
              can be read without opening the monitor. --%>
        <p
          id={"monitor-evidence-#{@row.monitor.id}"}
          class="mt-0.5 text-caption text-text-secondary"
        >
          {row_clause(@row)}
        </p>
      </div>

      <.monitor_timeline
        id={"uptime-timeline-#{@row.monitor.id}"}
        title="Availability"
        buckets={@uptime.buckets}
        range={@window}
        variant={:compact}
        scope={:monitor}
        legend={false}
        class="md:col-span-2 md:row-start-2 lg:col-span-1 lg:col-start-2 lg:row-start-1"
      />

      <p
        id={"monitor-uptime-#{@row.monitor.id}"}
        class={[
          "font-mono text-data font-semibold tabular-nums md:col-start-2 md:row-start-1 md:text-right lg:col-start-3",
          @uptime_available? && uptime_text_class(uptime_tone(@uptime_measurement)),
          not @uptime_available? && "sr-only"
        ]}
      >
        <%= if @uptime_available? do %>
          <span class="sr-only">Uptime in this window:</span>
          {uptime_value(@uptime_measurement)}
        <% else %>
          Uptime unavailable
        <% end %>
      </p>
    </div>
    """
  end

  @doc "Renders the detail response-time plot and its real alert threshold."
  attr :row, :any, required: true
  attr :activity, :any, required: true
  attr :window, :string, required: true

  def response_time_panel(assigns) do
    bars = response_time_bars(assigns.row, assigns.activity)
    threshold = response_threshold(assigns.row)
    max_value = response_scale(bars, threshold)

    thresholds =
      if is_integer(threshold) and max_value > 0 do
        [
          %{
            label: "Alert threshold",
            value: threshold,
            position: max(min(threshold / max_value * 100, 100), 0) |> Float.round(1)
          }
        ]
      else
        []
      end

    assigns =
      assign(assigns,
        bars: bars,
        state: response_bar_state(assigns.activity, bars),
        thresholds: thresholds
      )

    ~H"""
    <.data_display
      id={"response-time-chart-#{@row.monitor.id}"}
      title="Response time"
      heading={:assistive}
      kind={:bucket_bar}
      variant={:full}
      plot_height={:standard}
      state={@state}
      data={@bars}
      unit="ms"
      range={window_axis(@window)}
      thresholds={@thresholds}
      table={:assistive}
      table_columns={["Checked at", "Latency", "Status"]}
      empty_label="No latency data"
      description="Response time for recorded checks."
    />
    """
  end

  defp monitor_types,
    do: [
      {"Website (HTTP)", "http"},
      {"Keyword match", "keyword"},
      {"Heartbeat", "heartbeat"},
      {"TCP", "tcp"},
      {"DNS", "dns"}
    ]

  @doc "The accessible status label for a monitor: paused/up/down/degraded/unknown."
  def row_label(%Monitor{status: "paused"}), do: "Paused"
  def row_label(%Monitor{last_known_status: "up"}), do: "Up"
  def row_label(%Monitor{last_known_status: "down"}), do: "Down"
  def row_label(%Monitor{last_known_status: "degraded"}), do: "Degraded"
  def row_label(_monitor), do: "Unknown"

  @doc "The monitor's type label, e.g. \"HTTP monitor\"."
  def monitor_identity(%Monitor{type: "http"}), do: "HTTP monitor"
  def monitor_identity(%Monitor{type: "keyword"}), do: "HTTP keyword monitor"
  def monitor_identity(%Monitor{type: "heartbeat"}), do: "Heartbeat monitor"
  def monitor_identity(%Monitor{type: "tcp"}), do: "TCP monitor"
  def monitor_identity(%Monitor{type: "dns"}), do: "DNS monitor"

  defp state_tone(:up), do: "live"
  defp state_tone(:down), do: "error"
  defp state_tone(:degraded), do: "late"
  defp state_tone(:late), do: "late"
  defp state_tone(:paused), do: "paused"
  defp state_tone(:missing), do: "neutral"
  defp state_tone(_state), do: "neutral"

  defp state_label(:up), do: "Operational"
  defp state_label(:down), do: "Down"
  defp state_label(:degraded), do: "Degraded"
  defp state_label(:late), do: "Late"
  defp state_label(:waiting), do: "Waiting for the first check"
  defp state_label(:missing), do: "No recent checks"
  defp state_label(:paused), do: "Paused"
  defp state_label(_state), do: "No data"

  defp fallback_state(%Monitor{status: "paused"}), do: :paused
  defp fallback_state(%Monitor{last_known_status: "down"}), do: :down
  defp fallback_state(%Monitor{last_known_status: "degraded"}), do: :degraded
  defp fallback_state(%Monitor{last_known_status: "up"}), do: :up
  defp fallback_state(_monitor), do: :waiting

  # The index row's one trailing mono clause. It carries what the four-cell
  # definition list used to spend a grid on, minus latency: response time is
  # a detail-page question now.
  defp row_clause(row) do
    [
      monitor_identity(row.monitor),
      row.monitor.environment,
      interval_clause(row.interval_seconds),
      checked_clause(row.latest_check)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp interval_clause(seconds) when is_integer(seconds) and seconds < 60,
    do: "every #{seconds}s"

  defp interval_clause(seconds) when is_integer(seconds) and rem(seconds, 3600) == 0,
    do: "every #{div(seconds, 3600)}h"

  defp interval_clause(seconds) when is_integer(seconds) and rem(seconds, 60) == 0,
    do: "every #{div(seconds, 60)}m"

  defp interval_clause(seconds) when is_integer(seconds), do: "every #{seconds}s"
  defp interval_clause(_seconds), do: nil

  defp checked_clause(%{checked_at: checked_at}) when not is_nil(checked_at),
    do: "checked #{format_utc_seconds(checked_at)}"

  defp checked_clause(_check), do: "no check yet"

  @doc """
  The windowed uptime percentage from `Alplus.Monitoring.Uptime.calculate/4`'s
  result map (a ratio plus monitored/downtime microseconds), never a bare
  ratio. Shared by the Monitor index row and the monitor detail hero.
  """
  def uptime_value(%{uptime: ratio}) when is_number(ratio),
    do: "#{Float.round(ratio * 100, 2)}%"

  def uptime_value(_uptime), do: "No data"

  @doc "The status tone for a windowed uptime ratio."
  def uptime_tone(%{uptime: ratio}) when is_number(ratio) and ratio >= 0.999, do: "success"
  def uptime_tone(%{uptime: ratio}) when is_number(ratio) and ratio >= 0.99, do: "warning"
  def uptime_tone(%{uptime: ratio}) when is_number(ratio), do: "error"
  def uptime_tone(_uptime), do: "neutral"

  @doc "The text colour for a status tone, used by uptime and latency values."
  def uptime_text_class("success"), do: "text-status-live-ink"
  def uptime_text_class("warning"), do: "text-status-late-ink"
  def uptime_text_class("error"), do: "text-status-error-ink"
  def uptime_text_class(_neutral), do: "text-text-primary"

  @doc "The row's checked target (URL/host/PostDeploy endpoint), or an unavailable notice."
  def target_label(%MonitorOverview.Row{target: nil}), do: "Target unavailable"
  def target_label(%MonitorOverview.Row{target: target}), do: target

  @doc """
  A human duration ("2h 14m", "45m", "30s") for incident/uptime displays.
  Never renders a middot or a dash between the parts (AGENTS.md rule 6).
  """
  def duration_words(seconds) when is_integer(seconds) and seconds >= 0 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3600)
    minutes = seconds |> rem(3600) |> div(60)
    secs = rem(seconds, 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "#{secs}s"
    end
  end

  @doc """
  The duration label for an incident: "ongoing for Xh Ym" while open, or
  "lasted Xh Ym" once resolved. Uses the stored `duration_seconds` for a
  resolved incident rather than recomputing from timestamps.
  """
  def incident_duration_label(%{resolved_at: nil, started_at: started_at}) do
    "ongoing for #{duration_words(DateTime.diff(DateTime.utc_now(), started_at, :second))}"
  end

  def incident_duration_label(%{duration_seconds: duration_seconds}) do
    "lasted #{duration_words(duration_seconds || 0)}"
  end

  defp monitor_detail_path(org_token, project, monitor) do
    ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/monitor/#{monitor.id}"
  end

  def workspace_path(org_token, project, params \\ %{}) do
    ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/monitor?#{compact_params(params)}"
  end

  defp incidents_path(org_token, project) do
    workspace_path(org_token, project, %{"view" => "incidents"}) <> "#incident-list"
  end

  defp response_time_bars(row, activity) do
    samples =
      activity.checks
      |> Enum.filter(&is_integer(&1.latency_ms))
      |> Enum.reverse()

    threshold = response_threshold(row)
    max_v = response_scale_from_samples(samples, threshold)

    Enum.map(samples, fn check ->
      %{
        id: Map.get(check, :id) || format_utc_seconds(check.checked_at),
        label: format_utc_seconds(check.checked_at),
        value: check.latency_ms,
        height: if(max_v > 0, do: check.latency_ms / max_v * 100, else: 0),
        tone:
          if(is_integer(threshold) and check.latency_ms > threshold,
            do: "late",
            else: "latency"
          ),
        tooltip: sample_title(check),
        aria_label: sample_title(check),
        table_cells: [
          format_utc_seconds(check.checked_at),
          "#{check.latency_ms} ms",
          to_string(check.status)
        ]
      }
    end)
  end

  defp sample_title(%{checked_at: checked_at, latency_ms: latency_ms, status_code: nil}),
    do: "#{format_utc_seconds(checked_at)}, #{latency_ms} ms"

  defp sample_title(%{checked_at: checked_at, latency_ms: latency_ms, status_code: status_code}),
    do: "#{format_utc_seconds(checked_at)}, #{latency_ms} ms, HTTP #{status_code}"

  defp response_threshold(%{config: %{response_time_threshold_ms: ms}}) when is_integer(ms),
    do: ms

  defp response_threshold(%{monitor: %{config: %{response_time_threshold_ms: ms}}})
       when is_integer(ms),
       do: ms

  defp response_threshold(_row), do: nil

  defp response_scale(bars, threshold) do
    latencies = Enum.map(bars, & &1.value)
    response_scale_from_values(latencies, threshold)
  end

  defp response_scale_from_samples(samples, threshold) do
    response_scale_from_values(Enum.map(samples, & &1.latency_ms), threshold)
  end

  defp response_scale_from_values([], threshold) when is_integer(threshold), do: threshold
  defp response_scale_from_values([], _threshold), do: 1

  defp response_scale_from_values(values, threshold) do
    peak = Enum.max(values)
    if is_integer(threshold), do: max(peak, threshold), else: max(peak, 1)
  end

  defp response_bar_state(%{check_count: 0}, _bars), do: :empty
  defp response_bar_state(_activity, []), do: :empty
  defp response_bar_state(_activity, _bars), do: :ready

  defp compact_params(params) do
    Map.reject(params, fn {_key, value} -> is_nil(value) or value == "" end)
  end
end
