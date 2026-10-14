defmodule AlplusWeb.AgentConnectionLive do
  @moduledoc "Resumable, project-scoped agent activation runway."

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1]

  require Ash.Query

  alias Alplus.Audit.AuditLog
  alias Alplus.Mcp.Confirmations
  alias AlplusWeb.Onboarding

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(
        %{"org_token" => _org_token, "project_token" => _project_token},
        _session,
        %{assigns: %{current_user: %{confirmed_at: nil}}} = socket
      ) do
    {:ok,
     socket
     |> put_flash(:info, "Confirm your email before connecting an agent.")
     |> push_navigate(to: ~p"/dashboard")}
  end

  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Connect an agent",
             active: :projects
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)
      endpoint = mcp_endpoint(socket.assigns.org)

      socket =
        socket
        |> assign(:scope, scope)
        |> assign(:project, project)
        |> assign(:mcp_endpoint, endpoint)
        |> assign(
          :mcp_setup_prompt,
          mcp_setup_prompt(endpoint, project.name, project.public_token)
        )
        |> assign(:handshake, nil)
        |> assign(:status_message, "Waiting for a verified agent call on this project.")
        |> assign(:agent_audit_state, if(can_manage?(scope), do: :loading, else: :hidden))
        |> assign(:agent_audit_trail, [])
        |> assign(:confirmations, [])
        |> assign(:confirmations_state, if(can_manage?(scope), do: :loading, else: :hidden))
        |> assign(:agent_audit_error, nil)
        |> assign(
          :project_connected?,
          Alplus.Audit.agent_connected?(socket.assigns.org_id, project.id)
        )
        |> assign_activation()

      {:ok, if(connected?(socket), do: load_connection(socket), else: socket)}
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
      nav_projects={@nav_projects}
      scope={@scope}
      current_user={@current_user}
      active={:connect}
      page_title="Connect an agent"
      page_heading?={false}
      nav_project={@project}
      nav_locked?={not @project_connected?}
    >
      <.console_page id="agent-connection-page">
        <:title>
          {if @project_connected?, do: "Your agent is connected", else: "Connect your agent"}
        </:title>
        <section id="agent-connection" class="flex min-w-0 flex-col gap-4">
          <%!-- One card: the task to hand over, the one field a client asks
                for by hand, the one button that proves it worked, and the
                answer. --%>
          <.data_panel id="agent-connection-panel" padded class="min-w-0">
            <:actions>
              <span id="agent-scope">
                <.status_dot
                  tone={if(@project_connected?, do: "live", else: "neutral")}
                  label={if(@project_connected?, do: "Connected", else: "Not connected yet")}
                />
              </span>
            </:actions>
            <div id="remote-mcp-setup" class="flex min-w-0 flex-col gap-4">
              <p class="text-body text-text-secondary">
                Paste this into your MCP client. It opens a browser so you can sign in and
                approve access for <span
                  id="agent-scope-project"
                  class="font-medium text-text-primary"
                >every project in {@org.name}</span>, including projects added later.
              </p>
              <div class="relative">
                <pre
                  id="remote-mcp-setup-prompt"
                  class="max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-control bg-surface-sunken p-4 pr-24 font-mono text-data leading-relaxed text-text-primary"
                >{@mcp_setup_prompt}</pre>
                <div class="absolute right-3 top-3">
                  <.copy_button target="remote-mcp-setup-prompt" />
                </div>
              </div>
              <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
                <span class="text-label text-text-tertiary">Endpoint</span>
                <code
                  id="remote-mcp-endpoint"
                  class="min-w-0 break-all font-mono text-data text-text-primary"
                >{@mcp_endpoint}</code>
                <.copy_button target="remote-mcp-endpoint" />
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <.button
                  id="check-remote-connection"
                  variant="primary"
                  phx-click="check_remote_connection"
                >
                  Check connection
                </.button>
                <div id="agent-webmcp-panel" phx-hook=".WebMcpOption">
                  <.button
                    id="check-webmcp-connection"
                    variant="secondary"
                    phx-click="check_webmcp_connection"
                  >
                    Check this browser's agent
                  </.button>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".WebMcpOption">
                    export default {
                      mounted() {
                        const context = document.modelContext
                        const supported = window.isSecureContext && context &&
                          (typeof context.registerTool === "function" || typeof context.provideContext === "function")
                        if (!supported) this.el.hidden = true
                      }
                    }
                  </script>
                </div>
              </div>
            </div>
            <:footer>
              <span id="agent-connection-status" role="status" aria-live="polite">
                <span :if={is_nil(@handshake)}>{@status_message}</span>
                <span :if={@handshake} id="agent-handshake">
                  Agent connected. Last verified call:
                  <span id="handshake-operation" class="font-mono">{@handshake.operation}</span>
                  over <span id="handshake-transport">{@handshake.transport}</span>, <span id="handshake-access">{@handshake.access}</span>.
                  <.link
                    id="open-project-analysis"
                    navigate={
                      ~p"/dashboard/orgs/#{@org.public_token}/projects/#{@project.public_token}"
                    }
                    class="font-medium text-interactive-strong hover:underline"
                  >
                    Open the project
                  </.link>
                </span>
                <span
                  :if={is_nil(@handshake) and not @project_connected?}
                  id="agent-connection-help-steps"
                >
                  If nothing arrives, restart your MCP client and ask it to run a tool on this project, then check again.
                </span>
              </span>
            </:footer>
          </.data_panel>

          <.data_panel
            :if={
              @agent_audit_state in [:ready, :error] and
                (@agent_audit_trail != [] or @agent_audit_state == :error)
            }
            id="agent-audit-trail"
            title="Recent agent calls"
            class="min-w-0"
          >
            <.error_boundary :if={@agent_audit_state == :error} id="agent-audit-trail-error">
              {@agent_audit_error}
            </.error_boundary>
            <ul
              :if={@agent_audit_state == :ready}
              id="agent-audit-trail-table"
              class="divide-y divide-border-subtle"
            >
              <li
                :for={entry <- exceptions_first(@agent_audit_trail)}
                id={"agent-audit-#{entry.id}"}
                class="flex flex-wrap items-center justify-between gap-x-6 gap-y-1 px-5 py-3"
              >
                <span class="flex min-w-0 items-center gap-x-3">
                  <span class="font-mono text-data text-text-primary">{entry.action}</span>
                  <span class="text-caption text-text-tertiary">{transport_label(entry.transport)}</span>
                </span>
                <.status_badge
                  tone={agent_audit_outcome_tone(entry.outcome)}
                  label={String.capitalize(entry.outcome)}
                />
              </li>
            </ul>
          </.data_panel>
          <.data_panel
            :if={@confirmations_state == :ready}
            id="pending-confirmations"
            title="Pending confirmations"
            description="Destructive agent actions wait here until an owner or admin approves them."
            class="min-w-0"
          >
            <div
              :if={@confirmations == []}
              id="pending-confirmations-empty"
              class="px-5 py-4 text-caption text-text-secondary"
            >
              No pending destructive actions.
            </div>
            <ul
              :if={@confirmations != []}
              id="pending-confirmations-list"
              class="divide-y divide-border-subtle"
            >
              <li
                :for={confirmation <- @confirmations}
                id={"pending-confirmation-#{confirmation.id}"}
                class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 px-5 py-3"
              >
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <span class="font-mono text-data text-text-primary">{confirmation.action}</span>
                    <.status_badge
                      tone={confirmation_status_tone(confirmation.status)}
                      label={confirmation_status_label(confirmation.status)}
                    />
                  </div>
                  <p class="mt-1 text-caption text-text-tertiary">
                    Requested <.timestamp at={confirmation.requested_at} />
                  </p>
                  <p
                    :if={confirmation.status == "failed"}
                    class="mt-1 text-caption text-status-error-ink"
                  >
                    {confirmation.error || "The action could not be completed."}
                  </p>
                  <p
                    :if={confirmation.status == "approved"}
                    class="mt-1 text-caption text-status-live-ink"
                  >
                    Action completed.
                  </p>
                </div>
                <div :if={confirmation.status == "pending"} class="flex flex-wrap gap-2">
                  <.button
                    id={"approve-confirmation-#{confirmation.id}"}
                    variant="primary"
                    phx-click="approve_confirmation"
                    phx-value-id={confirmation.id}
                  >
                    Approve
                  </.button>
                  <.button
                    id={"reject-confirmation-#{confirmation.id}"}
                    variant="secondary"
                    phx-click="reject_confirmation"
                    phx-value-id={confirmation.id}
                  >
                    Reject
                  </.button>
                </div>
              </li>
            </ul>
          </.data_panel>
          <.permission_notice
            :if={@agent_audit_state == :hidden}
            id="agent-audit-trail-permission"
            message="Ask an organization owner or admin to review this project's agent activity."
          />
        </section>
      </.console_page>
    </.dashboard_shell>
    """
  end

  @impl true
  def handle_event("check_remote_connection", _params, socket),
    do: {:noreply, check_connection(socket, "remote_mcp")}

  def handle_event("check_webmcp_connection", _params, socket),
    do: {:noreply, check_connection(socket, "webmcp")}

  def handle_event("approve_confirmation", %{"id" => id}, socket) do
    case Confirmations.approve(socket.assigns.scope, id) do
      {:ok, confirmation} ->
        {:noreply,
         socket
         |> put_flash(:info, confirmation_result_copy(confirmation))
         |> load_confirmations()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You no longer have permission to approve this action.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That confirmation is no longer available.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "The confirmation could not be approved. Try again.")}
    end
  end

  def handle_event("reject_confirmation", %{"id" => id}, socket) do
    case Confirmations.reject(socket.assigns.scope, id) do
      {:ok, _confirmation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Action rejected. Nothing was changed.")
         |> load_confirmations()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You no longer have permission to reject this action.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That confirmation is no longer available.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "The confirmation could not be rejected. Try again.")}
    end
  end

  defp check_connection(socket, transport) do
    socket
    |> load_handshake(transport)
    |> sync_connected()
    |> load_agent_audit_trail()
    |> load_confirmations()
    |> assign_activation()
  end

  defp load_connection(socket) do
    socket
    |> load_handshake(nil)
    |> sync_connected()
    |> load_agent_audit_trail()
    |> load_confirmations()
    |> assign_activation()
  end

  # A verified handshake proves the connection, so the rail unlocks in place
  # instead of waiting for a reload. A transport-specific check that finds
  # nothing never re-locks: an agent that has reached this project once has
  # reached it, and the audit record is append-only.
  defp sync_connected(%{assigns: %{handshake: nil}} = socket), do: socket
  defp sync_connected(socket), do: assign(socket, :project_connected?, true)

  defp load_handshake(socket, transport) do
    opts = if is_binary(transport), do: [transport: transport], else: []

    case Alplus.Audit.latest_allowed_agent_audit(
           socket.assigns.scope,
           socket.assigns.project.id,
           opts
         ) do
      {:ok, nil} ->
        assign(socket,
          handshake: nil,
          status_message: missing_audit_copy(socket, transport)
        )

      {:ok, audit} ->
        assign(socket,
          handshake: handshake_from(audit, socket),
          status_message: "Agent connection verified."
        )

      {:error, %Ash.Error.Forbidden{}} ->
        assign(socket,
          handshake: nil,
          status_message:
            "You cannot read connection evidence. Ask an organization owner or admin to confirm the handshake."
        )

      {:error, _reason} ->
        assign(socket,
          handshake: nil,
          status_message: "Connection evidence is temporarily unavailable. Try again shortly."
        )
    end
  end

  defp handshake_from(audit, socket) do
    %{
      project: socket.assigns.project.public_token,
      transport: audit.transport,
      operation: audit.action,
      access: handshake_access(audit, socket)
    }
  end

  defp handshake_access(%{transport: "webmcp"}, socket) do
    if socket.assigns.scope.role in ["owner", "admin"],
      do: access_label(:read_write),
      else: access_label(:read)
  end

  defp handshake_access(_audit, socket) do
    if socket.assigns.scope.role in ["owner", "admin"],
      do: access_label(:read_write),
      else: access_label(:read)
  end

  defp load_agent_audit_trail(socket) do
    scope = socket.assigns.scope

    if can_manage?(scope) do
      query =
        AuditLog
        |> Ash.Query.for_read(:read, %{}, actor: scope)
        |> Ash.Query.filter(
          org_id == ^scope.org_id and project_id == ^socket.assigns.project.id and
            actor_kind == "agent"
        )
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(8)

      case Ash.read(query) do
        {:ok, entries} ->
          assign(socket,
            agent_audit_trail: entries,
            agent_audit_state: :ready,
            agent_audit_error: nil
          )

        {:error, _reason} ->
          assign(socket,
            agent_audit_state: :error,
            agent_audit_error: "Agent activity is temporarily unavailable."
          )
      end
    else
      socket
    end
  end

  defp load_confirmations(socket) do
    if can_manage?(socket.assigns.scope) do
      case Confirmations.pending(socket.assigns.scope) do
        {:ok, confirmations} ->
          assign(socket, confirmations: confirmations, confirmations_state: :ready)

        {:error, _reason} ->
          assign(socket, confirmations: [], confirmations_state: :error)
      end
    else
      assign(socket, confirmations: [], confirmations_state: :hidden)
    end
  end

  defp assign_activation(socket) do
    user = socket.assigns.current_user

    activation =
      Onboarding.activation(%{
        user_confirmed?: not is_nil(user && user.confirmed_at),
        organization: socket.assigns[:org],
        project: socket.assigns[:project],
        audit: socket.assigns[:handshake],
        analysis: false
      })

    assign(socket, :activation, activation)
  end

  # Denied and failed calls are the ones a person acts on, so they lead the
  # list; successful calls keep their newest-first order after them.
  defp exceptions_first(entries) do
    Enum.sort_by(entries, &(agent_audit_outcome_tone(&1.outcome) != "error"))
  end

  defp missing_audit_copy(%{assigns: %{project_connected?: true}}, nil),
    do: "Connected. Open the project to review its activity."

  defp missing_audit_copy(_socket, "remote_mcp"),
    do:
      "No allowed remote MCP call for this project yet. Invoke a tool from the remote agent, then check again."

  defp missing_audit_copy(_socket, "webmcp"),
    do:
      "No allowed WebMCP call for this project yet. Invoke a tool from this browser's agent, then check again."

  defp missing_audit_copy(_socket, _transport),
    do: "Waiting for a verified agent call on this project."

  defp access_label(:read_write), do: "read and write"
  defp access_label(_access), do: "read"

  defp mcp_endpoint(%{public_token: public_token}) when is_binary(public_token),
    do: Alplus.Mcp.OAuth.resource_uri(public_token)

  defp mcp_setup_prompt(endpoint, project_name, project_ref) do
    """
    Set up a remote MCP server named "PostDeploy" for this organization.
    Endpoint: #{endpoint}
    Authentication: OAuth.

    Add this URL in the client. When the browser opens, sign in and approve Read or Read and write access for the organization.

    After connecting, run context.get with project_ref "#{project_ref}" to verify #{project_name}.
    Then run actions.read with project_ref "#{project_ref}", action monitor.list, and empty arguments.
    Tell me when the connection succeeds.
    """
    |> String.trim()
  end

  defp transport_label("remote_mcp"), do: "Remote MCP"
  defp transport_label("webmcp"), do: "WebMCP"
  defp transport_label("session"), do: "Session"
  defp transport_label(other), do: other

  defp confirmation_status_tone("pending"), do: "late"
  defp confirmation_status_tone("approved"), do: "success"
  defp confirmation_status_tone("failed"), do: "error"
  defp confirmation_status_tone("rejected"), do: "neutral"
  defp confirmation_status_tone("expired"), do: "neutral"
  defp confirmation_status_tone(_status), do: "neutral"

  defp confirmation_status_label(status), do: String.capitalize(status)

  defp confirmation_result_copy(%{status: "approved"}), do: "Action approved and completed."

  defp confirmation_result_copy(%{status: "failed"}),
    do: "Action approved but could not be completed."

  defp confirmation_result_copy(_confirmation), do: "Action approved."

  defp agent_audit_outcome_tone("allowed"), do: "success"
  defp agent_audit_outcome_tone("denied"), do: "error"
  defp agent_audit_outcome_tone(_outcome), do: "neutral"
end
