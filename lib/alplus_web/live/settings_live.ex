defmodule AlplusWeb.SettingsLive do
  @moduledoc """
  Org settings, under `/dashboard/` (ARCHITECTURE.md §4, §9, §14).

  Organization only — personal profile (display name, email) moved to
  `AlplusWeb.DashboardLive` at `/dashboard` (it was never an organization
  setting; editing your own profile has nothing to do with an org role).

  Organization name is readable by any member (`Organization`'s read
  policy) but editable only by `owner`/`admin` (`:update` policy). The
  subscription state and creation date shown alongside it come straight off the already
  loaded `@org` struct — zero extra queries. The audit log is readable
  only by `owner`/`admin` (`AuditLog`'s read policy) — a `member` never
  sees it, and `load_audit_logs/1` is only ever called for `owner`/`admin`.
  Connected MCP clients list through `Alplus.Mcp.list_oauth_grants/1`;
  revoke is `owner`/`admin` only via `Alplus.Mcp.revoke_oauth_grant/2`.
  """

  use AlplusWeb, :live_view
  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1, owner?: 1]

  require Ash.Query

  alias AshPhoenix.Form
  alias Alplus.Audit.AuditLog
  alias Alplus.Billing.Package
  alias Alplus.Mcp
  alias Alplus.Mcp.Scope, as: McpScope
  alias Alplus.Orgs.Membership

  @page_size 25

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Settings",
             active: :settings
           ) do
      scope = socket.assigns.scope

      socket =
        socket
        |> assign(:name_form, name_form(socket.assigns.org, scope))
        |> assign(:mcp_endpoint, organization_mcp_endpoint(socket.assigns.org))
        |> assign(
          :mcp_setup_prompt,
          organization_mcp_setup_prompt(organization_mcp_endpoint(socket.assigns.org))
        )
        |> assign(:org_name_notice, nil)
        |> stream(:audit_logs, [])
        |> assign(:audit_outcome, "all")
        |> assign(:audit_logs_empty?, true)
        |> assign(:audit_cursor, nil)
        |> assign(:audit_has_more?, false)
        |> assign(:audit_state, :loading)
        |> assign(:audit_error, nil)
        |> assign(:oauth_grants_state, :loading)
        |> assign(:oauth_grants_error, nil)
        |> assign(:revoke_confirm_id, nil)
        |> assign(:revoke_confirm_text, "")
        |> assign(:members_state, :loading)
        |> assign(:members_preview, [])
        |> assign(:delete_org_confirming?, false)
        |> assign(:delete_org_confirm_text, "")
        |> stream(:oauth_grants, [], dom_id: &"grant-#{&1.id}")

      socket =
        if connected?(socket) do
          load_members_preview(socket)
        else
          socket
        end

      socket =
        if connected?(socket) and can_manage?(scope) do
          socket |> load_audit_logs(nil) |> load_oauth_grants()
        else
          socket
        end

      {:ok, socket}
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
      active={:settings}
      page_title="Settings"
    >
      <.console_page id="settings-page">
        <div class="flex flex-col gap-4">
          <.summary_card
            id="org-summary"
            headline={@org.name}
            subtitle="Organization settings apply to everyone in this org."
            stats={[
              %{
                id: "org-stat-subscription",
                label: "Subscription",
                value: subscription_name(@org.billing_status)
              },
              %{id: "org-stat-role", label: "Your role", value: role_name(@scope.role)}
            ]}
          >
            <:actions>
              <.button
                :if={can_manage?(@scope)}
                navigate={~p"/dashboard/orgs/#{@org_token}/settings#org-agent-connection"}
                id="org-connect-agent"
                variant="primary"
              >
                Connect an agent
              </.button>
              <.button
                :if={can_manage?(@scope)}
                navigate={~p"/dashboard/orgs/#{@org_token}/billing"}
                id="org-view-billing"
                variant="secondary"
              >
                Billing
              </.button>
              <.button
                navigate={~p"/dashboard/orgs/#{@org_token}/settings/notifications"}
                id="org-view-notifications"
                variant="secondary"
              >
                Notifications
              </.button>
            </:actions>
          </.summary_card>

          <%!-- Two columns from `lg` up. A single `max-w-sm` form stacked on a
              `max-w-sm` fact list left ~950px of the panel empty and made a
              rename field look like an afterthought; pairing the editable name
              with the org's read-only facts uses the width the panel actually
              has. --%>
          <.data_panel
            id="org-settings"
            title="Organization"
            description="The name shown across the dashboard."
            padded
          >
            <div class="grid gap-4 lg:grid-cols-[2fr_1fr]">
              <div>
                <.form
                  :if={can_manage?(@scope)}
                  for={@name_form}
                  id="org-name-form"
                  phx-change="validate_name"
                  phx-submit="save_name"
                  phx-hook="FocusInvalid"
                >
                  <.input field={@name_form[:name]} type="text" label="Name" id="org-name" required />
                  <.button id="save-org-name" variant="primary" phx-disable-with="Saving...">
                    Save name
                  </.button>
                  <p
                    :if={@org_name_notice}
                    id="org-name-notice"
                    role="status"
                    aria-live="polite"
                    class="mt-3 text-data text-status-live-ink"
                  >
                    {@org_name_notice}
                  </p>
                </.form>

                <div :if={not can_manage?(@scope)}>
                  <.permission_notice
                    id="org-settings-permission"
                    message="You can view this organization. Only owners and administrators can change settings."
                  />
                  <div class="mt-4">
                    <span class="mb-1 block text-label text-text-secondary">Name</span>
                    <p id="org-name-readonly" class="text-body text-text-primary">{@org.name}</p>
                  </div>
                </div>
              </div>

              <div class="border-t border-border-subtle pt-6 lg:border-l lg:border-t-0 lg:pl-10 lg:pt-0">
                <.definition_list>
                  <:row label="Created">
                    <.timestamp at={@org.inserted_at} />
                  </:row>
                </.definition_list>
              </div>
            </div>

            <%!-- Members preview: who has access, at a glance, ending in an
                "Invite a teammate" row that hands off to the full Team page
                — role changes, invitations, and removal stay there so this
                page never carries a second copy of that mutation logic. --%>
            <div id="org-members-preview" class="mt-8 border-t border-border-subtle pt-6">
              <%!-- A group title, not an eyebrow: uppercase in the console is
                    reserved for table column headers. --%>
              <p class="text-ui font-semibold text-text-primary">Members</p>
              <div :if={@members_state == :loading} class="mt-3">
                <.skeleton rows={2} />
              </div>
              <ul :if={@members_state == :ready} class="mt-3 divide-y divide-border-subtle">
                <li
                  :for={member <- @members_preview}
                  id={"org-member-preview-#{member.id}"}
                  class="flex items-center gap-3 py-2.5"
                >
                  <span class="inline-flex size-[26px] shrink-0 items-center justify-center rounded-dot bg-interactive-tint text-label font-semibold text-text-secondary">
                    {member_initial(member)}
                  </span>
                  <span class="min-w-0 flex-1 truncate text-body text-text-primary">
                    {member_display_name(member)}
                  </span>
                  <span class="shrink-0 text-label text-text-tertiary">{role_name(member.role)}</span>
                </li>
                <li>
                  <.link
                    navigate={~p"/dashboard/orgs/#{@org_token}/team"}
                    id="org-members-invite"
                    class="flex min-h-target-min items-center gap-3 py-2.5 text-body font-medium text-text-primary hover:text-interactive-strong"
                  >
                    <span class="inline-flex size-[26px] shrink-0 items-center justify-center rounded-dot border border-dashed border-border-control text-text-tertiary">
                      +
                    </span>
                    Invite a teammate
                  </.link>
                </li>
              </ul>
            </div>

            <%!-- Danger zone: destroys `Alplus.Orgs.Organization` through its
                real owner-only `:destroy` action (audited). Asks twice on
                purpose — the trigger reveals a typed-confirmation panel,
                never a single click. --%>
            <div
              :if={owner?(@scope)}
              id="org-danger-zone"
              class="mt-8 rounded-control border border-status-error-border bg-surface-raised p-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div class="min-w-0 flex-1">
                  <p class="font-semibold text-status-error-ink">Delete this organization</p>
                  <p class="mt-0.5 text-body text-text-secondary">
                    Removes every project, monitor, and page. Asks twice.
                  </p>
                </div>
                <.destructive_confirm
                  id="org-delete"
                  mode={:typed}
                  match={@org.name}
                  confirming={@delete_org_confirming?}
                  consequence="Removes every project, monitor and page in this organization. This cannot be undone."
                  trigger_label="Delete organization"
                  confirm_label="Confirm delete"
                  trigger_event="confirm_delete_org"
                  cancel_event="cancel_delete_org"
                  confirm_event="delete_org"
                  input_event="delete_org_input"
                  input_value={@delete_org_confirm_text}
                  value_name="org_id"
                  value={@org.id}
                />
              </div>
            </div>
          </.data_panel>

          <.data_panel
            :if={can_manage?(@scope)}
            id="org-agent-connection"
            title="Connect an agent"
            description="Authorize one agent for every current and future project in this organization."
            padded
          >
            <div class="flex min-w-0 flex-col gap-4">
              <p class="text-body text-text-secondary">
                Paste this setup request into your MCP client. Your browser opens so you can
                confirm the account, client, organization, and access level.
              </p>
              <div class="relative">
                <pre
                  id="org-mcp-setup-prompt"
                  class="max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-control bg-surface-sunken p-4 pr-24 font-mono text-data leading-relaxed text-text-primary"
                >{@mcp_setup_prompt}</pre>
                <div class="absolute right-3 top-3">
                  <.copy_button target="org-mcp-setup-prompt" />
                </div>
              </div>
              <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
                <span class="text-label text-text-tertiary">Endpoint</span>
                <code
                  id="org-mcp-endpoint"
                  class="min-w-0 break-all font-mono text-data text-text-primary"
                >{@mcp_endpoint}</code>
                <.copy_button target="org-mcp-endpoint" />
              </div>
              <p class="text-caption text-text-secondary">
                After approval, ask the client to run <code class="font-mono">context.get</code>.
                The connection then appears below with its last use.
              </p>
            </div>
          </.data_panel>

          <.data_panel
            :if={can_manage?(@scope)}
            id="connected-mcp-clients"
            title="Connected MCP Clients"
            description="OAuth clients that currently have access to this organization."
          >
            <div :if={@oauth_grants_state == :loading} id="connected-mcp-clients-loading" class="p-4">
              <.skeleton rows={3} />
            </div>
            <.error_boundary
              :if={@oauth_grants_state == :error}
              id="connected-mcp-clients-error"
              retry="retry_oauth_grants"
            >
              {@oauth_grants_error}
            </.error_boundary>

            <div
              :if={@oauth_grants_state == :ready}
              class="relative min-w-0 max-w-full overflow-x-auto"
              data-density="dense"
            >
              <table class="w-full text-left text-data">
                <thead>
                  <tr class="border-b border-border-default">
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Client</th>
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Account</th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary lg:table-cell"
                    >
                      Organization
                    </th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary sm:table-cell"
                    >
                      Project scope
                    </th>
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Access</th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary sm:table-cell"
                    >
                      Connected
                    </th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary lg:table-cell"
                    >
                      Last used
                    </th>
                    <th scope="col" class="px-4 py-2 text-right font-medium text-text-tertiary">
                      <span class="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody
                  id="connected-mcp-client-rows"
                  phx-update="stream"
                  class="divide-y divide-border-default"
                >
                  <tr id="connected-mcp-clients-none" class="hidden only:table-row">
                    <td colspan="8" class="px-4 py-5 text-body text-text-secondary">
                      No connected MCP clients.
                    </td>
                  </tr>
                  <tr :for={{dom_id, grant} <- @streams.oauth_grants} id={dom_id}>
                    <% confirming? = @revoke_confirm_id == grant.id %>
                    <td :if={not confirming?} class="px-4 py-3 font-medium text-text-primary">
                      {grant_client_name(grant)}
                    </td>
                    <td :if={not confirming?} class="px-4 py-3 text-text-secondary">
                      {grant_account(grant)}
                    </td>
                    <td
                      :if={not confirming?}
                      class="hidden px-4 py-3 text-text-secondary lg:table-cell"
                    >
                      {grant_org_name(grant)}
                    </td>
                    <td
                      :if={not confirming?}
                      class="hidden px-4 py-3 text-text-secondary sm:table-cell"
                    >
                      {grant_project_name(grant)}
                    </td>
                    <td :if={not confirming?} class="px-4 py-3 text-text-secondary">
                      <%!-- One summary per client; the full capability list sits
                            behind a disclosure so the row stays one line. --%>
                      <details class="min-w-0">
                        <summary class="cursor-pointer list-none text-text-primary hover:underline">
                          {grant_access_level(grant)}
                        </summary>
                        <ul class="mt-1.5 flex flex-col gap-0.5 text-label">
                          <li :for={label <- grant_scope_labels(grant)}>{label}</li>
                        </ul>
                      </details>
                    </td>
                    <td :if={not confirming?} class="hidden px-4 py-3 sm:table-cell">
                      <.timestamp at={grant.inserted_at} />
                    </td>
                    <td :if={not confirming?} class="hidden px-4 py-3 lg:table-cell">
                      <.timestamp at={grant.last_used_at} />
                    </td>
                    <td :if={not confirming?} class="px-4 py-3 text-right">
                      <.destructive_confirm
                        id={"revoke-#{grant.id}"}
                        mode={:typed}
                        match={grant_client_name(grant)}
                        confirming={false}
                        consequence="This client loses access immediately. Existing tokens stop working. This cannot be undone."
                        trigger_label="Revoke"
                        confirm_label="Confirm revoke"
                        trigger_event="confirm_revoke"
                        cancel_event="cancel_revoke"
                        confirm_event="revoke_grant"
                        input_event="revoke_input"
                        input_value={@revoke_confirm_text}
                        value_name="grant_id"
                        value={grant.id}
                      />
                    </td>
                    <%!-- A typed-confirm panel does not fit the action cell:
                        the confirming row collapses to one full-width cell,
                        one `<tr>` per stream item (the TeamLive recipe). --%>
                    <td :if={confirming?} colspan="8" class="px-4 py-3">
                      <.destructive_confirm
                        id={"revoke-#{grant.id}"}
                        mode={:typed}
                        match={grant_client_name(grant)}
                        confirming={true}
                        consequence="This client loses access immediately. Existing tokens stop working. This cannot be undone."
                        trigger_label="Revoke"
                        confirm_label="Confirm revoke"
                        trigger_event="confirm_revoke"
                        cancel_event="cancel_revoke"
                        confirm_event="revoke_grant"
                        input_event="revoke_input"
                        input_value={@revoke_confirm_text}
                        value_name="grant_id"
                        value={grant.id}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.data_panel>

          <.data_panel
            :if={can_manage?(@scope)}
            id="audit-panel"
            title="Audit log"
            description="Every action taken in this organization, including denied attempts."
          >
            <form
              :if={@audit_state != :loading}
              id="audit-filter"
              phx-change="filter_audit"
              class="flex flex-wrap items-center gap-3 border-b border-border-default px-4 py-3"
            >
              <label for="audit-outcome" class="text-label font-medium text-text-secondary">
                Show
              </label>
              <select
                id="audit-outcome"
                name="outcome"
                class="min-h-target-min rounded-dot border border-border-control bg-surface-raised px-3 text-label text-text-primary"
              >
                <option value="all" selected={@audit_outcome == "all"}>All events</option>
                <option value="exceptions" selected={@audit_outcome == "exceptions"}>
                  Denied and failed only
                </option>
              </select>
            </form>
            <div :if={@audit_state == :loading} id="audit-loading" class="p-4">
              <.skeleton rows={4} />
            </div>
            <.error_boundary :if={@audit_state == :error} id="audit-error" retry="retry_audit">
              {@audit_error}
            </.error_boundary>

            <div
              :if={@audit_state == :ready}
              class="relative min-w-0 max-w-full overflow-x-auto"
              data-density="dense"
            >
              <table class="w-full text-left text-data">
                <thead>
                  <tr class="border-b border-border-default">
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Action</th>
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Subject</th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary sm:table-cell"
                    >
                      Project
                    </th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary md:table-cell"
                    >
                      Actor
                    </th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary sm:table-cell"
                    >
                      When
                    </th>
                    <th scope="col" class="px-4 py-2 text-right font-medium text-text-tertiary">
                      Outcome
                    </th>
                  </tr>
                </thead>
                <tbody id="audit-log" phx-update="stream" class="divide-y divide-border-default">
                  <tr id="audit-log-empty" class="hidden only:table-row">
                    <td colspan="6" class="p-0">
                      <.empty_state
                        icon="hero-clipboard-document-list"
                        title={
                          if @audit_outcome == "exceptions",
                            do: "No denied or failed events",
                            else: "No audit events yet"
                        }
                        description="Actions taken in this organization show up here."
                        class="border-0"
                      />
                    </td>
                  </tr>
                  <tr :for={{dom_id, log} <- @streams.audit_logs} id={dom_id}>
                    <td class="px-4 py-3">
                      <span
                        id={"audit-action-#{log.id}"}
                        class="font-mono text-label text-text-primary"
                      >
                        {log.action}
                      </span>
                    </td>
                    <td class="px-4 py-3">
                      <p class="text-text-primary">{log.subject_type}</p>
                      <p
                        :if={log.subject_id}
                        class="max-w-[9rem] truncate font-mono text-label text-text-tertiary sm:max-w-measure"
                        title={log.subject_id}
                      >
                        {log.subject_id}
                      </p>
                      <%!-- Request id and client sit behind one disclosure: they
                            matter when a support case needs them, not on scan.
                            Below `sm` the same disclosure also carries project,
                            actor and time, so nothing is lost when columns fold. --%>
                      <details id={"audit-details-#{log.id}"} class="mt-1 text-label">
                        <summary class="cursor-pointer list-none text-text-tertiary hover:underline">
                          Details
                        </summary>
                        <dl class="mt-1.5 grid gap-x-3 gap-y-1 sm:grid-cols-[auto_minmax(0,1fr)]">
                          <dt class="text-text-tertiary sm:hidden">Project</dt>
                          <dd class="sm:hidden">{project_label(log)}</dd>
                          <dt class="text-text-tertiary md:hidden">Actor</dt>
                          <dd class="md:hidden">{actor_label(log.actor)}</dd>
                          <dt class="text-text-tertiary sm:hidden">When</dt>
                          <dd class="sm:hidden"><.timestamp at={log.inserted_at} /></dd>
                          <dt class="text-text-tertiary">Request id</dt>
                          <dd id={"audit-request-#{log.id}"} class="min-w-0 break-all font-mono">
                            {log.request_id || "Not available"}
                          </dd>
                          <dt class="text-text-tertiary">Client</dt>
                          <dd class="min-w-0 break-words">{log.user_agent || "Not available"}</dd>
                        </dl>
                      </details>
                    </td>
                    <td
                      id={"audit-project-#{log.id}"}
                      class="hidden max-w-measure truncate px-4 py-3 text-text-secondary sm:table-cell"
                    >
                      {project_label(log)}
                    </td>
                    <td
                      id={"audit-actor-#{log.id}"}
                      class="hidden px-4 py-3 text-text-secondary md:table-cell"
                    >
                      {actor_label(log.actor)}
                    </td>
                    <td class="hidden px-4 py-3 text-text-tertiary sm:table-cell">
                      <.timestamp at={log.inserted_at} />
                    </td>
                    <td class="px-4 py-3 text-right">
                      <span id={"audit-outcome-#{log.id}"}>
                        <.status_badge
                          tone={audit_outcome_tone(log.outcome)}
                          label={to_string(log.outcome)}
                        />
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div
              :if={@audit_state == :ready and @audit_has_more?}
              class="border-t border-border-default px-4 py-3"
            >
              <.button
                id="audit-log-load-more"
                variant="secondary"
                phx-click="load_more_audit"
                phx-disable-with="Loading..."
              >
                Load more
              </.button>
            </div>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp audit_outcome_tone("allowed"), do: "success"
  defp audit_outcome_tone("denied"), do: "error"
  defp audit_outcome_tone(_outcome), do: "neutral"

  # `actor_id` is `allow_nil? false` and every audited row has a real user
  # actor, but `belongs_to :actor` still resolves to `nil` if that user's
  # own read policy (`Alplus.Accounts.User`'s `exists(memberships, ...)`
  # clause) can no longer authorize it for this viewer's scope — e.g. the
  # actor has since left the org. That is filtered, not raised, so this
  # always has a label to show.
  defp actor_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_label(%{email: email}) when not is_nil(email), do: to_string(email)
  defp actor_label(_actor), do: "Unknown"

  defp project_label(%{project: project, project_id: project_id}) do
    cond do
      is_map(project) and is_binary(Map.get(project, :name)) and Map.get(project, :name) != "" ->
        Map.get(project, :name)

      is_binary(project_id) ->
        project_id

      true ->
        "Organization"
    end
  end

  defp subscription_name(:trialing), do: "Trial"
  defp subscription_name(_status), do: Package.get().name

  # The scope's role is a cache, never the authorization gate (every Ash policy
  # re-checks the live membership row). Displaying it is exactly what a cache
  # is safe for.
  defp role_name(nil), do: "Unknown"
  defp role_name(role), do: String.capitalize(role)

  defp member_initial(%{user: %{name: name}}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp member_initial(%{user: %{email: email}}) when not is_nil(email),
    do: email |> to_string() |> String.first() |> String.upcase()

  defp member_initial(_member), do: "?"

  defp member_display_name(%{user: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp member_display_name(%{user: %{email: email}}), do: to_string(email)
  defp member_display_name(_member), do: "Unknown"

  defp grant_client_name(%{oauth_client: %{client_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp grant_client_name(_grant), do: "Unknown client"

  defp grant_account(%{user: %{email: email}}) when not is_nil(email), do: to_string(email)
  defp grant_account(%{user: %{name: name}}) when is_binary(name) and name != "", do: name
  defp grant_account(_grant), do: "Unknown"

  defp grant_org_name(%{organization: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp grant_org_name(_grant), do: "Organization"

  defp grant_project_name(%{scope_mode: "organization"}), do: "All projects"
  defp grant_project_name(%{project: %{name: name}}) when is_binary(name) and name != "", do: name
  defp grant_project_name(_grant), do: "Project"

  defp grant_access_level(%{scopes: scopes}) when is_list(scopes) do
    if Enum.any?(scopes, &(is_binary(&1) and String.ends_with?(&1, ":write"))),
      do: "Read and write",
      else: "Read"
  end

  defp grant_access_level(_grant), do: "Read"

  defp grant_scope_labels(%{scopes: scopes}) when is_list(scopes) do
    McpScope.labels(Enum.join(scopes, " "))
  end

  defp grant_scope_labels(%{scopes: scopes}) when is_binary(scopes) do
    McpScope.labels(scopes)
  end

  defp grant_scope_labels(_grant), do: []

  @impl true
  def handle_event("validate_name", %{"organization" => params}, socket) do
    if can_manage?(socket.assigns.scope) do
      form = socket.assigns.name_form |> Form.validate(params, errors: false) |> to_form()
      {:noreply, assign(socket, name_form: form, org_name_notice: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_name", %{"organization" => params}, socket) do
    scope = socket.assigns.scope

    if can_manage?(scope) do
      case Form.submit(socket.assigns.name_form, params: params) do
        {:ok, org} ->
          {:noreply,
           socket
           |> assign(:org, org)
           |> assign(:name_form, name_form(org, scope))
           |> assign(:org_name_notice, "Organization updated.")
           |> put_flash(:info, "Organization updated.")}

        {:error, form} ->
          {:noreply, assign(socket, :name_form, to_form(form))}
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot update this org.")}
    end
  end

  # The danger zone destroys the real `Alplus.Orgs.Organization` `:destroy`
  # action (owner-only policy, audited). Confirming twice on purpose: the
  # trigger reveals a typed-confirmation panel, never a single click.
  def handle_event("confirm_delete_org", %{"org_id" => _org_id}, socket) do
    if owner?(socket.assigns.scope) do
      {:noreply, assign(socket, delete_org_confirming?: true, delete_org_confirm_text: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_delete_org", %{"org_id" => _org_id}, socket) do
    {:noreply, assign(socket, delete_org_confirming?: false, delete_org_confirm_text: "")}
  end

  def handle_event("delete_org_input", %{"org_id" => _org_id, "confirm_text" => text}, socket) do
    {:noreply, assign(socket, :delete_org_confirm_text, text)}
  end

  def handle_event("delete_org", %{"org_id" => _org_id, "confirm_text" => text}, socket) do
    scope = socket.assigns.scope
    org = socket.assigns.org

    if owner?(scope) and text == org.name do
      case Ash.destroy(org, action: :destroy, actor: scope) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Organization deleted.")
           |> push_navigate(to: ~p"/dashboard")}

        {:error, _reason} ->
          {:noreply,
           assign(socket, delete_org_confirming?: false, delete_org_confirm_text: "")
           |> put_flash(:error, "Could not delete this organization.")}
      end
    else
      {:noreply,
       assign(socket, delete_org_confirming?: false, delete_org_confirm_text: "")
       |> put_flash(:error, "Only the organization owner can delete this organization.")}
    end
  end

  def handle_event("filter_audit", %{"outcome" => outcome}, socket) do
    outcome = if outcome == "exceptions", do: "exceptions", else: "all"

    if can_manage?(socket.assigns.scope) do
      {:noreply,
       socket
       |> assign(:audit_outcome, outcome)
       |> assign(:audit_state, :loading)
       |> load_audit_logs(nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_more_audit", _params, socket) do
    if can_manage?(socket.assigns.scope) and socket.assigns.audit_has_more? do
      {:noreply, load_audit_logs(socket, socket.assigns.audit_cursor)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_audit", _params, socket) do
    if can_manage?(socket.assigns.scope) do
      {:noreply, socket |> assign(:audit_state, :loading) |> load_audit_logs(nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_oauth_grants", _params, socket) do
    if can_manage?(socket.assigns.scope) do
      {:noreply, socket |> assign(:oauth_grants_state, :loading) |> load_oauth_grants()}
    else
      {:noreply, socket}
    end
  end

  # Grants render inside a `phx-update="stream"` table, so a row only
  # re-renders on an explicit `stream_insert` (the TeamLive recipe).
  def handle_event("confirm_revoke", %{"grant_id" => id}, socket) do
    if can_manage?(socket.assigns.scope) do
      with_oauth_grant(socket, id, fn socket, grant ->
        socket
        |> assign(revoke_confirm_id: grant.id, revoke_confirm_text: "")
        |> stream_insert(:oauth_grants, grant)
      end)
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_revoke", %{"grant_id" => id}, socket) do
    if can_manage?(socket.assigns.scope) do
      with_oauth_grant(socket, id, fn socket, grant ->
        socket
        |> assign(revoke_confirm_id: nil, revoke_confirm_text: "")
        |> stream_insert(:oauth_grants, grant)
      end)
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke_input", %{"grant_id" => id, "confirm_text" => text}, socket) do
    if can_manage?(socket.assigns.scope) do
      with_oauth_grant(socket, id, fn socket, grant ->
        socket
        |> assign(:revoke_confirm_text, text)
        |> stream_insert(:oauth_grants, grant)
      end)
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke_grant", %{"grant_id" => id, "confirm_text" => text}, socket) do
    scope = socket.assigns.scope

    if can_manage?(scope) do
      case fetch_listed_grant(scope, id) do
        {:ok, grant} ->
          if text == grant_client_name(grant) do
            case Mcp.revoke_oauth_grant(grant, actor: scope) do
              {:ok, _revoked} ->
                {:noreply,
                 socket
                 |> assign(revoke_confirm_id: nil, revoke_confirm_text: "")
                 |> stream_delete(:oauth_grants, grant)
                 |> put_flash(:info, "Client access revoked.")}

              {:error, _reason} ->
                {:noreply, socket}
            end
          else
            {:noreply, socket}
          end

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp with_oauth_grant(socket, id, fun) do
    case fetch_listed_grant(socket.assigns.scope, id) do
      {:ok, grant} -> {:noreply, fun.(socket, grant)}
      :error -> {:noreply, socket}
    end
  end

  defp load_members_preview(socket) do
    scope = socket.assigns.scope
    org_id = socket.assigns.org_id

    query =
      Membership
      |> Ash.Query.for_read(:list_for_org, %{org_id: org_id}, actor: scope)
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.load(:user)
      |> Ash.Query.sort(inserted_at: :asc)

    case Ash.read(query, actor: scope) do
      {:ok, members} ->
        assign(socket, members_state: :ready, members_preview: members)

      {:error, _error} ->
        assign(socket, members_state: :error, members_preview: [])
    end
  end

  defp fetch_listed_grant(scope, id) do
    case Mcp.get_oauth_grant(id, actor: scope, load: [:oauth_client]) do
      {:ok, grant} ->
        if is_nil(grant.revoked_at) and grant.org_id == scope.org_id do
          {:ok, grant}
        else
          :error
        end

      {:error, _reason} ->
        :error
    end
  end

  defp organization_mcp_endpoint(%{public_token: public_token}) when is_binary(public_token),
    do: Alplus.Mcp.OAuth.resource_uri(public_token)

  defp organization_mcp_setup_prompt(endpoint) do
    """
    Connect an MCP client to #{endpoint} using OAuth.
    Open the browser sign-in and approve Read or Read and write access for this organization.
    Do not use a bearer token, API key, or query-string credential.
    After approval, call context.get to verify the organization and list its projects.
    Use the returned project_ref on every project-scoped action.
    """
    |> String.trim()
  end

  defp load_oauth_grants(socket) do
    scope = socket.assigns.scope

    case Mcp.list_oauth_grants(actor: scope) do
      {:ok, grants} ->
        socket
        |> stream(:oauth_grants, grants, reset: true)
        |> assign(:oauth_grants_state, :ready)
        |> assign(:oauth_grants_error, nil)

      {:error, _error} ->
        assign(socket,
          oauth_grants_state: :error,
          oauth_grants_error: "Connected clients could not be loaded."
        )
    end
  end

  defp filter_audit_outcome(query, "exceptions"),
    do: Ash.Query.filter(query, outcome != "allowed")

  defp filter_audit_outcome(query, _all), do: query

  defp load_audit_logs(socket, cursor) do
    scope = socket.assigns.scope
    org_id = socket.assigns.org_id

    query =
      AuditLog
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(org_id == ^org_id)
      |> filter_audit_outcome(socket.assigns[:audit_outcome])
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.load(:actor)
      |> Ash.Query.load(:project)
      |> Ash.Query.page(audit_page_options(cursor))

    case Ash.read(query, actor: scope) do
      {:ok, %Ash.Page.Keyset{} = page} ->
        page_logs = page.results

        next_cursor =
          if page.more?, do: page_logs |> List.last() |> Ash.Resource.get_metadata(:keyset)

        socket
        |> stream(:audit_logs, page_logs, reset: is_nil(cursor))
        |> assign(:audit_logs_empty?, is_nil(cursor) and page_logs == [])
        |> assign(:audit_cursor, next_cursor)
        |> assign(:audit_has_more?, page.more?)
        |> assign(:audit_state, :ready)
        |> assign(:audit_error, nil)

      {:error, _error} ->
        assign(socket, audit_state: :error, audit_error: "Audit events could not be loaded.")
    end
  end

  defp audit_page_options(nil), do: [limit: @page_size]
  defp audit_page_options(cursor), do: [limit: @page_size, after: cursor]

  defp name_form(org, scope) do
    org
    |> Form.for_update(:update, domain: Alplus.Orgs, actor: scope, as: "organization")
    |> to_form()
  end
end
