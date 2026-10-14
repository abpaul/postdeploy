defmodule AlplusWeb.ProjectRouteLive do
  @moduledoc """
  Safe redirects for retired organization-level pillar URLs.
  """

  use AlplusWeb, :live_view

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Projects",
             active: :projects
           ) do
      projects =
        Alplus.Projects.list_projects_for_org!(socket.assigns.org_id, actor: socket.assigns.scope)

      {:ok, assign(socket, :projects, projects)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns.projects do
      [project] ->
        {:noreply,
         push_navigate(socket,
           to:
             feature_path(
               socket.assigns.org.public_token,
               project.public_token,
               socket.assigns.live_action
             )
         )}

      _ ->
        {:noreply,
         socket
         |> put_flash(:info, "Choose a project before opening a product feature.")
         |> push_navigate(to: ~p"/dashboard/orgs/#{socket.assigns.org.public_token}/projects")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="project-route-redirect"></div>
    """
  end

  defp feature_path(org_token, project_token, :monitor),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/monitor"

  defp feature_path(org_token, project_token, :measure),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/measure"

  defp feature_path(org_token, project_token, :observe),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/observe"
end
