defmodule AlplusWeb.StatusWorkspaceLive do
  @moduledoc """
  Analysis-only Public Status workspace.

  The authenticated console reports monitor health, customer-visible services,
  incident timelines, announcements, maintenance evidence, history, and
  publication links. Public Status mutations are performed by the project
  agent; this surface intentionally has no forms or mutation events.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1]
  import AlplusWeb.Status.Display

  alias Alplus.Monitoring.MonitorOverview
  alias Alplus.PublicPages
  alias Alplus.Status
  alias Alplus.Status.{PublicPage, ScheduledMaintenance, StatusAnnouncement, StatusPage}
  alias AlplusWeb.AgentConnection

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Status workspace",
             active: :public
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)

      if connected?(socket),
        do: Phoenix.PubSub.subscribe(Alplus.PubSub, "monitor:#{project.id}")

      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:project, project)
       |> assign(:page, nil)
       |> assign(:public_page, nil)
       |> assign(:services, [])
       |> assign(:fleet_health, empty_fleet_health())
       |> assign(:incidents, [])
       |> assign(:announcements, [])
       |> assign(:maintenances, [])
       |> assign(:public_health, :unconfigured)
       |> assign(:last_public_update_at, nil)
       |> assign(:incident, nil)
       |> assign(:service, nil)
       |> assign(:updates, [])
       |> assign(:load_state, :loading)
       |> assign(:agent_state, nil)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, page} <- page_for_params(socket.assigns.scope, params["page_id"]),
         {:ok, socket} <- load_workspace(socket, page, params) do
      case socket.assigns.live_action do
        action when action in [:services_new, :maintenance_new, :incident_new] ->
          {:noreply,
           push_navigate(socket,
             to: services_path(socket.assigns.org_token, socket.assigns.project, page)
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:error, :not_found} -> raise AlplusWeb.NotFoundError
      {:error, _reason} -> {:noreply, assign(socket, :load_state, :unavailable)}
    end
  end

  @impl true
  def handle_info(
        {:monitor_updated, project_id},
        %{assigns: %{project: %{id: project_id}}} = socket
      ) do
    case load_workspace(socket, socket.assigns.page, %{}) do
      {:ok, socket} -> {:noreply, socket}
      {:error, _} -> {:noreply, assign(socket, :load_state, :unavailable)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_workspace", _params, socket) do
    with page when not is_nil(page) <- socket.assigns.page,
         {:ok, socket} <- load_workspace(socket, page, %{}) do
      {:noreply, socket}
    else
      _ -> {:noreply, assign(socket, :load_state, :unavailable)}
    end
  end

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
      active={:public}
      page_title={if(@public_page, do: @public_page.title, else: "Public")}
      page_heading?={false}
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.console_page id="status-workspace-page">
        <:title :if={is_nil(@service) and is_nil(@incident)}>Public status</:title>
        <div id="status-workspace" class="flex flex-col gap-4">
          <.dashboard_header class="border-b border-border-default">
            <:leading>
              <nav
                id="status-workspace-nav"
                aria-label="Status page sections"
                class="-mb-px flex min-w-0 max-w-full items-center gap-5 overflow-x-auto whitespace-nowrap"
              >
                <%!-- One selected-state vocabulary across the console: an ink
                      label over a 2px brand underline, the same treatment the
                      Changelog sub-nav and `tabs/1` already use. --%>
                <.link
                  :for={{section, label, path} <- workspace_sections(@org_token, @project, @page)}
                  id={"status-workspace-nav-#{section}"}
                  navigate={path}
                  aria-current={nav_section(@live_action) == section && "page"}
                  class={[
                    "inline-flex min-h-target-min items-center border-b-2 pb-2.5 pt-1 text-label transition-colors",
                    nav_section(@live_action) == section &&
                      "border-interactive-strong font-semibold text-text-primary",
                    nav_section(@live_action) != section &&
                      "border-transparent text-text-secondary hover:border-border-default hover:text-text-primary"
                  ]}
                >
                  {label}
                </.link>
              </nav>
            </:leading>
            <:trailing>
              <a
                :if={@public_page && @public_page.published_at}
                id="status-open-public-page"
                href={~p"/status/#{@public_page.public_slug}"}
                target="_blank"
                rel="noopener"
                class="inline-flex min-h-target-min items-center rounded-control border border-border-control px-3 text-label font-medium text-text-primary hover:bg-surface-sunken"
              >
                Open public page
              </a>
            </:trailing>
          </.dashboard_header>

          <%!-- A read in flight is a skeleton, and a read that failed is the
                red-wash error boundary. Neither is a first-run state, and
                dressing both as one taught the reader that "no evidence" and
                "we could not look" are the same thing. --%>
          <div :if={@load_state == :loading} id="status-workspace-loading" aria-busy="true">
            <.skeleton rows={3} />
          </div>

          <.error_boundary
            :if={@load_state == :unavailable}
            id="status-workspace-unavailable"
            retry="retry_workspace"
          >
            Public Status evidence is unavailable. Existing public pages and monitor
            checks continue independently.
          </.error_boundary>

          <%= if @load_state == :ready do %>
            <.section_panel {assigns} />
          <% end %>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  attr :page, :map, required: true
  attr :services, :list, required: true
  attr :incidents, :list, required: true
  attr :announcements, :list, required: true
  attr :maintenances, :list, required: true
  attr :public_page, :any, required: true
  attr :public_health, :atom, required: true
  attr :fleet_health, :map, required: true
  attr :last_public_update_at, :any, required: false
  attr :live_action, :atom, required: true
  attr :org_token, :string, required: true
  attr :project, :map, required: true
  attr :scope, :any, required: true
  attr :incident, :any, required: false
  attr :service, :any, required: false
  attr :updates, :list, required: true

  defp section_panel(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <section :if={@live_action in [:index, :services]} id="status-overview" class="space-y-4">
        <%!-- One banner, one answer: what a customer sees right now. The
              summary band above this used to repeat the same verdict as a
              badge while calling itself "Status overview", so the screen led
              with a section name instead of the answer. --%>
        <section
          id="status-overview-health"
          class={[
            "border px-4 py-4",
            workspace_health_class(@public_health)
          ]}
          aria-live="polite"
          aria-labelledby="status-overview-public-state"
        >
          <p
            id="status-overview-public-state"
            class="flex items-center gap-2 text-heading-01 font-semibold"
          >
            <.icon name={workspace_health_icon(@public_health)} class="size-5 shrink-0" />
            {workspace_health_label(@public_health)}
          </p>
          <p class="mt-1 text-body">
            {affected_services_line(@services)}<span :if={@last_public_update_at}>, last public update
            <.timestamp
              at={@last_public_update_at}
              class="tabular-nums"
            /></span><span :if={is_nil(@last_public_update_at)}>, no public updates yet</span>
          </p>
          <p
            id="status-overview-context"
            class="mt-3 flex flex-wrap gap-x-5 gap-y-1 border-t border-current/20 pt-2 font-mono text-data"
          >
            <span id="status-overview-monitors">{@fleet_health.total} monitors</span>
            <span id="status-overview-services">{length(@services)} services</span>
            <span id="status-overview-incidents">
              {length(active_incidents(@incidents))} open incidents
            </span>
            <span id="status-overview-fleet">
              {@fleet_health.operational} operational, {@fleet_health.down} down, {@fleet_health.degraded} degraded, {@fleet_health.paused} paused
            </span>
            <span id="status-overview-publication">
              <%= if @public_page && @public_page.published_at do %>
                published <.timestamp at={@public_page.published_at} class="tabular-nums" />
              <% else %>
                not published, customers cannot see this page yet
              <% end %>
            </span>
          </p>
        </section>
      </section>

      <section :if={@live_action in [:index, :services]} id="status-services-analysis">
        <.data_panel
          :if={@services != []}
          id="status-services-workspace"
          title="Services"
          description="Customer-facing health from the monitors connected to each service."
        >
          <ul class="divide-y divide-border-default">
            <li
              :for={service <- @services}
              class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 px-4 py-4 sm:px-5"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2.5">
                  <.link
                    navigate={service_path(@org_token, @project, @page, service.id)}
                    class="text-body font-medium text-text-primary hover:text-interactive-strong-hover"
                  >{service.name}</.link>
                  <.status_badge
                    tone={service_tone(service.state)}
                    label={service_state_label(service.state)}
                  />
                </div>
                <p
                  :if={service.description}
                  class="mt-1 line-clamp-2 text-caption text-text-secondary"
                >
                  {service.description}
                </p>
                <p class="mt-1 text-caption text-text-tertiary">
                  {length(service.monitor_ids)} connected {if length(service.monitor_ids) == 1,
                    do: "monitor",
                    else: "monitors"}
                </p>
              </div>
              <a
                :if={@public_page && @public_page.published_at}
                href={public_service_path(@public_page, service)}
                target="_blank"
                rel="noopener"
                class="inline-flex min-h-target-min items-center text-caption font-medium text-text-secondary underline underline-offset-2"
              >View public service</a>
            </li>
          </ul>
        </.data_panel>
        <.first_run_card
          :if={@services == []}
          id="status-services-empty"
          title="No Public Status services yet"
          description="Services turn monitor evidence into the health customers see on your public page."
          state={@agent_state}
          task="List this project's Public Status services and report why the service evidence is empty."
          action_href={connect_path(@org_token, @project)}
        />
      </section>

      <section :if={@live_action == :incidents} id="status-incidents-analysis">
        <.data_panel
          id="status-incidents-workspace"
          title="Incidents"
          description="Published incident communication and bounded history."
        >
          <div class="divide-y divide-border-default">
            <div
              :for={incident <- active_incidents(@incidents)}
              class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 px-4 py-4 sm:px-5"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2.5">
                  <.link
                    navigate={incident_path(@org_token, @project, @page, incident.id)}
                    class="text-body font-medium text-text-primary"
                  >{incident.title}</.link><.status_badge
                    tone={stage_tone(incident.stage)}
                    icon={stage_icon(incident.stage)}
                    label={incident_stage_label(incident.stage)}
                  />
                </div><p class="mt-1 line-clamp-2 text-caption text-text-secondary">
                  {incident.body}
                </p><p class="mt-1 text-caption text-text-tertiary">
                  {affected_incident_line(incident)}<span :if={incident.published_at}>, published
                  <.timestamp at={incident.published_at} class="tabular-nums" /></span>
                </p>
              </div>
              <.link
                navigate={incident_path(@org_token, @project, @page, incident.id)}
                class="inline-flex min-h-target-min items-center text-caption font-medium text-text-secondary underline underline-offset-2"
              >View timeline</.link>
            </div>
            <p
              :if={active_incidents(@incidents) == []}
              class="px-4 py-5 text-caption text-text-secondary sm:px-5"
            >
              No active incidents. Historical incident evidence remains available in History.
            </p>
          </div>
        </.data_panel>
      </section>

      <section :if={@live_action == :history} id="status-history-analysis">
        <.data_panel
          id="status-page-history"
          title="Incident history"
          description="Published customer communication, newest month first."
        >
          <div class="divide-y divide-border-default">
            <div :for={{month, incidents} <- history_months(@incidents)} class="px-4 py-4 sm:px-5">
              <h3 class="text-label font-medium text-text-primary">{month}</h3><ul class="mt-2 space-y-2">
                <li :for={incident <- incidents} class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
                  <.link
                    navigate={incident_path(@org_token, @project, @page, incident.id)}
                    class="text-caption font-medium text-text-secondary underline underline-offset-2"
                  >{incident.title}</.link><.status_badge
                    :if={incident.status != "open"}
                    tone="success"
                    icon="hero-check-circle"
                    label="Resolved"
                  /><.timestamp
                    at={incident.published_at}
                    format={:date}
                    class="text-label tabular-nums text-text-tertiary"
                  />
                </li>
              </ul>
            </div>
            <p
              :if={history_months(@incidents) == []}
              class="px-4 py-5 text-caption text-text-secondary sm:px-5"
            >
              No published incidents yet. The historical read is healthy and empty.
            </p>
          </div>
        </.data_panel>
      </section>

      <section :if={@live_action == :announcements} id="status-announcements-analysis">
        <.data_panel
          id="status-announcements-workspace"
          title="Announcements"
          description="Bounded customer-visible notice history."
        >
          <div class="divide-y divide-border-default">
            <article :for={announcement <- @announcements} class="px-4 py-4 sm:px-5">
              <div class="flex flex-wrap items-center gap-2.5">
                <h3 class="text-body font-medium text-text-primary">{announcement.title}</h3><.status_badge
                  :if={announcement.removed_at}
                  tone="neutral"
                  icon="hero-eye-slash"
                  label="Unpublished"
                /><.status_badge
                  :if={
                    is_nil(announcement.removed_at) and announcement_status(announcement) == :expired
                  }
                  tone="neutral"
                  icon="hero-clock"
                  label="Expired"
                />
              </div><p class="mt-1 whitespace-pre-line text-caption text-text-secondary">
                {announcement.body}
              </p><p class="mt-1 flex flex-wrap gap-x-3 text-caption text-text-tertiary">
                Published
                <.timestamp at={announcement.published_at} class="tabular-nums" /><span :if={
                  announcement.removed_at
                }>Unpublished <.timestamp at={announcement.removed_at} class="tabular-nums" /></span><span :if={
                  announcement.expires_at
                }>Expires <.timestamp at={announcement.expires_at} class="tabular-nums" /></span>
              </p>
            </article>
            <p :if={@announcements == []} class="px-4 py-5 text-caption text-text-secondary sm:px-5">
              No announcements in the bounded history window.
            </p>
          </div>
        </.data_panel>
      </section>

      <section :if={@live_action == :maintenance} id="status-maintenance-analysis">
        <.data_panel
          id="status-maintenance-list"
          title="Scheduled maintenance"
          description="Maintenance windows recorded for this project and their monitor evidence."
        >
          <div class="divide-y divide-border-default">
            <article :for={maintenance <- @maintenances} class="px-4 py-4 sm:px-5">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <h3 class="text-body font-medium text-text-primary">{maintenance.title}</h3><.status_badge
                  tone={maintenance_status_tone(maintenance.status)}
                  icon={maintenance_status_icon(maintenance.status)}
                  label={maintenance_status_label(maintenance.status)}
                />
              </div><p class="mt-1 text-data tabular-nums text-text-tertiary">
                {maintenance_window(maintenance)}
              </p><p :if={maintenance.description} class="mt-1 text-caption text-text-secondary">
                {maintenance.description}
              </p>
            </article><p
              :if={@maintenances == []}
              class="px-4 py-5 text-caption text-text-secondary sm:px-5"
            >
              No scheduled or recent maintenance windows.
            </p>
          </div>
        </.data_panel>
      </section>

      <section :if={@live_action == :settings} id="status-analysis-settings">
        <.data_panel
          id="status-operational-settings"
          title="Public Status evidence"
          description="Publication, links, and read boundaries for this project."
        >
          <.definition_list>
            <:row label="Publication">
              <.status_badge
                tone={if(@public_page && @public_page.published_at, do: "success", else: "neutral")}
                label={
                  if(@public_page && @public_page.published_at, do: "Published", else: "Private")
                }
              />
            </:row>
            <:row label="Public address">
              <span class="font-mono">{if @public_page,
                do: "/status/#{@public_page.public_slug}",
                else: "Unavailable"}</span>
            </:row>
            <:row label="Access">
              Analysis only. Ask the project agent to change Public identity or publication.
            </:row>
          </.definition_list>
          <p :if={is_nil(@public_page)} class="mt-4 text-caption text-text-secondary">
            Public identity is unavailable for this project. Inspect the agent connection before relying on publication state.
          </p>
        </.data_panel>
      </section>

      <section :if={@live_action in [:service_show, :incident_show]} id="status-detail-analysis">
        <.service_detail :if={@service} service={@service} />
        <.incident_detail
          :if={@incident}
          incident={@incident}
          updates={@updates}
          services={@services}
          org_token={@org_token}
          project={@project}
          page={@page}
        />
      </section>
    </div>
    """
  end

  attr :service, :map, required: true

  defp service_detail(assigns) do
    ~H"""
    <section id="status-service-detail" class="flex flex-col gap-4">
      <header class="space-y-2">
        <div class="flex flex-wrap items-center gap-2.5">
          <h1 class="text-heading-02 text-text-primary">{@service.name}</h1><.status_badge
            tone={service_tone(@service.state)}
            label={service_state_label(@service.state)}
          />
        </div><p :if={@service.description} class="text-body text-text-secondary">
          {@service.description}
        </p>
      </header>
      <section id="status-service-composition">
        <.data_panel
          id="status-service-monitors"
          title="Monitor observations"
          description="Current evidence connected to this customer-facing service."
        >
          <p class="px-4 pt-4 text-caption text-text-secondary sm:px-5">
            {length(@service.monitors)} of {length(@service.monitor_ids)} configured monitors provide
            current observations.
          </p>
          <ul class="divide-y divide-border-default">
            <li
              :for={monitor <- @service.monitors}
              id={"status-service-monitor-#{monitor.id}"}
              class="flex flex-wrap items-center justify-between gap-3 px-4 py-3 sm:px-5"
            >
              <span class="text-body text-text-primary">{monitor.name}</span><.status_badge
                tone={monitor_tone(monitor)}
                icon={monitor_icon(monitor)}
                label={monitor_state_label(monitor)}
              />
            </li><li :if={@service.monitors == []} class="px-4 py-4 text-caption text-text-secondary">
              No eligible monitor observations are connected.
            </li>
          </ul>
        </.data_panel>
      </section>
      <.service_reliability_panel
        :if={Map.has_key?(@service, :reliability)}
        reliability={@service.reliability}
      />
    </section>
    """
  end

  attr :incident, :map, required: true
  attr :updates, :list, required: true
  attr :services, :list, required: true
  attr :org_token, :string, required: true
  attr :project, :map, required: true
  attr :page, :map, required: true

  defp incident_detail(assigns) do
    ~H"""
    <section id="status-incident-detail" class="flex flex-col gap-4">
      <header id="status-incident-header" class="space-y-3">
        <div class="flex flex-wrap items-center gap-2.5">
          <h1 class="text-heading-02 text-text-primary">{@incident.title}</h1><.status_badge
            tone={stage_tone(@incident.stage)}
            icon={stage_icon(@incident.stage)}
            label={incident_stage_label(@incident.stage)}
          />
        </div><p class="flex flex-wrap gap-x-3 text-caption text-text-tertiary">
          <span :if={@incident.published_at}>Published
          <.timestamp at={@incident.published_at} class="tabular-nums" /></span><span>{affected_incident_line(
            @incident
          )}</span>
        </p>
      </header>
      <.data_panel
        id="status-incident-workspace"
        title="Customer narrative"
        description="Published communication for people affected by this incident."
        padded
      >
        <p class="whitespace-pre-line text-body text-text-secondary">{@incident.body}</p>
      </.data_panel>
      <.data_panel
        :if={@incident.detected_incident}
        id="status-incident-observation"
        title="Monitor observation"
        description="Machine evidence associated with this incident."
        padded
      >
        <div class="flex flex-wrap items-center gap-3 text-caption text-text-secondary">
          <.status_badge
            tone={detected_incident_tone(@incident.detected_incident)}
            icon={detected_incident_icon(@incident.detected_incident)}
            label={detected_incident_label(@incident.detected_incident)}
          /><span>Started
          <.timestamp at={@incident.detected_incident.started_at} class="tabular-nums" /></span><span :if={
            @incident.detected_incident.resolved_at
          }>Recovered <.timestamp at={@incident.detected_incident.resolved_at} class="tabular-nums" /></span>
        </div>
      </.data_panel><.data_panel
        id="status-incident-affected-services"
        title="Affected services"
        description="Customer-facing services associated with this incident."
      >
        <ul class="flex flex-wrap gap-2">
          <li
            :for={service <- incident_services(@incident)}
            class="inline-flex items-center gap-2 border border-border-default bg-surface-sunken px-2.5 py-1 text-caption text-text-secondary"
          >
            {service.name}<.status_badge
              :if={service[:state]}
              tone={service_tone(service.state)}
              label={service_state_label(service.state)}
            />
          </li>
        </ul><p :if={incident_services(@incident) == []} class="text-caption text-text-secondary">
          No affected services recorded.
        </p>
      </.data_panel><.data_panel
        id="status-incident-previous-updates"
        title="Incident timeline"
        description="Published updates remain immutable evidence."
      >
        <ol class="space-y-4 border-l border-border-default pl-4">
          <li :for={update <- @updates} class="space-y-1">
            <time class="text-label tabular-nums text-text-tertiary">{Calendar.strftime(
              update.inserted_at,
              "%d %b %Y, %H:%M UTC"
            )}</time><p class="whitespace-pre-line text-body text-text-secondary">{update.body}</p>
          </li>
        </ol><p :if={@updates == []} class="text-caption text-text-secondary">No updates yet.</p>
      </.data_panel>
    </section>
    """
  end

  attr :reliability, :any, required: true

  defp service_reliability_panel(%{reliability: nil} = assigns) do
    ~H"""
    <.data_panel
      id="status-service-reliability"
      title="Reliability objective"
      description="Bounded objective evidence."
      padded
    >
      <p id="status-service-reliability-absent" class="text-caption text-text-secondary">
        No eligible reliability objective is configured.
      </p>
    </.data_panel>
    """
  end

  defp service_reliability_panel(%{reliability: %{state: :error}} = assigns) do
    ~H"""
    <.data_panel
      id="status-service-reliability"
      title="Reliability objective"
      description="Bounded objective evidence."
      padded
    >
      <p class="text-caption text-status-error-ink" role="alert">
        Reliability evidence is unavailable. Try again later.
      </p>
    </.data_panel>
    """
  end

  defp service_reliability_panel(assigns) do
    ~H"""
    <.data_panel
      id="status-service-reliability"
      title="Reliability objective"
      description="Bounded objective evidence."
      padded
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <p class="text-caption text-text-secondary">
          Target
          <strong class="tabular-nums text-text-primary">{format_slo_percent(@reliability.target)}</strong>
        </p>
        <.status_badge
          tone={reliability_tone(@reliability)}
          icon={reliability_icon(@reliability)}
          label={reliability_label(@reliability)}
        />
      </div>
      <p id="status-service-reliability-days" class="mt-3 text-caption text-text-secondary">
        {length(@reliability.days)} daily records in the objective evidence window.
      </p>
      <dl class="mt-4 grid gap-3 text-caption sm:grid-cols-3">
        <div>
          <dt class="text-text-tertiary">Attainment</dt>
          <dd class="font-semibold tabular-nums text-text-primary">
            {format_slo_percent(@reliability.summary.uptime)}
          </dd>
        </div>
        <div>
          <dt class="text-text-tertiary">Incidents</dt>
          <dd class="font-semibold tabular-nums text-text-primary">
            {@reliability.summary.incident_count}
          </dd>
        </div>
        <div>
          <dt class="text-text-tertiary">Downtime</dt>
          <dd class="font-semibold tabular-nums text-text-primary">
            {format_reliability_duration(@reliability.summary.downtime_microseconds)}
          </dd>
        </div>
      </dl>
    </.data_panel>
    """
  end

  defp load_workspace(socket, page, params) do
    scope = socket.assigns.scope

    public_page =
      case PublicPages.get_for_project(scope, page.project_id) do
        {:ok, value} -> value
        {:error, :not_found} -> nil
        {:error, reason} -> raise reason
      end

    services = load_services(scope, page.id)

    incidents =
      load_incidents(scope, page.id) |> Enum.filter(&(&1.published_at || can_manage?(scope)))

    announcements = load_announcements(scope, page.id)
    maintenances = load_maintenances(scope, page.id)
    fleet_health = MonitorOverview.fleet_health_for_project(scope)

    socket =
      socket
      |> assign(
        page: page,
        public_page: public_page,
        services: services,
        incidents: incidents,
        announcements: announcements,
        maintenances: maintenances,
        fleet_health: fleet_health,
        public_health: Status.aggregate_health(services, false, nil, :unconfigured),
        # Only the first-run card below reads this.
        agent_state: if(services == [], do: AgentConnection.state(scope)),
        last_public_update_at:
          Status.last_public_update_at(scope, page.id, incidents, announcements),
        load_state: :ready
      )

    case params do
      %{"incident_id" => id} -> load_incident(socket, id)
      %{"service_id" => id} -> load_service(socket, id)
      _ -> {:ok, assign(socket, incident: nil, service: nil, updates: [])}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp page_for_params(scope, nil), do: Status.workspace_page(scope)
  defp page_for_params(scope, page_id), do: scoped_page(scope, page_id)

  defp load_incident(socket, incident_id) do
    case Status.incident_overview(socket.assigns.scope, incident_id) do
      {:ok,
       %{
         incident: incident,
         updates: updates,
         affected_services: services,
         detected_incident: detected
       }} ->
        incident =
          incident
          |> Map.put(:affected_services, services)
          |> Map.put(:detected_incident, detected)

        {:ok, assign(socket, incident: incident, updates: updates)}

      _ ->
        {:error, :not_found}
    end
  end

  defp load_service(socket, service_id) do
    case Status.service(socket.assigns.scope, socket.assigns.page, service_id, reliability?: true) do
      {:ok, service} -> {:ok, assign(socket, :service, service)}
      _ -> {:error, :not_found}
    end
  end

  defp scoped_page(scope, page_id) do
    case Ash.get(StatusPage, page_id, actor: scope) do
      {:ok, page} when page.org_id == scope.org_id and page.project_id == scope.project_id ->
        {:ok, page}

      _ ->
        {:error, :not_found}
    end
  end

  defp load_services(scope, page_id) do
    case Status.service_overview(scope, page_id) do
      {:ok, services} -> services
      {:error, :not_found} -> raise AlplusWeb.NotFoundError
      {:error, reason} -> raise reason
    end
  end

  defp load_announcements(scope, page_id),
    do:
      StatusAnnouncement
      |> Ash.Query.for_read(:for_page, %{status_page_id: page_id}, actor: scope)
      |> Ash.Query.sort(published_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: scope)
      |> ash_results()

  defp load_maintenances(scope, page_id),
    do:
      ScheduledMaintenance
      |> Ash.Query.for_read(:for_page, %{status_page_id: page_id}, actor: scope)
      |> Ash.Query.sort(starts_at: :desc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: scope)
      |> ash_results()
      |> Enum.filter(&(&1.status in ["scheduled", "active", "completed", "cancelled"]))

  defp load_incidents(scope, page_id) do
    case Status.list_incidents(scope, page_id, operator?: true) do
      {:ok, incidents} -> incidents
      {:error, :not_found} -> raise AlplusWeb.NotFoundError
      {:error, reason} -> raise reason
    end
  end

  defp ash_results(%{results: results}), do: results
  defp ash_results(results), do: results

  defp incident_services(%{affected_services: services}), do: services
  defp incident_services(_), do: []

  defp history_months(incidents),
    do:
      incidents
      |> published_incidents()
      |> Enum.group_by(fn i ->
        at = i.published_at || i.inserted_at
        {at.year, at.month}
      end)
      |> Enum.sort_by(fn {{year, month}, _} -> {year, month} end, :desc)
      |> Enum.map(fn {{year, month}, entries} ->
        {Calendar.strftime(Date.new!(year, month, 1), "%B %Y"), entries}
      end)

  defp published_incidents(incidents), do: Enum.filter(incidents, & &1.published_at)

  defp active_incidents(incidents),
    do: Enum.filter(incidents, &(&1.status == "open" and &1.published_at))

  defp incident_services_line(services),
    do: "#{length(services)} #{if length(services) == 1, do: "service", else: "services"}"

  defp affected_services_line(services), do: incident_services_line(services)
  defp affected_incident_line(incident), do: incident_services_line(incident_services(incident))

  defp workspace_sections(org_token, project, page),
    do: [
      {:services, "Services", services_path(org_token, project, page)},
      {:incidents, "Incidents", incidents_path(org_token, project, page)},
      {:announcements, "Announcements", announcements_path(org_token, project, page)},
      {:maintenance, "Maintenance", maintenance_path(org_token, project, page)},
      {:history, "History", history_path(org_token, project, page)},
      {:settings, "Evidence", settings_path(org_token, project, page)}
    ]

  defp nav_section(action) when action in [:incidents, :incident_show], do: :incidents
  defp nav_section(:maintenance), do: :maintenance
  defp nav_section(:announcements), do: :announcements
  defp nav_section(:history), do: :history
  defp nav_section(:settings), do: :settings
  defp nav_section(_), do: :services

  defp workspace_health_label(:operational), do: "All systems operational"
  defp workspace_health_label(:degraded), do: "Degraded performance"
  defp workspace_health_label(:maintenance), do: "Maintenance in progress"
  defp workspace_health_label(:major_outage), do: "Major outage"
  defp workspace_health_label(:partial_outage), do: "Partial outage"
  defp workspace_health_label(:unknown), do: "No observation yet"
  defp workspace_health_label(:unconfigured), do: "No services configured yet"
  defp workspace_health_label(value), do: to_string(value)
  defp workspace_health_icon(:operational), do: "hero-check-circle"
  defp workspace_health_icon(:degraded), do: "hero-exclamation-triangle"
  defp workspace_health_icon(:maintenance), do: "hero-wrench-screwdriver"

  defp workspace_health_icon(value) when value in [:major_outage, :partial_outage],
    do: "hero-x-circle"

  defp workspace_health_icon(_), do: "hero-information-circle"

  defp workspace_health_class(:operational),
    do: "border-status-live-border bg-status-live-bg text-status-live-ink"

  defp workspace_health_class(:degraded),
    do: "border-status-late-border bg-status-late-bg text-status-late-ink"

  defp workspace_health_class(:maintenance),
    do: "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink"

  defp workspace_health_class(value) when value in [:major_outage, :partial_outage],
    do: "border-status-error-border bg-status-error-bg text-status-error-ink"

  defp workspace_health_class(_), do: "border-border-default bg-surface-raised text-text-primary"

  defp service_tone(:up), do: "success"
  defp service_tone(:operational), do: "success"
  defp service_tone(:maintenance), do: "info"
  defp service_tone(:degraded), do: "warning"
  defp service_tone(:down), do: "error"
  defp service_tone(_), do: "neutral"
  defp service_state_label(:up), do: "Operational"
  defp service_state_label(:operational), do: "Operational"
  defp service_state_label(:maintenance), do: "Maintenance"
  defp service_state_label(:degraded), do: "Degraded"
  defp service_state_label(:down), do: "Outage"
  defp service_state_label(_), do: "Unknown"

  defp monitor_state_label(monitor) do
    case PublicPage.monitor_status(monitor) do
      :up -> "Operational"
      :down -> "Outage"
      :degraded -> "Degraded"
      :unknown -> "No observation"
    end
  end

  defp monitor_tone(monitor) do
    case PublicPage.monitor_status(monitor) do
      :up -> "success"
      :down -> "error"
      :degraded -> "warning"
      :unknown -> "neutral"
    end
  end

  defp monitor_icon(monitor) do
    case PublicPage.monitor_status(monitor) do
      :up -> "hero-check-circle"
      :down -> "hero-x-circle"
      :degraded -> "hero-exclamation-triangle"
      :unknown -> "hero-question-mark-circle"
    end
  end

  defp detected_incident_label(%{status: status}) when status in [:open, "open"],
    do: "Monitor incident open"

  defp detected_incident_label(%{status: status}) when status in [:resolved, "resolved"],
    do: "Monitor incident recovered"

  defp detected_incident_label(_), do: "Monitor observation"
  defp detected_incident_tone(%{status: status}) when status in [:open, "open"], do: "error"

  defp detected_incident_tone(%{status: status}) when status in [:resolved, "resolved"],
    do: "success"

  defp detected_incident_tone(_), do: "neutral"

  defp detected_incident_icon(%{status: status}) when status in [:open, "open"],
    do: "hero-exclamation-triangle"

  defp detected_incident_icon(%{status: status}) when status in [:resolved, "resolved"],
    do: "hero-check-circle"

  defp detected_incident_icon(_), do: "hero-information-circle"

  defp reliability_tone(%{budget: %{state: state}}) when state in [:exhausted, :alert],
    do: "error"

  defp reliability_tone(%{budget: %{state: :insufficient}}), do: "neutral"
  defp reliability_tone(_), do: "success"

  defp reliability_icon(%{budget: %{state: state}}) when state in [:exhausted, :alert],
    do: "hero-exclamation-triangle"

  defp reliability_icon(%{budget: %{state: :insufficient}}), do: "hero-information-circle"
  defp reliability_icon(_), do: "hero-check-circle"
  defp reliability_label(%{budget: %{state: :healthy}}), do: "Within budget"
  defp reliability_label(%{budget: %{state: :alert}}), do: "Burn alert"
  defp reliability_label(%{budget: %{state: :exhausted}}), do: "Budget exhausted"
  defp reliability_label(%{budget: %{state: :insufficient}}), do: "Insufficient evidence"
  defp reliability_label(_), do: "Evidence available"
  defp format_slo_percent(nil), do: "Not enough evidence"

  defp format_slo_percent(value) when is_number(value),
    do: value |> Kernel.*(100) |> Float.round(4) |> then(&"#{&1}%")

  defp format_reliability_duration(0), do: "0 seconds"

  defp format_reliability_duration(value) when is_integer(value),
    do: "#{div(value, 1_000_000)} seconds"

  defp format_reliability_duration(_), do: "Not available"

  defp maintenance_window(m),
    do:
      "#{Calendar.strftime(m.starts_at, "%d %b %Y, %H:%M")} to #{Calendar.strftime(m.ends_at, "%d %b %Y, %H:%M")} UTC"

  defp announcement_status(%{expires_at: expires_at}) when is_struct(expires_at, DateTime),
    do:
      if(DateTime.compare(expires_at, DateTime.utc_now()) == :lt, do: :expired, else: :published)

  defp announcement_status(_), do: :published

  defp empty_fleet_health,
    do: %{
      total: 0,
      active: 0,
      operational: 0,
      down: 0,
      degraded: 0,
      paused: 0,
      waiting: 0,
      late: 0,
      missing: 0,
      late_or_waiting: 0,
      latest_check_at: nil
    }

  defp status_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/public/status"

  defp services_path(org_token, project, _page),
    do: status_path(org_token, project) <> "/services"

  defp service_path(org_token, project, page, id),
    do: services_path(org_token, project, page) <> "/#{id}"

  defp incidents_path(org_token, project, _page),
    do: status_path(org_token, project) <> "/incidents"

  defp incident_path(org_token, project, page, id),
    do: incidents_path(org_token, project, page) <> "/#{id}"

  defp history_path(org_token, project, _page), do: status_path(org_token, project) <> "/history"

  defp settings_path(org_token, project, _page),
    do: status_path(org_token, project) <> "/settings"

  defp announcements_path(org_token, project, _page),
    do: status_path(org_token, project) <> "/announcements"

  defp maintenance_path(org_token, project, _page),
    do: status_path(org_token, project) <> "/maintenance"

  defp public_service_path(public_page, service),
    do: ~p"/status/#{public_page.public_slug}" <> "#status-component-#{service.id}"

  defp connect_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/connect"
end
