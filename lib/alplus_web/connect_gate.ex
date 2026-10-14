defmodule AlplusWeb.ConnectGate do
  @moduledoc """
  Keeps a project's pages closed until an agent has reached the project.

  Attached once to the `:authenticated_routes` live session, so every
  LiveView under `/dashboard/orgs/:org_token/projects/:project_token/...`
  is gated by the same rule instead of each page repeating it. A project
  with no agent activity has nothing to show, so the operator is sent to
  the project's Connect page, which is the one project page this hook
  exempts (`AlplusWeb.AgentConnectionLive`) — otherwise the redirect
  would loop.

  Routes without a `project_token` (the org's Projects, Team, Billing and
  Settings pages, the account pages, the dashboard) are untouched.

  Org and project are resolved through `AlplusWeb.OrgContext`, so an
  unknown or cross-tenant token still answers 404, never 403
  (ARCHITECTURE.md §4), and the resolution is reused by the view's own
  mount rather than repeated (`OrgContext.assign_org_context/2` is
  idempotent).
  """

  import Phoenix.Component, only: [assign: 3]
  use AlplusWeb, :verified_routes

  alias AlplusWeb.OrgContext

  @exempt_views [AlplusWeb.AgentConnectionLive]

  @spec on_mount(
          :default,
          Phoenix.LiveView.unsigned_params() | :not_mounted_at_router,
          map(),
          Phoenix.LiveView.Socket.t()
        ) :: {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    with %{"org_token" => org_token, "project_token" => project_token} <- params,
         true <- gate_applies?(socket) do
      gate(socket, org_token, project_token)
    else
      _ -> {:cont, socket}
    end
  end

  # A signed-out or unconfirmed visitor is somebody else's redirect: the
  # module-level `{AlplusWeb.LiveUserAuth, :live_user_required}` hook runs
  # after this session hook and sends a signed-out visitor to sign-in,
  # and each view's own unconfirmed clause sends an unconfirmed user to
  # the dashboard. Answering here first would either crash on a nil user
  # or bounce an unconfirmed user between Connect and the dashboard.
  #
  # Connect itself is exempt before any query runs, so the page the gate
  # redirects to never pays for the gate.
  defp gate_applies?(socket) do
    case socket.assigns[:current_user] do
      %{confirmed_at: nil} -> false
      nil -> false
      _user -> socket.view not in @exempt_views
    end
  end

  defp gate(socket, org_token, project_token) do
    socket = OrgContext.assign_org_context(socket, org_token)
    project = OrgContext.project_for_token!(socket, project_token)
    socket = assign(socket, :project, project)

    if Alplus.Audit.agent_connected?(socket.assigns.org_id, project.id) do
      # The gate has already paid for this answer, so the shell's top bar
      # states it on every project screen without a second read.
      {:cont, assign(socket, :agent_connected?, true)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:info, "Connect an agent to open this project.")
       |> Phoenix.LiveView.push_navigate(
         to:
           ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{project.public_token}/connect"
       )}
    end
  end
end
