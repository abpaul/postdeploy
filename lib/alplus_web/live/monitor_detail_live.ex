defmodule AlplusWeb.MonitorDetailLive do
  @moduledoc """
  Detail view for one monitor: the same resource-panel visual language as
  the Monitor index (`AlplusWeb.MonitorLive`), including the response-time
  chart, the time-proportional availability strip, and the accessible
  status dot. It adds detail-only depth: exact windowed metrics, the full
  recent-checks list, the full typed configuration, and the incident
  history.

  `monitor_id` resolves under the project public token in the route. A
  monitor outside that project (wrong project, wrong org, unknown id) never
  distinguishes itself from a monitor that does not exist. Both raise
  `AlplusWeb.NotFoundError` (ARCHITECTURE.md §4: 404, never 403).
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.MonitorActivityComponents
  import AlplusWeb.DataDisplayComponents
  import AlplusWeb.MonitorMetricsComponents
  import AlplusWeb.Format, only: [window_words: 1]

  alias Alplus.Monitoring.{
    Incident,
    Monitor,
    MonitorCheck,
    MonitorDisplay,
    MonitorMetrics,
    MonitorOverview,
    Reliability
  }

  alias Alplus.Observe.DeploymentCorrelation

  require Ash.Query

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @windows ~w(24h 7d 30d 90d)
  @checks_page_sizes [5, 15, 30, 50]

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Monitors", active: :monitor) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       socket
       |> assign(:projects, [project])
       |> assign(:project, project)
       |> assign(:monitor_topic, nil)
       |> assign(:monitor, nil)
       |> assign(:row, nil)
       |> assign(:activity, nil)
       |> assign(:metrics, nil)
       |> assign(:reliability, nil)
       |> assign(:recent_checks, [])
       |> assign(:checks_page, 0)
       |> assign(:checks_page_size, List.first(@checks_page_sizes))
       |> assign(:checks_total, 0)
       |> assign(:checks_has_more?, false)
       |> assign(:incidents, [])
       |> assign(:window, "24h")
       |> assign(:windows, @windows)
       |> assign(:checks_page_sizes, @checks_page_sizes)
       |> assign(:loading, true)
       |> assign(:load_failed?, false)}
    end
  end

  @impl true
  def handle_params(%{"monitor_id" => monitor_id} = params, _uri, socket) do
    project = socket.assigns.project

    if is_nil(project), do: raise(AlplusWeb.NotFoundError)

    scope = scope_for(socket.assigns.scope, project)

    socket =
      socket
      |> assign(:project, project)
      |> assign(:window, normalize_window(params["window"]))
      |> assign(:checks_page_size, normalize_checks_page_size(params["checks_size"]))
      |> assign(:checks_page, normalize_checks_page(params["checks_page"]))
      |> subscribe_to_project(project)

    case Ash.get(Monitor, monitor_id, actor: scope) do
      {:ok, monitor} ->
        {:noreply,
         socket
         |> assign(:monitor, monitor)
         |> assign(:page_title, monitor.name)
         |> load_detail_data()}

      {:error, _} ->
        raise AlplusWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("pick_window", %{"window" => window}, socket) when window in @windows do
    {:noreply, push_patch(socket, to: detail_path(socket, %{"window" => window}))}
  end

  def handle_event("set_checks_page_size", %{"size" => size}, socket) do
    size = normalize_checks_page_size(size)

    {:noreply,
     push_patch(socket,
       to: detail_path(socket, %{"checks_size" => size, "checks_page" => 0})
     )}
  end

  def handle_event("set_checks_page", %{"page" => page}, socket) do
    page = max(normalize_checks_page(page), 0)
    {:noreply, push_patch(socket, to: detail_path(socket, %{"checks_page" => page}))}
  end

  @impl true
  def handle_event("retry_load", _params, socket) do
    {:noreply, load_detail_data(socket)}
  end

  @impl true
  def handle_info(
        {:monitor_updated, project_id},
        %{assigns: %{project: %{id: project_id}, monitor: %{id: monitor_id}}} = socket
      ) do
    scope = project_scope(socket)

    case Ash.get(Monitor, monitor_id, actor: scope) do
      {:ok, monitor} -> {:noreply, socket |> assign(:monitor, monitor) |> load_detail_data()}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:monitor}
      nav_project={@project}
      nav_projects={@nav_projects}
      project_scoped={false}
      window={@row && @window}
      page_heading?={false}
    >
      <.console_page id="monitor-detail-page">
        <:title :if={not @loading and not @load_failed? and @row}>{@row.monitor.name}</:title>
        <div :if={@loading} id="monitor-detail-loading" class="grid gap-4">
          <.skeleton rows={5} />
        </div>

        <.error_boundary
          :if={not @loading and @load_failed?}
          id="monitor-detail-error"
          retry="retry_load"
        >
          Could not load this monitor.
        </.error_boundary>

        <div
          :if={not @loading and not @load_failed? and @row}
          class="grid min-w-0 gap-6"
        >
          <div
            id="monitor-detail-status-group"
            class="grid gap-4 md:grid-cols-12"
          >
            <section
              id={"monitor-panel-#{@row.monitor.id}"}
              class={[
                "min-w-0 rounded-structural border border-border-default p-5 md:col-span-5 lg:col-span-4",
                if(@row.monitor.status == "paused",
                  do: "bg-surface-sunken",
                  else: "bg-surface-raised"
                )
              ]}
              aria-labelledby="monitor-detail-answer"
            >
              <p id="monitor-detail-kind" class="font-mono text-data text-text-tertiary">
                {monitor_identity(@row.monitor)}
              </p>
              <p id="detail-target" class="mt-1 break-all font-mono text-data text-text-secondary">
                {target_label(@row)}
              </p>
              <p
                :if={is_nil(@row.target)}
                id={"focused-config-unavailable-#{@row.monitor.id}"}
                class="mt-3 text-body text-text-secondary"
              >
                Monitor configuration is unavailable.
              </p>

              <%!-- The state is this panel's answer, not the screen's: the
                    name in the page title outranks it. --%>
              <p
                id="monitor-detail-answer"
                class="mt-6 flex flex-wrap items-center gap-2.5 text-heading-02 font-semibold text-text-primary"
              >
                <span
                  class={[
                    "size-2.5 shrink-0 rounded-dot",
                    detail_dot_class(detail_state(@row, @activity))
                  ]}
                  aria-hidden="true"
                />
                {detail_state_label(detail_state(@row, @activity))}
              </p>

              <dl class="mt-6 grid gap-3 border-t border-border-subtle pt-4 text-data">
                <div id="stat-latest-latency" class="flex items-baseline justify-between gap-3">
                  <dt class="text-text-tertiary">Last check</dt>
                  <dd class="text-right font-semibold tabular-nums text-text-primary">
                    {latest_check_value(@row.latest_check)}
                    <span
                      :if={latest_latency_hint(@row.latest_check)}
                      class="font-normal text-text-tertiary"
                    >
                      ({latest_latency_hint(@row.latest_check)})
                    </span>
                  </dd>
                </div>
                <div id="stat-check-count" class="flex items-baseline justify-between gap-3">
                  <dt class="text-text-tertiary">Checks, last {window_words(@window)}</dt>
                  <dd class="font-semibold tabular-nums text-text-primary">
                    {@activity.check_count}
                  </dd>
                </div>
              </dl>
            </section>

            <section
              id="monitor-uptime"
              class="min-w-0 rounded-structural border border-border-default bg-surface-raised p-5 md:col-span-7 lg:col-span-8"
              aria-labelledby="monitor-uptime-heading"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-3">
                <h2
                  id="monitor-uptime-heading"
                  class="text-heading-03 font-semibold text-text-primary"
                >
                  {if @activity.check_count > 0, do: "Uptime", else: "Uptime and latency"}
                </h2>
                <p
                  :if={@activity.check_count > 0}
                  id="stat-uptime"
                  class={[
                    "text-metric-compact font-semibold tabular-nums",
                    uptime_text_class(uptime_tone(@activity.uptime))
                  ]}
                >
                  {uptime_value(@activity.uptime)}
                  <span class="text-body font-normal text-text-tertiary">
                    last {window_words(@window)}
                  </span>
                </p>
              </div>
              <%!-- A range with no checks is not a monitor with no checks. The
                    notice names the range, the lifetime last check, and why
                    it is late, and it stands in for both the uptime strip and
                    the latency chart until the range holds a sample. --%>
              <p
                :if={@activity.check_count == 0 and @row.target}
                id="monitor-metrics-waiting"
                class="mt-5 text-body text-text-secondary"
              >
                <span id={"focused-waiting-#{@row.monitor.id}"}>
                  {range_empty_sentence(@row, @activity, @window)}
                </span>
              </p>
              <.monitor_timeline
                :if={@activity.check_count > 0}
                id={"monitor-detail-timeline-#{@row.monitor.id}"}
                buckets={@activity.uptime_trace.buckets}
                range={@window}
                variant={:full}
                scope={:monitor}
                legend={true}
                table={:assistive}
                class="mt-5"
              />
              <.reliability_panel reliability={@reliability} />
            </section>
          </div>

          <%!-- The evidence the reader came for sits right under the state:
                what happened, check by check, and what it added up to. Both
                panels stretch to the taller of the two, so the row reads as
                one band rather than as a card beside a hole. --%>
          <div
            id="monitor-detail-evidence-group"
            class="grid min-w-0 gap-4 md:grid-cols-12"
          >
            <section
              id="recent-checks"
              class="min-w-0 rounded-structural border border-border-default bg-surface-raised p-5 md:col-span-7 lg:col-span-8"
              aria-labelledby="recent-checks-heading"
            >
              <div class="flex flex-wrap items-center justify-between gap-3">
                <h2 id="recent-checks-heading" class="text-heading-03 font-semibold text-text-primary">
                  Recent checks
                </h2>
                <form phx-change="set_checks_page_size" id="checks-page-size-form">
                  <label class="flex items-center gap-2 text-caption text-text-secondary">
                    Show
                    <select
                      name="size"
                      class="h-control-sm rounded-input border border-border-control bg-surface-raised px-2 text-body text-text-primary"
                    >
                      <option
                        :for={size <- @checks_page_sizes}
                        value={size}
                        selected={size == @checks_page_size}
                      >
                        {size}
                      </option>
                    </select>
                  </label>
                </form>
              </div>
              <p
                :if={@checks_total > 0}
                id="recent-checks-range"
                class="mt-1 text-data text-text-tertiary"
              >
                {checks_range_label(@checks_page, @checks_page_size, @checks_total)}
              </p>
              <p
                :if={@recent_checks == []}
                id="recent-checks-empty"
                class="mt-5 text-body text-text-secondary"
              >
                No checks recorded yet.
              </p>
              <div :if={@recent_checks != []} class="mt-3 divide-y divide-border-subtle">
                <div
                  :for={check <- @recent_checks}
                  id={"check-#{check.id}"}
                  class="grid min-h-11 grid-cols-[auto_minmax(0,1fr)] items-center gap-3 py-2 [@media(pointer:coarse)]:min-h-12"
                >
                  <.status_badge
                    tone={check_tone(check.status)}
                    label={String.capitalize(check.status)}
                  />
                  <span class="flex min-w-0 flex-wrap items-center justify-end gap-x-3 gap-y-1 text-data tabular-nums text-text-secondary">
                    <span :if={check.status_code}>HTTP {check.status_code}</span>
                    <span :if={check.latency_ms}>{check.latency_ms} ms</span>
                    <time datetime={DateTime.to_iso8601(check.checked_at)}>
                      {Calendar.strftime(check.checked_at, "%Y-%m-%d %H:%M:%S UTC")}
                    </time>
                  </span>
                </div>
              </div>
              <nav
                :if={@recent_checks != []}
                aria-label="Recent checks pages"
                class="mt-4 flex items-center justify-end gap-2"
              >
                <.button
                  id="checks-prev-page"
                  type="button"
                  variant="secondary"
                  disabled={@checks_page == 0}
                  phx-click="set_checks_page"
                  phx-value-page={@checks_page - 1}
                >
                  Prev
                </.button>
                <.button
                  id="checks-next-page"
                  type="button"
                  variant="secondary"
                  disabled={not @checks_has_more?}
                  phx-click="set_checks_page"
                  phx-value-page={@checks_page + 1}
                >
                  Next
                </.button>
              </nav>
            </section>

            <section
              id="monitor-incidents"
              class="min-w-0 rounded-structural border border-border-default bg-surface-raised p-5 md:col-span-5 lg:col-span-4"
              aria-labelledby="monitor-incidents-heading"
            >
              <div class="flex items-baseline justify-between gap-3">
                <h2
                  id="monitor-incidents-heading"
                  class="text-heading-03 font-semibold text-text-primary"
                >
                  Incidents
                </h2>
                <p
                  id="stat-incident-count"
                  class="font-mono text-data tabular-nums text-text-secondary"
                >
                  {@activity.incident_count} in the last {window_words(@window)}
                </p>
              </div>
              <p
                :if={@incidents == []}
                id="monitor-incidents-empty"
                class="mt-4 text-body text-text-secondary"
              >
                No incidents recorded.
              </p>
              <div :if={@incidents != []} class="mt-3 divide-y divide-border-subtle">
                <div
                  :for={incident <- @incidents}
                  id={"detail-incident-#{incident.id}"}
                  class="flex min-h-11 flex-wrap items-center justify-between gap-3 py-2 [@media(pointer:coarse)]:min-h-12"
                >
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <.status_badge
                        tone={if incident.status == :open, do: "error", else: "neutral"}
                        label={incident_status_label(incident)}
                      />
                      <span class="text-data text-text-primary">
                        {incident.cause}<span :if={incident.environment}> ({incident.environment})</span>
                      </span>
                    </div>
                    <p class="mt-1 text-data text-text-tertiary">
                      <time datetime={DateTime.to_iso8601(incident.started_at)}>
                        {Calendar.strftime(incident.started_at, "%Y-%m-%d %H:%M UTC")}
                      </time><span>, {incident_duration_label(incident)}</span>
                    </p>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <%!-- The chart the screen is built around takes the whole page, and
                the reference table under it reads in two columns instead of
                one tall rail. A heartbeat check-in carries no round trip, so
                the latency panel is absent for that type rather than present
                and empty. --%>
          <section
            :if={latency_panel?(@row.monitor, @activity, @metrics)}
            id="monitor-latency"
            class="grid min-w-0 gap-5 rounded-structural border border-border-default bg-surface-raised p-5"
            aria-labelledby="monitor-latency-heading"
          >
            <h2 id="monitor-latency-heading" class="text-heading-03 font-semibold text-text-primary">
              Latency
            </h2>
            <.latency_analysis metrics={@metrics} />
            <.response_time_panel
              :if={@metrics.state != :error and @metrics.latency_count > 0}
              row={@row}
              activity={@activity}
              window={@window}
            />
          </section>

          <section
            id="monitor-config"
            class="min-w-0 rounded-structural border border-border-default bg-surface-raised p-5"
            aria-labelledby="monitor-config-heading"
          >
            <div class="flex items-center gap-2">
              <h2
                id="monitor-config-heading"
                class="text-heading-03 font-semibold text-text-primary"
              >
                Configuration
              </h2>
              <.tooltip
                id="monitor-config-help"
                text="Ask your agent to change this setting."
                placement="bottom"
              >
                <button
                  type="button"
                  class="inline-flex h-control-md items-center rounded-control text-text-tertiary hover:text-text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  aria-label="How to change monitor settings"
                  aria-describedby="monitor-config-help"
                >
                  <.icon name="hero-question-mark-circle" class="size-4" />
                </button>
              </.tooltip>
            </div>
            <div class="grid min-w-0 gap-x-10 lg:grid-cols-2">
              <%!-- Stacked in one column, the halves need the rule the split
                    would otherwise swallow at the seam. --%>
              <div
                :for={{column, index} <- Enum.with_index(config_columns(@row.monitor, @row.config))}
                class={["min-w-0", index > 0 && "border-t border-border-default lg:border-t-0"]}
              >
                <.definition_list>
                  <:row :for={{label, value} <- column} label={label}>
                    {value}
                  </:row>
                </.definition_list>
              </div>
            </div>
          </section>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  attr :reliability, :map, default: nil

  defp reliability_panel(%{reliability: nil} = assigns), do: ~H""

  defp reliability_panel(%{reliability: %{state: :error, error: error}} = assigns) do
    assigns = assign(assigns, :reliability_error, error)

    ~H"""
    <section
      id="monitor-reliability"
      class="border-t border-border-subtle pt-5"
      aria-labelledby="monitor-reliability-heading"
    >
      <p class="text-body font-semibold text-text-primary">Reliability objective</p>
      <p class="mt-2 text-data text-status-error-ink">
        Reliability history is unavailable. Try again later.
      </p>
      <p class="mt-1 break-words text-label text-text-tertiary">
        Error: {inspect(@reliability_error)}
      </p>
    </section>
    """
  end

  defp reliability_panel(assigns) do
    ~H"""
    <%!-- The objective is context for the answer above, not a second answer,
          so it states itself in one sentence and keeps its evidence behind a
          disclosure. The 90-day history draws through the shared day grid
          rather than a hand-rolled strip of divs. --%>
    <section
      :if={@reliability.target}
      id="monitor-reliability"
      class="border-t border-border-subtle pt-4"
      aria-labelledby="monitor-reliability-heading"
    >
      <details id="monitor-reliability-disclosure">
        <summary
          id="monitor-reliability-heading"
          class="cursor-pointer py-1 text-data text-text-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          {reliability_sentence(@reliability)}
        </summary>

        <div class="grid gap-5 pt-4">
          <.data_display
            id="reliability-day-grid"
            title="Reliability, last 90 days"
            kind={:day_grid}
            variant={:full}
            state={if(@reliability.days == [], do: :empty, else: :ready)}
            data={reliability_grid_data(@reliability.days)}
            unit="day"
            range={%{start: "90 days ago", end: "Today"}}
            legend={reliability_legend(@reliability.days)}
            summary={"Target #{format_slo_percent(@reliability.target)}, attained #{format_slo_percent(@reliability.summary.uptime)}."}
            table_columns={["Day", "State", "Evidence"]}
            description="One square per day of reliability evidence. The current day is partial. Use the table to read each day."
          />

          <div
            :if={@reliability.budget}
            id="monitor-error-budget"
            class={["border-t border-border-subtle pt-4", budget_text_class(@reliability.budget)]}
            aria-labelledby="monitor-error-budget-heading"
          >
            <div class="flex flex-wrap items-start justify-between gap-2">
              <h3 id="monitor-error-budget-heading" class="text-body font-semibold">
                Error budget
              </h3>
              <span class="text-data font-medium">
                {budget_state_label(@reliability.budget.state)}
              </span>
            </div>
            <p :if={@reliability.budget.evidence_state != :ready} class="mt-2 text-data">
              Not enough evidence to report attainment or burn rate yet.
            </p>
            <dl
              :if={@reliability.budget.evidence_state == :ready}
              class="mt-3 grid gap-x-6 gap-y-2 text-data sm:grid-cols-2 lg:grid-cols-4"
            >
              <div>
                <dt class="text-text-tertiary">Allowed downtime</dt><dd class="font-semibold tabular-nums">
                  {format_reliability_duration(@reliability.budget.allowed_downtime_microseconds)}
                </dd>
              </div>
              <div>
                <dt class="text-text-tertiary">Spent</dt><dd class="font-semibold tabular-nums">
                  {format_reliability_duration(@reliability.budget.spent_downtime_microseconds)}
                </dd>
              </div>
              <div>
                <dt class="text-text-tertiary">Remaining</dt><dd class="font-semibold tabular-nums">
                  {format_reliability_duration(@reliability.budget.remaining_downtime_microseconds)}
                </dd>
              </div>
              <div>
                <dt class="text-text-tertiary">
                  Burn, last {@reliability.budget.burn_window_days} days
                </dt><dd class="font-semibold tabular-nums">
                  {format_burn_rate(@reliability.budget.burn_rate)}
                </dd>
              </div>
            </dl>
            <p class="mt-3 text-label text-text-tertiary">
              Budget month ends {Calendar.strftime(@reliability.budget.month_end, "%d %b %Y")}. Alert threshold: {format_burn_rate(
                @reliability.budget.alert_threshold
              )} burn.
            </p>
          </div>
        </div>
      </details>
    </section>
    """
  end

  # One sentence carrying every value the old three-cell strip printed.
  defp reliability_sentence(reliability) do
    "Reliability objective: target #{format_slo_percent(reliability.target)}, attained #{format_slo_percent(reliability.summary.uptime)} over 90 days, #{incident_words(reliability.summary.incident_count)}, #{format_reliability_duration(reliability.summary.downtime_microseconds)} of downtime."
  end

  defp incident_words(1), do: "1 incident"
  defp incident_words(count), do: "#{count} incidents"

  defp reliability_grid_data(days) do
    Enum.map(days, fn day ->
      label = Calendar.strftime(day.day, "%d %b")
      state = reliability_day_label(day)
      evidence = reliability_day_detail(day)
      sentence = "#{label}, #{state}, #{evidence}"

      %{
        id: Date.to_iso8601(day.day),
        label: label,
        value: state,
        tone: reliability_day_tone(day.state),
        tooltip: sentence,
        aria_label: sentence,
        table_cells: [label, state, evidence]
      }
    end)
  end

  defp reliability_legend(days) do
    days
    |> Enum.frequencies_by(& &1.state)
    |> Enum.sort_by(fn {state, _count} -> reliability_legend_order(state) end)
    |> Enum.map(fn {state, count} ->
      %{label: reliability_state_word(state), tone: reliability_day_tone(state), count: count}
    end)
  end

  defp reliability_legend_order(:healthy), do: 0
  defp reliability_legend_order(:degraded), do: 1
  defp reliability_legend_order(:partial), do: 2
  defp reliability_legend_order(:incident), do: 3
  defp reliability_legend_order(:paused), do: 4
  defp reliability_legend_order(_state), do: 5

  defp reliability_state_word(:healthy), do: "Healthy"
  defp reliability_state_word(:degraded), do: "Degraded"
  defp reliability_state_word(:partial), do: "Partial"
  defp reliability_state_word(:incident), do: "Incident"
  defp reliability_state_word(:paused), do: "Paused"
  defp reliability_state_word(:missing), do: "No evidence"

  defp reliability_day_tone(:healthy), do: "live"
  defp reliability_day_tone(:degraded), do: "late"
  defp reliability_day_tone(:partial), do: "late"
  defp reliability_day_tone(:incident), do: "error"
  defp reliability_day_tone(:paused), do: "paused"
  defp reliability_day_tone(:missing), do: "neutral"

  defp reliability_day_label(%{state: :missing}), do: "No evidence"
  defp reliability_day_label(%{state: :paused, pause_count: count}), do: "Paused (#{count})"

  defp reliability_day_label(%{state: :incident, incident_count: count, pause_count: pause_count})
       when pause_count > 0,
       do: "Incident (#{count}), paused (#{pause_count})"

  defp reliability_day_label(%{state: :incident, incident_count: count}),
    do: "Incident (#{count})"

  defp reliability_day_label(%{state: :partial}), do: "Partial, retention gap"

  defp reliability_day_label(%{state: :degraded, pause_count: pause_count}) when pause_count > 0,
    do: "Degraded, paused"

  defp reliability_day_label(%{state: :degraded}), do: "Degraded"

  defp reliability_day_label(%{state: :healthy, pause_count: pause_count}) when pause_count > 0,
    do: "Healthy, paused"

  defp reliability_day_label(%{state: :healthy}), do: "Healthy"

  defp reliability_day_detail(day) do
    uptime =
      case day.uptime do
        value when is_number(value) -> "#{Float.round(value * 100, 2)}% uptime"
        _ -> "No uptime"
      end

    monitored = format_reliability_duration(day.monitored_microseconds)
    evidence = if day.check_count > 0, do: "#{day.check_count} checks", else: "No checks"
    pauses = maintenance_pause_detail(day.pause_count)
    "#{uptime}, monitored #{monitored}, #{evidence}, #{pauses}"
  end

  defp maintenance_pause_detail(0), do: "no maintenance pauses"
  defp maintenance_pause_detail(1), do: "1 maintenance pause"
  defp maintenance_pause_detail(count), do: "#{count} maintenance pauses"

  defp format_slo_percent(nil), do: "Not enough evidence"

  defp format_slo_percent(value) when is_number(value) do
    value = Float.round(value * 100, 4)
    if value == trunc(value), do: "#{trunc(value)}%", else: "#{value}%"
  end

  defp format_reliability_duration(0), do: "0 seconds"

  defp format_reliability_duration(microseconds) when is_integer(microseconds) do
    seconds = div(microseconds, 1_000_000)

    cond do
      seconds >= 86_400 -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      seconds >= 60 -> "#{div(seconds, 60)}m"
      true -> "under a minute"
    end
  end

  defp format_reliability_duration(_), do: "Not available"

  defp format_burn_rate(nil), do: "Not available"
  defp format_burn_rate(value) when is_number(value), do: "#{Float.round(value, 2)}x"

  defp budget_state_label(:healthy), do: "Within budget"
  defp budget_state_label(:alert), do: "Burn alert"
  defp budget_state_label(:exhausted), do: "Budget exhausted"
  defp budget_state_label(:insufficient), do: "Insufficient evidence"

  defp budget_text_class(%{state: state}) when state in [:alert, :exhausted],
    do: "text-status-error-ink"

  defp budget_text_class(%{state: :insufficient}), do: "text-text-secondary"
  defp budget_text_class(_budget), do: "text-text-primary"

  defp load_detail_data(socket) do
    scope = project_scope(socket)
    monitor = socket.assigns.monitor
    window = socket.assigns.window

    try do
      {row, activity} = MonitorOverview.activity_for(monitor, scope, window)
      metrics = load_metrics(row, activity, scope, window)
      reliability = load_reliability(row.monitor, scope)

      checks_page =
        MonitorCheck
        |> Ash.Query.for_read(:list_for_monitor, %{monitor_id: monitor.id}, actor: scope)
        |> Ash.Query.filter(
          org_id == ^scope.org_id and project_id == ^scope.project_id and
            monitor_id == ^monitor.id
        )
        |> Ash.Query.sort(checked_at: :desc, id: :desc)
        |> Ash.Query.page(
          limit: socket.assigns.checks_page_size,
          offset: socket.assigns.checks_page * socket.assigns.checks_page_size,
          count: true
        )
        |> Ash.read!(actor: scope)

      socket
      |> assign(:monitor, row.monitor)
      |> assign(:row, row)
      |> assign(:activity, activity)
      |> assign(:metrics, metrics)
      |> assign(:reliability, reliability)
      |> assign(:recent_checks, checks_page.results)
      |> assign(:checks_total, checks_page.count)
      |> assign(:checks_has_more?, checks_page.more?)
      |> load_incidents()
      |> assign(:loading, false)
      |> assign(:load_failed?, false)
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        require Logger
        Logger.error("monitor detail load failed: #{Exception.message(error)}")
        assign(socket, loading: false, load_failed?: true)
    end
  end

  defp load_metrics(row, activity, scope, window) do
    now = DateTime.utc_now()

    annotations =
      Enum.map(activity.incidents, fn incident ->
        %{
          id: incident.id,
          at: incident.started_at,
          label: "Incident, #{Calendar.strftime(incident.started_at, "%Y-%m-%d")}"
        }
      end)

    release_annotations =
      scope
      |> DeploymentCorrelation.markers(row.monitor.environment,
        now: now,
        window_seconds: marker_window_seconds(window)
      )
      |> Enum.map(fn marker ->
        Map.put(marker, :label, "Deploy #{marker.version}")
      end)

    case MonitorMetrics.load(row.monitor, row.config, scope, window,
           annotations: annotations ++ release_annotations,
           now: now
         ) do
      {:ok, metrics} -> metrics
      {:error, reason} -> MonitorMetrics.error("Latency data unavailable", reason)
    end
  end

  defp marker_window_seconds("24h"), do: 86_400
  defp marker_window_seconds("7d"), do: 7 * 86_400
  defp marker_window_seconds("30d"), do: 30 * 86_400
  defp marker_window_seconds("90d"), do: 90 * 86_400
  defp marker_window_seconds(_window), do: 86_400

  defp load_reliability(monitor, scope) do
    case Reliability.histories([monitor], scope) do
      {:ok, histories} ->
        Map.get(histories, monitor.id, %{state: :error, error: :not_found})

      {:error, reason} ->
        require Logger
        Logger.warning("monitor reliability unavailable: #{inspect(reason)}")
        %{state: :error, error: reason}
    end
  end

  defp load_incidents(socket) do
    scope = project_scope(socket)
    monitor = socket.assigns.monitor

    incidents =
      Incident
      |> Ash.Query.filter(
        org_id == ^scope.org_id and project_id == ^scope.project_id and monitor_id == ^monitor.id
      )
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(20)
      |> Ash.read!(actor: scope)

    assign(socket, :incidents, incidents)
  end

  defp config_rows(monitor, config) do
    [
      {"Type", monitor.type},
      {"Environment", monitor.environment || "-"},
      {"SLO target", format_slo_target(monitor.slo_target)},
      {"Failure threshold", to_string(monitor.failure_threshold)},
      {"Resend after failed checks", to_string(monitor.resend_after_failed_checks)}
    ] ++ type_rows(monitor.type, config)
  end

  defp format_slo_target(nil), do: "No objective"
  defp format_slo_target(target), do: "#{Float.round(target * 100, 4)}%"

  defp type_rows(_type, nil), do: []

  defp type_rows(type, config) when type in ["http", "keyword"] do
    [
      {"URL", MonitorDisplay.sanitize_url(config.url)},
      {"Method", config.method},
      {"Expected status", format_expected_status(config.expected_status)},
      {"Keyword match", format_keyword_match(config.keyword_match)},
      {"Headers", MonitorDisplay.format_headers(config.headers)},
      {"Follow redirects", boolean_label(config.follow_redirects)},
      {"Maximum redirects", to_string(config.max_redirects)},
      {"Interval", humanize_interval(config.interval_seconds)},
      {"Retry interval", humanize_interval(config.retry_interval_seconds)},
      {"Timeout", humanize_interval(config.timeout_seconds)},
      {"Response threshold", format_milliseconds(config.response_time_threshold_ms)},
      {"SSL expiry warnings", format_days(config.ssl_expiry_warn_days)},
      {"Domain expiry warnings", format_days(config.domain_expiry_warn_days)}
    ]
  end

  defp type_rows("heartbeat", config) do
    [
      {"Schedule",
       config.cron_expression || "Every #{humanize_interval(config.interval_seconds)}"},
      {"Grace period", humanize_interval(config.grace_period_seconds)},
      {"Timezone", config.timezone},
      {"Track duration", boolean_label(config.track_duration)},
      {"Expected duration", humanize_interval(config.expected_duration_seconds)},
      {"Token prefix", config.heartbeat_token_prefix}
    ]
  end

  defp type_rows("tcp", config) do
    [
      {"Hostname", config.hostname},
      {"Port", to_string(config.port)},
      {"Interval", humanize_interval(config.interval_seconds)},
      {"Retry interval", humanize_interval(config.retry_interval_seconds)},
      {"Timeout", humanize_interval(config.timeout_seconds)}
    ]
  end

  defp type_rows("dns", config) do
    [
      {"Hostname", config.hostname},
      {"Record type", config.record_type},
      {"Expected values", Enum.join(config.expected_values, ", ")},
      {"Match mode", config.match_mode},
      {"Interval", humanize_interval(config.interval_seconds)},
      {"Retry interval", humanize_interval(config.retry_interval_seconds)}
    ]
  end

  defp format_expected_status(nil), do: "-"

  defp format_expected_status(%{"kind" => "exact", "code" => code}), do: "Exactly #{code}"

  defp format_expected_status(%{"kind" => "range", "min" => min, "max" => max}),
    do: "#{min} to #{max}"

  defp format_expected_status(value), do: format_map(value)

  defp format_keyword_match(nil), do: "-"

  defp format_keyword_match(%{"value" => value}) when is_binary(value), do: value

  defp format_keyword_match(value), do: format_map(value)

  defp format_map(value) when value == %{}, do: "-"
  defp format_map(value) when is_map(value), do: inspect(value, printable_limit: :infinity)
  defp format_map(value), do: to_string(value)

  defp boolean_label(true), do: "Yes"
  defp boolean_label(false), do: "No"
  defp boolean_label(nil), do: "-"

  defp format_milliseconds(nil), do: "-"
  defp format_milliseconds(value), do: "#{value} ms"

  defp format_days(nil), do: "-"
  defp format_days([]), do: "-"
  defp format_days(days), do: Enum.map_join(days, ", ", &to_string/1)

  # Render a raw second count as human copy ("30 seconds", "5 minutes", "1 hour")
  # instead of a bare "300s". Falls back to seconds for values that are not a
  # whole number of minutes or hours.
  defp humanize_interval(nil), do: "unset"

  defp humanize_interval(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> pluralize(seconds, "second")
      rem(seconds, 3600) == 0 -> pluralize(div(seconds, 3600), "hour")
      rem(seconds, 60) == 0 -> pluralize(div(seconds, 60), "minute")
      true -> pluralize(div(seconds, 60), "minute") <> " #{rem(seconds, 60)} sec"
    end
  end

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(count, unit), do: "#{count} #{unit}s"

  defp check_tone("up"), do: "success"
  defp check_tone("down"), do: "error"
  defp check_tone("degraded"), do: "warning"
  defp check_tone(_status), do: "neutral"

  # The hero state comes from the same windowed evidence the strip below it
  # draws, not from `last_known_status`. A monitor whose checks stopped
  # arriving still carries "up" as its last known status, and headlining
  # "Operational" over a strip full of missing intervals is the one thing this
  # screen must never do.
  # Configuration is reference material, so it takes the page width under the
  # evidence rather than a tall rail beside it. The rows split down the middle
  # and each half keeps its own rules, so a reader still scans one label column
  # at a time. An odd count leaves the longer half on the left, where reading
  # starts.
  defp config_columns(monitor, config) do
    rows = config_rows(monitor, config)
    Enum.chunk_every(rows, ceil(length(rows) / 2))
  end

  # A heartbeat check-in reports that a job ran, not how long a request took,
  # so it never records a round trip. The panel is worth its space only when
  # this monitor type can produce a reading.
  defp latency_panel?(monitor, activity, metrics) do
    activity.check_count > 0 and
      (monitor.type != "heartbeat" or metrics.state == :error or
         metrics.latency_count > 0)
  end

  defp detail_state(row, activity) do
    Map.get(activity || %{}, :state) || Map.get(row, :state) || fallback_detail_state(row.monitor)
  end

  defp fallback_detail_state(%{status: "paused"}), do: :paused
  defp fallback_detail_state(%{last_known_status: "down"}), do: :down
  defp fallback_detail_state(%{last_known_status: "degraded"}), do: :degraded
  defp fallback_detail_state(%{last_known_status: "up"}), do: :up
  defp fallback_detail_state(_monitor), do: :waiting

  defp detail_state_label(:up), do: "Operational"
  defp detail_state_label(:down), do: "Down"
  defp detail_state_label(:degraded), do: "Degraded"
  defp detail_state_label(:late), do: "Late"
  defp detail_state_label(:missing), do: "No recent checks"
  defp detail_state_label(:paused), do: "Paused"
  defp detail_state_label(:waiting), do: "Waiting"
  defp detail_state_label(_state), do: "Unknown"

  defp detail_dot_class(:up), do: "bg-status-live"
  defp detail_dot_class(:down), do: "bg-status-error"
  defp detail_dot_class(state) when state in [:degraded, :late], do: "bg-status-late"
  defp detail_dot_class(:paused), do: "bg-status-paused"
  defp detail_dot_class(_state), do: "bg-status-neutral"

  # The last check's result first, its latency when there is one: "Up, 84 ms"
  # rather than "No data" beside a check that plainly happened.
  defp latest_check_value(nil), do: "No check yet"

  defp latest_check_value(%{status: status, latency_ms: latency}) when is_integer(latency),
    do: "#{check_word(status)}, #{latency} ms"

  defp latest_check_value(%{status: status}), do: check_word(status)

  defp check_word(status) when is_binary(status), do: String.capitalize(status)
  defp check_word(_status), do: "Recorded"

  # "Waiting for the first check" only when the monitor has never reported.
  # Otherwise the sentence names the range, the lifetime last check, and the
  # reason the monitor is late when it is.
  defp range_empty_sentence(row, activity, window) do
    case row.latest_check || monitor_last_check(row.monitor) do
      nil ->
        "Waiting for the first check."

      %{checked_at: checked_at} ->
        "No checks in the last #{window_words(window)}. Last check #{relative_words(checked_at)}." <>
          late_reason(row, activity)
    end
  end

  defp monitor_last_check(%{last_check_at: %DateTime{} = at}), do: %{checked_at: at}
  defp monitor_last_check(_monitor), do: nil

  defp late_reason(row, activity) do
    case {Map.get(activity, :state), row.interval_seconds} do
      {:late, seconds} when is_integer(seconds) ->
        " It runs every #{humanize_interval(seconds)}, so it is late. The next successful check clears this."

      {:late, _interval} ->
        " It is late. The next successful check clears this."

      _other ->
        ""
    end
  end

  defp relative_words(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "under a minute ago"
      seconds < 3600 -> plural_ago(div(seconds, 60), "minute")
      seconds < 86_400 -> plural_ago(div(seconds, 3600), "hour")
      true -> plural_ago(div(seconds, 86_400), "day")
    end
  end

  defp relative_words(%NaiveDateTime{} = dt),
    do: relative_words(DateTime.from_naive!(dt, "Etc/UTC"))

  defp plural_ago(1, unit), do: "1 #{unit} ago"
  defp plural_ago(count, unit), do: "#{count} #{unit}s ago"

  defp latest_latency_hint(nil), do: nil

  defp latest_latency_hint(%{status_code: nil, checked_at: checked_at}),
    do: relative_time(checked_at)

  defp latest_latency_hint(%{status_code: status_code, checked_at: checked_at}),
    do: "HTTP #{status_code}, #{relative_time(checked_at)}"

  defp relative_time(nil), do: "No data"

  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp normalize_window(window) when window in @windows, do: window
  defp normalize_window(_window), do: "24h"

  # Lifecycle (open/resolved) and acknowledgement are distinct: an
  # acknowledged-but-open incident must still read "Open", not "Acknowledged".
  defp incident_status_label(%{status: :open, acknowledged_at: nil}), do: "Open"
  defp incident_status_label(%{status: :open}), do: "Open, acknowledged"
  defp incident_status_label(%{status: :resolved}), do: "Resolved"

  defp normalize_checks_page_size(size) when size in @checks_page_sizes, do: size

  defp normalize_checks_page_size(size) when is_binary(size) do
    case Integer.parse(size) do
      {int, ""} -> normalize_checks_page_size(int)
      _ -> List.first(@checks_page_sizes)
    end
  end

  defp normalize_checks_page_size(_size), do: List.first(@checks_page_sizes)

  defp normalize_checks_page(page) when is_integer(page) and page >= 0, do: page

  defp normalize_checks_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp normalize_checks_page(_page), do: 0

  defp checks_range_label(page, page_size, total) do
    first = page * page_size + 1
    last = min(first + page_size - 1, total)
    "Showing #{first}-#{last} of #{total}"
  end

  defp scope_for(scope, nil), do: scope
  defp scope_for(scope, project), do: Alplus.Scope.put_project(scope, project.id)

  defp project_scope(socket), do: scope_for(socket.assigns.scope, socket.assigns.project)

  defp detail_path(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "checks_size" => socket.assigns.checks_page_size,
        "checks_page" => socket.assigns.checks_page
      }
      |> Map.merge(overrides)

    ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{socket.assigns.project.public_token}/monitor/#{socket.assigns.monitor.id}?#{params}"
  end

  defp subscribe_to_project(socket, project) do
    next_topic = project && "monitor:#{project.id}"
    previous_topic = socket.assigns.monitor_topic

    if connected?(socket) and previous_topic != next_topic do
      if previous_topic, do: Phoenix.PubSub.unsubscribe(Alplus.PubSub, previous_topic)
      if next_topic, do: Phoenix.PubSub.subscribe(Alplus.PubSub, next_topic)
    end

    assign(socket, :monitor_topic, next_topic)
  end
end
