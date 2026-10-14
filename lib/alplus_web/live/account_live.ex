defmodule AlplusWeb.AccountLive do
  @moduledoc """
  The operator's own account, at `/dashboard/account` (ARCHITECTURE.md §9):
  display name and the staged email change.

  This is the only screen under `/dashboard/` that is about the person rather
  than about an organization, which is exactly why it is its own route. It
  lived briefly on `/dashboard` and did not belong there: `/dashboard` answers
  "which org do I want", and a settings form is not an answer to that.
  Personal details are equally not an *organization* setting, so it does not
  belong under `/dashboard/orgs/:org_token/settings` either — a display name
  does not change when you switch orgs.

  Both forms are `Alplus.Accounts.User`'s own `:update_profile` action,
  authorized by `actor == record` — no org role is involved, and this route
  carries no `org_token`, so there is no tenant to scope. A name change applies
  immediately. An email change is staged and re-verified through the
  `:confirm_email_change` add-on (see `Alplus.Accounts.User`'s moduledoc):
  `@current_user.email` never changes here until the emailed link is
  confirmed, so the email form's submit only ever shows a "check your inbox"
  notice, never a new address in place.

  Layout note: the page uses `console_page/1`'s reading column rather than taking
  the shell's full `max-w-wide`. Two short forms stretched across a 1320px
  column read as tiny controls lost in a void; the fix is a narrower column,
  not wider fields.
  """

  use AlplusWeb, :live_view
  import AlplusWeb.DashboardComponents

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  alias AshPhoenix.Form

  @impl true
  def mount(_params, _session, socket) do
    scope = Alplus.Scope.for_user(socket.assigns.current_user.id)
    current_user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:scope, scope)
     |> assign(:page_title, "Account")
     |> assign(:organizations, [])
     |> assign(:name_form, name_form(current_user, scope))
     |> assign(:email_form, email_form(current_user, scope))
     |> assign(:profile_name_notice, nil)
     |> assign(:email_notice, nil)
     |> load_organizations()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      flash={@flash}
      org={nil}
      organizations={@organizations}
      current_user={@current_user}
      active={:account}
      page_title="Account"
      page_heading?={false}
    >
      <.console_page id="account-page" width={:reading}>
        <:title>Account</:title>
        <div class="flex flex-col gap-4">
          <.data_panel
            id="account-name"
            padded
            title="Display name"
            description="Shown instead of your email address across the dashboard."
          >
            <.form
              for={@name_form}
              id="profile-name-form"
              phx-change="validate_profile_name"
              phx-submit="save_profile_name"
              phx-hook="FocusInvalid"
            >
              <.input
                field={@name_form[:name]}
                type="text"
                label="Your name"
                id="profile-name"
                placeholder="Ada Lovelace"
              />
              <.button id="save-profile-name" variant="primary" phx-disable-with="Saving...">
                Save name
              </.button>
              <p
                :if={@profile_name_notice}
                id="profile-name-notice"
                role="status"
                aria-live="polite"
                class="mt-3 text-data text-status-live-ink"
              >
                {@profile_name_notice}
              </p>
            </.form>
          </.data_panel>

          <.data_panel
            id="account-email"
            padded
            title="Email address"
            description="Your sign-in address. Account and security messages are sent here."
          >
            <.definition_list>
              <:row label="Current">
                <span class="font-mono">{@current_user.email}</span>
              </:row>
            </.definition_list>

            <%!-- The notice sits above the form, not below the button: it is the
                result of the last submit, and the field underneath it is
                still holding the address the operator just asked for. --%>
            <p
              :if={@email_notice}
              id="profile-email-notice"
              role="status"
              aria-live="polite"
              class="mt-4 border border-status-neutral-border bg-status-neutral-bg p-3 text-data text-status-neutral-ink"
            >
              {@email_notice}
            </p>

            <.form
              for={@email_form}
              id="profile-email-form"
              phx-change="validate_profile_email"
              phx-submit="save_profile_email"
              phx-hook="FocusInvalid"
              class="mt-4 border-t border-border-subtle pt-4"
            >
              <.input
                field={@email_form[:email]}
                type="email"
                label="New address"
                id="profile-email"
                placeholder="you@example.com"
              />
              <.button id="save-profile-email" variant="secondary" phx-disable-with="Sending...">
                Send confirmation link
              </.button>
              <p class="mt-2 text-label text-text-tertiary">
                Your current address keeps working until you follow the link.
              </p>
            </.form>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # `Alplus.Accounts.User`'s `:update_profile` policy (`actor == record`) is
  # the only gate on this page. There is deliberately no `can_manage?/1` check
  # anywhere here: an org role has nothing to do with editing your own name.
  @impl true
  def handle_event("validate_profile_name", %{"user" => params}, socket) do
    form = socket.assigns.name_form |> Form.validate(params, errors: false) |> to_form()
    {:noreply, assign(socket, name_form: form, profile_name_notice: nil)}
  end

  def handle_event("save_profile_name", %{"user" => params}, socket) do
    case Form.submit(socket.assigns.name_form, params: params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:name_form, name_form(user, socket.assigns.scope))
         |> assign(:profile_name_notice, "Profile updated.")
         |> put_flash(:info, "Profile updated.")}

      {:error, form} ->
        {:noreply, assign(socket, name_form: to_form(form), profile_name_notice: nil)}
    end
  end

  def handle_event("validate_profile_email", %{"user" => params}, socket) do
    form = socket.assigns.email_form |> Form.validate(params, errors: false) |> to_form()
    {:noreply, assign(socket, email_form: form, email_notice: nil)}
  end

  def handle_event("save_profile_email", %{"user" => params}, socket) do
    case Form.submit(socket.assigns.email_form, params: params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:email_form, email_form(user, socket.assigns.scope))
         |> assign(
           :email_notice,
           "Check your inbox to confirm your new email address. Your current email stays active until then."
         )}

      {:error, form} ->
        {:noreply, assign(socket, email_form: to_form(form), email_notice: nil)}
    end
  end

  # Only feeds the shell's org-less sidebar, which lists the actor's orgs as
  # nav so this page is not a dead end. `Organization`'s read policy already
  # scopes the query to orgs the actor belongs to.
  defp load_organizations(socket) do
    organizations =
      Alplus.Orgs.list_organizations!(
        actor: socket.assigns.scope,
        query: Ash.Query.sort(Alplus.Orgs.Organization, inserted_at: :desc)
      )

    assign(socket, :organizations, organizations)
  end

  # Same `:update_profile` action backs both forms; each only ever submits its
  # own field (`name` here, `email` below), so submitting one never touches
  # the other.
  defp name_form(user, scope) do
    user
    |> Form.for_update(:update_profile, domain: Alplus.Accounts, actor: scope, as: "user")
    |> to_form()
  end

  defp email_form(user, scope) do
    user
    |> Form.for_update(:update_profile, domain: Alplus.Accounts, actor: scope, as: "user")
    |> to_form()
  end
end
