defmodule AlplusWeb.PublicPageRedirectLive do
  @moduledoc "Redirects the project Public destination to its Status section."

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.PublicPageComponents, only: [public_page_path: 3]

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
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      project =
        AlplusWeb.OrgContext.project_for_token!(socket, socket.assigns.project.public_token)

      {:noreply,
       socket
       |> assign(:project, project)
       |> push_navigate(
         to:
           public_page_path(
             socket.assigns.org_token,
             project.public_token,
             :status
           )
       )}
    else
      {:noreply, socket}
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
      page_title="Public"
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.skeleton rows={3} />
    </.dashboard_shell>
    """
  end
end
