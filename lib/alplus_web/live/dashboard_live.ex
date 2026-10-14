defmodule AlplusWeb.DashboardLive do
  @moduledoc """
  The organization picker, at `/dashboard` (ARCHITECTURE.md §9). It answers
  one question — which organization do I want to work in — and it is the only
  screen that can answer it, because every other console route needs an
  `:org_token` it does not have yet.

  Each row carries what the operator needs to choose: the org's name, its
  subscription state (plus a status badge when it is not healthy), their own role in
  it, and how many projects it holds. Everything but the project count rides
  on data already loaded:

    * `Organization`'s read policy scopes the list to orgs where the actor
      holds a live membership (`exists(memberships, user_id ==
      ^actor(:user_id))`), so there is no tenant predicate to repeat here.
    * `billing_status` and `trial_ends_at` are plain attributes on the row.
    * The actor's own role comes from loading their membership alongside the
      org in the same query, so listing N orgs costs one query, not N+1.
    * Project counts come from ONE cross-org read. `Project`'s read policy is
      `exists(organization.memberships, user_id == ^actor(:user_id))` — it
      authorizes per row against membership rather than against a pinned
      `actor(:org_id)` — so a user-scoped `list_projects` returns every
      project the actor can see across every org, and grouping it by `org_id`
      here costs nothing further.

  Deliberately absent: monitor/issue health per org. `Monitor` and
  `Observe.Issue` both gate reads on `org_id == ^actor(:org_id) and
  project_id == ^actor(:project_id)`, so a cross-org health roll-up would
  cost one scoped read per project on the landing page. That belongs behind a
  real aggregate, not behind an N+1 on the first screen after sign-in. Health
  lives one click away, on the org's own project list, which already computes
  it for the org you actually picked.

  Personal account details are NOT here. They moved to
  `AlplusWeb.AccountLive` (`/dashboard/account`): a settings form is not an
  answer to "which org do I want".

  Who reaches this screen: `AlplusWeb.AuthController.default_redirect/1`
  routes a zero-org sign-in to `/dashboard/orgs/new` and a single-org sign-in
  straight into that org, so in practice the picker is for operators who
  genuinely have a choice to make. It still renders correctly for a direct
  visit in either of those states — including the empty state, for a user who
  has left their only org.
  """

  use AlplusWeb, :live_view
  import AlplusWeb.DashboardComponents

  require Ash.Query

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  alias Alplus.Billing.Package
  alias Alplus.Orgs.Membership

  @impl true
  def mount(_params, _session, socket) do
    scope = Alplus.Scope.for_user(socket.assigns.current_user.id)

    socket =
      socket
      |> assign(:scope, scope)
      |> assign(:page_title, "Organizations")
      # `:organizations` is a plain list for the summary stat and the shell's
      # org-less sidebar nav; the `:organizations` *stream* below drives the
      # page's own rows. Phoenix streams live under the separate `@streams`
      # assign, so the two never collide despite sharing a name.
      |> assign(:organizations, [])
      |> stream(:organizations, [])
      |> assign(:project_counts, %{})

    socket = if connected?(socket), do: load_organizations(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      flash={@flash}
      org={nil}
      organizations={@organizations}
      current_user={@current_user}
      active={:dashboard}
      page_title="Organizations"
    >
      <.console_page id="dashboard-page">
        <div
          :if={@current_user.confirmed_at == nil}
          id="activation-email-verification"
          class="flex flex-col gap-4"
        >
          <.summary_card
            id="activation-verification-card"
            headline="Verify your email to activate your workspace"
            subtitle="Your session is safe, but organization, project, and agent activation stay locked until confirmation."
            stats={[]}
          />
        </div>

        <div
          :if={@current_user.confirmed_at != nil and not connected?(@socket)}
          id="organizations-loading"
        >
          <.skeleton rows={3} />
        </div>

        <div
          :if={@current_user.confirmed_at != nil and connected?(@socket)}
          class="flex flex-col gap-4"
        >
          <.summary_card
            id="organizations-summary"
            headline={org_count_headline(@organizations)}
            subtitle={org_summary_subtitle(@current_user)}
            stats={org_summary_stats(@organizations, @project_counts)}
          >
            <:actions :if={@organizations != [] and show_create_org_link?(@organizations)}>
              <.button navigate={~p"/dashboard/orgs/new"} variant="primary" id="create-org-link">
                Create organization
              </.button>
            </:actions>
          </.summary_card>

          <%!-- No panel title: the band above already names what this list is,
              and a panel headed "Organizations" over a column headed
              "Organization" printed the same word twice, one line apart. --%>
          <.data_panel id="organizations-panel">
            <table class="block w-full text-left text-body sm:table">
              <thead class="hidden sm:table-header-group">
                <tr class="border-b border-border-default">
                  <th
                    scope="col"
                    class="px-4 py-2 text-label font-semibold uppercase text-text-secondary"
                  >
                    Organization
                  </th>
                  <th
                    scope="col"
                    class="whitespace-nowrap px-4 py-2 text-label font-semibold uppercase text-text-secondary"
                  >
                    Subscription
                  </th>
                  <th
                    scope="col"
                    class="whitespace-nowrap px-4 py-2 text-label font-semibold uppercase text-text-secondary"
                  >
                    Your role
                  </th>
                  <th
                    scope="col"
                    class="whitespace-nowrap px-4 py-2 text-right text-label font-semibold uppercase text-text-secondary"
                  >
                    Projects
                  </th>
                </tr>
              </thead>
              <tbody
                id="organizations"
                phx-update="stream"
                class="block divide-y divide-border-default sm:table-row-group"
              >
                <tr :if={@organizations == []} id="organizations-empty" class="block sm:table-row">
                  <td colspan="4" class="block px-4 py-6 sm:table-cell">
                    <.empty_state
                      icon="hero-building-office-2"
                      title="No organizations yet"
                      description="An organization is your team's workspace. One login, one bill."
                    >
                      <.button
                        navigate={~p"/dashboard/orgs/new"}
                        variant="primary"
                        id="create-org-link"
                      >
                        Create an organization
                      </.button>
                    </.empty_state>
                  </td>
                </tr>

                <tr
                  :for={{dom_id, org} <- @streams.organizations}
                  id={dom_id}
                  data-org-row="true"
                  class="block border-b border-border-default last:border-b-0 sm:table-row"
                >
                  <td class="block px-4 py-3 sm:table-cell">
                    <.link
                      navigate={~p"/dashboard/orgs/#{org.public_token}/projects"}
                      id={"org-link-#{org.id}"}
                      class="flex min-h-target-min items-center gap-2.5 font-medium text-text-primary hover:text-interactive-strong-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                    >
                      <span class="flex size-7 shrink-0 items-center justify-center rounded-dot border border-border-default bg-surface-sunken text-caption font-semibold text-interactive-strong">
                        {org_initial(org)}
                      </span>
                      <span class="min-w-0 truncate">{org.name}</span>
                    </.link>
                  </td>
                  <td
                    data-label="Subscription"
                    class="block px-4 py-3 text-text-primary sm:table-cell"
                  >
                    <span class="mr-2 text-caption font-medium uppercase tracking-wide text-text-tertiary sm:hidden">
                      Subscription
                    </span>
                    <% badge = subscription_badge(org) %>
                    <% term = trial_term(org) %>
                    <%!-- A running trial's remaining term is quiet metadata
                        beside the state, not a state to flag. A trial that
                        ended IS a state, and keeps its badge. --%>
                    <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                      <span class="whitespace-nowrap">{subscription_name(org)}</span>
                      <span :if={term} class="whitespace-nowrap text-caption text-text-secondary">
                        {term}
                      </span>
                      <.status_badge :if={badge} tone={elem(badge, 0)} label={elem(badge, 1)} />
                    </div>
                    <%!-- Trial lapse note: the org is read-only from `trial_ends_at`
                        until its data is purged after the separate inactive
                        retention window. Rendered as a caption under the
                        subscription cell, so it never fights the row's other columns. --%>
                    <% note = trial_inactive_note(org) %>
                    <p
                      :if={note}
                      class="mt-1 max-w-xs text-caption text-status-error-ink"
                    >
                      {note} <.timestamp at={purge_at(org)} format={:date} />.
                    </p>
                  </td>
                  <td data-label="Role" class="block px-4 py-3 text-text-secondary sm:table-cell">
                    <span class="mr-2 text-caption font-medium uppercase tracking-wide text-text-tertiary sm:hidden">
                      Role
                    </span>
                    <span id={"org-role-#{org.id}"}>{role_name(actor_role(org))}</span>
                  </td>
                  <td
                    data-label="Projects"
                    id={"org-projects-#{org.id}"}
                    class="flex items-center justify-between gap-3 px-4 py-3 tabular-nums text-text-secondary sm:table-cell sm:text-right"
                  >
                    <span class="text-caption font-medium uppercase tracking-wide text-text-tertiary sm:hidden">
                      Projects
                    </span>
                    <span>
                      {Map.get(@project_counts, org.id, 0)}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp load_organizations(socket) do
    scope = socket.assigns.scope

    # Loads each org's role for `scope.user_id` in the same query
    # (`Ash.Query.load(memberships: ...)` filtered to the actor's own user id)
    # instead of one membership lookup per org — one join, not an N+1.
    organizations =
      Alplus.Orgs.list_organizations!(
        actor: scope,
        query:
          Alplus.Orgs.Organization
          |> Ash.Query.sort(inserted_at: :desc)
          |> Ash.Query.load(memberships: Ash.Query.filter(Membership, user_id == ^scope.user_id))
      )

    socket
    |> assign(:organizations, organizations)
    |> assign(:project_counts, project_counts(scope))
    |> stream(:organizations, organizations, reset: true)
  end

  # One read for every org at once. `Project`'s read policy authorizes per row
  # against the actor's membership (`exists(organization.memberships, user_id
  # == ^actor(:user_id))`) rather than against a pinned `actor(:org_id)`, so a
  # user-scoped list already spans every org the actor belongs to and the
  # grouping happens in memory. A per-org `list_projects_for_org!` here would
  # be the same data at N queries.
  defp project_counts(scope) do
    Alplus.Projects.list_projects!(actor: scope)
    |> Enum.frequencies_by(& &1.org_id)
  end

  defp org_count_headline([_one]), do: "1 organization"
  defp org_count_headline(organizations), do: "#{length(organizations)} organizations"

  # The band names the operator, because this screen is reached from a sidebar
  # that has no org context yet and the account it belongs to is the only
  # framing available.
  defp org_summary_subtitle(%{name: name, email: email}) when is_binary(name) and name != "",
    do: "Signed in as #{name} (#{email})"

  defp org_summary_subtitle(%{email: email}), do: "Signed in as #{email}"

  # Two totals, both free: the org count is the list length, and the project
  # total is the sum of the counts already grouped for the rows.
  defp org_summary_stats(organizations, project_counts) do
    [
      %{
        id: "organizations-stat-count",
        label: "Organizations",
        value: length(organizations)
      },
      %{
        id: "organizations-stat-projects",
        label: "Projects",
        value: project_counts |> Map.values() |> Enum.sum()
      }
    ]
  end

  # Mirrors `org_switcher/1`'s own cap check (`DashboardComponents`) so this
  # header action never offers something `OrgCreateLive`'s own mount guard
  # would immediately bounce. Only ever consulted once the operator has at
  # least one org — the zero-org case gets its own action in the empty state,
  # where the first org is unconditionally allowed.
  defp show_create_org_link?(organizations), do: Enum.any?(organizations, &subscribed?/1)

  defp subscribed?(%{billing_status: status}), do: status in [:active, :past_due]

  defp subscription_name(%{billing_status: :trialing}), do: "Trial"
  defp subscription_name(_org), do: Package.get().name

  # Issue #61 item 35: the Subscription column badge gains trial vocabulary.
  # While the trial runs, it counts the days left off `trial_ends_at`; once
  # the trial lapses the badge says so outright. Every other status keeps the
  # existing subscription-status vocabulary. The deadline is a required
  # database invariant, so a missing value must surface instead of rendering
  # a fallback.
  defp subscription_badge(%{billing_status: :trialing, trial_ends_at: ends_at}) do
    if trial_running?(ends_at), do: nil, else: {"error", "Trial ended"}
  end

  defp subscription_badge(%{billing_status: :active}), do: nil

  defp subscription_badge(%{billing_status: status}),
    do: {status_tone(status), status_label(status)}

  # How much of the trial is left, as a phrase that completes the state name
  # rather than repeating it.
  defp trial_term(%{billing_status: :trialing, trial_ends_at: ends_at}) do
    now = DateTime.utc_now()

    if trial_running?(ends_at) do
      days = ends_at |> DateTime.diff(now) |> Integer.ceil_div(86_400)
      "#{days} #{plural_days(days)} left"
    end
  end

  defp trial_term(_org), do: nil

  defp trial_running?(ends_at), do: DateTime.compare(ends_at, DateTime.utc_now()) == :gt

  defp plural_days(1), do: "day"
  defp plural_days(_days), do: "days"

  # The read-only sentence for a lapsed trial. The purge date itself renders
  # through `<.timestamp>` in the template; this only decides whether the
  # note shows at all.
  defp trial_inactive_note(%{billing_status: :trialing, trial_ends_at: ends_at}) do
    if DateTime.compare(ends_at, DateTime.utc_now()) != :gt,
      do: "Read only: writes and ingest are stopped. Data is deleted on "
  end

  defp trial_inactive_note(_org), do: nil

  defp purge_at(org),
    do: DateTime.add(org.trial_ends_at, Package.inactive_retention_days() * 86_400, :second)

  defp status_tone(status)
       when status in [:past_due, :canceled, :incomplete_expired, :unpaid],
       do: "error"

  defp status_tone(_status), do: "warning"

  defp status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp actor_role(%{memberships: [%{role: role} | _]}), do: role
  defp actor_role(_org), do: nil

  defp role_name(nil), do: "Unavailable"
  defp role_name(role), do: String.capitalize(role)

  defp org_initial(%{name: name}) when is_binary(name),
    do: String.upcase(String.first(name) || "?")

  defp org_initial(_org), do: "?"
end
