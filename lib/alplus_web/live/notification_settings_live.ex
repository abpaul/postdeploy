defmodule AlplusWeb.NotificationSettingsLive do
  @moduledoc """
  Organization notification routing settings.

  This page assigns only the presentation maps returned by
  `Alplus.Notifications`. Channel configuration is decrypted inside that
  domain and is accepted here only from a submit event.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1]

  alias AshPhoenix.Form
  alias Alplus.Billing.Access
  alias Alplus.Notifications
  alias Alplus.Notifications.{AlertRule, Channel, ChannelConfig}

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @channel_options [
    {"Email", "email"},
    {"Slack", "slack"},
    {"Discord", "discord"},
    {"Webhook", "webhook"},
    {"Telegram", "telegram"}
  ]

  @trigger_options %{
    "observe" => [
      {"New issue", "new_issue"},
      {"Issue regression", "issue_regression"},
      {"Error spike", "error_spike"},
      {"Quota reached", "quota"}
    ],
    "monitor" => [
      {"Check down", "check_down"},
      {"Check recovered", "check_recovered"},
      {"SSL certificate expiring", "ssl_expiring"},
      {"Domain expiring", "domain_expiring"}
    ]
  }

  @impl true
  def mount(%{"org_token" => org_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Notification settings",
             active: :settings
           ) do
      scope = socket.assigns.scope
      project = List.first(socket.assigns.nav_projects)

      socket =
        socket
        |> assign(:channel_state, :loading)
        |> assign(:channel_error, nil)
        |> assign(:channel_form, channel_form(scope))
        |> assign(:channel_form_mode, :closed)
        |> assign(:channel_type, "email")
        |> assign(:channel_type_options, [])
        |> assign(:channel_gated_types, [])
        |> assign(:editing_channel_name, nil)
        |> assign(:editing_channel_id, nil)
        |> assign(:editing_channel_default, false)
        |> assign(:delete_channel_id, nil)
        |> assign(:channel_by_id, %{})
        |> assign(:channel_count, 0)
        |> assign(:rule_state, :loading)
        |> assign(:rule_error, nil)
        |> assign(:rule_form, rule_form(scope, project))
        |> assign(:rule_form_mode, :closed)
        |> assign(:rule_project_id, project && project.id)
        |> assign(:rule_module, "monitor")
        |> assign(:rule_trigger, "check_down")
        |> assign(:rule_edit_values, nil)
        |> assign(:delete_rule_id, nil)
        |> assign(:editing_rule_id, nil)
        |> assign(:rule_by_id, %{})
        |> assign(:delivery_state, :loading)
        |> assign(:delivery_error, nil)
        |> assign(:delivery_count, 0)
        |> assign(:rule_count, 0)
        |> stream(:notification_channels, [])
        |> stream(:notification_rules, [])
        |> stream(:notification_deliveries, [])

      socket =
        if connected?(socket) and can_manage?(scope) do
          socket
          |> load_channel_options()
          |> load_channels()
          |> load_rules()
          |> load_deliveries()
        else
          assign(socket, channel_state: :ready, rule_state: :ready, delivery_state: :ready)
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
      page_title="Notification settings"
    >
      <.console_page id="notification-settings-page">
        <div class="flex flex-col gap-4">
          <.summary_card
            id="notification-settings-summary"
            headline="Notification routing"
            subtitle="Send alerts to your team's email or webhook destinations."
            stats={[
              %{id: "notification-project-count", label: "Projects", value: length(@nav_projects)},
              %{id: "notification-rule-count", label: "Alert rules", value: @rule_count}
            ]}
          >
            <:actions>
              <.button navigate={~p"/dashboard/orgs/#{@org_token}/settings"} variant="secondary">
                Organization settings
              </.button>
            </:actions>
          </.summary_card>

          <.permission_notice
            :if={not can_manage?(@scope)}
            id="notification-settings-permission"
            message="You can view this organization. Only owners and administrators can manage notification routing."
          />

          <div :if={can_manage?(@scope)} class="flex flex-col gap-4">
            <.data_panel
              id="notification-channels"
              title="Notification channels"
              description="Secret values are stored encrypted and are not shown again after you save them."
            >
              <:actions>
                <.button
                  :if={@channel_form_mode == :closed}
                  id="new-notification-channel"
                  variant={if(@rule_form_mode == :closed, do: "primary", else: "secondary")}
                  phx-click="new_channel"
                >
                  Add channel
                </.button>
              </:actions>

              <div :if={@channel_form_mode != :closed} class="border-b border-border-default p-4">
                <.form
                  for={@channel_form}
                  id="notification-channel-form"
                  phx-submit="submit_channel"
                  class="grid gap-3 sm:grid-cols-2"
                >
                  <.input
                    name="channel[name]"
                    id="notification-channel-name"
                    label="Name"
                    type="text"
                    value={@editing_channel_name || ""}
                    placeholder="Primary alerts"
                    required
                  />
                  <.input
                    name="channel[type]"
                    id="notification-channel-type"
                    label="Type"
                    type="select"
                    options={@channel_type_options}
                    value={@channel_type}
                    phx-change="select_channel_type"
                  />

                  <div class="sm:col-span-2">
                    <p class="text-label text-text-secondary">Destination</p>
                    <p class="mt-1 text-label text-text-tertiary">
                      Replacement values are required when editing a channel. Existing secrets stay hidden.
                    </p>
                  </div>

                  <.input
                    :if={@channel_type == "email"}
                    name="channel[config][to]"
                    id="notification-channel-email"
                    label="Email address"
                    type="email"
                    value=""
                    placeholder="alerts@example.com"
                    required
                  />
                  <.input
                    :if={@channel_type in ["slack", "discord"]}
                    name="channel[config][webhook_url]"
                    id="notification-channel-webhook"
                    label="Webhook URL"
                    type="url"
                    value=""
                    placeholder="https://..."
                    required
                  />
                  <.input
                    :if={@channel_type == "webhook"}
                    name="channel[config][url]"
                    id="notification-channel-endpoint"
                    label="HTTPS endpoint"
                    type="url"
                    value=""
                    placeholder="https://example.com/alerts"
                    required
                  />
                  <.input
                    :if={@channel_type == "webhook"}
                    name="channel[config][secret]"
                    id="notification-channel-secret"
                    label="Signing secret"
                    type="password"
                    value=""
                    minlength="16"
                    maxlength="256"
                    placeholder="Enter a replacement secret"
                    required
                  />
                  <.input
                    :if={@channel_type == "telegram"}
                    name="channel[config][bot_token]"
                    id="notification-channel-bot-token"
                    label="Bot token"
                    type="password"
                    value=""
                    minlength="10"
                    maxlength="256"
                    placeholder="Enter a replacement token"
                    required
                  />
                  <.input
                    :if={@channel_type == "telegram"}
                    name="channel[config][chat_id]"
                    id="notification-channel-chat-id"
                    label="Chat ID"
                    type="text"
                    value=""
                    maxlength="64"
                    required
                  />
                  <.input
                    name="channel[is_default]"
                    id="notification-channel-default"
                    label="Use as the default channel"
                    type="checkbox"
                    checked={@editing_channel_default}
                  />
                  <div class="flex items-end gap-2">
                    <.button
                      id="notification-channel-submit"
                      type="submit"
                      variant={if(@rule_form_mode == :closed, do: "primary", else: "secondary")}
                    >
                      {if @channel_form_mode == :create, do: "Create channel", else: "Save channel"}
                    </.button>
                    <.button type="button" variant="secondary" phx-click="cancel_channel">
                      Cancel
                    </.button>
                  </div>
                </.form>
                <p
                  :if={@channel_type in @channel_gated_types}
                  id="notification-channel-billing-gate"
                  class="mt-2 text-label text-status-late-ink"
                >
                  This organization cannot add this channel type until its billing is active.
                </p>
              </div>

              <div :if={@channel_state == :loading} class="space-y-3 p-4">
                <.skeleton :for={_ <- 1..3} class="h-12 w-full" />
              </div>
              <div :if={@channel_state == :error} class="p-4">
                <p class="text-body text-status-error-ink">{@channel_error}</p>
                <.button class="mt-3" variant="secondary" phx-click="reload_channels">Try again</.button>
              </div>
              <div :if={@channel_state == :ready}>
                <.empty_state
                  :if={@channel_count == 0 and @channel_form_mode == :closed}
                  id="notification-channels-empty"
                  icon="hero-bell-slash"
                  title="No notification channels"
                  description="Add an encrypted destination before routing an alert."
                />
                <div :if={@channel_count > 0} id="notification-channels-table" data-density="dense">
                  <div
                    id="notification-channels-table-body"
                    phx-update="stream"
                    class="divide-y divide-border-subtle"
                  >
                    <div
                      :for={{dom_id, channel} <- @streams.notification_channels}
                      id={dom_id}
                      class="flex items-center gap-3.5 px-4 py-3"
                    >
                      <span class="flex size-[34px] shrink-0 items-center justify-center rounded-control bg-surface-sunken font-mono text-label font-bold text-text-secondary">
                        {channel_initials(channel.type)}
                      </span>
                      <span class="min-w-0 flex-1">
                        <span class="block truncate text-body font-semibold text-text-primary">
                          {channel.name}
                        </span>
                        <span class="block truncate text-label text-text-secondary">
                          {channel_type_label(channel.type)}: {channel.destination}
                        </span>
                      </span>
                      <div class="flex shrink-0 flex-wrap items-center justify-end gap-2">
                        <.status_badge
                          :if={channel.is_default}
                          tone="success"
                          icon="hero-star"
                          label="Default"
                        />
                        <button
                          type="button"
                          class="min-h-target-min rounded-control border border-border-control px-3 text-label font-medium text-text-primary hover:bg-interactive-tint"
                          phx-click="edit_channel"
                          phx-value-id={channel.id}
                        >
                          Edit
                        </button>
                        <button
                          :if={not channel.is_default}
                          type="button"
                          class="min-h-target-min px-2 text-label font-semibold text-interactive-strong hover:underline"
                          phx-click="make_default_channel"
                          phx-value-id={channel.id}
                        >
                          Make default
                        </button>
                        <%= if @delete_channel_id == channel.id do %>
                          <button
                            type="button"
                            class="min-h-target-min rounded-control border border-status-error-border px-3 text-label font-medium text-status-error-ink hover:bg-status-error-bg"
                            phx-click="delete_channel"
                            phx-value-id={channel.id}
                          >
                            Confirm delete
                          </button>
                          <button
                            type="button"
                            class="min-h-target-min rounded-control border border-border-control px-3 text-label font-medium text-text-primary hover:bg-hover"
                            phx-click="cancel_delete_channel"
                          >
                            Cancel
                          </button>
                        <% else %>
                          <button
                            type="button"
                            class="min-h-target-min rounded-control border border-status-error-border px-3 text-label font-medium text-status-error-ink hover:bg-status-error-bg"
                            phx-click="confirm_delete_channel"
                            phx-value-id={channel.id}
                          >
                            Delete
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </.data_panel>

            <.data_panel
              id="notification-rules"
              title="Alert rules"
              description="Each rule belongs to one project and routes one Monitor or Observe event."
            >
              <:actions>
                <.button
                  :if={@nav_projects != [] and @rule_form_mode == :closed}
                  id="new-notification-rule"
                  variant="secondary"
                  phx-click="new_rule"
                  disabled={@channel_count == 0}
                  title={if @channel_count == 0, do: "Add a notification channel first."}
                >
                  Add rule
                </.button>
              </:actions>
              <p
                :if={@nav_projects != [] and @channel_count == 0}
                id="notification-rules-need-channel"
                class="border-b border-border-subtle px-4 py-3 text-body text-text-secondary"
              >
                Add a notification channel first. Rules send to a channel.
              </p>
              <div :if={@nav_projects == []} class="p-4">
                <.empty_state
                  id="notification-rules-no-projects"
                  icon="hero-folder-open"
                  title="Create a project first"
                  description="Alert rules use a project scope to keep routing isolated."
                >
                  <.button navigate={~p"/dashboard/orgs/#{@org_token}/projects"} variant="secondary">
                    Open projects
                  </.button>
                </.empty_state>
              </div>
              <div
                :if={@nav_projects != [] and @rule_form_mode != :closed}
                class="border-b border-border-default p-4"
              >
                <.form
                  for={@rule_form}
                  id="notification-rule-form"
                  phx-submit="submit_rule"
                  class="grid gap-3 sm:grid-cols-2"
                >
                  <.input
                    name="rule[project_id]"
                    id="notification-rule-project"
                    label="Project"
                    type="select"
                    options={project_options(@nav_projects)}
                    value={@rule_project_id}
                    phx-change="select_rule_project"
                  />
                  <.input
                    name="rule[module]"
                    id="notification-rule-module"
                    label="Product"
                    type="select"
                    options={[{"Monitor", "monitor"}, {"Observe", "observe"}]}
                    value={@rule_module}
                    phx-change="select_rule_module"
                  />
                  <.input
                    name="rule[trigger_type]"
                    id="notification-rule-trigger"
                    label="Alert condition"
                    type="select"
                    options={trigger_options(@rule_module)}
                    value={@rule_trigger}
                  />
                  <.input
                    name="rule[channel_id]"
                    id="notification-rule-channel"
                    label="Route to"
                    type="select"
                    options={channel_options(@channel_by_id)}
                    prompt="Select a channel"
                    value={rule_value(@rule_edit_values, :channel_id)}
                    required
                  />
                  <.input
                    name="rule[condition][threshold]"
                    id="notification-rule-threshold"
                    label="Threshold (optional)"
                    type="number"
                    value={rule_threshold(@rule_edit_values)}
                    min="1"
                    placeholder="For error spikes or quota alerts"
                  />
                  <.input
                    name="rule[enabled]"
                    id="notification-rule-enabled"
                    label="Enabled"
                    type="checkbox"
                    value="true"
                    checked={rule_value(@rule_edit_values, :enabled) != false}
                  />
                  <div class="flex items-end gap-2">
                    <.button
                      id="notification-rule-submit"
                      type="submit"
                      variant={if(@channel_form_mode == :closed, do: "primary", else: "secondary")}
                    >
                      {if @rule_form_mode == :create, do: "Create rule", else: "Save rule"}
                    </.button>
                    <.button type="button" variant="secondary" phx-click="cancel_rule">Cancel</.button>
                  </div>
                </.form>
              </div>
              <div :if={@rule_state == :loading} class="space-y-3 p-4">
                <.skeleton :for={_ <- 1..3} class="h-12 w-full" />
              </div>
              <div :if={@rule_state == :error} class="p-4">
                <p class="text-body text-status-error-ink">{@rule_error}</p>
                <.button class="mt-3" variant="secondary" phx-click="reload_rules">Try again</.button>
              </div>
              <div :if={@rule_state == :ready}>
                <.empty_state
                  :if={@rule_count == 0 and @rule_form_mode == :closed}
                  id="notification-rules-empty"
                  icon="hero-adjustments-horizontal"
                  title="No alert rules"
                  description="Route a Monitor or Observe condition to an encrypted channel."
                />
                <div :if={@rule_count > 0} class="overflow-x-auto">
                  <table
                    id="notification-rules-table"
                    data-density="dense"
                    class="w-full border-collapse text-left text-data"
                  >
                    <thead>
                      <tr class="border-b border-border-default">
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">
                          Project and condition
                        </th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Channel</th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">State</th>
                        <th class="min-h-row px-4 py-3"><span class="sr-only">Actions</span></th>
                      </tr>
                    </thead>
                    <tbody
                      id="notification-rules-table-body"
                      phx-update="stream"
                      class="divide-y divide-border-default"
                    >
                      <tr :for={{dom_id, rule} <- @streams.notification_rules} id={dom_id}>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          <span class="font-medium">{rule.project_name}</span>
                          <span class="block text-data text-text-tertiary">{module_label(rule.module)} / {trigger_label(
                            rule.trigger_type
                          )}</span>
                        </td>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          {(rule.channel && rule.channel.name) || "Channel unavailable"}
                        </td>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          <.status_badge
                            tone={if(rule.enabled, do: "success", else: "paused")}
                            icon={
                              if(rule.enabled, do: "hero-check-circle", else: "hero-pause-circle")
                            }
                            label={if(rule.enabled, do: "Enabled", else: "Disabled")}
                          />
                        </td>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          <div class="flex min-h-target-min flex-wrap items-center justify-end gap-2">
                            <button
                              type="button"
                              class="min-h-target-min px-2 text-label font-semibold text-interactive-strong hover:underline"
                              phx-click="toggle_rule"
                              phx-value-id={rule.id}
                              phx-value-project-id={rule.project_id}
                            >{if rule.enabled, do: "Disable", else: "Enable"}</button>
                            <button
                              type="button"
                              class="min-h-target-min px-2 text-label font-semibold text-interactive-strong hover:underline"
                              phx-click="edit_rule"
                              phx-value-id={rule.id}
                              phx-value-project-id={rule.project_id}
                            >Edit</button>
                            <%= if @delete_rule_id == rule.id do %>
                              <button
                                type="button"
                                class="min-h-target-min rounded-control border border-status-error-border px-3 text-label font-medium text-status-error-ink hover:bg-status-error-bg"
                                phx-click="delete_rule"
                                phx-value-id={rule.id}
                                phx-value-project-id={rule.project_id}
                              >Confirm delete</button>
                              <button
                                type="button"
                                class="min-h-target-min rounded-control border border-border-control px-3 text-label font-medium text-text-primary hover:bg-hover"
                                phx-click="cancel_delete_rule"
                              >Cancel</button>
                            <% else %>
                              <button
                                type="button"
                                class="min-h-target-min rounded-control border border-status-error-border px-3 text-label font-medium text-status-error-ink hover:bg-status-error-bg"
                                phx-click="confirm_delete_rule"
                                phx-value-id={rule.id}
                                phx-value-project-id={rule.project_id}
                              >Delete</button>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </.data_panel>

            <.data_panel
              id="notification-deliveries"
              title="Recent delivery history"
              description="The latest 50 deliveries for this organization."
            >
              <:actions>
                <.button
                  id="reload-notification-deliveries"
                  variant="secondary"
                  phx-click="reload_deliveries"
                >
                  Refresh
                </.button>
              </:actions>
              <div :if={@delivery_state == :loading} class="space-y-3 p-4">
                <.skeleton :for={_ <- 1..3} class="h-12 w-full" />
              </div>
              <div :if={@delivery_state == :error} class="p-4">
                <p class="text-body text-status-error-ink">{@delivery_error}</p>
                <.button class="mt-3" variant="secondary" phx-click="reload_deliveries">Try again</.button>
              </div>
              <div :if={@delivery_state == :ready}>
                <.empty_state
                  :if={@delivery_count == 0}
                  id="notification-deliveries-empty"
                  icon="hero-clock"
                  title="No deliveries yet"
                  description="Delivery attempts appear here after an alert matches a rule."
                />
                <div :if={@delivery_count > 0} class="overflow-x-auto">
                  <table
                    id="notification-deliveries-table"
                    data-density="dense"
                    class="w-full border-collapse text-left text-data"
                  >
                    <thead>
                      <tr class="border-b border-border-default">
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Trigger</th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Subject</th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Channel</th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Status</th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Attempt</th>
                        <th class="min-h-row px-4 py-3 font-semibold text-text-tertiary">Sent</th>
                      </tr>
                    </thead>
                    <tbody
                      id="notification-deliveries-table-body"
                      phx-update="stream"
                      class="divide-y divide-border-default"
                    >
                      <tr :for={{dom_id, delivery} <- @streams.notification_deliveries} id={dom_id}>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          {trigger_label(delivery.trigger)}
                        </td>
                        <td class="min-h-row px-4 py-3 text-text-primary">{delivery.subject}</td>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          {delivery.channel_name || channel_type_label(delivery.channel_type)}
                        </td>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          <.status_badge
                            tone={delivery_tone(delivery.status)}
                            icon={delivery_icon(delivery.status)}
                            label={delivery_status_label(delivery.status)}
                          />
                          <span
                            :if={delivery.error}
                            class="mt-1 block text-data text-status-error-ink"
                          >{delivery.error}</span>
                        </td>
                        <td class="min-h-row px-4 py-3 tabular-nums text-text-primary">
                          {delivery.attempt}
                        </td>
                        <td class="min-h-row px-4 py-3 text-text-primary">
                          <.timestamp at={delivery.sent_at} />
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </.data_panel>
          </div>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  @impl true
  def handle_event(event, params, socket) do
    case refresh_manager_scope(socket) do
      {:ok, socket} -> handle_management_event(event, params, socket)
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp handle_management_event("new_channel", _params, socket) do
    {:noreply,
     socket
     |> assign(
       channel_form_mode: :create,
       editing_channel_id: nil,
       editing_channel_name: nil,
       editing_channel_default: false,
       channel_type: "email"
     )
     |> assign(:channel_form, channel_form(socket.assigns.scope))}
  end

  defp handle_management_event("cancel_channel", _params, socket) do
    {:noreply,
     assign(socket,
       channel_form_mode: :closed,
       editing_channel_id: nil,
       editing_channel_name: nil,
       editing_channel_default: false
     )}
  end

  defp handle_management_event("select_channel_type", %{"channel" => %{"type" => type}}, socket)
       when type in ["email", "slack", "discord", "webhook", "telegram"] do
    {:noreply, assign(socket, :channel_type, type)}
  end

  defp handle_management_event("select_channel_type", %{"channel" => params}, socket) do
    {:noreply,
     assign(socket, :channel_type, Map.get(params, "type", socket.assigns.channel_type))}
  end

  defp handle_management_event(
         "submit_channel",
         %{"channel" => params},
         %{assigns: %{channel_form_mode: mode}} = socket
       )
       when mode in [:create, :edit] do
    scope = socket.assigns.scope
    type = Map.get(params, "type", socket.assigns.channel_type)

    attrs =
      case mode do
        :create -> channel_create_attrs(params, type, scope.org_id)
        :edit -> channel_update_attrs(params, type)
      end

    with true <- can_manage?(scope),
         :ok <- Access.allow_notification_channel(scope.org_id, type),
         :ok <- ChannelConfig.validate(type, attrs.config),
         {:ok, _presentation} <- save_channel(socket, attrs) do
      {:noreply,
       socket
       |> assign(
         channel_form_mode: :closed,
         editing_channel_id: nil,
         editing_channel_name: nil,
         editing_channel_default: false
       )
       |> load_channels()
       |> load_rules()
       |> put_flash(:info, "Notification channel saved.")}
    else
      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Could not save that notification channel.")}

      false ->
        {:noreply, put_flash(socket, :error, "You cannot change notification settings.")}
    end
  end

  defp handle_management_event(
         "submit_channel",
         %{"channel" => params},
         %{assigns: %{channel_form_mode: :closed}} = socket
       ) do
    handle_management_event(
      "submit_channel",
      %{"channel" => params},
      assign(socket, :channel_form_mode, :create)
    )
  end

  defp handle_management_event("edit_channel", %{"id" => id}, socket) do
    if Map.has_key?(socket.assigns.channel_by_id, id) do
      {:noreply,
       assign(socket,
         channel_form_mode: :edit,
         editing_channel_id: id,
         editing_channel_name: socket.assigns.channel_by_id[id].name,
         editing_channel_default: socket.assigns.channel_by_id[id].is_default,
         channel_type: socket.assigns.channel_by_id[id].type
       )}
    else
      {:noreply, socket}
    end
  end

  defp handle_management_event("make_default_channel", %{"id" => id}, socket) do
    with true <- can_manage?(socket.assigns.scope),
         {:ok, _presentation} <-
           Notifications.update_channel(id, %{is_default: true}, socket.assigns.scope) do
      {:noreply,
       socket |> load_channels() |> put_flash(:info, "Default notification channel updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update the default channel.")}
    end
  end

  defp handle_management_event("confirm_delete_channel", %{"id" => id}, socket) do
    {:noreply, assign(socket, :delete_channel_id, id)}
  end

  defp handle_management_event("cancel_delete_channel", _params, socket),
    do: {:noreply, assign(socket, :delete_channel_id, nil)}

  defp handle_management_event("delete_channel", %{"id" => id}, socket) do
    with true <- can_manage?(socket.assigns.scope),
         :ok <- Notifications.delete_channel(id, socket.assigns.scope) do
      {:noreply,
       socket
       |> assign(:delete_channel_id, nil)
       |> load_channels()
       |> load_rules()
       |> put_flash(:info, "Notification channel deleted.")}
    else
      {:error, :deliveries_exist} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This channel has delivery history and cannot be deleted. Keep it for history or create a replacement."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not delete that notification channel.")}
    end
  end

  defp handle_management_event("reload_channels", _params, socket),
    do: {:noreply, load_channels(socket)}

  defp handle_management_event("new_rule", _params, socket) do
    project =
      Enum.find(socket.assigns.nav_projects, &(&1.id == socket.assigns.rule_project_id)) ||
        List.first(socket.assigns.nav_projects)

    {:noreply,
     socket
     |> assign(
       rule_form_mode: :create,
       rule_project_id: project && project.id,
       rule_module: "monitor",
       rule_trigger: "check_down",
       rule_edit_values: nil,
       editing_rule_id: nil,
       delete_rule_id: nil
     )
     |> assign(:rule_form, rule_form(socket.assigns.scope, project))}
  end

  defp handle_management_event("cancel_rule", _params, socket),
    do: {:noreply, assign(socket, :rule_form_mode, :closed)}

  defp handle_management_event(
         "select_rule_project",
         %{"rule" => %{"project_id" => project_id}},
         socket
       ) do
    case Enum.find(socket.assigns.nav_projects, &(&1.id == project_id)) do
      nil ->
        {:noreply, socket}

      project ->
        {:noreply,
         socket
         |> assign(:rule_project_id, project.id)
         |> assign(:rule_form, rule_form(socket.assigns.scope, project))}
    end
  end

  defp handle_management_event("select_rule_module", %{"rule" => %{"module" => module}}, socket)
       when module in ["monitor", "observe"] do
    trigger = @trigger_options[module] |> List.first() |> elem(1)
    {:noreply, assign(socket, rule_module: module, rule_trigger: trigger)}
  end

  defp handle_management_event(
         "submit_rule",
         %{"rule" => params},
         %{assigns: %{rule_form_mode: :closed}} = socket
       ) do
    handle_management_event(
      "submit_rule",
      %{"rule" => params},
      assign(socket, :rule_form_mode, :create)
    )
  end

  defp handle_management_event("submit_rule", %{"rule" => params}, socket) do
    scope = socket.assigns.scope
    project_id = Map.get(params, "project_id", socket.assigns.rule_project_id)

    with true <- can_manage?(scope),
         true <- project_belongs_to_org?(socket, project_id),
         project_scope <- Alplus.Scope.put_project(scope, project_id),
         attrs <- rule_attrs_for_mode(params, project_scope, socket.assigns.rule_form_mode),
         {:ok, _presentation} <- save_rule(socket, attrs, project_scope) do
      {:noreply,
       socket
       |> assign(rule_form_mode: :closed)
       |> load_rules()
       |> put_flash(:info, "Alert rule saved.")}
    else
      {:error, _error} -> {:noreply, put_flash(socket, :error, "Could not save that alert rule.")}
      false -> {:noreply, put_flash(socket, :error, "Select a project in this organization.")}
    end
  end

  defp handle_management_event("edit_rule", %{"id" => id, "project-id" => project_id}, socket) do
    case Map.get(socket.assigns.rule_by_id, id) do
      %{project_id: ^project_id} = rule ->
        {:noreply,
         assign(socket,
           rule_form_mode: :edit,
           rule_project_id: project_id,
           editing_rule_id: id,
           rule_module: rule.module,
           rule_trigger: rule.trigger_type,
           rule_edit_values: rule
         )}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_management_event("toggle_rule", %{"id" => id, "project-id" => project_id}, socket) do
    update_rule(socket, id, project_id, %{enabled: !rule_enabled?(socket, id)})
  end

  defp handle_management_event("confirm_delete_rule", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :delete_rule_id, id)}

  defp handle_management_event("cancel_delete_rule", _params, socket),
    do: {:noreply, assign(socket, :delete_rule_id, nil)}

  defp handle_management_event("delete_rule", %{"id" => id, "project-id" => project_id}, socket) do
    scope = socket.assigns.scope

    with true <- can_manage?(scope),
         true <- project_belongs_to_org?(socket, project_id),
         :ok <-
           Notifications.delete_rule(id, Alplus.Scope.put_project(scope, project_id)) do
      {:noreply,
       socket
       |> assign(:delete_rule_id, nil)
       |> load_rules()
       |> put_flash(:info, "Alert rule deleted.")}
    else
      {:error, :deliveries_exist} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This alert rule has delivery history and cannot be deleted. Disable it instead."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not delete that alert rule.")}
    end
  end

  defp handle_management_event("reload_rules", _params, socket),
    do: {:noreply, load_rules(socket)}

  defp handle_management_event("reload_deliveries", _params, socket),
    do: {:noreply, load_deliveries(socket)}

  defp handle_management_event(_event, _params, socket), do: {:noreply, socket}

  # Membership changes do not currently publish an organization-wide event.
  # Rebuild the scope before every settings event so a stale socket cannot
  # mutate configuration or reload owner/admin-only delivery history.
  defp refresh_manager_scope(socket) do
    scope = socket.assigns.scope

    case Alplus.Orgs.build_scope(Alplus.Scope.for_user(scope.user_id), socket.assigns.org_id) do
      {:ok, fresh_scope} ->
        if can_manage?(fresh_scope) do
          {:ok, assign(socket, :scope, fresh_scope)}
        else
          {:error, clear_management_state(assign(socket, :scope, fresh_scope))}
        end

      {:error, :not_found} ->
        {:error, clear_management_state(assign(socket, :scope, %{scope | role: "member"}))}
    end
  end

  defp clear_management_state(socket) do
    socket
    |> stream(:notification_channels, [], reset: true)
    |> stream(:notification_rules, [], reset: true)
    |> stream(:notification_deliveries, [], reset: true)
    |> assign(
      channel_state: :ready,
      channel_error: nil,
      channel_form_mode: :closed,
      channel_by_id: %{},
      channel_count: 0,
      channel_type_options: [],
      channel_gated_types: [],
      editing_channel_id: nil,
      editing_channel_name: nil,
      editing_channel_default: false,
      delete_channel_id: nil,
      rule_state: :ready,
      rule_error: nil,
      rule_form_mode: :closed,
      rule_by_id: %{},
      rule_count: 0,
      editing_rule_id: nil,
      delete_rule_id: nil,
      delivery_state: :ready,
      delivery_error: nil,
      delivery_count: 0
    )
    |> assign(:channel_form, Phoenix.Component.to_form(%{}, as: "channel"))
    |> assign(:rule_form, Phoenix.Component.to_form(%{}, as: "rule"))
    |> put_flash(:error, "Your organization role no longer permits notification management.")
  end

  defp channel_form(scope) do
    Channel
    |> Form.for_create(:create, domain: Alplus.Notifications, actor: scope, as: "channel")
    |> Phoenix.Component.to_form()
  end

  defp rule_form(_scope, nil), do: Phoenix.Component.to_form(%{}, as: "rule")

  defp rule_form(scope, _project) do
    AlertRule
    |> Form.for_create(:create, domain: Alplus.Notifications, actor: scope, as: "rule")
    |> Phoenix.Component.to_form()
  end

  defp load_channel_options(socket) do
    {options, gated_types} =
      Enum.reduce(@channel_options, {[], []}, fn {label, type}, {options, gated_types} ->
        case Access.allow_notification_channel(socket.assigns.org_id, type) do
          :ok -> {[{label, type} | options], gated_types}
          {:error, _} -> {[{"#{label} (billing required)", type} | options], [type | gated_types]}
        end
      end)

    assign(socket,
      channel_type_options: Enum.reverse(options),
      channel_gated_types: gated_types
    )
  end

  defp load_channels(socket) do
    case Notifications.list_channel_presentations(socket.assigns.scope) do
      {:ok, channels} ->
        socket
        |> stream(:notification_channels, channels, reset: true)
        |> assign(:channel_by_id, Map.new(channels, &{&1.id, &1}))
        |> assign(:channel_count, length(channels))
        |> assign(channel_state: :ready, channel_error: nil)

      {:error, _error} ->
        assign(socket,
          channel_state: :error,
          channel_error: "Notification channels could not be loaded."
        )
    end
  end

  defp load_rules(socket) do
    case Notifications.list_rule_presentations(socket.assigns.scope, socket.assigns.nav_projects) do
      {:ok, rules} ->
        socket
        |> stream(:notification_rules, rules, reset: true)
        |> assign(:rule_by_id, Map.new(rules, &{&1.id, &1}))
        |> assign(rule_count: length(rules), rule_state: :ready, rule_error: nil)

      {:error, _error} ->
        assign(socket, rule_state: :error, rule_error: "Alert rules could not be loaded.")
    end
  end

  defp load_deliveries(socket) do
    case Notifications.list_delivery_presentations(socket.assigns.scope) do
      {:ok, deliveries} ->
        socket
        |> stream(:notification_deliveries, deliveries, reset: true)
        |> assign(:delivery_count, length(deliveries))
        |> assign(delivery_state: :ready, delivery_error: nil)

      {:error, _error} ->
        assign(socket,
          delivery_state: :error,
          delivery_error: "Delivery history could not be loaded."
        )
    end
  end

  defp save_channel(socket, attrs) do
    case socket.assigns.channel_form_mode do
      :create ->
        Notifications.create_channel(attrs, socket.assigns.scope)

      :edit ->
        Notifications.update_channel(
          socket.assigns.editing_channel_id,
          attrs,
          socket.assigns.scope
        )

      _ ->
        {:error, :closed}
    end
  end

  defp save_rule(socket, attrs, scope) do
    case socket.assigns.rule_form_mode do
      :create -> Notifications.create_rule(attrs, scope)
      :edit -> Notifications.update_rule(socket.assigns.editing_rule_id, attrs, scope)
      _ -> {:error, :closed}
    end
  end

  defp update_rule(socket, id, project_id, attrs) do
    scope = socket.assigns.scope

    with true <- can_manage?(scope),
         true <- project_belongs_to_org?(socket, project_id),
         {:ok, _presentation} <-
           Notifications.update_rule(
             id,
             attrs,
             Alplus.Scope.put_project(scope, project_id)
           ) do
      {:noreply, socket |> load_rules() |> put_flash(:info, "Alert rule updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update that alert rule.")}
    end
  end

  defp channel_create_attrs(params, type, org_id) do
    Map.merge(channel_update_attrs(params, type), %{org_id: org_id, type: type})
  end

  defp channel_update_attrs(params, type) do
    %{
      name: Map.get(params, "name", "") |> String.trim(),
      is_default: checkbox_value(Map.get(params, "is_default")),
      config: config_attrs(type, Map.get(params, "config", %{}))
    }
  end

  defp checkbox_value(value) when is_list(value), do: Enum.any?(value, &(&1 in ["true", true]))
  defp checkbox_value(value), do: value in ["true", true]

  defp config_attrs("email", config), do: %{"to" => trim_value(Map.get(config, "to"))}

  defp config_attrs(type, config) when type in ["slack", "discord"],
    do: %{"webhook_url" => trim_value(Map.get(config, "webhook_url"))}

  defp config_attrs("webhook", config),
    do: %{
      "url" => trim_value(Map.get(config, "url")),
      "secret" => string_value(Map.get(config, "secret"))
    }

  defp config_attrs("telegram", config),
    do: %{
      "bot_token" => string_value(Map.get(config, "bot_token")),
      "chat_id" => trim_value(Map.get(config, "chat_id"))
    }

  defp config_attrs(_type, _config), do: %{}

  defp trim_value(value) when is_binary(value), do: String.trim(value)
  defp trim_value(_value), do: ""
  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: ""

  defp rule_create_attrs(params, scope) do
    Map.merge(rule_update_attrs(params), %{org_id: scope.org_id, project_id: scope.project_id})
  end

  defp rule_update_attrs(params) do
    %{
      module: Map.get(params, "module", "monitor"),
      trigger_type: Map.get(params, "trigger_type", "check_down"),
      channel_id: Map.get(params, "channel_id", ""),
      enabled: checkbox_value(Map.get(params, "enabled")),
      condition: condition_attrs(Map.get(params, "condition", %{}))
    }
  end

  defp rule_attrs_for_mode(params, scope, :create), do: rule_create_attrs(params, scope)
  defp rule_attrs_for_mode(params, _scope, :edit), do: rule_update_attrs(params)
  defp rule_attrs_for_mode(_params, _scope, _mode), do: %{}

  defp condition_attrs(%{"threshold" => threshold})
       when is_binary(threshold) and threshold != "" do
    case Integer.parse(threshold) do
      {value, ""} when value > 0 -> %{threshold: value}
      _ -> %{}
    end
  end

  defp condition_attrs(_), do: %{}

  defp project_belongs_to_org?(socket, project_id),
    do: Enum.any?(socket.assigns.nav_projects, &(&1.id == project_id))

  defp rule_value(nil, _key), do: ""
  defp rule_value(rule, key), do: Map.get(rule, key, "")

  defp rule_threshold(nil), do: ""

  defp rule_threshold(rule) do
    rule
    |> Map.get(:condition, %{})
    |> Map.get(:threshold) ||
      rule
      |> Map.get(:condition, %{})
      |> Map.get("threshold", "")
  end

  defp rule_enabled?(socket, rule_id) do
    get_in(socket.assigns, [:rule_by_id, rule_id, :enabled]) || false
  end

  defp project_options(projects), do: Enum.map(projects, &{&1.name, &1.id})

  defp channel_options(channels),
    do: channels |> Map.values() |> Enum.sort_by(& &1.name) |> Enum.map(&{&1.name, &1.id})

  defp channel_type_label("email"), do: "Email"
  defp channel_type_label("slack"), do: "Slack"
  defp channel_type_label("discord"), do: "Discord"
  defp channel_type_label("webhook"), do: "Webhook"
  defp channel_type_label("telegram"), do: "Telegram"
  defp channel_type_label(type), do: type

  defp channel_initials("email"), do: "EM"
  defp channel_initials("slack"), do: "SL"
  defp channel_initials("discord"), do: "DI"
  defp channel_initials("webhook"), do: "WH"
  defp channel_initials("telegram"), do: "TG"
  defp channel_initials(type), do: type |> to_string() |> String.slice(0, 2) |> String.upcase()

  defp module_label("monitor"), do: "Monitor"
  defp module_label("observe"), do: "Observe"
  defp module_label(module), do: module

  defp trigger_label(trigger) do
    @trigger_options
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(trigger, fn {label, value} -> if value == trigger, do: label end)
  end

  defp trigger_options(module), do: Map.get(@trigger_options, module, [])

  defp delivery_tone("sent"), do: "success"
  defp delivery_tone("pending"), do: "info"
  defp delivery_tone("skipped"), do: "warning"
  defp delivery_tone("failed"), do: "error"
  defp delivery_tone(_status), do: "neutral"

  defp delivery_icon("sent"), do: "hero-check-circle"
  defp delivery_icon("pending"), do: "hero-clock"
  defp delivery_icon("skipped"), do: "hero-forward"
  defp delivery_icon("failed"), do: "hero-x-circle"
  defp delivery_icon(_status), do: "hero-question-mark-circle"

  defp delivery_status_label("sent"), do: "Sent"
  defp delivery_status_label("pending"), do: "Pending"
  defp delivery_status_label("failed"), do: "Failed"
  defp delivery_status_label("skipped"), do: "Skipped"
  defp delivery_status_label(status), do: status
end
