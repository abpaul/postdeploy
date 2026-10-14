defmodule AlplusWeb.PublicPageLegacyRedirectLive do
  @moduledoc "Redirects retired authenticated Status and Changelog management routes."

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.PublicPageComponents, only: [public_page_path: 3]

  alias Alplus.Status

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Public",
             active: :public
           ) do
      {:ok, assign(socket, :project, %{public_token: project_token, id: nil, name: "Project"})}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      project =
        AlplusWeb.OrgContext.project_for_token!(socket, socket.assigns.project.public_token)

      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)
      socket = assign(socket, project: project, scope: scope)

      if page_id = params["page_id"] do
        case Status.page_for_scope(scope, page_id) do
          {:ok, _page} -> redirect_for(socket, params)
          _ -> raise AlplusWeb.NotFoundError
        end
      else
        redirect_for(socket, params)
      end
    else
      {:noreply, socket}
    end
  end

  defp redirect_for(socket, params) do
    path =
      case socket.assigns.live_action do
        action when action in [:status_collection, :status_new, :status_page] ->
          status_path(socket)

        :status_services ->
          status_path(socket) <> "/services"

        :status_service_new ->
          status_path(socket) <> "/services/new"

        :status_service ->
          status_path(socket) <> "/services/" <> params["service_id"]

        :status_incidents ->
          status_path(socket) <> "/incidents"

        :status_incident_new ->
          status_path(socket) <> "/incidents/new"

        :status_incident ->
          status_path(socket) <> "/incidents/" <> params["incident_id"]

        :status_announcements ->
          status_path(socket) <> "/announcements"

        :status_history ->
          status_path(socket) <> "/history"

        :status_maintenance ->
          status_path(socket) <> "/maintenance"

        :status_maintenance_new ->
          status_path(socket) <> "/maintenance/new"

        :status_settings ->
          settings_path(socket)

        :changelog ->
          changelog_path(socket)

        :changelog_entries ->
          changelog_path(socket) <> "/entries"

        :changelog_entry ->
          changelog_path(socket) <> "/entries/" <> params["entry_handle"]

        :changelog_settings ->
          settings_path(socket)

        :changelog_activity ->
          changelog_path(socket) <> "/activity"

        _ ->
          public_page_path(
            socket.assigns.org_token,
            socket.assigns.project.public_token,
            :status
          )
      end

    {:noreply, push_navigate(socket, to: path)}
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
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.skeleton rows={3} />
    </.dashboard_shell>
    """
  end

  defp status_path(socket),
    do:
      public_page_path(
        socket.assigns.org_token,
        socket.assigns.project.public_token,
        :status
      )

  defp changelog_path(socket),
    do:
      public_page_path(
        socket.assigns.org_token,
        socket.assigns.project.public_token,
        :changelog
      )

  defp settings_path(socket),
    do:
      public_page_path(
        socket.assigns.org_token,
        socket.assigns.project.public_token,
        :settings
      )
end
