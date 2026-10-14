defmodule AlplusWeb.RetiredRouteRedirectLive do
  @moduledoc """
  Tenant-safe redirects from retired human mutation routes to analysis views.

  Organization, project, and resource validation happens during the initial
  disconnected mount as well as the connected mount. A foreign, archived, or
  unknown reference therefore has the same not-found outcome and never leaks
  resource existence through a redirect.
  """

  use AlplusWeb, :live_view

  alias Alplus.Monitoring.Monitor

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(
        %{"org_token" => org_token, "project_token" => project_token} = params,
        _session,
        socket
      ) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: page_title(socket.assigns.live_action),
             active: active_nav(socket.assigns.live_action)
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)
      validate_resource!(socket.assigns.live_action, params, scope)

      {:ok,
       socket
       |> assign(:project, project)
       |> assign(:scope, scope)
       |> put_flash(:info, notice(socket.assigns.live_action))
       |> redirect(to: destination(socket.assigns.live_action, org_token, project_token, params))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="retired-route-redirect" aria-busy="true">
      <h1 class="sr-only">{@page_title}</h1>
      <p role="status" class="sr-only">Opening the closest analysis view.</p>
    </main>
    """
  end

  defp validate_resource!(:monitor_edit, %{"monitor_id" => monitor_id}, scope) do
    if not AlplusWeb.OrgContext.can_manage?(scope), do: raise(AlplusWeb.NotFoundError)

    case Ash.get(Monitor, monitor_id, actor: scope) do
      {:ok, %Monitor{project_id: project_id}} when project_id == scope.project_id -> :ok
      _ -> raise AlplusWeb.NotFoundError
    end
  end

  defp validate_resource!(_action, _params, _scope), do: :ok

  defp destination(:monitor_new, org_token, project_token, _params),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/monitor"

  defp destination(:monitor_edit, org_token, project_token, %{"monitor_id" => monitor_id}),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/monitor/#{monitor_id}"

  defp destination(:observe_new, org_token, project_token, _params),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/observe"

  defp destination(:status_service_new, org_token, project_token, _params),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/status/services"

  defp destination(:status_incident_new, org_token, project_token, _params),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/status/incidents"

  defp destination(:status_maintenance_new, org_token, project_token, _params),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/status/maintenance"

  defp notice(:monitor_new),
    do: "Monitor creation now runs through your connected agent. Review existing monitors here."

  defp notice(:monitor_edit),
    do:
      "Monitor changes now run through your connected agent. Review this monitor and its evidence here."

  defp notice(:observe_new),
    do:
      "Observe source setup now runs through your connected agent. Review current sources and issues here."

  defp notice(:status_service_new),
    do: "Service creation now runs through your connected agent. Review current services here."

  defp notice(:status_incident_new),
    do: "Incident creation now runs through your connected agent. Review current incidents here."

  defp notice(:status_maintenance_new),
    do:
      "Maintenance creation now runs through your connected agent. Review scheduled maintenance here."

  defp page_title(action) when action in [:monitor_new, :monitor_edit], do: "Monitor"
  defp page_title(:observe_new), do: "Observe"
  defp page_title(_action), do: "Public Status"

  defp active_nav(action) when action in [:monitor_new, :monitor_edit], do: :monitor
  defp active_nav(:observe_new), do: :observe
  defp active_nav(_action), do: :public
end
