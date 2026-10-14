defmodule AlplusWeb.DashboardComponents do
  @moduledoc """
  The application shell for every `/dashboard/` route (ARCHITECTURE.md §9):
  a persistent sidebar (brand, org switcher, role-aware nav, account footer)
  and a content area with a context bar (page title, project selector,
  environment filter).

  Wraps `Layouts.app` in its `:bare` variant, so flash handling and the root
  layout stay defined in one place while the shell owns the full chrome.

  Organization navigation contains organization-owned work only. Project
  features live in the explicit project hub, so Monitor, Measure, and Observe
  can never be entered without a project route segment.

  Role-aware: sensitive org nav items are gated by the underlying Ash
  policy, which stays the real gate (hide the control AND reject the
  event).

  IA (design system v3, `designSystem/PostDeploy v3.dc.html` §04): a
  project's sidebar is a flat list with Overview and Monitors, followed by
  Observe, Measure, Analytics, and Public groups. Only reachable destinations are listed. Monitors includes uptime
  checks, heartbeats, and recent incidents.
  Project switching uses the topbar's `project_select/1` (already rendered by
  every project-scoped page via `@project_scoped`), so opening a project no
  longer needs a sidebar list of every sibling project.
  """

  use Phoenix.Component
  use AlplusWeb, :verified_routes

  import AlplusWeb.CoreComponents, only: [logo: 1]
  import AlplusWeb.LucideIcons, only: [lucide: 1]

  import AlplusWeb.ConsoleComponents,
    only: [project_select: 1, environment_select: 1, window_select: 1]

  alias AlplusWeb.Layouts
  alias Phoenix.LiveView.JS

  attr :flash, :map, required: true
  attr :active, :atom, default: nil
  attr :org, :any, default: nil, doc: "the current org (id + name), or nil on org-less pages"
  attr :organizations, :list, default: [], doc: "orgs the actor belongs to, for the switcher"
  attr :scope, :any, default: nil, doc: "the request scope, for role-aware nav"
  attr :current_user, :any, default: nil, doc: "for the account footer"
  attr :page_title, :string, default: nil

  attr :page_heading?, :boolean,
    default: true,
    doc: """
    Whether the shell draws the page's `<h1>` from `page_title`. A screen that
    draws its own visible heading (a service name, an incident title) passes
    false, so the page keeps exactly one heading and the visible one wins.
    `page_title` still feeds the browser tab title and the trail.
    """

  attr :onboarding?, :boolean, default: false
  attr :center_content?, :boolean, default: true
  attr :nav_project, :any, default: nil
  attr :nav_projects, :list, default: []

  attr :nav_locked?, :boolean,
    default: false,
    doc: """
    When true the rail shows this project's destinations as locked rows
    instead of links, because the project has no agent connection yet.
    Connect (MCP) stays active, and the org switcher, breadcrumb and
    account footer stay usable.
    """

  attr :project_scoped, :boolean,
    default: false,
    doc: "when true, the context bar shows the project selector + environment filter"

  attr :projects, :list, default: []
  attr :project, :any, default: nil
  attr :environments, :list, default: []
  attr :environment, :string, default: nil

  @doc_window """
  The page header's time range. A page with time-scoped data passes the
  window it is currently reading and handles `pick_window`; a page with no
  time-scoped data passes nothing and the header draws no control, rather
  than a dead one.
  """
  attr :agent_connected?, :boolean,
    default: false,
    doc: "draws the connection state in the top bar; project screens pass the gate's answer"

  attr :window, :any, default: nil, doc: @doc_window
  attr :windows, :list, default: ~w(24h 7d 30d)

  slot :inner_block, required: true
  slot :context_actions, doc: "trailing controls in the context bar (e.g. a page action)"

  def dashboard_shell(assigns) do
    assigns =
      assigns
      |> assign(:nav_project, assigns.nav_project || assigns.project)
      |> assign(
        :nav,
        if(assigns.onboarding? and is_nil(assigns.nav_project),
          do: [],
          else: nav_items(role(assigns.scope))
        )
      )

    ~H"""
    <Layouts.app flash={@flash} variant={:bare}>
      <div
        data-webmcp-dashboard
        data-webmcp-org-id={@org && @org.id}
        data-webmcp-project-handle={@nav_project && @nav_project.id}
        class="min-h-dvh bg-surface-page lg:flex"
      >
        <%!-- Mobile top bar --%>
        <div class="flex min-h-target-min items-center justify-between border-b border-border-default bg-surface-raised px-4 lg:hidden">
          <.logo href={~p"/dashboard"} variant={:full} size={:sm} />
          <button
            type="button"
            id="mobile-nav-open"
            phx-click={show_mobile_nav()}
            phx-hook=".MobileNavEscape"
            class="flex min-h-target-min min-w-target-min cursor-pointer items-center justify-center rounded-control border border-border-default bg-surface-raised text-text-primary hover:bg-interactive-tint"
            aria-label="Open navigation"
            aria-controls="mobile-nav"
            aria-expanded="false"
          >
            <.lucide name="menu" class="size-5" />
          </button>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".MobileNavEscape">
            export default {
              mounted() {
                this.onKey = (event) => {
                  if (event.key !== "Escape") return
                  if (this.el.getAttribute("aria-expanded") !== "true") return
                  event.preventDefault()
                  const close = document.getElementById("mobile-nav-close")
                  if (close) close.click()
                }
                window.addEventListener("keydown", this.onKey, true)
              },
              destroyed() {
                window.removeEventListener("keydown", this.onKey, true)
              }
            }
          </script>
        </div>
        <%!-- Scrim + drawer (mobile) and static sidebar (desktop) --%>
        <div
          id="mobile-nav-scrim"
          phx-click={hide_mobile_nav()}
          class="fixed inset-0 z-30 hidden bg-scrim lg:hidden"
          aria-hidden="true"
        />
        <.sidebar
          id="mobile-nav"
          class="fixed inset-y-0 left-0 z-40 hidden min-w-0 w-72 -translate-x-full border-r border-border-default transition-transform duration-productive lg:hidden"
          nav={@nav}
          active={@active}
          org={@org}
          nav_project={@nav_project}
          nav_projects={@nav_projects}
          organizations={@organizations}
          current_user={@current_user}
          onboarding?={@onboarding?}
          page_title={@page_title}
          nav_locked?={@nav_locked?}
          mobile
        />
        <.sidebar
          id="desktop-nav"
          class="sticky top-0 hidden h-dvh min-w-0 w-sidebar shrink-0 border-r border-border-default lg:flex"
          nav={@nav}
          active={@active}
          org={@org}
          nav_project={@nav_project}
          nav_projects={@nav_projects}
          organizations={@organizations}
          current_user={@current_user}
          onboarding?={@onboarding?}
          page_title={@page_title}
          nav_locked?={@nav_locked?}
        />

        <%!-- Content. The console main region is white and full-bleed: the
              design source draws each screen inside a bordered specimen frame
              only because it is a documentation page. In the product the
              sidebar and the `#FFFFFF` main region are the whole viewport, so
              no 1200px cap and no second frame. --%>
        <%!-- `data-console-content` is the console content scale (theme-
              console.css). The rail is deliberately outside it: it is chrome
              at the right density already, and the product beside it is read
              for minutes on a 1440px canvas. --%>
        <div data-console-content class="min-w-0 max-w-full flex-1 bg-surface-raised">
          <%!-- The rule spans the whole content column; the row inside it
                aligns to the same 1440px measure the page body uses, so the
                breadcrumb, the time range and the first card share one left
                and one right edge. --%>
          <div
            :if={
              @org || @page_title || @project_scoped || @window || @agent_connected? ||
                @context_actions != []
            }
            class="border-b border-border-default bg-surface-raised"
          >
            <div class="mx-auto flex w-full max-w-page-full flex-col gap-3 px-4 py-3 sm:px-6 lg:flex-row lg:items-center lg:justify-between lg:px-8">
              <div class="flex flex-wrap items-center gap-3">
                <%!-- The trail IS the page heading here: its last crumb names the
                    current page at reading weight, so a second `<h1>` printing
                    the same word directly beneath it was pure duplication
                    ("Projects › Projects"). The `<h1>` stays for assistive
                    technology and the browser-tab title contract — one per
                    page, never removed, just not drawn twice.

                    A screen that draws its own visible `<h1>` (a service, an
                    incident) passes `page_heading?={false}`, so the two never
                    compete for the same page. --%>
                <h1 :if={@page_title && @page_heading?} class="sr-only">{@page_title}</h1>
                <%!-- On a screen that carries the project selector, the selector
                    names the project. The trail drops its project crumb there
                    so the context bar says the project once, and keeps the org
                    crumb, which nothing else links to. --%>
                <.breadcrumbs
                  :if={@org}
                  org={@org}
                  project={@nav_project}
                  project_in_selector={@project_scoped}
                  active={@active}
                  page_title={@page_title}
                />
                <p
                  :if={is_nil(@org) and @page_title}
                  aria-hidden="true"
                  class="text-body font-semibold text-text-primary"
                >
                  {@page_title}
                </p>
                <div :if={@project_scoped} class="flex flex-wrap items-center gap-2">
                  <.project_select projects={@projects} project={@project} />
                  <.environment_select
                    :if={@project}
                    environments={@environments}
                    environment={@environment}
                  />
                </div>
              </div>
              <%!-- The design source puts the time range on the right of the
                  page header, once per screen. It lives here rather than in
                  each LiveView so it cannot drift in position or in the
                  ranges it offers. --%>
              <div
                :if={@window || @agent_connected? || @context_actions != []}
                class="flex flex-wrap items-center gap-2"
              >
                <%!-- The one place the console states the agent connection.
                      It is a standing fact about the project, not an event, so
                      it reads as a quiet dot and two words beside the range
                      rather than as a status pill competing with the page. --%>
                <p
                  :if={@agent_connected?}
                  id="topbar-agent-connection"
                  class="flex items-center gap-2 whitespace-nowrap text-caption text-text-secondary"
                >
                  <span class="size-2 shrink-0 rounded-dot bg-status-live" aria-hidden="true" />
                  Agent connected
                </p>
                <.window_select :if={@window} window={@window} windows={@windows} />
                {render_slot(@context_actions)}
              </div>
            </div>
          </div>

          <%!-- The page gutter: 16px on a phone, 24px from `sm`, 32px from
                `lg` where the canvas can pay for it. The 1440px cap keeps a
                table from stretching to an unreadable line length on an
                ultrawide display; below that the page is full-bleed. --%>
          <main class={[
            "mx-auto min-w-0 w-full max-w-page-full",
            if(@onboarding? and @center_content?,
              do:
                "flex min-h-[calc(100dvh-3.5rem)] items-center justify-center px-4 py-6 sm:px-6 lg:min-h-dvh lg:px-8",
              else: "p-4 sm:p-6 lg:px-8 lg:py-7"
            )
          ]}>
            <.live_component
              :if={not is_nil(@current_user) and not @onboarding?}
              module={AlplusWeb.ConfirmEmailBanner}
              id="confirm-email-banner"
              current_user={@current_user}
            />
            {render_slot(@inner_block)}
          </main>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  The org → project → product/resource trail, and the console's visible page
  heading (issue #29). The sidebar's org switcher and project-tools block
  already carry this context, but the sidebar collapses to a hidden mobile
  drawer, so this is the only place current org + project stay visible on
  every viewport. It also turns the route's own path segments (`:org_token`,
  `:project_token` — `router.ex`) into a clickable trail instead of only an
  address-bar detail.

  The last crumb is the current page: not a link, `aria-current="page"`, and
  drawn at reading weight because it is what names the screen. The shell's
  `<h1>` is `sr-only` for exactly that reason — the heading exists once for
  assistive technology, and this trail is its visible form, rather than the
  two printing the same word one line apart.

  Built entirely from what every `dashboard_shell/1` caller already passes
  (`org`, `nav_project`, `active`, `page_title`) — no new assign to wire up
  per LiveView. `active` picks the product crumb's label and link;
  `page_title` becomes a trailing resource crumb (a monitor name, an issue)
  only when it says something none of the earlier crumbs already say, so a
  page whose title is just the product or project name doesn't duplicate
  itself.
  """
  attr :org, :any, required: true
  attr :project, :any, default: nil, doc: "the nav-pinned project (nav_project), or nil"

  attr :project_in_selector, :boolean,
    default: false,
    doc: "when true the context bar already names the project, so the trail omits its crumb"

  attr :active, :atom, default: nil
  attr :page_title, :string, default: nil
  attr :id, :string, default: "breadcrumbs"

  def breadcrumbs(assigns) do
    assigns = assign(assigns, :items, breadcrumb_items(assigns))

    ~H"""
    <nav
      :if={@items != []}
      id={@id}
      aria-label="Breadcrumb"
      class="flex flex-wrap items-center gap-1.5 text-body text-text-tertiary"
    >
      <%= for {item, index} <- Enum.with_index(@items) do %>
        <span :if={index > 0} class="select-none text-text-divider" aria-hidden="true">/</span>
        <.link
          :if={item.navigate}
          navigate={item.navigate}
          id={"#{@id}-#{index}"}
          class="max-w-40 truncate hover:text-text-primary"
        >
          {item.label}
        </.link>
        <%!-- The current page. This is the console's visible page heading, so
              it carries the ink and the weight the `<h1>` used to. --%>
        <span
          :if={is_nil(item.navigate)}
          id={"#{@id}-#{index}"}
          aria-current="page"
          class="max-w-64 truncate font-semibold text-text-primary"
        >
          {item.label}
        </span>
      <% end %>
    </nav>
    """
  end

  @product_labels %{
    projects: "Projects",
    monitor: "Monitors",
    measure: "Traffic",
    analytics: "Analytics",
    observe: "Issues",
    public: "Public",
    connect: "MCP",
    team: "Team",
    billing: "Billing",
    settings: "Settings"
  }

  defp breadcrumb_items(%{org: org} = assigns) do
    project = Map.get(assigns, :project)

    org_item = %{label: org.name, navigate: ~p"/dashboard/orgs/#{org.public_token}/projects"}

    # The product crumb still needs to know a project is open, even when the
    # selector names it and the project crumb is dropped.
    project_item =
      if Map.get(assigns, :project_in_selector), do: nil, else: project_item(org, project)

    product_item = product_item(org, project, Map.get(assigns, :active))

    items = Enum.reject([org_item, project_item, product_item], &is_nil/1)
    labels = MapSet.new(items, & &1.label)

    resource_label = Map.get(assigns, :page_title)

    items =
      if resource_label && resource_label not in labels do
        items ++ [%{label: resource_label, navigate: nil}]
      else
        items
      end

    # The last crumb is always the current page, whether it is the trailing
    # resource crumb above or (when there is none) the product crumb itself.
    List.update_at(items, -1, &Map.put(&1, :navigate, nil))
  end

  defp project_item(_org, nil), do: nil

  defp project_item(org, project),
    do: %{
      label: project.name,
      navigate: ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}"
    }

  # The project hub (`active: :projects` with a project open) already reads
  # as the project crumb directly above it — no separate "Projects" crumb
  # for that one page.
  defp product_item(_org, project, :projects) when not is_nil(project), do: nil

  defp product_item(org, nil, :projects),
    do: %{
      label: @product_labels.projects,
      navigate: ~p"/dashboard/orgs/#{org.public_token}/projects"
    }

  # The MCP connect page passes its own `page_title` ("Connect an agent"),
  # which already becomes the trailing breadcrumb crumb below — same reason
  # the project's own :projects overview needs no product crumb either.
  defp product_item(_org, project, :connect) when not is_nil(project), do: nil

  defp product_item(org, project, active)
       when active in [:monitor, :measure, :analytics, :observe, :public] do
    if project do
      %{
        label: @product_labels[active],
        navigate: project_nav_path(org.public_token, project.public_token, active)
      }
    else
      nil
    end
  end

  # The project's own Settings screen lives under Public, so the trail still
  # reads through Public even though the rail pins Settings to its foot.
  defp product_item(org, project, :project_settings) when not is_nil(project),
    do: %{
      label: @product_labels.public,
      navigate: project_nav_path(org.public_token, project.public_token, :public)
    }

  defp product_item(org, _project, active) when active in [:team, :billing, :settings],
    do: %{label: @product_labels[active], navigate: nav_path(org.public_token, active)}

  defp product_item(_org, _project, _active), do: nil

  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :nav, :list, required: true
  attr :active, :atom, default: nil
  attr :org, :any, default: nil
  attr :nav_project, :any, default: nil
  attr :nav_projects, :list, default: []
  attr :organizations, :list, default: []
  attr :current_user, :any, default: nil
  attr :mobile, :boolean, default: false
  attr :onboarding?, :boolean, default: false
  attr :page_title, :string, default: nil
  attr :nav_locked?, :boolean, default: false

  # Only the mobile drawer is a focus trap. The desktop rail used to sit inside
  # a `focus_wrap` too, and LiveView's focus_wrap hook moves focus to its first
  # focusable child whenever it mounts, so every page load and every live
  # navigation landed on the logo and skipped the skip link (audit 2026-08-30).
  defp sidebar(%{mobile: true} = assigns) do
    ~H"""
    <.focus_wrap
      id={"#{@id}-focus-wrap"}
      class="hidden"
      aria-hidden="true"
      phx-key="escape"
      phx-keydown={hide_mobile_nav()}
    >
      <.sidebar_nav {assigns} />
    </.focus_wrap>
    """
  end

  defp sidebar(assigns) do
    ~H"""
    <.sidebar_nav {assigns} />
    """
  end

  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :nav, :list, required: true
  attr :active, :atom, default: nil
  attr :org, :any, default: nil
  attr :nav_project, :any, default: nil
  attr :nav_projects, :list, default: []
  attr :organizations, :list, default: []
  attr :current_user, :any, default: nil
  attr :mobile, :boolean, default: false
  attr :onboarding?, :boolean, default: false
  attr :page_title, :string, default: nil
  attr :nav_locked?, :boolean, default: false

  defp sidebar_nav(assigns) do
    ~H"""
    <nav
      id={@id}
      class={["flex h-full min-w-0 flex-col bg-surface-page", @class]}
      aria-label="Primary"
      aria-hidden={@mobile && "true"}
      role={@mobile && "dialog"}
      aria-modal={@mobile && "true"}
      aria-labelledby={@mobile && "#{@id}-title"}
    >
      <div class="flex min-h-target-min items-center justify-between border-b border-border-default px-4">
        <.logo href={~p"/dashboard"} variant={:full} size={:sm} />
        <span :if={@mobile} id={"#{@id}-title"} class="sr-only">
          {@page_title || "PostDeploy navigation"}
        </span>
        <button
          :if={@mobile}
          type="button"
          id="mobile-nav-close"
          phx-click={hide_mobile_nav()}
          class="flex min-h-target-min min-w-target-min cursor-pointer items-center justify-center rounded-control text-text-secondary hover:bg-interactive-tint hover:text-text-primary"
          aria-label="Close navigation"
        >
          <.lucide name="x" class="size-5" />
        </button>
      </div>

      <div :if={is_map(@org)} class="px-3 pb-2 pt-3">
        <.org_switcher org={@org} organizations={@organizations} id={"#{@id}-org"} />
      </div>

      <div
        :if={
          is_map(@org) and is_map(@nav_project) and
            (not @onboarding? or is_map(@nav_project))
        }
        id={"#{@id}-project-nav"}
        class="flex-1 overflow-y-auto px-3 py-2"
      >
        <%!-- The flat, single-project IA keeps one monitor destination.
                Switching projects is the topbar's job. --%>
        <div class="space-y-0.5">
          <%!-- The prerequisite is said once, above the rows it locks, not
                  as a note repeated on every row. --%>
          <p
            :if={@nav_locked?}
            id={"#{@id}-locked-note"}
            class="px-2.5 pb-2 text-caption text-text-secondary"
          >
            Connect an agent to manage this project.
          </p>
          <.nav_link
            id={"#{@id}-overview"}
            navigate={~p"/dashboard/orgs/#{@org.public_token}/projects/#{@nav_project.public_token}"}
            label="Overview"
            icon="layout-dashboard"
            active?={@active == :projects}
            disabled?={@nav_locked?}
          />
          <%!-- Uptime checks and heartbeats are one screen, so they are one
                  row. The page's own filter separates them; a second nav row
                  pointing at the same route only ever meant "the same page
                  with a query string". --%>
          <.nav_link
            id={"#{@id}-monitors"}
            navigate={project_nav_path(@org.public_token, @nav_project.public_token, :monitor)}
            label="Monitors"
            icon="activity"
            active?={@active == :monitor}
            disabled?={@nav_locked?}
          />
        </div>

        <div :for={{group_label, items} <- project_nav_groups(@org, @nav_project)}>
          <p class="mt-4 px-2.5 pb-1 text-label font-medium text-text-tertiary">
            {group_label}
          </p>
          <div class="space-y-0.5">
            <.nav_link
              :for={item <- items}
              id={"#{@id}-#{item.key}"}
              navigate={item.navigate}
              label={item.label}
              icon={item.icon}
              active?={not @nav_locked? and @active == item.active}
              disabled?={@nav_locked?}
            />
          </div>
        </div>

        <%!-- Pinned foot of the rail (design source §04): how you inspect and
                configure this project, kept apart from the groups you watch. --%>
        <div class="mt-4 space-y-0.5 border-t border-border-default pt-3">
          <%!-- MCP stays reachable while the rail is locked: it is the one
                  screen that resolves the lock. --%>
          <.nav_link
            :for={item <- project_pinned_items(@org, @nav_project)}
            id={"#{@id}-#{item.key}"}
            navigate={item.navigate}
            label={item.label}
            icon={item.icon}
            active?={@active == item.active}
            disabled?={@nav_locked? and item.key != :mcp}
          />
        </div>
      </div>

      <%!-- Org-level pages (no project open): the org's own screens, gated
            by role. "Projects" leads because it is the org home (project list
            + onboarding) and the way back into a specific project. --%>
      <div
        :if={is_map(@org) and is_nil(@nav_project) and (not @onboarding? or @nav_projects != [])}
        class="flex-1 overflow-y-auto px-3 py-2"
      >
        <div id={"#{@id}-organization-nav"} class="space-y-0.5">
          <.nav_link
            :for={{key, label, icon} <- @nav}
            id={"#{@id}-#{key}"}
            navigate={nav_path(org_token(@org), key)}
            label={label}
            icon={icon}
            active?={@active == key}
          />
        </div>
      </div>

      <div :if={is_map(@org) and @onboarding? and not is_map(@nav_project)} class="flex-1" />

      <%!-- Org-less pages (`/dashboard`, `/dashboard/account`) have no
            switcher, so the org list itself becomes the nav: the sidebar
            stays a way to get somewhere instead of an empty column. The
            picker leads, so `/dashboard/account` is never a dead end. --%>
      <div :if={is_nil(@org)} class="flex-1 overflow-y-auto px-3 py-2">
        <.link
          navigate={~p"/dashboard"}
          id={"#{@id}-all-orgs"}
          class={nav_class(@active == :dashboard)}
          aria-current={@active == :dashboard && "page"}
        >
          <.lucide name="layout-dashboard" class="size-4 shrink-0" />
          <span class="min-w-0 truncate">All organizations</span>
        </.link>
        <p class="px-2.5 pb-1 pt-3 text-label font-medium text-text-tertiary">
          Organizations
        </p>
        <div id={"#{@id}-organization-list"} class="space-y-0.5">
          <%!-- An icon, not the initial tile the switcher uses: a nav row's
                leading glyph is `size-4`, and no type step fits a letter in
                16px (`caption`, the smallest, is 15px). Matching the other nav
                rows beats inventing an off-ramp font size for one tile. --%>
          <.link
            :for={o <- @organizations}
            navigate={~p"/dashboard/orgs/#{o.public_token}/projects"}
            id={"#{@id}-org-#{o.id}"}
            class={nav_class(false)}
          >
            <.lucide name="building-2" class="size-4 shrink-0 text-interactive-strong" />
            <span class="min-w-0 truncate">{o.name}</span>
          </.link>
          <p :if={@organizations == []} class="px-2.5 py-1 text-body text-text-secondary">
            None yet.
          </p>
        </div>
      </div>

      <%!-- The account footer (design system v3 §04): avatar initial, name,
            and a `...` overflow menu. The overflow is the only remaining
            entry point to the org's own screens (Team, Billing, Organization
            settings) from inside a project's flat nav, plus the operator's
            own account and sign-out — everything the old two-line
            account/sign-out block and the org-level nav used to cover. --%>
      <div :if={@current_user} class="relative border-t border-border-default p-3">
        <div class="flex items-center gap-1">
          <.link
            navigate={~p"/dashboard/account"}
            id={"#{@id}-account"}
            aria-current={@active == :account && "page"}
            class={[
              "flex h-control-md min-w-0 flex-1 items-center gap-2.5 rounded-control px-2.5 py-2",
              @active == :account &&
                "border border-border-default bg-surface-raised text-text-primary shadow-nav-active",
              @active != :account && "border border-transparent hover:bg-hover"
            ]}
          >
            <span
              class="flex size-6 shrink-0 items-center justify-center rounded-dot bg-interactive-tint text-label font-semibold text-interactive-strong"
              aria-hidden="true"
            >
              {user_initial(@current_user)}
            </span>
            <span
              class={[
                "min-w-0 flex-1 truncate text-ui text-text-primary",
                user_shows_email?(@current_user) && "font-mono text-data"
              ]}
              title={to_string(@current_user.email)}
            >
              {user_display_name(@current_user)}
            </span>
          </.link>
          <button
            type="button"
            id={"#{@id}-account-toggle"}
            phx-click={
              JS.toggle(to: "##{@id}-account-menu")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              |> JS.toggle_attribute({"aria-hidden", "false", "true"}, to: "##{@id}-account-menu")
            }
            class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-control text-text-tertiary hover:bg-hover hover:text-text-primary"
            aria-haspopup="menu"
            aria-expanded="false"
            aria-controls={"#{@id}-account-menu"}
            aria-label="More account options"
          >
            <.lucide name="ellipsis" class="size-4" />
          </button>
        </div>

        <div
          id={"#{@id}-account-menu"}
          phx-click-away={hide_account_menu(@id)}
          phx-hook=".ConsoleMenu"
          class="absolute bottom-full left-3 right-3 z-10 mb-1 hidden rounded-control border border-border-default bg-surface-raised p-1 shadow-overlay"
          role="menu"
          aria-hidden="true"
        >
          <div :if={is_map(@org)}>
            <.link
              navigate={nav_path(org_token(@org), :team)}
              id={"#{@id}-account-team"}
              role="menuitem"
              class="flex h-control-md items-center rounded-control-sm px-2 py-1.5 text-label text-text-secondary hover:bg-hover hover:text-text-primary"
            >
              Team
            </.link>
            <.link
              navigate={nav_path(org_token(@org), :billing)}
              id={"#{@id}-account-billing"}
              role="menuitem"
              class="flex h-control-md items-center rounded-control-sm px-2 py-1.5 text-label text-text-secondary hover:bg-hover hover:text-text-primary"
            >
              Billing
            </.link>
            <.link
              navigate={nav_path(org_token(@org), :settings)}
              id={"#{@id}-account-settings"}
              role="menuitem"
              class="flex h-control-md items-center rounded-control-sm px-2 py-1.5 text-label text-text-secondary hover:bg-hover hover:text-text-primary"
            >
              Organization settings
            </.link>
          </div>
          <div class="my-1 border-t border-border-subtle" />
          <.link
            href={~p"/sign-out"}
            method="delete"
            id={"#{@id}-sign-out"}
            role="menuitem"
            class="flex h-control-md items-center rounded-control-sm px-2 py-1.5 text-label text-text-secondary hover:bg-hover hover:text-text-primary"
          >
            Sign out
          </.link>
        </div>
      </div>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, default: nil
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active?, :boolean, default: false
  attr :disabled?, :boolean, default: false
  slot :trailing

  defp nav_link(assigns) do
    ~H"""
    <.link
      :if={!@disabled?}
      navigate={@navigate}
      id={@id}
      class={nav_class(@active?)}
      aria-current={@active? && "page"}
    >
      <.lucide name={@icon} class="size-4 shrink-0" />
      <span class="min-w-0 flex-1 truncate">{@label}</span>
      {render_slot(@trailing)}
    </.link>
    <span
      :if={@disabled?}
      id={@id}
      aria-disabled="true"
      title="Connect an agent to manage this project."
      class="flex h-control-md items-center gap-2.5 rounded-control border border-transparent px-2.5 py-2 text-ui text-text-tertiary"
    >
      <.lucide name={@icon} class="size-4 shrink-0 text-text-disabled" />
      <span class="min-w-0 flex-1 truncate">{@label}</span>
      {render_slot(@trailing)}
    </span>
    """
  end

  attr :org, :any, required: true
  attr :organizations, :list, default: []
  attr :id, :string, required: true

  defp org_switcher(assigns) do
    # A trial-only user is capped at one organization; owning a subscribed
    # org lifts the cap. `billing_status` rides on every loaded org, so this
    # needs no extra query. `OrgCreateLive` enforces the same rule at
    # the route — this only hides a control that would fail.
    assigns = assign(assigns, :can_create_org?, Enum.any?(assigns.organizations, &subscribed?/1))

    ~H"""
    <div class="relative" id={@id}>
      <button
        type="button"
        id={"#{@id}-toggle"}
        phx-click={
          JS.toggle(to: "##{@id}-menu")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          |> JS.toggle_attribute({"aria-hidden", "false", "true"}, to: "##{@id}-menu")
        }
        class="flex h-control-md w-full cursor-pointer items-center justify-between gap-2 rounded-control border border-border-default bg-surface-raised px-2.5 py-2 text-left text-text-primary hover:bg-interactive-tint"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
      >
        <span class="flex min-w-0 items-center gap-2">
          <span class="flex size-6 shrink-0 items-center justify-center rounded-control bg-interactive-tint text-label font-semibold text-interactive-strong">
            {org_initial(@org)}
          </span>
          <span class="min-w-0 truncate text-ui font-medium text-text-primary">{@org.name}</span>
        </span>
        <.lucide name="chevrons-up-down" class="size-4 shrink-0 text-text-tertiary" />
      </button>

      <div
        id={"#{@id}-menu"}
        phx-click-away={hide_org_menu(@id)}
        phx-hook=".ConsoleMenu"
        class="absolute left-0 right-0 z-10 mt-1 hidden rounded-control border border-border-default bg-surface-raised p-1 shadow-overlay"
        role="menu"
        aria-hidden="true"
      >
        <.link
          :for={o <- @organizations}
          navigate={~p"/dashboard/orgs/#{o.public_token}/projects"}
          id={"#{@id}-switch-#{o.id}"}
          class={[
            "flex h-control-md items-center justify-between gap-2 rounded-control px-2 py-1.5 text-label hover:bg-interactive-tint",
            o.id == @org.id && "text-text-primary font-medium",
            o.id != @org.id && "text-text-secondary"
          ]}
          role="menuitem"
        >
          <span class="min-w-0 truncate">{o.name}</span>
          <.lucide
            :if={o.id == @org.id}
            name="check"
            class="size-4 shrink-0 text-interactive-strong"
          />
        </.link>
        <div :if={@can_create_org?} class="my-1 border-t border-border-subtle" />
        <.link
          :if={@can_create_org?}
          navigate={~p"/dashboard/orgs/new"}
          id={"#{@id}-new"}
          class="flex h-control-md items-center gap-2 rounded-control px-2 py-1.5 text-label text-text-secondary hover:bg-interactive-tint hover:text-text-primary"
          role="menuitem"
        >
          <.lucide name="plus" class="size-4" /> New organization
        </.link>
      </div>
      <%!-- One hook serves every console menu (the account menu and the org
           switcher): arrow keys open and walk the items, Home/End jump,
           Escape closes and returns focus to the button. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConsoleMenu">
        export default {
          mounted() {
            this.button = this.el.parentElement.querySelector('[aria-controls="' + this.el.id + '"]')
            this.items = () => Array.from(this.el.querySelectorAll('[role="menuitem"]'))
            this.isOpen = () => this.button && this.button.getAttribute("aria-expanded") === "true"

            this.focusItem = (index) => {
              const items = this.items()
              if (!items.length) return
              const i = ((index % items.length) + items.length) % items.length
              items[i].focus({preventScroll: true})
            }

            this.close = () => {
              this.el.classList.add("hidden")
              this.el.setAttribute("aria-hidden", "true")
              if (this.button) {
                this.button.setAttribute("aria-expanded", "false")
                this.button.focus({preventScroll: true})
              }
            }

            this.openAndFocus = (index) => {
              this.el.classList.remove("hidden")
              this.el.setAttribute("aria-hidden", "false")
              if (this.button) this.button.setAttribute("aria-expanded", "true")
              requestAnimationFrame(() => this.focusItem(index))
            }

            this.buttonKeydown = (event) => {
              if (event.key === "ArrowDown") {
                event.preventDefault()
                this.openAndFocus(0)
              } else if (event.key === "ArrowUp") {
                event.preventDefault()
                this.openAndFocus(this.items().length - 1)
              } else if (event.key === "Escape" && this.isOpen()) {
                event.preventDefault()
                this.close()
              }
            }

            this.menuKeydown = (event) => {
              const items = this.items()
              if (!items.length) return
              const current = items.indexOf(document.activeElement)
              if (event.key === "ArrowDown") {
                event.preventDefault()
                this.focusItem(current < 0 ? 0 : current + 1)
              } else if (event.key === "ArrowUp") {
                event.preventDefault()
                this.focusItem(current < 0 ? items.length - 1 : current - 1)
              } else if (event.key === "Home") {
                event.preventDefault()
                this.focusItem(0)
              } else if (event.key === "End") {
                event.preventDefault()
                this.focusItem(items.length - 1)
              } else if (event.key === "Escape") {
                event.preventDefault()
                this.close()
              }
            }

            this.openHandler = () => {
              requestAnimationFrame(() => {
                if (this.isOpen()) this.focusItem(0)
              })
            }

            if (this.button) {
              this.button.addEventListener("click", this.openHandler)
              this.button.addEventListener("keydown", this.buttonKeydown)
            }
            this.el.addEventListener("keydown", this.menuKeydown)
          },
          destroyed() {
            if (this.button) {
              this.button.removeEventListener("click", this.openHandler)
              this.button.removeEventListener("keydown", this.buttonKeydown)
            }
            this.el.removeEventListener("keydown", this.menuKeydown)
          }
        }
      </script>
    </div>
    """
  end

  # ---- Nav definition -------------------------------------------------------

  # {key, label, icon}.
  defp nav_items(_role) do
    [
      {:overview, "Projects", "layout-dashboard"},
      {:team, "Team", "users"},
      {:billing, "Billing", "credit-card"},
      {:settings, "Settings", "settings-2"}
    ]
  end

  defp role(%Alplus.Scope{role: role}), do: role
  defp role(_), do: nil

  defp nav_class(true),
    do:
      "flex h-control-md items-center gap-2.5 rounded-control border border-border-default bg-surface-raised px-2.5 py-2 text-ui font-semibold text-text-primary shadow-nav-active"

  defp nav_class(_),
    do:
      "flex h-control-md items-center gap-2.5 rounded-control border border-transparent px-2.5 py-2 text-ui text-text-secondary hover:bg-hover hover:text-text-primary"

  defp nav_path(org_id, :overview), do: ~p"/dashboard/orgs/#{org_id}/projects"
  defp nav_path(org_id, :team), do: ~p"/dashboard/orgs/#{org_id}/team"
  defp nav_path(org_id, :billing), do: ~p"/dashboard/orgs/#{org_id}/billing"
  defp nav_path(org_id, :settings), do: ~p"/dashboard/orgs/#{org_id}/settings"

  # Design system v3 §04's flat, grouped project nav. Every row navigates
  # somewhere real. Destinations the product does not have yet (Search,
  # Releases, Reports) are not listed: a rail row that cannot be opened is a
  # dead end the reader has to classify on every visit (audit 2026-08-30).
  # `active` names the `dashboard_shell` `active` atom that highlights the row.
  #
  # Uptime checks and heartbeats are the same screen, so "Monitors" is a
  # single ungrouped row above (the mock's Monitor group had two rows over one
  # route). The page's own type filter separates the two.
  defp project_nav_groups(org, project) do
    [
      {"Observe",
       [
         %{
           key: :issues,
           label: "Issues",
           icon: "circle-alert",
           navigate: project_nav_path(org.public_token, project.public_token, :observe),
           active: :observe
         }
       ]},
      {"Measure",
       [
         %{
           key: :traffic,
           label: "Traffic",
           icon: "chart-column",
           navigate: project_nav_path(org.public_token, project.public_token, :measure),
           active: :measure
         }
       ] ++ seo_nav_item(org, project)},
      # Product analytics is its own group, not a row under Measure: Measure
      # answers how much traffic a site got, Analytics answers what the
      # people who arrived went on to do (ADR 0007).
      {"Analytics",
       [
         %{
           key: :analytics_overview,
           label: "Overview",
           icon: "gauge",
           navigate: project_nav_path(org.public_token, project.public_token, :analytics),
           active: :analytics
         },
         %{
           key: :analytics_events,
           label: "Events",
           icon: "list",
           navigate:
             ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/analytics/events",
           active: :analytics
         },
         %{
           key: :analytics_funnels,
           label: "Funnels",
           icon: "filter",
           navigate:
             ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/analytics/funnels",
           active: :analytics
         },
         %{
           key: :analytics_retention,
           label: "Retention",
           icon: "repeat",
           navigate:
             ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/analytics/retention",
           active: :analytics
         },
         %{
           key: :analytics_live,
           label: "Live events",
           icon: "activity",
           navigate:
             ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/analytics/live",
           active: :analytics
         }
       ]},
      {"Public",
       [
         %{
           key: :status_page,
           label: "Status page",
           icon: "globe",
           navigate: project_nav_path(org.public_token, project.public_token, :public),
           active: :public
         },
         %{
           key: :changelog,
           label: "Changelog",
           icon: "megaphone",
           navigate: project_nav_path(org.public_token, project.public_token, :changelog),
           active: :changelog
         }
       ]}
    ]
  end

  defp seo_nav_item(org, project) do
    if Alplus.Seo.Feature.enabled?(org.id) do
      [
        %{
          key: :seo,
          label: "SEO",
          icon: "search",
          navigate:
            ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/measure/seo",
          active: :measure
        }
      ]
    else
      []
    end
  end

  # Design source §04 pins MCP and Settings to the foot of the rail, above the
  # user row, separated from the product groups. They are how you inspect and
  # configure the project, not another thing to watch, so they do not belong
  # under "Public".
  defp project_pinned_items(org, project) do
    [
      %{
        key: :mcp,
        label: "MCP",
        icon: "plug",
        navigate: project_nav_path(org.public_token, project.public_token, :connect),
        active: :connect
      },
      %{
        key: :public_settings,
        label: "Settings",
        icon: "settings-2",
        navigate: project_nav_path(org.public_token, project.public_token, :settings),
        # Its own key, not `:public`. Sharing the Status page key marked two
        # rows current at once, so the rail could not say which screen you
        # were on.
        active: :project_settings
      }
    ]
  end

  defp hide_org_menu(id) do
    JS.hide(to: "##{id}-menu")
    |> JS.set_attribute({"aria-hidden", "true"}, to: "##{id}-menu")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-toggle")
  end

  defp hide_account_menu(id) do
    JS.hide(to: "##{id}-account-menu")
    |> JS.set_attribute({"aria-hidden", "true"}, to: "##{id}-account-menu")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-account-toggle")
  end

  defp project_nav_path(org_token, project_token, :monitor),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/monitor"

  defp project_nav_path(org_token, project_token, :measure),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/measure"

  defp project_nav_path(org_token, project_token, :analytics),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/analytics"

  defp project_nav_path(org_token, project_token, :observe),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/observe"

  defp project_nav_path(org_token, project_token, :connect),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/connect"

  defp project_nav_path(org_token, project_token, :public),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/status"

  defp project_nav_path(org_token, project_token, :changelog),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/changelog"

  defp project_nav_path(org_token, project_token, :settings),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/public/settings"

  defp show_mobile_nav do
    %JS{}
    |> JS.push_focus()
    |> JS.show(to: "#mobile-nav-focus-wrap")
    |> JS.set_attribute({"aria-hidden", "false"}, to: "#mobile-nav-focus-wrap")
    |> JS.show(to: "#mobile-nav-scrim")
    |> JS.show(to: "#mobile-nav")
    |> JS.remove_class("-translate-x-full", to: "#mobile-nav")
    |> JS.set_attribute({"aria-hidden", "false"}, to: "#mobile-nav")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#mobile-nav-open")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "#mobile-nav")
  end

  defp hide_mobile_nav do
    %JS{}
    |> JS.hide(to: "#mobile-nav-focus-wrap")
    |> JS.set_attribute({"aria-hidden", "true"}, to: "#mobile-nav-focus-wrap")
    |> JS.hide(to: "#mobile-nav-scrim")
    |> JS.hide(to: "#mobile-nav")
    |> JS.add_class("-translate-x-full", to: "#mobile-nav")
    |> JS.set_attribute({"aria-hidden", "true"}, to: "#mobile-nav")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#mobile-nav-open")
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  defp org_initial(%{name: name}) when is_binary(name),
    do: String.upcase(String.first(name) || "?")

  defp org_initial(_), do: "?"

  defp user_initial(user), do: user |> user_display_name() |> initial()

  defp initial(""), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()

  # Subscribed means an active or past-due subscription, never a trial or a
  # lapsed subscription.
  defp subscribed?(%{billing_status: status}), do: status in [:active, :past_due]
  defp subscribed?(_), do: false

  defp org_token(%{public_token: token}) when is_binary(token), do: token
  defp org_token(_), do: ""

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: nil}), do: ""
  defp user_display_name(%{email: email}), do: to_string(email)
  defp user_display_name(_), do: ""

  defp user_shows_email?(%{name: name}) when is_binary(name) and name != "", do: false
  defp user_shows_email?(%{email: email}) when not is_nil(email), do: true
  defp user_shows_email?(_), do: false
end
