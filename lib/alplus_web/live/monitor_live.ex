defmodule AlplusWeb.MonitorLive do
  @moduledoc """
  Monitor status for the project named by the route.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.MonitorActivityComponents
  import AlplusWeb.Format

  alias Alplus.Monitoring.MonitorOverview
  alias AlplusWeb.AgentConnection

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Monitors", active: :monitor) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       socket
       |> assign(:projects, [project])
       |> assign(:project, project)
       |> assign(:environment, nil)
       |> assign(:window, "24h")
       |> assign(:query, nil)
       |> assign(:status_filter, nil)
       |> assign(:type_filter, nil)
       |> assign(:cursor, nil)
       |> assign(:view, "all")
       |> assign(:invalid_filter, nil)
       |> assign(:overview_loader, overview_loader(session))
       |> assign(:overview, nil)
       |> assign(:agent_state, nil)
       |> assign(:monitor_rows, [])
       |> assign(:environments, [])
       |> assign(:monitor_topic, nil)
       |> assign(:stat_total, 0)
       |> assign(:stat_up, 0)
       |> assign(:stat_down, 0)
       |> assign(:stat_paused, 0)
       |> assign(:stat_checked, 0)
       |> assign(:loading, false)
       |> assign(:load_failed?, false)
       |> stream(:monitors, [])
       |> stream(:incidents, [])}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    project = socket.assigns.project
    requested_view = normalize_value(params["view"])
    {filters, invalid_filter} = overview_filters(params)

    socket =
      socket
      |> assign(:project, project)
      |> assign(:environment, filters.environment)
      |> assign(:window, filters.window)
      |> assign(:query, filters.query)
      |> assign(:status_filter, filters.status)
      |> assign(:type_filter, filters.type)
      |> assign(:cursor, filters.cursor)
      |> assign(:view, filters.view || "all")
      |> assign(:invalid_filter, invalid_filter)
      |> assign(:loading, not is_nil(project))
      |> subscribe_to_project()

    socket =
      cond do
        is_nil(project) ->
          clear_monitor_data(socket)

        invalid_filter ->
          socket |> clear_monitor_data() |> assign(:invalid_filter, invalid_filter)

        true ->
          load_monitor_data(socket)
      end

    socket =
      if is_nil(requested_view) and socket.assigns.overview do
        default = default_view(socket.assigns.overview)

        socket
        |> assign(:view, default)
        |> then(fn socket ->
          if default == "all", do: socket, else: load_monitor_data(socket)
        end)
      else
        socket
      end

    socket =
      if is_nil(requested_view) and connected?(socket) and socket.assigns.view != "all" do
        push_patch(socket, to: monitor_path(socket, current_filter_params(socket)))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("pick_environment", %{"environment" => ""}, socket) do
    {:noreply, patch_filter(socket, "environment", nil)}
  end

  def handle_event("pick_environment", %{"environment" => environment}, socket) do
    {:noreply, patch_filter(socket, "environment", environment)}
  end

  def handle_event("pick_project", %{"project_id" => project_id}, socket)
      when is_binary(project_id) do
    case Enum.find(socket.assigns.nav_projects, &(&1.id == project_id)) do
      nil -> {:noreply, socket}
      project -> {:noreply, push_navigate(socket, to: monitor_project_path(socket, project))}
    end
  end

  def handle_event("pick_project", _params, socket), do: {:noreply, socket}

  # The page header's time range (design source §04). It drives exactly the
  # same filter the GET form already carried, so the window still round-trips
  # through the URL and every read stays bounded by `overview_filters/1`.
  def handle_event("pick_window", %{"window" => window}, socket)
      when window in ["24h", "7d", "30d", "90d"] do
    {:noreply, patch_filter(socket, "window", window)}
  end

  def handle_event("pick_window", _params, socket), do: {:noreply, socket}

  # The in-page heartbeat filter. It writes the same `type` query parameter the
  # filter form already carried, so the URL still round-trips and every read
  # stays bounded by `overview_filters/1`.
  def handle_event("pick_monitor_kind", %{"tab" => "heartbeat"}, socket) do
    {:noreply, patch_filter(socket, "type", "heartbeat")}
  end

  def handle_event("pick_monitor_kind", %{"tab" => _all}, socket) do
    {:noreply, patch_filter(socket, "type", nil)}
  end

  # One live filter grammar across Monitor, Observe and Changelog: the form
  # patches in place instead of reloading the page, so the Apply button that
  # used to be a second primary on this view is gone. The window stays out of
  # this map because the page header owns it.
  def handle_event("filter_monitors", params, socket) do
    case overview_filters(params) do
      {_filters, invalid} when is_binary(invalid) ->
        # A hand-edited value reaches this handler the same way it reaches a
        # URL. Hold the current view rather than patching to something the
        # loader would reject.
        {:noreply, socket}

      {filters, nil} ->
        next =
          socket
          |> current_filter_params()
          |> Map.merge(%{
            "environment" => filters.environment,
            "query" => filters.query,
            "status" => filters.status,
            "type" => filters.type
          })
          |> Map.delete("cursor")
          |> compact_params()

        {:noreply, push_patch(socket, to: monitor_path(socket, next))}
    end
  end

  def handle_event("retry_monitors", _params, socket) do
    {:noreply, if(socket.assigns.project, do: load_monitor_data(socket), else: socket)}
  end

  @impl true
  def handle_info(
        {:monitor_updated, project_id},
        %{assigns: %{project: %{id: project_id}}} = socket
      ) do
    had_result_before? = socket.assigns.stat_checked > 0
    socket = load_monitor_data(socket)

    socket =
      if not had_result_before? and socket.assigns.stat_checked > 0 do
        put_flash(socket, :info, "Your first check result came in.")
      else
        socket
      end

    {:noreply, socket}
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
      nav_projects={@nav_projects}
      project_scoped={true}
      projects={@nav_projects}
      project={@project}
      environments={@environments}
      environment={@environment}
      center_content?={false}
      page_heading?={false}
      window={@project && @window}
    >
      <.console_page :if={@project} id="monitor-page">
        <:title>{page_answer(@view, @overview)}</:title>

        <div :if={@loading} id="monitors-loading">
          <.skeleton rows={5} />
        </div>

        <.error_boundary
          :if={not @loading && @load_failed?}
          id="monitors-error"
          retry="retry_monitors"
        >
          Monitor activity is unavailable. Existing monitors continue to run.
        </.error_boundary>

        <section
          :if={not @loading && @invalid_filter}
          id="invalid-monitor-filter"
          class="rounded-structural border border-status-late-border bg-status-late-bg p-4"
          aria-labelledby="invalid-monitor-filter-title"
        >
          <h2 id="invalid-monitor-filter-title" class="font-semibold text-status-late-ink">
            This {@invalid_filter} filter is not valid
          </h2>
          <.link
            navigate={workspace_path(@org_token, @project)}
            class="mt-3 inline-flex text-interactive-strong hover:underline"
          >
            Clear filters
          </.link>
        </section>

        <nav
          :if={not @loading && not @load_failed? && is_nil(@invalid_filter)}
          id="monitor-views"
          class="flex min-w-0 gap-5 overflow-x-auto border-b border-border-default"
          aria-label="Monitor views"
        >
          <.link
            :for={{value, label} <- monitor_views()}
            id={"monitor-view-#{value}"}
            patch={monitor_view_path(assigns, value)}
            aria-current={@view == value && "page"}
            class={[
              "relative inline-flex h-control-md shrink-0 items-center text-body font-medium text-text-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              @view == value &&
                "text-text-primary after:absolute after:inset-x-0 after:bottom-0 after:h-0.5 after:bg-interactive-primary"
            ]}
          >
            {label}
          </.link>
        </nav>

        <div
          :if={
            @view != "incidents" && not @loading && not @load_failed? &&
              is_nil(@invalid_filter)
          }
          id="monitor-workspace"
          class="flex flex-col gap-4"
        >
          <p :if={@overview} id="monitor-health-summary" class="sr-only">
            <span id="stat-up">Operational: {@overview.health.operational}</span>
          </p>

          <.first_run_card
            :if={@overview && @overview.health.total == 0}
            id="monitors-empty"
            title="No monitors yet"
            description="Uptime checks and heartbeats appear here once your agent creates one."
            state={@agent_state}
            task="Inspect this project's current health and recent changes."
            action_href={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
          />

          <div :if={@overview && @overview.health.total > 0} class="flex flex-col gap-4">
            <%!-- Search and filters appear only once a list is long enough
                  to need them. --%>
            <.filter_bar
              :if={
                @overview.health.total > 6 or not is_nil(@query) or not is_nil(@status_filter) or
                  not is_nil(@type_filter)
              }
              org_token={@org_token}
              project={@project}
              environments={@environments}
              environment={@environment}
              window={@window}
              query={@query}
              status={@status_filter}
              type={@type_filter}
              view={@view}
            />

            <div id="monitor-rows" class="flex min-w-0 flex-col gap-4">
              <.data_panel
                :if={@overview.filtered_total == 0}
                id="monitors-filtered-empty"
                padded
              >
                <p class="text-body text-text-secondary">
                  No monitors match these filters.
                  <.link
                    navigate={
                      workspace_path(@org_token, @project, %{"view" => @view, "window" => @window})
                    }
                    class="font-medium text-interactive-strong hover:text-interactive-strong-hover"
                  >
                    Clear filters
                  </.link>
                </p>
              </.data_panel>

              <.data_panel :if={@overview.filtered_total > 0} id="monitors-list">
                <.monitor_timeline_legend />
                <div data-density="dense" class="divide-y divide-border-subtle">
                  <.monitor_row
                    :for={row <- @monitor_rows}
                    row={row}
                    activity={@overview.activities[row.monitor.id]}
                    org_token={@org_token}
                    project={@project}
                    window={@window}
                  />
                </div>
              </.data_panel>
            </div>

            <nav :if={@overview.next_cursor} aria-label="Monitor pages" class="flex justify-end">
              <.button
                id="next-monitor-page"
                variant="secondary"
                patch={
                  workspace_path(
                    @org_token,
                    @project,
                    Map.put(current_filter_params(assigns), "cursor", @overview.next_cursor)
                  )
                }
              >
                Next page
              </.button>
            </nav>
          </div>
        </div>

        <div
          :if={@view == "incidents" && not @loading && not @load_failed?}
          id="monitor-incidents-view"
          class="flex flex-col gap-4"
        >
          <p :if={@overview} id="incidents-answer" class="sr-only">
            {incidents_answer(@overview.incidents)}
          </p>
          <.incidents_panel
            :if={@overview && @overview.incidents != []}
            incidents={@overview.incidents}
            org_token={@org_token}
            project={@project}
          />

          <.data_panel :if={@overview && @overview.incidents == []} id="incidents-open" padded>
            <p id="incidents-empty" class="flex items-center gap-3 text-body text-text-secondary">
              <span class="size-2 shrink-0 rounded-dot bg-status-live" aria-hidden="true"></span>
              {incident_coverage_sentence(@overview.health)}
            </p>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # The screen's title is its answer.
  defp page_answer("incidents", nil), do: "Recent incidents"
  defp page_answer("incidents", overview), do: incidents_answer(overview.incidents)
  defp page_answer(_view, nil), do: "Monitors"
  defp page_answer(_view, %{health: %{total: 0}}), do: "Monitors"
  defp page_answer(_view, %{health: health}), do: health_answer(health)

  defp health_answer(%{down: down}) when down > 0,
    do: "#{down} #{if down == 1, do: "monitor is", else: "monitors are"} down"

  defp health_answer(%{degraded: degraded}) when degraded > 0,
    do: "#{degraded} #{if degraded == 1, do: "monitor is", else: "monitors are"} degraded"

  defp health_answer(%{late: late, missing: missing}) when late + missing > 0 do
    count = late + missing
    "#{count} #{if count == 1, do: "monitor needs", else: "monitors need"} attention"
  end

  defp health_answer(%{waiting: waiting}) when waiting > 0,
    do:
      "#{waiting} #{if waiting == 1, do: "monitor is waiting for its", else: "monitors are waiting for their"} first check"

  defp health_answer(_health), do: "Everything is up"

  defp incident_coverage_sentence(_health), do: "No recent incidents."

  defp incidents_panel(assigns) do
    ~H"""
    <.data_panel id="incident-list" class="min-w-0">
      <div
        id="recent-incidents"
        class="divide-y divide-border-subtle"
        role="list"
        aria-label="Recent monitor incidents"
      >
        <div
          :for={incident <- @incidents}
          id={"incident-#{incident.id}"}
          class="flex h-11 flex-wrap items-center justify-between gap-x-6 gap-y-2 px-5 py-2 [@media(pointer:coarse)]:h-12"
          role="listitem"
        >
          <div class="flex min-w-0 items-center gap-x-3">
            <.status_dot
              tone={incident_state_tone(Map.get(incident, :monitor_state))}
              label={incident_state_label(Map.get(incident, :monitor_state))}
            />
            <.status_badge
              tone={if(incident.status == :open, do: "error", else: "neutral")}
              label={if(incident.status == :open, do: "Open", else: "Resolved")}
            />
            <span class="min-w-0 truncate text-body font-semibold text-text-primary">
              <%= if incident.monitor do %>
                {incident.monitor.name}
              <% else %>
                Monitor unavailable
              <% end %>
            </span>
            <span
              id={"incident-cause-#{incident.id}"}
              class="hidden font-mono text-data text-text-tertiary sm:inline"
            >
              {incident_duration_label(incident)}, since {format_utc_seconds(incident.started_at)}
            </span>
          </div>
          <.link
            :if={incident.monitor}
            id={"open-monitor-#{incident.id}"}
            navigate={incident_monitor_path(@org_token, @project, incident.monitor_id)}
            class="inline-flex min-h-target-min items-center text-body font-medium text-interactive-strong hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            Open monitor
          </.link>
        </div>
      </div>
    </.data_panel>
    """
  end

  defp load_monitor_data(socket) do
    scope = project_scope(socket)
    project = socket.assigns.project

    try do
      overview = socket.assigns.overview_loader.load!(project, scope, current_filters(socket))

      socket
      |> assign(:overview, overview)
      # Only the first-run card reads this, so the extra read happens only when
      # the screen has no monitor or incident evidence to draw.
      |> assign(:agent_state, first_run_agent_state(scope, overview))
      |> assign(:monitor_rows, overview.rows)
      |> assign(:environments, overview.environments)
      |> stream(:incidents, overview.incidents, reset: true)
      |> assign(:stat_total, overview.health.total)
      |> assign(:stat_up, overview.health.operational)
      |> assign(:stat_down, overview.health.down)
      |> assign(:stat_paused, overview.health.paused)
      |> assign(:stat_checked, overview.health.active - overview.health.waiting)
      |> assign(:loading, false)
      |> assign(:load_failed?, false)
    rescue
      error in [
        DBConnection.ConnectionError,
        DBConnection.OwnershipError,
        Postgrex.Error,
        Ash.Error.Invalid
      ] ->
        require Logger
        Logger.error("monitor list load failed: #{Exception.message(error)}")

        socket
        |> assign(:overview, nil)
        |> assign(:agent_state, nil)
        |> assign(:monitor_rows, [])
        |> assign(:environments, [])
        |> stream(:incidents, [], reset: true)
        |> assign(:stat_total, 0)
        |> assign(:stat_up, 0)
        |> assign(:stat_down, 0)
        |> assign(:stat_paused, 0)
        |> assign(:stat_checked, 0)
        |> assign(:loading, false)
        |> assign(:load_failed?, true)
    end
  end

  defp clear_monitor_data(socket) do
    socket
    |> assign(:environments, [])
    |> assign(:overview, nil)
    |> assign(:agent_state, nil)
    |> assign(:monitor_rows, [])
    |> stream(:monitors, [], reset: true)
    |> stream(:incidents, [], reset: true)
    |> assign(:stat_total, 0)
    |> assign(:stat_up, 0)
    |> assign(:stat_down, 0)
    |> assign(:stat_paused, 0)
    |> assign(:stat_checked, 0)
    |> assign(:loading, false)
    |> assign(:load_failed?, false)
  end

  defp first_run_agent_state(scope, overview) do
    if overview.health.total == 0, do: AgentConnection.state(scope)
  end

  defp project_scope(socket),
    do: Alplus.Scope.put_project(socket.assigns.scope, socket.assigns.project.id)

  # Chooses which `overview_loader/1` body to compile per env, rather than
  # branching at runtime on a `Mix.env() == :test` module attribute: `Mix`
  # is stripped from a release (a runtime `Mix.env/0` call would crash the
  # page), and folding that attribute into a runtime `if` left Dialyzer
  # seeing a permanently-true condition under the `MIX_ENV=test` PLT CI
  # dialyzes with, which it flags as an unreachable pattern.
  if Mix.env() == :test do
    defp overview_loader(session) do
      if session["monitor_overview_failure"] do
        Alplus.Test.UnavailableMonitorOverview
      else
        MonitorOverview
      end
    end
  else
    defp overview_loader(_session), do: MonitorOverview
  end

  defp subscribe_to_project(socket) do
    next_topic = socket.assigns.project && "monitor:#{socket.assigns.project.id}"
    previous_topic = socket.assigns.monitor_topic

    if connected?(socket) and previous_topic != next_topic do
      if previous_topic, do: Phoenix.PubSub.unsubscribe(Alplus.PubSub, previous_topic)
      if next_topic, do: Phoenix.PubSub.subscribe(Alplus.PubSub, next_topic)
    end

    assign(socket, :monitor_topic, next_topic)
  end

  defp normalize_environment(nil), do: nil
  defp normalize_environment(""), do: nil
  defp normalize_environment(environment), do: environment

  defp overview_filters(params) do
    filters = %{
      environment: normalize_environment(params["environment"]),
      window: normalize_value(params["window"]) || "24h",
      query: normalize_value(params["query"]),
      status: normalize_value(params["status"]),
      type: normalize_value(params["type"]),
      cursor: normalize_value(params["cursor"]),
      view: normalize_value(params["view"])
    }

    invalid =
      cond do
        filters.window not in ["24h", "7d", "30d", "90d"] ->
          "time window"

        filters.status not in [
          nil,
          "active",
          "up",
          "down",
          "degraded",
          "late",
          "missing",
          "paused",
          "waiting"
        ] ->
          "status"

        filters.view not in [nil, "all", "attention", "healthy", "incidents"] ->
          "view"

        filters.type not in [nil, "http", "keyword", "heartbeat", "tcp", "dns"] ->
          "monitor type"

        filters.query && String.length(filters.query) > 200 ->
          "search query"

        filters.environment && String.length(filters.environment) > 64 ->
          "environment"

        true ->
          nil
      end

    {filters, invalid}
  end

  defp normalize_value(nil), do: nil
  defp normalize_value(""), do: nil
  defp normalize_value(value), do: String.trim(value)

  defp current_filters(socket) do
    %{
      environment: socket.assigns.environment,
      window: socket.assigns.window,
      query: socket.assigns.query,
      status: socket.assigns.status_filter,
      type: socket.assigns.type_filter,
      cursor: socket.assigns.cursor,
      view: socket.assigns.view
    }
  end

  defp patch_filter(socket, key, value) do
    params =
      socket
      |> current_filter_params()
      |> Map.put(key, value)
      |> Map.delete("cursor")
      |> compact_params()

    push_patch(socket, to: monitor_path(socket, params))
  end

  defp current_filter_params(%Phoenix.LiveView.Socket{assigns: assigns}),
    do: current_filter_params(assigns)

  defp current_filter_params(assigns) when is_map(assigns) do
    %{
      "environment" => assigns.environment,
      "window" => assigns.window,
      "query" => assigns.query,
      "status" => assigns.status_filter,
      "type" => assigns.type_filter,
      "cursor" => assigns.cursor,
      "view" => assigns.view
    }
  end

  defp monitor_path(socket, params) do
    ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{socket.assigns.project.public_token}/monitor?#{compact_params(params)}"
  end

  defp monitor_project_path(socket, project) do
    ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{project.public_token}/monitor?#{%{"view" => socket.assigns.view}}"
  end

  defp incident_monitor_path(org_token, project, monitor_id) do
    ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/monitor/#{monitor_id}"
  end

  defp incidents_answer([]), do: "No recent incidents"

  defp incidents_answer(incidents) do
    case Enum.count(incidents, &(&1.status == :open)) do
      0 -> "Recent incidents"
      1 -> "1 open incident"
      count -> "#{count} open incidents"
    end
  end

  defp monitor_views,
    do: [
      {"all", "All"},
      {"attention", "Needs attention"},
      {"healthy", "Healthy"},
      {"incidents", "Recent incidents"}
    ]

  defp monitor_view_path(assigns, view) do
    params =
      assigns
      |> current_filter_params()
      |> Map.put("view", view)
      |> Map.delete("cursor")

    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/monitor?#{compact_params(params)}"
  end

  defp default_view(%{incidents: incidents, health: health}) do
    open? = Enum.any?(incidents, &(&1.status == :open))
    attention = health.down + health.degraded + health.late + health.missing
    if open? or attention > 0, do: "attention", else: "all"
  end

  defp incident_state_tone(:up), do: "live"
  defp incident_state_tone(:down), do: "error"
  defp incident_state_tone(:degraded), do: "late"
  defp incident_state_tone(:late), do: "late"
  defp incident_state_tone(:paused), do: "paused"
  defp incident_state_tone(:waiting), do: "neutral"
  defp incident_state_tone(:missing), do: "neutral"
  defp incident_state_tone(_state), do: "neutral"

  defp incident_state_label(:up), do: "Operational"
  defp incident_state_label(:down), do: "Down"
  defp incident_state_label(:degraded), do: "Degraded"
  defp incident_state_label(:late), do: "Late"
  defp incident_state_label(:paused), do: "Paused"
  defp incident_state_label(:waiting), do: "Waiting"
  defp incident_state_label(:missing), do: "No recent checks"
  defp incident_state_label(_state), do: "Unavailable"

  defp compact_params(params) do
    Map.reject(params, fn {_key, value} -> is_nil(value) or value == "" end)
  end
end
