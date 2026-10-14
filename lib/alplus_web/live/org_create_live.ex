defmodule AlplusWeb.OrgCreateLive do
  @moduledoc """
  Organization creation, under `/dashboard/` (ARCHITECTURE.md §9).

  `Alplus.Orgs.Organization`'s `:create` action already runs
  `Alplus.Orgs.Changes.CreateOwnerMembership` in the same transaction, so
  the creator becomes the org's owner as a side effect of this one Ash
  call — no separate membership step here.

  Reachable in two states: a brand-new user with zero orgs (always
  allowed — `create_allowed?/1`'s `[] -> true` clause), or a user who
  already owns an active paid org and wants another one (the trial cap is
  lifted by owning any paid org). A trial-only user who already has their
  one org never reaches a rendered form: the mount guard below redirects
  them straight back to `/dashboard` with a subscribe prompt. `mount/3`
  fetches the org list once and reuses it both for that cap check and for
  `has_organizations?`, which gates the "back to your account" link in
  the card — a brand-new user has nowhere useful to go back to yet, so
  the link only appears for the second, existing-orgs case.
  """

  use AlplusWeb, :live_view

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  alias AshPhoenix.Form
  alias Alplus.Billing.Access
  alias Alplus.Orgs.Organization

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: %{confirmed_at: nil}}} = socket) do
    {:ok,
     socket
     |> put_flash(:info, "Confirm your email before creating an organization.")
     |> push_navigate(to: ~p"/dashboard")}
  end

  def mount(_params, session, socket) do
    scope = Alplus.Scope.for_user(socket.assigns.current_user.id)
    organizations = Alplus.Orgs.list_organizations!(actor: scope)

    {:ok,
     socket
     |> assign(:scope, scope)
     |> assign(:page_title, "Create organization")
     |> assign(:has_organizations?, organizations != [])
     |> assign(:create_allowed?, create_allowed?(organizations))
     |> assign(:handoff_return_to, AlplusWeb.WebsiteHealthCheck.Handoff.continue_path(session))
     |> assign(:form, build_form(scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title="Create your organization">
      <:subtitle>Your team's workspace. One login, one bill. You can rename it later.</:subtitle>
      <%!-- The limit is explained where the person arrived, with the way
            forward, instead of a redirect and a flash they may miss. --%>
      <div
        :if={not @create_allowed?}
        id="org-limit-notice"
        role="status"
        class="rounded-frame border border-border-default bg-surface-sunken px-4 py-3 text-body text-text-secondary"
      >
        <p class="font-semibold text-text-primary">A trial includes one organization.</p>
        <p class="mt-1">Subscribe to PostDeploy on the billing page to add another organization.</p>
      </div>
      <.form
        :if={@create_allowed?}
        for={@form}
        id="new-org-form"
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" id="org-name" required />
        <.button
          phx-disable-with="Creating..."
          id="create-org-submit"
          variant="primary"
          class="w-full"
        >
          Create organization
        </.button>
      </.form>
      <.link
        :if={@has_organizations?}
        navigate={~p"/dashboard"}
        class="mt-4 block min-h-target-min text-center text-body text-interactive-strong underline hover:text-interactive-strong-hover"
      >
        Back to your account
      </.link>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    form = socket.assigns.form |> Form.validate(params, errors: false) |> to_form()
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    # Re-check at the write boundary: the mount guard hides the route, this
    # stops a socket that was already open when the cap was reached.
    scope = socket.assigns.scope

    if create_allowed?(Alplus.Orgs.list_organizations!(actor: scope)) do
      save_org(socket, params)
    else
      {:noreply,
       socket
       |> put_flash(:error, "A trial includes one organization. Subscribe to add more.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  defp save_org(socket, params) do
    case Form.submit(socket.assigns.form, params: params) do
      {:ok, organization} ->
        path =
          socket.assigns.handoff_return_to ||
            ~p"/dashboard/orgs/#{organization.public_token}/projects"

        {:noreply, push_navigate(socket, to: path)}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  defp build_form(scope) do
    Organization
    |> Form.for_create(:create, domain: Alplus.Orgs, actor: scope, as: "organization")
    |> to_form()
  end

  # A trial-only user gets one organization; owning any subscribed org lifts
  # the cap. The first org (empty list) is always allowed.
  #
  # Each org's access resolves through `Access.check/1`, and only a
  # subscription lifts the cap. A handful of orgs means a handful of cheap,
  # indexed reads, so no aggregate query is warranted here.
  defp create_allowed?([]), do: true

  defp create_allowed?(organizations) do
    Enum.any?(organizations, fn org ->
      Access.check(org.id) == {:ok, :subscribed}
    end)
  end
end
