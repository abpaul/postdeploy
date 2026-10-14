defmodule AlplusWeb.StatusPagesLive do
  @moduledoc """
  Analysis entry point for the project Public Status workspace.

  Existing workspaces continue into `StatusWorkspaceLive`. When no workspace
  exists, this view explains the missing evidence and hands the project-scoped
  operation to the connected agent instead of exposing an authenticated builder.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents
  import AlplusWeb.PublicPageComponents, only: [public_page_path: 3]

  alias Alplus.Monitoring.Monitor
  alias Alplus.Status

  require Ash.Query

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Public",
             active: :public
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)

      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:project, project)
       |> assign(:monitors, [])
       |> assign(:fleet_health, empty_fleet_health())
       |> assign(:load_state, :loading)
       |> assign(:agent_state, nil)
       |> subscribe_monitor_updates(project.id)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :legacy_redirect ->
        {:noreply, push_navigate(socket, to: status_path(socket))}

      action when action in [:public, :project] ->
        case Status.workspace_page(socket.assigns.scope) do
          {:ok, _page} ->
            {:noreply,
             push_navigate(socket,
               to: status_path(socket) |> then(&status_services_path(&1, params))
             )}

          {:error, :not_found} ->
            {:noreply, load_data(socket)}

          {:error, _error} ->
            {:noreply, assign(socket, :load_state, :unavailable)}
        end

      _ ->
        {:noreply, load_data(socket)}
    end
  end

  @impl true
  def handle_info(
        {:monitor_updated, project_id},
        %{assigns: %{project: %{id: project_id}}} = socket
      ) do
    {:noreply, load_data(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_status_pages", _params, socket) do
    {:noreply, load_data(socket)}
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
      page_title="Public"
      page_heading?={false}
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.console_page id="status-pages-page">
        <:title>Status page</:title>
        <div :if={@live_action != :legacy_redirect} id="status-pages" class="flex flex-col gap-4">
          <div :if={@load_state == :loading} id="status-pages-loading" aria-busy="true">
            <.skeleton rows={3} />
          </div>

          <.error_boundary
            :if={@load_state == :unavailable}
            id="status-pages-unavailable"
            retry="retry_status_pages"
          >
            Public Status is unavailable. Existing public pages and monitor checks
            continue independently.
          </.error_boundary>

          <%!-- There is no status page yet, so the screen is the one card that
                names the missing prerequisite and the action that fills it. --%>
          <div :if={@load_state == :ready} id="status-pages-workspace" class="min-w-0">
            <p id="status-page-state" class="sr-only">{workspace_headline(@monitors)}</p>
            <.first_run_card
              :if={@monitors == []}
              id="status-pages-need-monitors"
              title="A monitor has to run first"
              description="Your status page shows the health of your monitors, so one has to report before a page can exist. The page will then show each service, its 90-day uptime, and any open incident, at a public address you can share."
              state={@agent_state}
              task="Create a monitor for this project's main endpoint, then create a status page from this project's monitors. Publish it and return the public URL."
              action_href={monitor_path(@org_token, @project)}
              action_label="Open monitors"
            />

            <.first_run_card
              :if={@monitors != []}
              id="status-page-workspace-empty"
              title="No status page yet"
              description="Your monitors are reporting. The page will show each service, its 90-day uptime, and any open incident, at a public address you can share."
              state={@agent_state}
              task="Create a status page from this project's monitors. Publish it and return the public URL."
              action_href={connect_path(@org_token, @project)}
            />
          </div>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # The headline names the prerequisite that is actually missing, so the reader
  # does not have to compare two cards to work out which step is next.
  defp workspace_headline([]), do: "No monitors are reporting yet"
  defp workspace_headline(_monitors), do: "Your monitors are reporting. No status page yet."

  defp load_data(socket) do
    scope = socket.assigns.scope

    monitors =
      Monitor
      |> Ash.Query.filter(project_id == ^scope.project_id)
      |> Ash.Query.sort(:name)
      |> Ash.read!(actor: scope)

    socket
    |> assign(:monitors, monitors)
    |> assign(:fleet_health, Alplus.Monitoring.MonitorOverview.fleet_health(monitors))
    # This screen has no populated state yet, so the first-run card always
    # draws and always needs the real agent connection state.
    |> assign(:agent_state, AlplusWeb.AgentConnection.state(scope))
    |> assign(:load_state, :ready)
  rescue
    _error -> assign(socket, :load_state, :unavailable)
  end

  defp status_path(socket) do
    public_page_path(
      socket.assigns.org_token,
      socket.assigns.project.public_token,
      :status
    )
  end

  defp status_services_path(status_path, %{"monitor" => monitor}) when is_binary(monitor) do
    status_path <> "/services?" <> URI.encode_query(%{monitor: monitor})
  end

  defp status_services_path(status_path, _params), do: status_path <> "/services"

  defp monitor_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/monitor"

  defp connect_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/connect"

  defp subscribe_monitor_updates(socket, project_id) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Alplus.PubSub, "monitor:#{project_id}")
    socket
  end

  defp empty_fleet_health do
    %{
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
  end
end
