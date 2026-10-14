defmodule AlplusWeb.TeamLive do
  @moduledoc """
  Team management for one org, under `/dashboard/` (ARCHITECTURE.md §4, §9).

  Every member can list who else is in the org (`Membership`'s read policy
  allows any org member to read every membership row in that org). Invite,
  resend, revoke, role change, remove, and ownership transfer all require
  `owner`/`admin` — enforced twice: the control is hidden from a `member`
  here, and the underlying Ash policy rejects a directly-sent event
  regardless (ARCHITECTURE.md: "hide the control AND reject the event").

  Pending invitations are only ever loaded for `owner`/`admin`
  (`Invitation`'s read policy denies `member` outright) — a `member` never
  even attempts that query, and the summary band only ever surfaces counts a
  `member` can actually verify (admins, members — never a pending count they
  cannot see).

  Layout: a `summary_card` band (who has access, seat usage against the
  package, the "Invite member" reveal toggle) above a `data_panel` members
  table, above a `data_panel` pending-invitations table that only renders
  while `@invitations_empty?` is false — an empty invitation list is the
  normal, healthy state and gets no permanent furniture. The invite form
  itself is hidden behind `@show_invite`, mirroring
  `AlplusWeb.ProjectsLive`'s `toggle_new_project`, and appears as the first
  thing inside the members panel's body once revealed.
  """

  use AlplusWeb, :live_view
  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1, owner?: 1]

  alias AshPhoenix.Form
  alias Alplus.Billing.Package
  alias Alplus.Orgs
  alias Alplus.Orgs.{Invitation, Membership}

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Team", active: :team) do
      org_id = socket.assigns.org_id
      scope = socket.assigns.scope

      socket =
        socket
        |> assign(:invite_form, invite_form(scope, org_id))
        |> assign(:show_invite, false)
        |> assign(:remove_confirm_id, nil)
        |> assign(:remove_confirm_text, "")
        |> assign(:transfer_confirm_id, nil)
        |> assign(:transfer_confirm_text, "")
        |> assign(:member_total, nil)
        |> assign(:admin_count, nil)
        |> assign(:plain_member_count, nil)
        |> assign(:pending_invitations_count, nil)
        |> assign(:members_state, :loading)
        |> assign(:members_error, nil)
        |> assign(:members_empty?, false)
        |> assign(:invitations_state, if(can_manage?(scope), do: :loading, else: :hidden))
        |> assign(:invitations_error, nil)
        |> assign(:invite_error, nil)
        |> stream(:members, [])
        |> stream(:invitations, [])
        |> assign(:invitations_empty?, false)

      socket = if connected?(socket), do: load_team(socket), else: socket

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
      active={:team}
      page_title="Team"
    >
      <.console_page id="team-page">
        <div class="flex flex-col gap-4">
          <.summary_card
            id="team-summary"
            headline={member_count_headline(@member_total)}
            subtitle={seat_subtitle(@org, @member_total, @pending_invitations_count)}
            stats={team_stats(@scope, @admin_count, @plain_member_count, @pending_invitations_count)}
          >
            <:actions>
              <.button
                :if={can_manage?(@scope) and confirmed_user?(@current_user)}
                id="invite-toggle"
                variant="primary"
                phx-click="toggle_invite"
              >
                <.icon name="hero-user-plus" class="size-4" /> Invite member
              </.button>
            </:actions>
          </.summary_card>

          <%!-- Onboarding overhaul decision #1: everything else in the dashboard
              is open before email confirmation, but a teammate invite carries
              real trust into the org, so it is the one action still gated on
              `confirmed_at` (docs/research/onboarding-best-practices-2026-08-13.md).
              Rendered as a sibling in the page stack, never nested inside a
              bordered panel (DESIGN-SYSTEM.md's one-border rule), since it
              stands in for the invite affordance the band above just hid. --%>
          <.permission_notice
            :if={can_manage?(@scope) and not confirmed_user?(@current_user)}
            id="invite-confirm-required"
            message="Confirm your email address to invite teammates. Use the banner above to resend the link."
          />

          <.permission_notice
            :if={not can_manage?(@scope)}
            id="invitations-permission"
            message="Only organization owners and administrators can invite people or change team access."
          />

          <%!-- No panel title: the `<h1>` says "Team", the band says how many
              people have access, and the column header says "Member". A panel
              titled "Members" on top of that printed the word four times on
              one screen. --%>
          <.data_panel id="members-panel">
            <div data-density="dense">
              <.form
                :if={@show_invite and confirmed_user?(@current_user)}
                for={@invite_form}
                id="invite-form"
                phx-change="validate_invite"
                phx-submit="invite"
                class="flex flex-wrap items-end gap-3 border-b border-border-default p-4"
              >
                <input type="hidden" name="invitation[org_id]" id="invite-org-id" value={@org_id} />
                <.alert
                  :if={@invite_error}
                  id="invite-error"
                  kind="error"
                  title="The invitation was not created"
                  message={@invite_error}
                  class="w-full"
                />
                <div class="max-w-xs">
                  <.input
                    field={@invite_form[:email]}
                    type="email"
                    label="Email"
                    id="invite-email"
                    required
                  />
                </div>
                <div class="w-40">
                  <.input
                    field={@invite_form[:role]}
                    type="select"
                    label="Role"
                    id="invite-role"
                    options={[{"Member", "member"}, {"Admin", "admin"}]}
                  />
                </div>
                <div class="mb-3 flex gap-2">
                  <.button id="invite-submit" variant="primary" phx-disable-with="Sending...">
                    Send invite
                  </.button>
                  <.button type="button" variant="secondary" phx-click="toggle_invite">
                    Cancel
                  </.button>
                </div>
              </.form>

              <%= cond do %>
                <% @members_state == :loading -> %>
                  <div id="members-loading" class="p-4">
                    <.skeleton rows={4} />
                    <p class="mt-3 text-body text-text-secondary">Loading team access.</p>
                  </div>
                <% @members_state == :error -> %>
                  <.error_boundary id="members-error" retry="retry_team">
                    {@members_error}
                  </.error_boundary>
                <% true -> %>
                  <div class="overflow-x-auto">
                    <table id="members-table" class="w-full text-left text-body">
                      <thead>
                        <tr class="border-b border-border-default">
                          <th scope="col" class="min-h-row px-4 py-2 font-medium text-text-secondary">
                            Member
                          </th>
                          <th scope="col" class="min-h-row px-4 py-2 font-medium text-text-secondary">
                            Role
                          </th>
                          <th
                            scope="col"
                            class="hidden min-h-row px-4 py-2 font-medium text-text-secondary sm:table-cell"
                          >
                            Joined
                          </th>
                          <th
                            scope="col"
                            class="min-h-row px-4 py-2 text-right font-medium text-text-secondary"
                          >
                            <span class="sr-only">Actions</span>
                          </th>
                        </tr>
                      </thead>
                      <tbody id="members" phx-update="stream" class="divide-y divide-border-default">
                        <tr
                          :if={@members_empty?}
                          id="members-empty"
                          class="hidden only:table-row"
                        >
                          <td
                            colspan="4"
                            class="min-h-row px-4 py-8 text-center text-body text-text-secondary"
                          >
                            No team members are available.
                          </td>
                        </tr>
                        <tr :for={{dom_id, member} <- @streams.members} id={dom_id}>
                          <% confirming? =
                            @transfer_confirm_id == member.id or @remove_confirm_id == member.id %>
                          <td
                            :if={not confirming?}
                            id={"member-email-#{member.id}"}
                            class="min-h-row px-4 py-3"
                          >
                            <span class="font-medium text-text-primary">
                              {member.user.name || to_string(member.user.email)}
                            </span>
                            <span
                              :if={member.user_id == @scope.user_id}
                              class="ml-1.5 text-label text-text-tertiary"
                            >
                              You
                            </span>
                            <p :if={member.user.name} class="text-label text-text-tertiary">
                              {member.user.email}
                            </p>

                            <div
                              class="mt-3 space-y-2 border-t border-border-default pt-3 sm:hidden"
                              id={"member-mobile-summary-#{member.id}"}
                            >
                              <div class="flex flex-wrap items-center gap-2">
                                <span class="text-label font-semibold text-text-secondary">Role</span>
                                <.role_control
                                  :if={can_manage?(@scope) and member.role != "owner"}
                                  member={member}
                                  scope={@scope}
                                  suffix="-mobile"
                                />
                                <.status_badge
                                  :if={member.role == "owner" or not can_manage?(@scope)}
                                  tone={role_tone(member.role)}
                                  label={member.role}
                                />
                              </div>
                              <p class="text-body text-text-secondary">
                                <span class="font-medium text-text-primary">Joined</span>
                                <.timestamp at={member.inserted_at} />
                              </p>
                              <div class="flex flex-wrap gap-2">
                                <.destructive_confirm
                                  :if={can_manage?(@scope) and member.role != "owner"}
                                  id={"member-remove-mobile-#{member.id}"}
                                  mode={:typed}
                                  match={to_string(member.user.email)}
                                  confirming={false}
                                  consequence="This member immediately loses access to this organization."
                                  trigger_label="Remove"
                                  trigger_variant="destructive"
                                  confirm_label="Confirm remove"
                                  trigger_event="confirm_remove"
                                  cancel_event="cancel_remove"
                                  confirm_event="remove"
                                  input_event="remove_input"
                                  input_value={@remove_confirm_text}
                                  value_name="id"
                                  value={member.id}
                                />
                                <.destructive_confirm
                                  :if={owner?(@scope) and member.role != "owner"}
                                  id={"member-transfer-mobile-#{member.id}"}
                                  mode={:typed}
                                  match={to_string(member.user.email)}
                                  confirming={false}
                                  consequence="You give up the owner role. This cannot be undone by anyone but the new owner."
                                  trigger_label="Make owner"
                                  confirm_label="Confirm transfer"
                                  trigger_event="confirm_transfer_ownership"
                                  cancel_event="cancel_transfer_ownership"
                                  confirm_event="transfer_ownership"
                                  input_event="transfer_ownership_input"
                                  input_value={@transfer_confirm_text}
                                  value_name="id"
                                  value={member.id}
                                />
                                <span
                                  :if={not can_manage?(@scope) or member.role == "owner"}
                                  class="text-body text-text-secondary"
                                >
                                  Read only
                                </span>
                              </div>
                            </div>
                          </td>
                          <td
                            :if={not confirming?}
                            id={"member-role-#{member.id}"}
                            class="hidden min-h-row px-4 py-3 sm:table-cell"
                          >
                            <.role_control
                              :if={can_manage?(@scope) and member.role != "owner"}
                              member={member}
                              scope={@scope}
                            />
                            <.status_badge
                              :if={member.role == "owner" or not can_manage?(@scope)}
                              tone={role_tone(member.role)}
                              label={member.role}
                            />
                          </td>
                          <td :if={not confirming?} class="hidden min-h-row px-4 py-3 sm:table-cell">
                            <.timestamp at={member.inserted_at} />
                          </td>
                          <td
                            :if={not confirming?}
                            class="hidden min-h-row px-4 py-3 text-right sm:table-cell"
                          >
                            <div class="flex flex-wrap justify-end gap-2">
                              <.destructive_confirm
                                :if={can_manage?(@scope) and member.role != "owner"}
                                id={"member-remove-#{member.id}"}
                                mode={:typed}
                                match={to_string(member.user.email)}
                                confirming={@remove_confirm_id == member.id}
                                consequence="This member immediately loses access to this organization."
                                trigger_label="Remove"
                                trigger_variant="destructive"
                                confirm_label="Confirm remove"
                                trigger_event="confirm_remove"
                                cancel_event="cancel_remove"
                                confirm_event="remove"
                                input_event="remove_input"
                                input_value={@remove_confirm_text}
                                value_name="id"
                                value={member.id}
                              />
                              <.destructive_confirm
                                :if={owner?(@scope) and member.role != "owner"}
                                id={"member-transfer-#{member.id}"}
                                mode={:typed}
                                match={to_string(member.user.email)}
                                confirming={@transfer_confirm_id == member.id}
                                consequence="You give up the owner role. This cannot be undone by anyone but the new owner."
                                trigger_label="Make owner"
                                confirm_label="Confirm transfer"
                                trigger_event="confirm_transfer_ownership"
                                cancel_event="cancel_transfer_ownership"
                                confirm_event="transfer_ownership"
                                input_event="transfer_ownership_input"
                                input_value={@transfer_confirm_text}
                                value_name="id"
                                value={member.id}
                              />
                            </div>
                          </td>
                          <%!-- A typed-confirm panel does not fit a right-hand action
                        cell (docs/DESIGN-SYSTEM.md table recipe): when this
                        row is confirming, it collapses to one full-width
                        cell spanning every column instead of squeezing the
                        panel into the actions column alone. Deliberately a
                        single `<tr>` per stream item, not a second sibling
                        `<tr>` — the client's stream reordering indexes
                        `parent.children` positionally
                        (assets/js/phoenix_live_view/dom_patch.ts), so a
                        second, untracked child per item would desync every
                        later row's position. --%>
                          <td :if={confirming?} colspan="4" class="min-h-row px-4 py-3">
                            <.destructive_confirm
                              :if={@remove_confirm_id == member.id}
                              id={"member-remove-#{member.id}"}
                              mode={:typed}
                              match={to_string(member.user.email)}
                              confirming={true}
                              consequence="This member immediately loses access to this organization."
                              trigger_label="Remove"
                              trigger_variant="destructive"
                              confirm_label="Confirm remove"
                              trigger_event="confirm_remove"
                              cancel_event="cancel_remove"
                              confirm_event="remove"
                              input_event="remove_input"
                              input_value={@remove_confirm_text}
                              value_name="id"
                              value={member.id}
                            />
                            <.destructive_confirm
                              :if={@transfer_confirm_id == member.id}
                              id={"member-transfer-#{member.id}"}
                              mode={:typed}
                              match={to_string(member.user.email)}
                              confirming={true}
                              consequence="You give up the owner role. This cannot be undone by anyone but the new owner."
                              trigger_label="Make owner"
                              confirm_label="Confirm transfer"
                              trigger_event="confirm_transfer_ownership"
                              cancel_event="cancel_transfer_ownership"
                              confirm_event="transfer_ownership"
                              input_event="transfer_ownership_input"
                              input_value={@transfer_confirm_text}
                              value_name="id"
                              value={member.id}
                            />
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
              <% end %>
            </div>
          </.data_panel>

          <.data_panel
            :if={can_manage?(@scope)}
            id="invitations-panel"
            title="Pending invitations"
            class="overflow-hidden"
          >
            <div data-density="dense">
              <%= cond do %>
                <% @invitations_state == :loading -> %>
                  <div id="invitations-loading" class="p-4">
                    <.skeleton rows={2} />
                    <p class="mt-3 text-body text-text-secondary">Loading pending invitations.</p>
                  </div>
                <% @invitations_state == :error -> %>
                  <.error_boundary id="invitations-error" retry="retry_team">
                    {@invitations_error}
                  </.error_boundary>
                <% @invitations_empty? -> %>
                  <div id="invitations-empty" class="p-4 text-body text-text-secondary" role="status">
                    No pending invitations.
                  </div>
                <% true -> %>
                  <div class="overflow-x-auto">
                    <table class="w-full text-left text-body">
                      <thead>
                        <tr class="border-b border-border-default">
                          <th scope="col" class="min-h-row px-4 py-2 font-medium text-text-secondary">
                            Invitee
                          </th>
                          <th
                            scope="col"
                            class="hidden min-h-row px-4 py-2 font-medium text-text-secondary sm:table-cell"
                          >
                            Role
                          </th>
                          <th
                            scope="col"
                            class="hidden min-h-row px-4 py-2 font-medium text-text-secondary sm:table-cell"
                          >
                            Status
                          </th>
                          <th
                            scope="col"
                            class="hidden min-h-row px-4 py-2 font-medium text-text-secondary sm:table-cell"
                          >
                            Sent
                          </th>
                          <th
                            scope="col"
                            class="hidden min-h-row px-4 py-2 font-medium text-text-secondary sm:table-cell"
                          >
                            Expires
                          </th>
                          <th
                            scope="col"
                            class="hidden min-h-row px-4 py-2 text-right font-medium text-text-secondary sm:table-cell"
                          >
                            <span class="sr-only">Actions</span>
                          </th>
                        </tr>
                      </thead>
                      <tbody
                        id="invitations"
                        phx-update="stream"
                        class="divide-y divide-border-default"
                      >
                        <tr :for={{dom_id, invitation} <- @streams.invitations} id={dom_id}>
                          <td
                            id={"invitation-email-#{invitation.id}"}
                            class="min-h-row px-4 py-3 text-text-primary"
                          >
                            <span class="font-medium">{invitation.email}</span>
                            <div
                              id={"invitation-mobile-summary-#{invitation.id}"}
                              class="mt-3 space-y-2 border-t border-border-default pt-3 sm:hidden"
                            >
                              <p class="text-body font-medium text-text-primary">
                                {invitation.email}
                              </p>
                              <div class="flex flex-wrap items-center gap-2">
                                <span class="text-label font-semibold text-text-secondary">Role</span>
                                <span class="text-body text-text-primary">{invitation.role}</span>
                                <span class="text-label font-semibold text-text-secondary">Status</span>
                                <.status_badge
                                  tone={invitation_tone(invitation.status)}
                                  label={invitation.status}
                                />
                              </div>
                              <p class="text-body text-text-secondary">
                                <span class="font-medium text-text-primary">Sent</span>
                                <.timestamp at={invitation.inserted_at} />
                              </p>
                              <p class="text-body text-text-secondary">
                                <span class="font-medium text-text-primary">Expires</span>
                                <.status_badge
                                  :if={invitation_expired?(invitation)}
                                  tone="warning"
                                  label="Expired"
                                />
                                <.timestamp
                                  :if={not invitation_expired?(invitation)}
                                  at={invitation.expires_at}
                                />
                              </p>
                              <div
                                :if={invitation.status == "pending"}
                                class="flex flex-wrap gap-2"
                              >
                                <.button
                                  type="button"
                                  variant="secondary"
                                  id={"invitation-resend-mobile-#{invitation.id}"}
                                  phx-click="resend_invitation"
                                  phx-value-id={invitation.id}
                                >
                                  Resend
                                </.button>
                                <.button
                                  type="button"
                                  variant="secondary"
                                  id={"invitation-revoke-mobile-#{invitation.id}"}
                                  phx-click="revoke_invitation"
                                  phx-value-id={invitation.id}
                                >
                                  Revoke
                                </.button>
                              </div>
                            </div>
                          </td>
                          <td
                            id={"invitation-role-#{invitation.id}"}
                            class="hidden min-h-row px-4 py-3 text-text-secondary sm:table-cell"
                          >
                            {invitation.role}
                          </td>
                          <td
                            id={"invitation-status-#{invitation.id}"}
                            class="hidden min-h-row px-4 py-3 sm:table-cell"
                          >
                            <.status_badge
                              tone={invitation_tone(invitation.status)}
                              label={invitation.status}
                            />
                          </td>
                          <td class="hidden min-h-row px-4 py-3 sm:table-cell">
                            <.timestamp at={invitation.inserted_at} />
                          </td>
                          <td class="hidden min-h-row px-4 py-3 sm:table-cell">
                            <.status_badge
                              :if={invitation_expired?(invitation)}
                              tone="warning"
                              label="Expired"
                            />
                            <.timestamp
                              :if={not invitation_expired?(invitation)}
                              at={invitation.expires_at}
                            />
                          </td>
                          <td class="hidden min-h-row px-4 py-3 text-right sm:table-cell">
                            <div
                              :if={invitation.status == "pending"}
                              class="flex flex-wrap justify-end gap-2"
                            >
                              <.button
                                type="button"
                                variant="secondary"
                                id={"invitation-resend-#{invitation.id}"}
                                phx-click="resend_invitation"
                                phx-value-id={invitation.id}
                              >
                                Resend
                              </.button>
                              <.button
                                type="button"
                                variant="secondary"
                                id={"invitation-revoke-#{invitation.id}"}
                                phx-click="revoke_invitation"
                                phx-value-id={invitation.id}
                              >
                                Revoke
                              </.button>
                            </div>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
              <% end %>
            </div>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp role_tone("owner"), do: "neutral"
  defp role_tone("admin"), do: "info"
  defp role_tone(_member), do: "neutral"

  defp invitation_tone("pending"), do: "warning"
  defp invitation_tone("accepted"), do: "success"
  defp invitation_tone(_revoked_or_expired), do: "neutral"

  # `expires_at` never auto-transitions a stale `pending` row to `expired` —
  # nothing rewrites the status column client-side of a cron. An operator can
  # be looking at a `pending` invitation that has already lapsed, so this
  # compares against real time rather than trusting the stored status alone.
  defp invitation_expired?(%{status: "pending"} = invitation) do
    DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :lt
  end

  defp invitation_expired?(_invitation), do: false

  defp invitation_reserved?(%{status: "pending"} = invitation),
    do: not invitation_expired?(invitation)

  defp invitation_reserved?(_invitation), do: false

  defp decrement_pending_count(socket, false), do: socket

  defp decrement_pending_count(socket, true) do
    assign(
      socket,
      :pending_invitations_count,
      max((socket.assigns.pending_invitations_count || 0) - 1, 0)
    )
  end

  attr :member, :any, required: true
  attr :scope, :any, required: true
  attr :suffix, :string, default: ""

  defp role_control(assigns) do
    ~H"""
    <form phx-change="change_role" id={"role-form#{@suffix}-#{@member.id}"}>
      <input type="hidden" name="membership_id" value={@member.id} />
      <select
        name="role"
        id={"role-select#{@suffix}-#{@member.id}"}
        disabled={@member.user_id == @scope.user_id}
        aria-label={"Role for #{@member.user.email}"}
        class="h-control-sm rounded-control border border-border-default bg-surface-raised px-2 text-body text-text-primary disabled:cursor-not-allowed disabled:opacity-45"
      >
        <option value="admin" selected={@member.role == "admin"}>admin</option>
        <option value="member" selected={@member.role == "member"}>member</option>
      </select>
    </form>
    """
  end

  # Avoids the word "member" so it is not competing with the "Members" stat
  # beside it and the "Member" column header below it.
  defp member_count_headline(nil), do: "Team access is loading"
  defp member_count_headline(0), do: "No people have access"
  defp member_count_headline(1), do: "1 person has access"
  defp member_count_headline(n), do: "#{n} people have access"

  # The counts an owner scans first, split by capability rather than by raw
  # role string. Splitting by role produced a band that contradicted its own
  # headline: a solo org read "1 member" above "Admins 0, Members 0", because
  # the owner is neither an `admin` row nor a `member` row. Grouping the owner
  # with the admins makes the two numbers sum to the headline, and capability
  # is the question anyway — who can change this org, and who can only look.
  #
  # A `member` can read every membership row in the org (`Membership`'s read
  # policy), so both counts are always real; pending invitations are
  # `Invitation`-policy-gated to owner/admin, so a `member` gets no third stat
  # rather than a zero they cannot verify.
  defp team_stats(scope, manager_count, plain_member_count, pending_invitations_count) do
    base = [
      %{id: "team-stat-admins", label: "Can manage", value: manager_count},
      %{id: "team-stat-members", label: "View only", value: plain_member_count}
    ]

    if can_manage?(scope) do
      base ++
        [
          %{
            id: "team-stat-pending",
            label: "Pending",
            value: pending_invitations_count
          }
        ]
    else
      base
    end
  end

  defp seat_subtitle(_org, nil, _pending_count), do: "Seat capacity is loading."

  defp seat_subtitle(_org, member_total, pending_count) do
    seats = Package.limit(:members)

    case pending_count do
      pending when is_integer(pending) ->
        "#{member_total + pending} of #{seats} seats in use. #{count_words(member_total, "member")}, #{pending_words(pending)}."

      _ ->
        "#{member_total} of #{seats} member seats in use"
    end
  end

  defp count_words(1, noun), do: "1 #{noun}"
  defp count_words(n, noun), do: "#{n} #{noun}s"

  defp pending_words(0), do: "no pending invitations"
  defp pending_words(1), do: "1 pending invitation"
  defp pending_words(n), do: "#{n} pending invitations"

  defp confirmed_user?(%{confirmed_at: confirmed_at}), do: not is_nil(confirmed_at)
  defp confirmed_user?(_user), do: false

  defp can_invite?(socket),
    do: can_manage?(socket.assigns.scope) and confirmed_user?(socket.assigns.current_user)

  defp invite_permission_message(socket) do
    cond do
      not can_manage?(socket.assigns.scope) ->
        "Only organization owners and administrators can manage invitations."

      not confirmed_user?(socket.assigns.current_user) ->
        "Confirm your email address to invite teammates."

      true ->
        "You cannot manage invitations in this organization."
    end
  end

  defp team_permission_message,
    do: "Only organization owners and administrators can change team access."

  defp owner_permission_message,
    do: "Only the organization owner can transfer ownership."

  defp email_handoff_message(subject),
    do:
      "#{subject}. The email service accepted the handoff. This does not confirm delivery to the mailbox."

  defp invite_form_error(form) do
    form
    |> AshPhoenix.Form.raw_errors(for_path: :all)
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value("Could not create that invitation.", &form_error_message/1)
  end

  defp form_error_message(%{message: message}) when is_binary(message) and message != "",
    do: message

  defp form_error_message(error) do
    message = Exception.message(error)
    if message != "", do: message
  rescue
    _ -> nil
  end

  @impl true
  def handle_event("retry_team", _params, socket) do
    {:noreply, load_team(socket)}
  end

  def handle_event("toggle_invite", _params, socket) do
    if can_invite?(socket) do
      {:noreply,
       socket
       |> assign(:show_invite, not socket.assigns.show_invite)
       |> assign(:invite_error, nil)}
    else
      {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
    end
  end

  def handle_event("validate_invite", %{"invitation" => params}, socket)
      when is_map(params) do
    if can_invite?(socket) do
      form = socket.assigns.invite_form |> Form.validate(params, errors: false) |> to_form()
      {:noreply, assign(socket, invite_form: form, invite_error: nil)}
    else
      {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
    end
  end

  def handle_event("validate_invite", _params, socket) do
    {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
  end

  def handle_event("invite", %{"invitation" => params}, socket) when is_map(params) do
    if can_invite?(socket) do
      params = Map.put(params, "org_id", socket.assigns.org_id)
      do_invite(socket, socket.assigns.scope, params)
    else
      {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
    end
  end

  def handle_event("invite", _params, socket) do
    {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
  end

  def handle_event("resend_invitation", %{"id" => id}, socket)
      when is_binary(id) and byte_size(id) > 0 do
    if can_invite?(socket) do
      with_invitation(socket, id, fn invitation, scope ->
        case Orgs.resend_invitation(invitation, %{}, actor: scope) do
          {:ok, invitation} ->
            {:ok,
             socket
             |> stream_insert(:invitations, invitation)
             |> put_flash(:info, email_handoff_message("Invitation regenerated"))}

          {:error, _} ->
            {:error, "Could not resend that invitation. It may no longer be pending."}
        end
      end)
    else
      {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
    end
  end

  def handle_event("resend_invitation", _params, socket) do
    {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket)
      when is_binary(id) and byte_size(id) > 0 do
    if can_manage?(socket.assigns.scope) do
      with_invitation(socket, id, fn invitation, scope ->
        reserved? = invitation_reserved?(invitation)

        case Orgs.revoke_invitation(invitation, %{}, actor: scope) do
          {:ok, invitation} ->
            {:ok,
             socket
             |> stream_insert(:invitations, invitation)
             |> decrement_pending_count(reserved?)
             |> put_flash(:info, "Invitation revoked. Its link will no longer work.")}

          {:error, _} ->
            {:error, "Could not revoke that invitation. It may no longer be pending."}
        end
      end)
    else
      {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
    end
  end

  def handle_event("revoke_invitation", _params, socket) do
    {:noreply, put_flash(socket, :error, invite_permission_message(socket))}
  end

  def handle_event("change_role", %{"membership_id" => id, "role" => role}, socket)
      when is_binary(id) and byte_size(id) > 0 and is_binary(role) do
    if can_manage?(socket.assigns.scope) do
      with_member(socket, id, fn member, scope ->
        case Orgs.change_member_role(member, %{role: role}, actor: scope) do
          {:ok, _member} ->
            {:ok,
             socket
             |> load_members()
             |> put_flash(:info, "Role updated.")}

          {:error, _} ->
            {:error, "Could not change that member's role. You cannot change your own role."}
        end
      end)
    else
      {:noreply, put_flash(socket, :error, team_permission_message())}
    end
  end

  def handle_event("change_role", _params, socket) do
    {:noreply, put_flash(socket, :error, team_permission_message())}
  end

  # Members render inside a `phx-update="stream"` table, so a row only
  # re-renders on an explicit `stream_insert` — never on a plain assign
  # change, even when the row's template reads an assign like
  # `@transfer_confirm_id` (FRAMEWORK-RULES.md, LiveView streams; matches
  # `AlplusWeb.ProjectsLive`'s `confirm_archive`).
  def handle_event("confirm_transfer_ownership", %{"id" => id}, socket)
      when is_binary(id) and byte_size(id) > 0 do
    if owner?(socket.assigns.scope) do
      with_member(socket, id, fn member, _scope ->
        {:ok,
         socket
         |> assign(transfer_confirm_id: member.id, transfer_confirm_text: "")
         |> stream_insert(:members, member)}
      end)
    else
      {:noreply, put_flash(socket, :error, owner_permission_message())}
    end
  end

  def handle_event("confirm_transfer_ownership", _params, socket) do
    if owner?(socket.assigns.scope) do
      {:noreply, put_flash(socket, :error, "Choose a member to transfer ownership to.")}
    else
      {:noreply, put_flash(socket, :error, owner_permission_message())}
    end
  end

  def handle_event("cancel_transfer_ownership", _params, socket) do
    if owner?(socket.assigns.scope) do
      id = socket.assigns.transfer_confirm_id
      socket = assign(socket, transfer_confirm_id: nil, transfer_confirm_text: "")
      {:noreply, reinsert_member(socket, id)}
    else
      {:noreply, put_flash(socket, :error, owner_permission_message())}
    end
  end

  def handle_event("transfer_ownership_input", %{"id" => id, "confirm_text" => text}, socket)
      when is_binary(id) and byte_size(id) > 0 and is_binary(text) do
    if owner?(socket.assigns.scope) do
      with_member(socket, id, fn member, _scope ->
        {:ok,
         socket
         |> assign(:transfer_confirm_text, text)
         |> stream_insert(:members, member)}
      end)
    else
      {:noreply, put_flash(socket, :error, owner_permission_message())}
    end
  end

  def handle_event("transfer_ownership_input", _params, socket) do
    {:noreply, put_flash(socket, :error, owner_permission_message())}
  end

  def handle_event("transfer_ownership", %{"id" => id, "confirm_text" => text}, socket)
      when is_binary(id) and byte_size(id) > 0 and is_binary(text) do
    scope = socket.assigns.scope

    if owner?(scope) do
      with_member(socket, id, fn member, scope ->
        if text == to_string(member.user.email) do
          case Orgs.promote_to_owner(member, %{}, actor: scope) do
            {:ok, _new_owner} ->
              {:ok,
               socket
               |> assign(transfer_confirm_id: nil, transfer_confirm_text: "")
               |> put_flash(:info, "Ownership transferred.")
               |> reload_team()}

            {:error, _} ->
              {:error, "Could not transfer ownership."}
          end
        else
          {:error, "Type the member's email to confirm."}
        end
      end)
    else
      {:noreply, put_flash(socket, :error, "Only the owner can transfer ownership.")}
    end
  end

  def handle_event("transfer_ownership", _params, socket) do
    if owner?(socket.assigns.scope) do
      {:noreply, put_flash(socket, :error, "Type the member's email to confirm.")}
    else
      {:noreply, put_flash(socket, :error, owner_permission_message())}
    end
  end

  def handle_event("confirm_remove", %{"id" => id}, socket)
      when is_binary(id) and byte_size(id) > 0 do
    if can_manage?(socket.assigns.scope) do
      with_member(socket, id, fn member, _scope ->
        {:ok,
         socket
         |> assign(remove_confirm_id: member.id, remove_confirm_text: "")
         |> stream_insert(:members, member)}
      end)
    else
      {:noreply, put_flash(socket, :error, team_permission_message())}
    end
  end

  def handle_event("confirm_remove", _params, socket) do
    if can_manage?(socket.assigns.scope) do
      {:noreply, put_flash(socket, :error, "Choose a member to remove.")}
    else
      {:noreply, put_flash(socket, :error, team_permission_message())}
    end
  end

  def handle_event("cancel_remove", _params, socket) do
    if can_manage?(socket.assigns.scope) do
      id = socket.assigns.remove_confirm_id
      socket = assign(socket, remove_confirm_id: nil, remove_confirm_text: "")
      {:noreply, reinsert_member(socket, id)}
    else
      {:noreply, put_flash(socket, :error, team_permission_message())}
    end
  end

  def handle_event("remove_input", %{"id" => id, "confirm_text" => text}, socket)
      when is_binary(id) and byte_size(id) > 0 and is_binary(text) do
    if can_manage?(socket.assigns.scope) do
      with_member(socket, id, fn member, _scope ->
        {:ok,
         socket
         |> assign(:remove_confirm_text, text)
         |> stream_insert(:members, member)}
      end)
    else
      {:noreply, put_flash(socket, :error, team_permission_message())}
    end
  end

  def handle_event("remove_input", _params, socket) do
    {:noreply, put_flash(socket, :error, team_permission_message())}
  end

  def handle_event("remove", %{"id" => id, "confirm_text" => text}, socket)
      when is_binary(id) and byte_size(id) > 0 and is_binary(text) do
    if can_manage?(socket.assigns.scope) do
      with_member(socket, id, fn member, scope ->
        if text == to_string(member.user.email) do
          case Orgs.remove_member(member, actor: scope) do
            :ok ->
              {:ok,
               socket
               |> stream_delete(:members, member)
               |> assign(remove_confirm_id: nil, remove_confirm_text: "")
               |> load_members()
               |> put_flash(:info, "Member removed.")}

            {:error, _} ->
              {:error, "Could not remove that member. The owner cannot be removed this way."}
          end
        else
          {:error, "Type the member's email to confirm."}
        end
      end)
    else
      {:noreply, put_flash(socket, :error, team_permission_message())}
    end
  end

  def handle_event("remove", _params, socket) do
    {:noreply, put_flash(socket, :error, team_permission_message())}
  end

  defp do_invite(socket, scope, params) do
    case Form.submit(socket.assigns.invite_form, params: params) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> stream_insert(:invitations, invitation, at: 0)
         |> assign(:invitations_empty?, false)
         |> assign(
           :pending_invitations_count,
           (socket.assigns.pending_invitations_count || 0) + 1
         )
         |> assign(:invite_form, invite_form(scope, socket.assigns.org_id))
         |> assign(:show_invite, false)
         |> assign(:invite_error, nil)
         |> put_flash(
           :info,
           "Invitation sent to #{invitation.email}. It remains pending until accepted."
         )}

      {:error, form} ->
        message = invite_form_error(form)

        {:noreply,
         socket
         |> assign(:invite_form, to_form(form))
         |> assign(:invite_error, message)}
    end
  end

  defp reinsert_member(socket, nil), do: socket

  defp reinsert_member(socket, id) do
    case scoped_member(socket, id) do
      {:ok, %Membership{} = member} -> stream_insert(socket, :members, member)
      {:error, _} -> socket
      {:ok, nil} -> socket
    end
  end

  defp with_member(socket, id, fun) do
    scope = socket.assigns.scope

    case scoped_member(socket, id) do
      {:ok, %Membership{} = member} ->
        case fun.(member, scope) do
          {:ok, socket} -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "That member is not available in this organization.")}

      {:ok, nil} ->
        {:noreply,
         put_flash(socket, :error, "That member is not available in this organization.")}
    end
  end

  defp with_invitation(socket, id, fun) do
    scope = socket.assigns.scope

    case scoped_invitation(socket, id) do
      {:ok, %Invitation{} = invitation} ->
        case fun.(invitation, scope) do
          {:ok, socket} -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "That invitation is not available in this organization.")}

      {:ok, nil} ->
        {:noreply,
         put_flash(socket, :error, "That invitation is not available in this organization.")}
    end
  end

  defp load_team(socket) do
    socket
    |> mark_loading()
    |> load_members()
    |> load_invitations()
  end

  defp mark_loading(socket) do
    socket
    |> assign(:members_state, :loading)
    |> assign(:members_error, nil)
    |> assign(
      :invitations_state,
      if(can_manage?(socket.assigns.scope), do: :loading, else: :hidden)
    )
    |> assign(:invitations_error, nil)
  end

  defp load_members(socket) do
    scope = socket.assigns.scope
    org_id = socket.assigns.org_id

    case Orgs.list_org_members(scope, org_id) do
      {:ok, members} ->
        socket
        |> assign_member_counts(members)
        |> assign(members_state: :ready, members_error: nil, members_empty?: members == [])
        |> stream(:members, members, reset: true)

      {:error, _error} ->
        assign(socket,
          members_state: :error,
          members_error: "Team members could not be loaded. Try again."
        )
    end
  end

  defp load_invitations(socket) do
    scope = socket.assigns.scope

    if can_manage?(scope) do
      org_id = socket.assigns.org_id

      case Orgs.list_org_invitations(scope, org_id) do
        {:ok, all_invitations} ->
          invitations = Enum.filter(all_invitations, &(&1.status == "pending"))
          reserved_count = Enum.count(invitations, &invitation_reserved?/1)

          socket
          |> stream(:invitations, invitations, reset: true)
          |> assign(
            invitations_state: :ready,
            invitations_error: nil,
            invitations_empty?: invitations == [],
            pending_invitations_count: reserved_count
          )

        {:error, _error} ->
          assign(socket,
            invitations_state: :error,
            invitations_error: "Pending invitations could not be loaded. Try again."
          )
      end
    else
      socket
      |> stream(:invitations, [], reset: true)
      |> assign(
        invitations_state: :hidden,
        invitations_error: nil,
        invitations_empty?: true,
        pending_invitations_count: nil
      )
    end
  end

  defp reload_team(socket) do
    scope = socket.assigns.scope

    case Alplus.Orgs.build_scope(Alplus.Scope.for_user(scope.user_id), socket.assigns.org_id) do
      {:ok, scope} -> load_team(assign(socket, :scope, scope))
      {:error, :not_found} -> socket
    end
  end

  defp assign_member_counts(socket, members) do
    counts = Enum.frequencies_by(members, & &1.role)

    socket
    |> assign(:member_total, length(members))
    # `owner` and `admin` are one number in the band: both can change the org,
    # and the two stats have to sum to the headline's total.
    |> assign(:admin_count, Map.get(counts, "owner", 0) + Map.get(counts, "admin", 0))
    |> assign(:plain_member_count, Map.get(counts, "member", 0))
  end

  defp scoped_member(socket, id),
    do: Orgs.fetch_org_member(socket.assigns.scope, socket.assigns.org_id, id)

  defp scoped_invitation(socket, id),
    do: Orgs.fetch_org_invitation(socket.assigns.scope, socket.assigns.org_id, id)

  defp invite_form(scope, _org_id) do
    Invitation
    |> Form.for_create(:invite, domain: Alplus.Orgs, actor: scope, as: "invitation")
    |> to_form()
  end
end
