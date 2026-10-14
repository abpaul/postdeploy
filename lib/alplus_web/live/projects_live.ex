defmodule AlplusWeb.ProjectsLive do
  @moduledoc """
  The org Projects screen, under `/dashboard/` (ARCHITECTURE.md §9): the
  resumable onboarding checklist, an org-wide health roll-up derived from
  every project's `AlplusWeb.ProjectSignals`, the project list, and project
  creation/archival for one org.

  Tenancy (ARCHITECTURE.md §4): the org id in the URL is resolved to a
  `Alplus.Scope` through `Alplus.Orgs.build_scope/2`, which looks up the
  actor's live membership row — a user with no membership in that org gets a
  404, never a 403. Every query repeats the `org_id` predicate itself; the
  read policy on `Alplus.Projects.Project` proves the actor belongs to *some*
  org that owns a project, which is not the same as proving it belongs to
  *this* org.

  The onboarding checklist is derived from real rows by `AlplusWeb.Onboarding`
  (never a stored flag) and collapses once every step is done. Once it does,
  the page reads as one answer to "is anything broken across my projects" (a
  `ConsoleComponents.summary_card/1` roll-up built from `@project_signals`)
  above one `ConsoleComponents.data_panel/1` table — never a grid of
  duplicated cards.
  """

  use AlplusWeb, :live_view
  import AlplusWeb.DashboardComponents
  import AlplusWeb.OrgContext, only: [can_manage?: 1]

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  alias AshPhoenix.Form
  alias Alplus.Billing.{Access, Package}
  alias Alplus.Projects.Project

  require Logger

  # One connected-only timer covers row types that do not currently emit a
  # PubSub event (Source, MonitorCheck, Issue, and AnalyticsDay). It is one
  # cancellable message per LiveView, not a per-row poll or a stored flag.
  @onboarding_refresh_interval 10_000

  @impl true
  def mount(
        %{"org_token" => _org_token},
        _session,
        %{assigns: %{current_user: %{confirmed_at: nil}}} = socket
      ) do
    {:ok,
     socket
     |> put_flash(:info, "Confirm your email before creating or selecting a project.")
     |> push_navigate(to: ~p"/dashboard")}
  end

  def mount(%{"org_token" => org_token}, session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Projects",
             active: :overview
           ) do
      scope = socket.assigns.scope

      socket =
        socket
        |> assign(:confirm_archive_id, nil)
        |> assign(:confirm_archive_text, "")
        |> assign(:show_new_project, false)
        |> assign(:form, new_project_form(scope))
        |> assign(:loading, true)
        |> assign(:checklist, [])
        |> assign(:just_completed?, false)
        |> assign(:connected_project_ids, MapSet.new())
        |> assign(:onboarding?, false)
        |> assign(:subscribed_topics, MapSet.new())
        |> assign(:can_add_project?, false)
        |> assign(:at_project_limit?, false)
        |> assign(:project_limit, nil)
        |> assign(:access_active?, true)
        |> assign(:project_signals, %{})
        |> assign(:handoff_return_to, AlplusWeb.WebsiteHealthCheck.Handoff.continue_path(session))
        |> stream(:projects, [])
        |> assign(:projects, [])
        |> assign(:projects_empty?, true)
        |> assign(:load_failed?, false)
        |> assign(:onboarding_refresh_timer, nil)

      socket = if connected?(socket), do: load(socket), else: socket

      {:ok, socket}
    end
  end

  # Live-updating (onboarding overhaul §4): existing Monitor/Observe events
  # are fast paths. The bounded connected-only refresh below covers row types
  # without a notifier and also notices a newly-created project.
  @impl true
  def handle_info({:monitor_updated, project_id}, socket) do
    {:noreply, socket |> refresh_project_signal(project_id) |> refresh_checklist()}
  end

  def handle_info({:observe_updated, project_id}, socket) do
    {:noreply, socket |> refresh_project_signal(project_id) |> refresh_checklist()}
  end

  def handle_info(:refresh_onboarding, socket) do
    socket = assign(socket, :onboarding_refresh_timer, nil)
    {:noreply, socket |> refresh_checklist() |> schedule_onboarding_refresh()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
      active={:overview}
      page_title={if(@onboarding?, do: nil, else: "Projects")}
      onboarding?={@onboarding?}
    >
      <.console_page id="projects-page">
        <div :if={@loading} id="projects-loading" class="space-y-4">
          <.skeleton rows={2} />
          <.skeleton rows={3} />
        </div>

        <div
          :if={not @loading and @load_failed?}
          id="projects-load-error"
          class="flex flex-col gap-4"
        >
          <.alert
            id="projects-load-error-message"
            kind="error"
            title="Projects are temporarily unavailable"
            message="We couldn't load this organization's projects. Your data is unchanged."
          />
          <.button id="projects-retry" variant="primary" phx-click="retry_load">
            Try again
          </.button>
        </div>

        <div
          :if={not @loading and not @load_failed? and @onboarding?}
          id="first-project-onboarding"
          class="w-full max-w-measure"
        >
          <.onboarding_panel
            checklist={@checklist}
            org={@org}
            project={List.first(@projects)}
            scope={@scope}
            form={@form}
            show_new_project={@show_new_project}
            just_completed?={@just_completed?}
          />
        </div>

        <div
          :if={not @loading and not @load_failed? and not @onboarding?}
          id="projects-content"
          phx-hook=".ProjectsArchiveFocus"
          data-archive-focus-id={archive_focus_id(@confirm_archive_id)}
          data-archive-focus-fallback-id="projects-summary"
          class="flex flex-col gap-4"
        >
          <%!-- Issue #61: when the org has no active access, this page is
              read only. No limit number is invented; the notice names the
              state and points at Billing, and every create affordance above
              and below stays hidden (`@can_add_project?` is false). --%>
          <.alert
            :if={not @access_active?}
            id="projects-billing-inactive"
            kind="warning"
            title="This organization has no active subscription."
          >
            Writes and ingest are stopped.
            <.link
              navigate={~p"/dashboard/orgs/#{@org.public_token}/billing"}
              class="font-medium underline"
            >
              Subscribe on the Billing page
            </.link>
            to continue.
          </.alert>

          <.onboarding_panel
            :if={@checklist != []}
            checklist={@checklist}
            org={@org}
            project={List.first(@projects)}
            scope={@scope}
            form={@form}
            show_new_project={@show_new_project}
            just_completed?={@just_completed?}
          />

          <.summary_card
            id="projects-summary"
            tabindex="-1"
            headline={org_health_headline(@project_signals)}
            subtitle={projects_subtitle(length(@projects))}
            stats={org_health_stats(@project_signals)}
          >
            <:actions>
              <.button
                :if={@can_add_project? and not @show_new_project}
                id="new-project-toggle"
                variant="primary"
                phx-click="toggle_new_project"
              >
                <.icon name="hero-plus" class="size-4" /> New project
              </.button>
              <p
                :if={@at_project_limit? and can_manage?(@scope)}
                id="project-limit-note"
                class="text-body text-text-secondary"
              >
                PostDeploy includes {@project_limit} projects. Delete a project to add another.
              </p>
            </:actions>
          </.summary_card>

          <%!-- No panel title: the `<h1>` above already says "Projects", and a
              panel heading repeating it sat one line above a column header
              saying "Project". --%>
          <.data_panel id="projects-panel" class="overflow-hidden">
            <div
              :if={@show_new_project}
              id="new-project-card"
              class="border-b border-border-default p-4"
            >
              <.form
                for={@form}
                id="new-project-form"
                phx-change="validate"
                phx-submit="save"
                class="max-w-sm"
              >
                <input type="hidden" name="project[org_id]" id="project-org-id" value={@org_id} />
                <.input field={@form[:name]} type="text" label="Name" id="project-name" required />
                <div class="mt-2 flex gap-2">
                  <.button id="create-project-submit" variant="primary" phx-disable-with="Creating...">
                    Create project
                  </.button>
                  <.button type="button" variant="secondary" phx-click="toggle_new_project">
                    Cancel
                  </.button>
                </div>
              </.form>
            </div>

            <div class="overflow-x-auto">
              <table class="block w-full text-left text-data sm:table">
                <thead class="hidden sm:table-header-group">
                  <tr class="border-b border-border-default">
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Project</th>
                    <%!-- Pillar ink lives on the header, never on the row's
                        status dot: pillar colour is identity, status colour is
                        health, and the two token groups never cross (the One
                        Ledger Rule, docs/DESIGN-SYSTEM.md). Equal widths keep
                        the three pillars reading as one scannable grid instead
                        of bunching left with dead space at the row end. --%>
                    <th scope="col" class="w-1/5 px-4 py-2 font-medium text-text-secondary">
                      Monitor
                    </th>
                    <th
                      scope="col"
                      class="w-1/5 px-4 py-2 font-medium text-text-secondary"
                    >
                      Observe
                    </th>
                    <th
                      scope="col"
                      class="w-1/5 px-4 py-2 font-medium text-text-secondary"
                    >
                      Measure
                    </th>
                    <th scope="col" class="px-4 py-2 text-right font-medium text-text-tertiary">
                      <span class="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody
                  id="projects"
                  phx-update="stream"
                  class="block divide-y divide-border-default sm:table-row-group"
                >
                  <tr id="projects-empty" class="hidden only:table-row">
                    <td colspan="5" class="block p-4 sm:table-cell">
                      <.empty_state
                        icon="hero-cube"
                        title="No projects yet"
                        description="A project groups the monitors, errors, and analytics for one app."
                      >
                        <.button
                          :if={@can_add_project?}
                          id="empty-new-project"
                          variant="primary"
                          phx-click="toggle_new_project"
                        >
                          Create your first project
                        </.button>
                      </.empty_state>
                    </td>
                  </tr>

                  <%!-- Two logical rows per project — the data row and, once
                      archiving starts, its typed-confirmation panel — would
                      need a `<tbody>` per stream item, but `<tbody>` cannot
                      nest inside the `<tbody phx-update="stream">` that
                      tracks it (invalid HTML; a nested `<tbody>` silently
                      closes its parent). Instead the row's own trailing cell
                      expands via `colspan` to take the full row width while
                      archiving, collapsing the other cells for that
                      project — one `<tr id={dom_id}>` per stream item,
                      matching every other streamed table in the console. --%>
                  <tr
                    :for={{dom_id, project} <- @streams.projects}
                    id={dom_id}
                    class="block border-b border-border-default last:border-b-0 sm:table-row"
                  >
                    <% signals =
                      Map.get(@project_signals, project.id, AlplusWeb.ProjectSignals.unavailable()) %>
                    <% archiving? = @confirm_archive_id == project.id %>
                    <td :if={not archiving?} class="block px-4 py-3 sm:table-cell">
                      <.link
                        id={"open-project-#{project.id}"}
                        navigate={
                          project_destination(
                            @org,
                            project,
                            @connected_project_ids
                          )
                        }
                        class="inline-flex min-h-target-min items-center font-medium text-text-primary hover:text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                      >
                        <span
                          id={"project-name-#{project.id}"}
                          class="block max-w-[16rem] truncate"
                          title={project.name}
                        >
                          {project.name}
                        </span>
                      </.link>
                    </td>
                    <%!-- Each pillar cell enters that pillar for that project.
                        Before this the row held three read-only readouts and
                        one link, so reaching a project's Monitor took two
                        clicks through the hub; the signal text was already
                        naming the destination, so making it the link is what
                        it looked like it did. The link fills the cell
                        (`block px-4 py-3`), so the padding is the hit
                        target. --%>
                    <.pillar_cell
                      :if={not archiving?}
                      id={"project-#{project.id}-monitor"}
                      navigate={
                        ~p"/dashboard/orgs/#{@org.public_token}/projects/#{project.public_token}/monitor"
                      }
                      signals={signals}
                      state={signals && signals.monitor.state}
                      tone={signals && monitor_status_tone(signals)}
                      label={signals && index_monitor_signal(signals)}
                      pillar="Monitor"
                    />
                    <.pillar_cell
                      :if={not archiving?}
                      id={"project-#{project.id}-observe"}
                      navigate={
                        ~p"/dashboard/orgs/#{@org.public_token}/projects/#{project.public_token}/observe"
                      }
                      signals={signals}
                      state={signals && signals.observe.state}
                      tone={signals && observe_status_tone(signals)}
                      label={signals && index_observe_signal(signals)}
                      pillar="Observe"
                    />
                    <.pillar_cell
                      :if={not archiving?}
                      id={"project-#{project.id}-measure"}
                      navigate={
                        ~p"/dashboard/orgs/#{@org.public_token}/projects/#{project.public_token}/measure"
                      }
                      signals={signals}
                      state={signals && signals.measure.state}
                      tone={signals && measure_status_tone(signals)}
                      label={signals && index_measure_signal(signals)}
                      pillar="Measure"
                    />
                    <td
                      class={[
                        "block px-4 py-3 sm:table-cell",
                        archiving? || "text-right"
                      ]}
                      colspan={archiving? && "5"}
                    >
                      <.destructive_confirm
                        :if={can_manage?(@scope)}
                        id={"archive-project-#{project.id}"}
                        mode={:typed}
                        match={project.name}
                        confirming={archiving?}
                        consequence="This project stops accepting data immediately and is permanently deleted after a 14-day grace period."
                        trigger_label="Archive"
                        confirm_label="Confirm archive"
                        trigger_event="confirm_archive"
                        cancel_event="cancel_archive"
                        confirm_event="archive"
                        input_event="archive_input"
                        input_value={@confirm_archive_text}
                        value_name="id"
                        value={project.id}
                        focus_fallback_id="projects-summary"
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.data_panel>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".ProjectsArchiveFocus">
            export default {
              mounted() {
                this.focusId = this.el.dataset.archiveFocusId || null
              },
              updated() {
                const previousId = this.focusId
                const nextId = this.el.dataset.archiveFocusId || null
                this.focusId = nextId

                if (previousId && !nextId) this.restoreFocus(previousId)
              },
              restoreFocus(id) {
                window.requestAnimationFrame(() => {
                  const trigger = id && document.getElementById(id)
                  const fallbackId = this.el.dataset.archiveFocusFallbackId
                  const fallback = fallbackId && document.getElementById(fallbackId)
                  const destination = trigger || fallback || document.getElementById("main-content")

                  if (destination && typeof destination.focus === "function") {
                    destination.focus({preventScroll: true})
                  }
                })
              }
            }
          </script>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # One project's cell for one pillar: the pillar's current signal, and a link
  # into that pillar. Local to this screen on purpose — it is a row-shape
  # one-off, not a shared primitive (docs/DESIGN-SYSTEM.md §7).
  #
  # `signals` is nil until `load/1` has computed them, which is the same
  # window the skeleton covers; the cell renders empty rather than inventing
  # a zero.
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :signals, :any, required: true
  attr :state, :atom, default: nil
  attr :tone, :any, required: true
  attr :label, :any, required: true
  attr :pillar, :string, required: true
  attr :class, :any, default: nil

  defp pillar_cell(assigns) do
    ~H"""
    <td
      class={["block p-0 align-middle sm:table-cell", @class]}
      data-state={@state}
    >
      <.link
        :if={@signals}
        navigate={@navigate}
        id={@id}
        data-state={@state}
        class="flex min-h-target-min items-center justify-between gap-3 px-4 py-3 text-text-secondary hover:bg-interactive-tint hover:text-text-primary"
      >
        <span class="text-eyebrow uppercase text-text-tertiary sm:hidden">
          {@pillar}
        </span>
        <.status_dot tone={@tone} label={@label} />
      </.link>
      <span :if={is_nil(@signals)} class="block min-h-target-min px-4 py-3"></span>
    </td>
    """
  end

  attr :checklist, :list, required: true
  attr :org, :any, required: true
  attr :project, :any, default: nil
  attr :scope, :any, required: true
  attr :form, :any, required: true
  attr :show_new_project, :boolean, required: true
  attr :just_completed?, :boolean, default: false

  defp onboarding_panel(assigns) do
    assigns =
      assigns
      |> assign(:complete?, AlplusWeb.Onboarding.complete?(assigns.checklist))
      |> assign(:done, AlplusWeb.Onboarding.done_count(assigns.checklist))
      |> assign(:monitor_path, project_monitor_path(assigns.org, assigns.project))
      |> assign(:project_path, project_path(assigns.org, assigns.project))
      |> assign(:project_name, project_name(assigns.project))

    ~H"""
    <.section_card
      :if={not @complete?}
      id="onboarding-checklist"
      title="Get to first value"
      description={"#{@done} of #{length(@checklist)} steps done. Usually under five minutes."}
    >
      <ul class="divide-y divide-border-subtle">
        <.checklist_item
          :for={step <- @checklist}
          id={"onboarding-step-#{step.key}"}
          state={step.state}
          title={step.title}
          description={step.description}
        >
          <.form
            :if={step.key == :project and @show_new_project}
            for={@form}
            id="first-project-form"
            phx-change="validate"
            phx-submit="save"
            class="max-w-sm"
          >
            <input type="hidden" name="project[org_id]" id="first-project-org-id" value={@org.id} />
            <.input
              field={@form[:name]}
              type="text"
              label="Project name"
              id="first-project-name"
              required
            />
            <.button id="create-first-project-submit" variant="primary" phx-disable-with="Creating...">
              Create project
            </.button>
          </.form>
          <.button
            :if={step.key == :project and not @show_new_project and can_manage?(@scope)}
            id="checklist-create-project"
            variant="primary"
            phx-click="toggle_new_project"
          >
            Create a project
          </.button>
          <.permission_notice
            :if={step.key == :project and not @show_new_project and not can_manage?(@scope)}
            id="onboarding-no-permission"
            message="Ask an organization owner or admin to create the first project."
          />
          <%!-- Name the project the action enters. The checklist can show
                while a project already exists, so an unlabelled "Start with
                Monitor" would silently pick one project; stating "in
                <project>" keeps the destination explicit. Monitor leads
                because it reaches first value with no code; "Open <project>"
                routes to the project hub for Measure and Observe. --%>
          <div
            :if={step.key == :integrate and not is_nil(@project) and can_manage?(@scope)}
            class="flex flex-wrap items-center gap-3"
          >
            <.button
              navigate={@monitor_path}
              variant="primary"
              id="checklist-setup-monitor"
            >
              Set up Monitor
            </.button>
            <span class="text-body text-text-secondary">
              A website check in <strong>{@project_name}</strong>. Just a URL, no code.
            </span>
            <.link
              navigate={@project_path}
              class="text-body text-text-secondary underline hover:text-text-primary"
            >
              or open {@project_name}
            </.link>
          </div>
          <.permission_notice
            :if={step.key == :integrate and not is_nil(@project) and not can_manage?(@scope)}
            id="onboarding-no-permission"
            message="Ask an organization owner or admin to finish the first tool setup."
          />
        </.checklist_item>
      </ul>
    </.section_card>

    <%!-- The completion moment (research: "celebrate small, not big" — a
          tick and a color pulse, no modal, no confetti). This block is
          absent from the DOM until the checklist actually completes, so
          `phx-mounted` fires exactly once, the moment it first appears —
          never again on a later page load, when it renders the calmer,
          already-mounted state below instead. --%>
    <.alert
      :if={@complete? and @just_completed?}
      id="onboarding-just-completed"
      phx-mounted={
        JS.show(
          transition:
            {"transition-[opacity,transform] duration-productive ease-productive",
             "opacity-0 translate-y-1", "opacity-100 translate-y-0"}
        )
      }
      kind="success"
      title="You're live."
      message="PostDeploy is receiving real data from this org."
    />
    """
  end

  @impl true
  def handle_event("retry_load", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:load_failed?, false)

    {:noreply, load(socket)}
  end

  def handle_event("toggle_new_project", _params, socket) do
    {:noreply, assign(socket, :show_new_project, not socket.assigns.show_new_project)}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    form = socket.assigns.form |> Form.validate(params, errors: false) |> to_form()
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"project" => params}, socket) do
    if can_manage?(socket.assigns.scope) do
      case Form.submit(socket.assigns.form, params: params) do
        {:ok, project} ->
          path =
            socket.assigns.handoff_return_to ||
              ~p"/dashboard/orgs/#{socket.assigns.org.public_token}/projects/#{project.public_token}/connect"

          {:noreply, push_navigate(socket, to: path)}

        {:error, form} ->
          {:noreply, assign(socket, :form, to_form(form))}
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot create a project in this org.")}
    end
  end

  # Streamed rows only re-render on an explicit `stream_insert` (never on a
  # plain assign change), even when the row's template reads an assign like
  # `@confirm_archive_id` — so every handler below that toggles the
  # confirm-archive UI for one row re-inserts that row to force it to
  # re-render (FRAMEWORK-RULES.md, LiveView streams).
  def handle_event("confirm_archive", %{"id" => id}, socket) do
    if can_manage?(socket.assigns.scope) do
      case Ash.get(Project, id, actor: socket.assigns.scope) do
        {:ok, project} ->
          {:noreply,
           socket
           |> assign(:confirm_archive_id, project.id)
           |> assign(:confirm_archive_text, "")
           |> stream_insert(:projects, project)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_archive", %{"id" => id}, socket) do
    socket =
      socket
      |> assign(:confirm_archive_id, nil)
      |> assign(:confirm_archive_text, "")

    socket =
      case Ash.get(Project, id, actor: socket.assigns.scope) do
        {:ok, project} -> stream_insert(socket, :projects, project)
        {:error, _} -> socket
      end

    {:noreply, socket}
  end

  def handle_event("archive_input", %{"id" => id, "confirm_text" => text}, socket) do
    socket = assign(socket, :confirm_archive_text, text)

    socket =
      case Ash.get(Project, id, actor: socket.assigns.scope) do
        {:ok, project} -> stream_insert(socket, :projects, project)
        {:error, _} -> socket
      end

    {:noreply, socket}
  end

  def handle_event("archive", %{"id" => id, "confirm_text" => text}, socket) do
    scope = socket.assigns.scope

    with true <- can_manage?(scope),
         {:ok, project} <- Ash.get(Project, id, actor: scope),
         true <- text == project.name,
         :ok <- Ash.destroy(project, action: :archive, actor: scope) do
      {:noreply,
       socket
       |> stream_delete(:projects, project)
       |> assign(:confirm_archive_id, nil)
       |> assign(:confirm_archive_text, "")
       |> refresh_checklist()
       |> put_flash(:info, "Project archived.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not archive that project.")}
    end
  end

  # ---- Index signals --------------------------------------------------------

  defp index_monitor_signal(%{monitors: %{total: nil}}), do: "Unavailable"
  defp index_monitor_signal(%{monitors: %{total: 0}}), do: "No checks yet"

  defp index_monitor_signal(%{monitors: %{down: down}}) when down > 0,
    do: "#{down} down"

  defp index_monitor_signal(%{uptime: nil, monitor: %{trend: %{state: :unavailable}}}),
    do: "Unavailable"

  defp index_monitor_signal(%{uptime: nil}), do: "Awaiting checks"

  defp index_monitor_signal(%{uptime: uptime}),
    do: "#{AlplusWeb.ProjectSignals.uptime_label(uptime)} up"

  defp index_observe_signal(%{issues_open: nil}), do: "Unavailable"
  defp index_observe_signal(%{issues_open: 0}), do: "No open issues"
  defp index_observe_signal(%{issues_open: 1}), do: "1 open issue"
  defp index_observe_signal(%{issues_open: n}), do: "#{n} open issues"

  defp index_measure_signal(%{measure: %{state: :unavailable}}), do: "Unavailable"
  defp index_measure_signal(%{measure_installed?: false}), do: "No analytics yet"
  defp index_measure_signal(%{pageviews: nil}), do: "No traffic yet"

  defp index_measure_signal(%{pageviews: pageviews}),
    do: "#{AlplusWeb.Marketing.PackagePresenter.thousands(pageviews)} views, 7d"

  # ---- Org health summary ---------------------------------------------------

  # The org-wide answer to "is anything broken across my projects" —
  # `summary_card/1`'s headline, built from `@project_signals` (already
  # loaded per project by `load/1`; never re-queried here). Worst-first: a
  # monitor down and an open issue are both worth naming in one sentence,
  # "2 monitors down, 1 open issue", rather than picking just one.
  defp org_health_headline(project_signals) do
    totals = org_signal_totals(project_signals)
    org_health_headline_for_totals(totals)
  end

  defp org_health_headline_for_totals(%{down: 0, issues: 0, up: up, unavailable?: false})
       when up > 0,
       do: "Everything is up"

  defp org_health_headline_for_totals(%{down: 0, issues: 0, unavailable?: true}),
    do: "Some telemetry is unavailable"

  defp org_health_headline_for_totals(%{down: 0, issues: 0}),
    do: "Waiting for the first check"

  defp org_health_headline_for_totals(%{down: down, issues: issues, unavailable?: unavailable?}) do
    [
      monitor_down_phrase(down),
      issue_open_phrase(issues),
      unavailable? && "Some telemetry is unavailable"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp monitor_down_phrase(0), do: nil
  defp monitor_down_phrase(1), do: "1 monitor down"
  defp monitor_down_phrase(n), do: "#{n} monitors down"

  defp issue_open_phrase(0), do: nil
  defp issue_open_phrase(1), do: "1 open issue"
  defp issue_open_phrase(n), do: "#{n} open issues"

  defp projects_subtitle(1), do: "Across 1 project"
  defp projects_subtitle(n), do: "Across #{n} projects"

  # `summary_card/1`'s three stat tiles: monitors down and open issues carry
  # the error ink only when actually nonzero — a real zero is never colored
  # as if it were bad.
  defp org_health_stats(project_signals) do
    totals = org_signal_totals(project_signals)

    [
      %{
        id: "stat-monitors-down",
        label: "Monitors down",
        value: if(totals.monitors_unavailable?, do: "Unavailable", else: totals.down),
        class: totals.down > 0 && "text-status-error-ink"
      },
      %{
        id: "stat-issues-open",
        label: "Open issues",
        value: if(totals.issues_unavailable?, do: "Unavailable", else: totals.issues),
        class: totals.issues > 0 && "text-status-error-ink"
      },
      %{
        id: "stat-pageviews",
        label: "Pageviews, 7d",
        value: measure_total_label(totals),
        class: nil
      }
    ]
  end

  defp measure_total_label(%{measure_state: :unavailable}), do: "Unavailable"

  defp measure_total_label(%{measure_state: :empty, measure_sources?: false}),
    do: "No analytics yet"

  defp measure_total_label(%{measure_state: :empty, measure_sources?: true}), do: "No traffic yet"

  defp measure_total_label(%{measure_state: :available, pageviews: pageviews}),
    do: AlplusWeb.Marketing.PackagePresenter.thousands(pageviews)

  defp org_signal_totals(project_signals) do
    signals = Map.values(project_signals)

    monitors_unavailable? = Enum.any?(signals, &get_in(&1, [:monitor, :unavailable?]))
    issues_unavailable? = Enum.any?(signals, &get_in(&1, [:observe, :unavailable?]))
    pageviews_unavailable? = Enum.any?(signals, &get_in(&1, [:measure, :unavailable?]))

    measure_states = Enum.map(signals, &get_in(&1, [:measure, :state]))

    measure_state =
      cond do
        :unavailable in measure_states -> :unavailable
        :available in measure_states -> :available
        true -> :empty
      end

    measure_sources? = Enum.any?(signals, &get_in(&1, [:measure, :installed?]))

    %{
      down: signals |> Enum.map(& &1.monitors.down) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      up: signals |> Enum.map(& &1.monitors.up) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      issues: signals |> Enum.map(& &1.issues_open) |> Enum.filter(&is_integer/1) |> Enum.sum(),
      pageviews:
        if(measure_state == :available,
          do: signals |> Enum.map(& &1.pageviews) |> Enum.filter(&is_integer/1) |> Enum.sum(),
          else: nil
        ),
      monitors_unavailable?: monitors_unavailable?,
      issues_unavailable?: issues_unavailable?,
      pageviews_unavailable?: pageviews_unavailable?,
      measure_state: measure_state,
      measure_sources?: measure_sources?,
      measure_no_series?: measure_state == :empty and measure_sources?,
      unavailable?: monitors_unavailable? or issues_unavailable? or pageviews_unavailable?
    }
  end

  # The `<.status_dot>` tone for each pillar column. The dot's tone always
  # describes health, never the product pillar.
  defp monitor_status_tone(%{monitors: %{total: 0}}), do: "neutral"
  defp monitor_status_tone(%{monitors: %{total: nil}}), do: "warning"
  defp monitor_status_tone(%{monitors: %{down: down}}) when down > 0, do: "error"
  defp monitor_status_tone(%{uptime: nil}), do: "neutral"
  defp monitor_status_tone(_signals), do: "success"

  defp observe_status_tone(%{issues_open: nil}), do: "warning"
  defp observe_status_tone(%{issues_open: 0}), do: "success"
  defp observe_status_tone(_signals), do: "error"

  defp measure_status_tone(%{measure: %{state: :unavailable}}), do: "warning"
  defp measure_status_tone(%{measure_installed?: false}), do: "neutral"
  defp measure_status_tone(%{pageviews: nil}), do: "neutral"
  defp measure_status_tone(_signals), do: "success"

  defp load(socket) do
    try do
      socket
      |> do_load()
      |> schedule_onboarding_refresh()
    rescue
      exception ->
        Logger.error(Exception.format(:error, exception, __STACKTRACE__))

        socket
        |> assign(:loading, false)
        |> assign(:load_failed?, true)
    end
  end

  defp do_load(socket) do
    scope = socket.assigns.scope

    projects =
      Alplus.Projects.list_projects_for_org!(scope.org_id,
        actor: scope,
        query: Ash.Query.sort(Project, inserted_at: :desc)
      )

    connected_project_ids =
      Alplus.Audit.agent_connected_project_ids(scope.org_id, Enum.map(projects, & &1.id))

    # Signals render inside streamed rows, so they must be assigned BEFORE
    # the stream insert: streamed rows only re-render on an explicit
    # stream_insert, never on a later assign change. The bounded batch loader
    # keeps resource reads fixed while its actions still enforce this org and
    # the explicit project-id set.
    signals = AlplusWeb.ProjectSignals.load_many(projects, scope)

    socket
    |> assign(:project_signals, signals)
    |> assign(:connected_project_ids, connected_project_ids)
    |> stream(:projects, projects, reset: true)
    |> assign(:projects, projects)
    |> assign(:projects_empty?, projects == [])
    |> assign(:onboarding?, projects == [])
    |> assign_project_capacity(length(projects))
    # Auto-reveal the create form for an empty org (owner/admin), so the first
    # project is one field away; a member sees the empty state instead.
    |> assign(:show_new_project, projects == [] and can_manage?(scope))
    # First load, not a live transition: never treated as "just completed"
    # (`refresh_checklist/1` is what compares before/after for that).
    |> assign(:checklist, AlplusWeb.Onboarding.checklist(scope))
    |> subscribe_to_projects(projects)
    |> assign(:load_failed?, false)
    |> assign(:loading, false)
  end

  # Live-updating (onboarding overhaul §4): subscribes to every current
  # project's Monitor/Observe topic so a check result or an error landing
  # elsewhere flips this page's checklist without a reload. Only ever adds
  # subscriptions — projects are rarely archived mid-session, and an extra
  # subscription to an archived project's topic is harmless (nothing
  # broadcasts to it again).
  defp subscribe_to_projects(socket, projects) do
    if connected?(socket) do
      already = socket.assigns.subscribed_topics

      new_topics =
        projects
        |> Enum.flat_map(&["monitor:#{&1.id}", "observe:#{&1.id}"])
        |> MapSet.new()
        |> MapSet.difference(already)

      Enum.each(new_topics, &Phoenix.PubSub.subscribe(Alplus.PubSub, &1))

      assign(socket, :subscribed_topics, MapSet.union(already, new_topics))
    else
      socket
    end
  end

  # Compares checklist completion before and after recomputing, so the
  # "You're live" moment (`onboarding_panel/1`) renders exactly once, on
  # the transition — never on a plain page load (`load/1` above assigns
  # the checklist directly, without this comparison).
  # PubSub identifies the changed project. Refresh only that row's read model,
  # then reinsert the row because streamed rows do not observe plain assigns.
  defp refresh_project_signal(socket, project_id) when is_binary(project_id) do
    case Enum.find(socket.assigns.projects, &(&1.id == project_id)) do
      nil ->
        socket

      project ->
        signal = AlplusWeb.ProjectSignals.load(project, socket.assigns.scope)

        socket
        |> update(:project_signals, &Map.put(&1, project.id, signal))
        |> stream_insert(:projects, project)
    end
  end

  defp refresh_project_signal(socket, _project_id), do: socket

  defp refresh_checklist(socket) do
    try do
      scope = socket.assigns.scope
      was_complete? = AlplusWeb.Onboarding.complete?(socket.assigns.checklist)
      projects = list_projects(scope)
      checklist = AlplusWeb.Onboarding.checklist(scope)

      connected_project_ids =
        Alplus.Audit.agent_connected_project_ids(scope.org_id, Enum.map(projects, & &1.id))

      now_complete? = AlplusWeb.Onboarding.complete?(checklist)

      socket =
        socket
        |> sync_project_snapshot(projects)
        |> assign(:checklist, checklist)
        |> assign(:connected_project_ids, connected_project_ids)
        |> assign(:just_completed?, now_complete? and not was_complete?)
        |> assign(:load_failed?, false)

      if now_complete?, do: stop_onboarding_refresh(socket), else: socket
    rescue
      exception ->
        Logger.error(Exception.format(:error, exception, __STACKTRACE__))
        assign(socket, :load_failed?, true)
    end
  end

  defp list_projects(scope) do
    Alplus.Projects.list_projects_for_org!(scope.org_id,
      actor: scope,
      query: Ash.Query.sort(Project, inserted_at: :desc)
    )
  end

  defp project_destination(org, project, connected_project_ids) do
    if MapSet.member?(connected_project_ids, project.id) do
      ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}"
    else
      ~p"/dashboard/orgs/#{org.public_token}/projects/#{project.public_token}/connect"
    end
  end

  defp sync_project_snapshot(socket, projects) do
    previous_ids = Enum.map(socket.assigns.projects, & &1.id)
    next_ids = Enum.map(projects, & &1.id)

    if previous_ids == next_ids do
      socket
    else
      signals = AlplusWeb.ProjectSignals.load_many(projects, socket.assigns.scope)

      socket
      |> assign(:project_signals, signals)
      |> stream(:projects, projects, reset: true)
      |> assign(:projects, projects)
      |> assign(:projects_empty?, projects == [])
      |> assign(:onboarding?, projects == [])
      |> assign_project_capacity(length(projects))
      |> assign(:show_new_project, projects == [] and can_manage?(socket.assigns.scope))
      |> subscribe_to_projects(projects)
    end
  end

  defp schedule_onboarding_refresh(socket) do
    if connected?(socket) and
         not AlplusWeb.Onboarding.complete?(socket.assigns.checklist) and
         is_nil(socket.assigns[:onboarding_refresh_timer]) do
      timer = Process.send_after(self(), :refresh_onboarding, @onboarding_refresh_interval)
      assign(socket, :onboarding_refresh_timer, timer)
    else
      socket
    end
  end

  defp stop_onboarding_refresh(socket) do
    if timer = socket.assigns[:onboarding_refresh_timer] do
      Process.cancel_timer(timer)
    end

    assign(socket, :onboarding_refresh_timer, nil)
  end

  @impl true
  def terminate(_reason, socket) do
    if timer = socket.assigns[:onboarding_refresh_timer] do
      Process.cancel_timer(timer)
    end

    :ok
  end

  defp new_project_form(scope) do
    Project
    |> Form.for_create(:create, domain: Alplus.Projects, actor: scope, as: "project")
    |> to_form()
  end

  # The package caps the active project count (Access already rejects
  # the create; this only hides the control so a member never taps a button
  # that cannot succeed). When access cannot be resolved at all, the org is
  # inactive: no limit is invented, adding is blocked, and a
  # read-only notice explains why (issue #61).
  defp assign_project_capacity(socket, project_count) do
    case project_limit(socket.assigns.scope.org_id) do
      :inactive ->
        socket
        |> assign(:project_limit, nil)
        |> assign(:at_project_limit?, false)
        |> assign(:can_add_project?, false)
        |> assign(:access_active?, false)

      limit ->
        at_limit? = project_count >= limit

        socket
        |> assign(:project_limit, limit)
        |> assign(:at_project_limit?, at_limit?)
        |> assign(:can_add_project?, can_manage?(socket.assigns.scope) and not at_limit?)
        |> assign(:access_active?, true)
    end
  end

  defp project_limit(org_id) do
    case Access.check(org_id) do
      {:ok, _access} -> Package.limit(:projects)
      {:error, _} -> :inactive
    end
  end

  defp project_monitor_path(%{public_token: org_token}, %{public_token: project_token}),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/monitor"

  defp project_monitor_path(_org, _project), do: nil

  defp project_path(%{public_token: org_token}, %{public_token: project_token}),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}"

  defp project_path(_org, _project), do: nil

  defp archive_focus_id(nil), do: nil
  defp archive_focus_id(id), do: "archive-project-#{id}-trigger"

  defp project_name(%{name: name}) when is_binary(name), do: name
  defp project_name(_project), do: "this project"
end
