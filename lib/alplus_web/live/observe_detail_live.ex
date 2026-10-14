defmodule AlplusWeb.ObserveDetailLive do
  @moduledoc """
  Analysis for one project-scoped Observe Source: source health, error trends,
  issues, releases, occurrences, and deployment evidence.

  `source_id` resolves under the project public token in the route. A
  Source outside that project (wrong project, wrong org, unknown id, or not
  an `:observe` Source) never distinguishes itself from a Source that does
  not exist — both raise `AlplusWeb.NotFoundError` (ARCHITECTURE.md §4: 404,
  never 403).

  "Per Source" means scoped by `source_id` plus org/project (issue #46
  follow-up): the issues and releases lists here filter to `source.id`, not
  `source.environment`, so a sibling Source in the same project -- even one
  sharing this Source's environment, such as a revoked predecessor -- never
  leaks into this page.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DeploymentCorrelationComponents
  import AlplusWeb.ObserveActivityComponents
  import AlplusWeb.Format
  import AlplusWeb.Observe.Display

  alias Alplus.Observe.{
    Dashboard,
    DeploymentCorrelation,
    IssueListing,
    ReleaseHealth,
    ReleaseListing,
    SessionHealth
  }

  alias Alplus.Sources.Source

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @windows Dashboard.windows()
  @statuses ~w(open resolved ignored all)
  @levels ~w(all fatal error warning info)
  # A hard per-page cap keeps the table query bounded. Pagination exposes the
  # remainder instead of silently hiding it behind one truncated page.
  @issue_limit 50
  @max_search_bytes 200
  @release_limit ReleaseHealth.max_releases()

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Observe", active: :observe) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       socket
       |> assign(:projects, [project])
       |> assign(:project, project)
       |> assign(:source, nil)
       |> assign(:window, "24h")
       |> assign(:windows, @windows)
       |> assign(:status_filter, "open")
       |> assign(:statuses, @statuses)
       |> assign(:level_filter, "all")
       |> assign(:levels, @levels)
       |> assign(:search, "")
       |> assign(:tag_filter, "")
       |> assign(:issue_limit, @issue_limit)
       |> assign(:issue_limit_reached?, false)
       |> assign(:issue_page, 1)
       |> assign(:issue_total_pages, 1)
       |> assign(:summary, %{trend: [], open_issues: 0, latest_release: nil})
       |> assign(:issues, [])
       |> assign(:releases, [])
       |> assign(:deployment_correlation, nil)
       |> assign(:release_limit, @release_limit)
       |> assign(:release_page, 1)
       |> assign(:release_total_pages, 1)
       |> assign(:release_limit_reached?, false)
       |> assign(:unattributed_release_count, 0)
       |> stream(:issues, [])}
    end
  end

  @impl true
  def handle_params(%{"source_id" => source_id} = params, _uri, socket) do
    project = socket.assigns.project

    if is_nil(project), do: raise(AlplusWeb.NotFoundError)

    socket = assign(socket, :project, project)
    project_scope = project_scope(socket, project)

    case Ash.get(Source, source_id, actor: project_scope) do
      {:ok, %Source{type: :observe} = source} ->
        {:noreply,
         socket
         |> assign(:source, source)
         |> assign(:window, valid_window(params["window"]))
         |> assign(:status_filter, valid_status(params["status"]))
         |> assign(:level_filter, valid_level(params["level"]))
         |> assign(:search, valid_search(params["q"]))
         |> assign(:tag_filter, valid_tag(params["tag"]))
         |> assign(:issue_page, valid_page(params["page"]))
         |> assign(:release_page, valid_page(params["release_page"]))
         |> assign(:page_title, source.name)
         |> load_detail_data()}

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("retry_observe_detail", _params, socket) do
    {:noreply, load_detail_data(socket)}
  end

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: detail_path(socket, %{"window" => valid_window(window)}))}
  end

  # One form, one event: search, level, and status patch the URL together.
  # A partial payload (LiveViewTest sends only the changed control) falls
  # back to the current assigns for the untouched controls.
  def handle_event("filter_issues", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         detail_path(socket, %{
           "q" => valid_search(Map.get(params, "q", socket.assigns.search)),
           "level" => valid_level(Map.get(params, "level", socket.assigns.level_filter)),
           "status" => valid_status(Map.get(params, "status", socket.assigns.status_filter)),
           "tag" => Map.get(params, "tag", socket.assigns.tag_filter),
           "page" => 1
         })
     )}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:issue_pagination_path, issue_pagination_path(assigns))
      |> assign(:release_pagination_path, release_pagination_path(assigns))

    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:observe}
      nav_project={@project}
      nav_projects={@nav_projects}
      project_scoped={false}
      window={@source && @window}
    >
      <.console_page id="observe-detail-page">
        <.error_boundary :if={@load_failed?} id="observe-detail-error" retry="retry_observe_detail">
          Could not load this Observe Source.
        </.error_boundary>

        <div :if={not @load_failed? and @source} class="flex flex-col gap-4">
          <h1 class="sr-only">Observe detail for {@source.name}</h1>

          <section
            id={"observe-panel-#{@source.id}"}
            class="overflow-hidden rounded-structural border border-border-default bg-surface-raised"
            aria-label={@source.name}
          >
            <div class="flex flex-wrap items-start justify-between gap-4 border-b border-border-default px-4 py-4">
              <div class="min-w-0">
                <p id="observe-detail-name" class="text-heading-02 font-semibold text-text-primary">
                  {@source.name}
                </p>
                <p class="mt-1 text-body text-text-secondary">
                  Environment: <span class="font-mono text-data">{@source.environment}</span>
                </p>
              </div>
              <div class="min-w-0 lg:text-right">
                <span id="observe-detail-source-status">
                  <.status_badge
                    tone={source_status_tone(@source.status)}
                    label={source_status_label(@source.status)}
                  />
                </span>
                <%!-- The one answer: how much is open here, and what shipped
                      last. Nothing else on the screen is drawn at this weight. --%>
                <p
                  id="observe-detail-answer"
                  class="mt-1.5 text-heading-01 font-semibold text-text-primary"
                >
                  {source_answer(@summary)}
                </p>
              </div>
            </div>

            <div class="space-y-4 p-4">
              <p
                :if={@source.status == :revoked}
                id="observe-detail-source-revoked"
                class="rounded-structural border border-status-late-border bg-status-late-bg p-4 text-body text-status-late-ink"
              >
                This source is revoked. Historical release health remains available, but new data is not accepted.
              </p>

              <%!-- The credential prefix identifies which key a source uses.
                    It is a diagnostic detail, so it sits behind a disclosure
                    rather than leading the panel. --%>
              <details class="text-body text-text-secondary">
                <summary class="inline-flex min-h-target-min cursor-pointer items-center text-label font-medium text-text-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
                  Credential
                </summary>
                <p class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
                  <span>Key prefix</span>
                  <code
                    id="observe-detail-secret-prefix"
                    class="font-mono text-data text-text-primary"
                  >
                    {@source.secret_prefix || "Not available"}
                  </code>
                </p>
              </details>
            </div>
          </section>

          <%!-- One panel, like every other section on every other console
                screen. These charts carry no border of their own, so before
                this they sat naked on the page while the Source header and the
                Issues list beside them were framed. --%>
          <.section_card
            id="observe-detail-release-health"
            title="Release health"
            description="Error trend and deployment evidence for this Source, measured in UTC."
          >
            <div class={["flex flex-col gap-4", @source.status == :revoked && "opacity-75"]}>
              <.observe_error_chart source={@source} summary={@summary} window={@window} />

              <details
                :if={Map.get(@summary, :release_markers, []) != []}
                id="observe-detail-release-markers"
                class="border-t border-border-subtle pt-3"
              >
                <summary class="cursor-pointer py-1 text-data text-text-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus">
                  Deploy markers in this window
                </summary>
                <ul class="mt-2 flex flex-wrap gap-3 text-data text-text-secondary">
                  <li
                    :for={marker <- Map.get(@summary, :release_markers, [])}
                    id={"observe-detail-release-marker-#{marker.id}"}
                  >
                    <span class="text-interactive-strong">{marker.version}</span>
                    <time datetime={DateTime.to_iso8601(marker.deployed_at)}>
                      {format_utc(marker.deployed_at)}
                    </time>
                  </li>
                </ul>
              </details>
            </div>
          </.section_card>

          <.deployment_correlation_panel
            :if={@deployment_correlation}
            comparison={@deployment_correlation}
          />

          <.section_card id="observe-detail-issues" title="Issues">
            <:actions>
              <form
                id="observe-detail-issue-filters"
                phx-change="filter_issues"
                phx-submit="filter_issues"
                class="flex flex-wrap items-center gap-inline"
              >
                <p
                  :if={@tag_filter != ""}
                  id="observe-detail-tag-filter"
                  class="text-data text-text-secondary"
                >
                  Tag {@tag_filter}
                  <.link
                    id="observe-detail-clear-tag"
                    patch={
                      ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/observe/#{@source.id}?#{%{window: @window, status: @status_filter, level: @level_filter, q: @search}}"
                    }
                    class="underline"
                  >
                    Clear
                  </.link>
                </p>
                <label for="observe-detail-issue-search-input" class="sr-only">
                  Search issues
                </label>
                <input
                  id="observe-detail-issue-search-input"
                  type="search"
                  name="q"
                  value={@search}
                  placeholder="Search title or culprit"
                  phx-debounce="300"
                  class="h-control-sm w-full min-w-0 rounded-control border border-border-default bg-surface-raised px-2 text-body text-text-primary sm:w-56"
                />
                <label for="observe-detail-level-filter-select" class="sr-only">
                  Filter by level
                </label>
                <select
                  id="observe-detail-level-filter-select"
                  name="level"
                  class="h-control-sm rounded-control border border-border-default bg-surface-raised px-2 text-body text-text-primary"
                >
                  <option :for={level <- @levels} value={level} selected={@level_filter == level}>
                    {level_option_label(level)}
                  </option>
                </select>
                <label for="observe-detail-status-filter-select" class="sr-only">
                  Filter by status
                </label>
                <select
                  id="observe-detail-status-filter-select"
                  name="status"
                  class="h-control-sm rounded-control border border-border-default bg-surface-raised px-2 text-body text-text-primary"
                >
                  <option
                    :for={status <- @statuses}
                    value={status}
                    selected={@status_filter == status}
                  >
                    {status_option_label(status)}
                  </option>
                </select>
              </form>
            </:actions>

            <p
              :if={@issue_limit_reached?}
              id="observe-detail-issue-limit-note"
              class="mb-3 text-data text-text-secondary"
            >
              Showing up to {@issue_limit} issues per page.
            </p>

            <.empty_state
              :if={@issues_empty?}
              id="observe-detail-issues-empty"
              icon="hero-check-circle"
              title="No issues match this filter"
              description="No matching error evidence is available for this Source."
            />
            <div :if={@issues_empty?} id="observe-detail-agent-empty" class="space-y-3">
              <p id="observe-detail-agent-connection-state" class="text-body text-text-secondary">
                Agent connection state is available from the activation runway. <.link
                  id="observe-detail-agent-repair"
                  navigate={
                    ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"
                  }
                  class="font-medium text-interactive-strong underline"
                >Check or repair the connection</.link>.
              </p>
              <div class="flex items-center gap-2 text-body text-text-secondary">
                <code
                  id="observe-detail-agent-task-text"
                  class="min-w-0 flex-1 break-words font-mono text-data text-text-primary"
                >Inspect this project's current health and recent changes.</code>
                <.copy_button target="observe-detail-agent-task-text" />
              </div>
            </div>

            <div
              :if={not @issues_empty?}
              class="sm:hidden divide-y divide-border-default border-y border-border-default"
            >
              <article :for={issue <- @issues} class="space-y-2 px-3 py-4">
                <div class="flex items-start justify-between gap-3">
                  <.link
                    id={"observe-detail-issue-mobile-#{issue.id}"}
                    navigate={
                      ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/observe/issues/#{issue.id}"
                    }
                    class="min-h-target-min min-w-0 font-medium text-text-primary hover:text-interactive-strong-hover hover:underline"
                  >
                    {issue.title}
                  </.link>
                  <span class="shrink-0 font-mono text-data tabular-nums text-text-primary">
                    {issue.event_count} events
                  </span>
                </div>
                <p class="break-words text-data text-text-tertiary">
                  {issue.culprit || "No cause identified yet."}
                </p>
                <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-data">
                  <div>
                    <dt class="text-text-tertiary">Level</dt>
                    <dd class="mt-0.5">
                      <.status_badge
                        tone={level_tone(issue.level)}
                        label={String.capitalize(issue.level)}
                      />
                    </dd>
                  </div>
                  <div>
                    <dt class="text-text-tertiary">Status</dt>
                    <dd class="mt-0.5">
                      <.status_badge
                        tone={status_tone(issue.status)}
                        label={status_label(issue.status)}
                      />
                    </dd>
                  </div>
                  <div class="col-span-2">
                    <dt class="text-text-tertiary">Last seen</dt>
                    <dd class="mt-0.5 tabular-nums text-text-primary">
                      <time
                        datetime={DateTime.to_iso8601(issue.last_seen_at)}
                        title={format_utc(issue.last_seen_at)}
                      >
                        {relative_time(issue.last_seen_at)}
                      </time>
                    </dd>
                  </div>
                </dl>
              </article>
            </div>

            <div
              :if={not @issues_empty?}
              class="hidden sm:block"
            >
              <.table id="observe-detail-issues-table" rows={@streams.issues}>
                <:col :let={{_id, issue}} label="Level">
                  <.status_badge
                    tone={level_tone(issue.level)}
                    label={String.capitalize(issue.level)}
                  />
                </:col>
                <:col :let={{_id, issue}} label="Issue">
                  <.link
                    id={"observe-detail-issue-title-#{issue.id}"}
                    navigate={
                      ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/observe/issues/#{issue.id}"
                    }
                    class="font-medium text-text-primary hover:underline"
                  >
                    {issue.title}
                  </.link>
                  <p class="mt-0.5 text-data text-text-tertiary">
                    {issue.culprit || "No cause identified yet."}
                  </p>
                </:col>
                <:col :let={{_id, issue}} label="Status">
                  <.status_badge tone={status_tone(issue.status)} label={status_label(issue.status)} />
                </:col>
                <:col :let={{_id, issue}} label="Events">{issue.event_count}</:col>
                <:col :let={{_id, issue}} label="Last seen">
                  <time
                    datetime={DateTime.to_iso8601(issue.last_seen_at)}
                    title={format_utc(issue.last_seen_at)}
                  >
                    {relative_time(issue.last_seen_at)}
                  </time>
                </:col>
              </.table>
            </div>

            <.pagination
              :if={not @issues_empty? and @issue_total_pages > 1}
              id="observe-detail-issues-pagination"
              path={@issue_pagination_path}
              current_page={@issue_page}
              total_pages={@issue_total_pages}
              page_param="page"
              aria_label="Observe issue pages"
            />
          </.section_card>

          <.data_panel
            id="observe-detail-releases"
            title="Releases"
            description="Deployment evidence and session health for this Source."
          >
            <.empty_state
              :if={@releases == []}
              id="observe-detail-releases-empty"
              icon="hero-rocket-launch"
              title="No releases yet"
              description="No release evidence is available for this Source."
            />
            <p
              :if={@releases == []}
              id="observe-detail-releases-agent-repair"
              class="text-body text-text-secondary"
            >
              Check the
              <.link
                navigate={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
                class="font-medium text-interactive-strong underline"
              >agent connection</.link>
              if release evidence is unavailable.
            </p>
            <p
              :if={@release_limit_reached?}
              id="observe-detail-release-limit-note"
              class="mb-4 text-body text-text-secondary"
            >
              Showing the latest {@release_limit} releases. Older release history is not loaded on this page.
            </p>

            <div :if={@releases != []} class="sm:hidden divide-y divide-border-default">
              <article :for={row <- @releases} class="space-y-3 py-4 first:pt-0 last:pb-0">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h3 class="font-mono text-data font-semibold text-text-primary">
                      {row.release.version}
                    </h3>
                    <time
                      class="text-data text-text-secondary"
                      datetime={DateTime.to_iso8601(row.release.released_at)}
                    >
                      {relative_time(row.release.released_at)}
                    </time>
                  </div>
                  <.status_badge
                    tone={comparison_tone(row.health.comparison_state)}
                    label={comparison_label(row.health)}
                  />
                </div>
                <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-data">
                  <div>
                    <dt class="text-text-tertiary">Events</dt>
                    <dd class="tabular-nums text-text-primary">{row.health.event_count}</dd>
                  </div>
                  <div>
                    <dt class="text-text-tertiary">Artifacts</dt>
                    <dd class="text-text-primary">{artifact_label(row.health.artifacts)}</dd>
                  </div>
                  <div>
                    <dt class="text-text-tertiary">Crash-free</dt>
                    <dd class="text-text-primary">
                      {mobile_crash_free_label(row.session_health)}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-text-tertiary">Commit</dt>
                    <dd class="font-mono text-text-primary">
                      {row.release.commit_sha || "Not provided"}
                    </dd>
                  </div>
                </dl>
                <div class="flex flex-wrap gap-x-4 gap-y-2 text-data">
                  <.link
                    :for={issue_id <- row.health.new_issue_ids}
                    navigate={issue_path(@org_token, @project, issue_id)}
                    aria-label={"Open new issue #{issue_id} for release #{row.release.version}"}
                    class="text-interactive-strong hover:underline"
                  >
                    New issue {issue_id}
                  </.link>
                  <.link
                    :for={issue_id <- row.health.resolved_issue_ids}
                    navigate={issue_path(@org_token, @project, issue_id)}
                    aria-label={"Open resolved issue #{issue_id} for release #{row.release.version}"}
                    class="text-interactive-strong hover:underline"
                  >
                    Resolved issue {issue_id}
                  </.link>
                </div>
              </article>
            </div>

            <div :if={@releases != []} class="hidden overflow-x-auto sm:block">
              <.table id="observe-detail-releases-table" rows={@releases}>
                <:col :let={row} label="Version">
                  <span
                    id={"observe-detail-release-version-#{row.release.id}"}
                    class="font-mono text-data"
                  >
                    {row.release.version}
                  </span>
                </:col>
                <:col :let={row} label="Deployed">
                  <time
                    datetime={DateTime.to_iso8601(row.release.released_at)}
                    title={format_utc(row.release.released_at)}
                  >
                    {relative_time(row.release.released_at)}
                  </time>
                </:col>
                <:col :let={row} label="Commit">
                  <code
                    class="font-mono text-data"
                    title={row.release.commit_sha || "Commit not provided"}
                  >
                    {row.release.commit_sha || "Not provided"}
                  </code>
                </:col>
                <:col :let={row} label="Artifacts">
                  <div id={"observe-detail-release-artifacts-#{row.release.id}"}>
                    <.status_badge
                      tone={artifact_tone(row.health.artifacts.state)}
                      label={artifact_label(row.health.artifacts)}
                    />
                    <p class="mt-1 text-data text-text-tertiary">
                      {artifact_count_label(row.health.artifacts)}
                    </p>
                  </div>
                </:col>
                <:col :let={row} label="Events">
                  <span
                    id={"observe-detail-release-events-#{row.release.id}"}
                    class="text-data tabular-nums"
                  >
                    {row.health.event_count}
                  </span>
                </:col>
                <:col :let={row} label="New issues">
                  <span
                    id={"observe-detail-release-new-issues-#{row.release.id}"}
                    class="text-data tabular-nums"
                  >
                    {row.health.new_issues}
                  </span>
                  <ul :if={row.health.new_issue_ids != []} class="mt-1 space-y-1 text-data">
                    <li :for={issue_id <- row.health.new_issue_ids}>
                      <.link
                        id={"observe-detail-release-new-issue-#{row.release.id}-#{issue_id}"}
                        navigate={issue_path(@org_token, @project, issue_id)}
                        aria-label={"Open new issue #{issue_id} for release #{row.release.version}"}
                        class="text-interactive-strong hover:underline"
                      >
                        Open issue
                      </.link>
                    </li>
                  </ul>
                </:col>
                <:col :let={row} label="Resolved issues">
                  <span
                    id={"observe-detail-release-resolved-issues-#{row.release.id}"}
                    class="text-data tabular-nums"
                  >
                    {row.health.resolved_issues}
                  </span>
                  <ul :if={row.health.resolved_issue_ids != []} class="mt-1 space-y-1 text-data">
                    <li :for={issue_id <- row.health.resolved_issue_ids}>
                      <.link
                        id={"observe-detail-release-resolved-issue-#{row.release.id}-#{issue_id}"}
                        navigate={issue_path(@org_token, @project, issue_id)}
                        aria-label={"Open resolved issue #{issue_id} for release #{row.release.version}"}
                        class="text-interactive-strong hover:underline"
                      >
                        Open issue
                      </.link>
                    </li>
                  </ul>
                </:col>
                <:col :let={row} label="Crash-free sessions">
                  <span
                    :if={row.session_health.state == :ready}
                    id={"observe-detail-release-crash-free-#{row.release.id}"}
                  >
                    <.status_badge
                      tone={crash_free_tone(row.session_health.result)}
                      label={format_crash_free_pct(elem(row.session_health.result, 1).crash_free_pct)}
                    />
                    <p class="mt-1 text-data text-text-tertiary">
                      {row.session_health.sessions} sessions
                    </p>
                  </span>
                  <span
                    :if={row.session_health.state == :not_enough_data}
                    id={"observe-detail-release-crash-free-#{row.release.id}"}
                    class="space-y-1"
                  >
                    <.status_badge tone="warning" label="Not enough data" />
                    <p class="text-data text-text-secondary">
                      {row.session_health.sessions} of {row.session_health.minimum_sessions} sessions needed
                    </p>
                  </span>
                  <span
                    :if={row.session_health.state == :unattributed}
                    id={"observe-detail-release-crash-free-#{row.release.id}"}
                    class="space-y-1"
                  >
                    <.status_badge tone="neutral" label="Unavailable" />
                    <p class="text-data text-text-secondary">Source attribution is missing.</p>
                  </span>
                </:col>
                <:col :let={row} label="Comparison">
                  <div id={"observe-detail-release-comparison-#{row.release.id}"}>
                    <.status_badge
                      tone={comparison_tone(row.health.comparison_state)}
                      label={comparison_label(row.health)}
                    />
                    <p
                      :if={row.health.previous_release_version}
                      class="mt-1 text-data text-text-tertiary"
                    >
                      vs {row.health.previous_release_version}
                    </p>
                  </div>
                </:col>
              </.table>
            </div>

            <.pagination
              :if={@release_total_pages > 1}
              id="observe-detail-releases-pagination"
              path={@release_pagination_path}
              current_page={@release_page}
              total_pages={@release_total_pages}
              page_param="release_page"
              aria_label="Observe release pages"
            />
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp load_detail_data(socket) do
    source = socket.assigns.source
    window = socket.assigns.window
    scope = project_scope(socket, socket.assigns.project)

    try do
      overview = Dashboard.overview(source.id, window, scope)
      trend = overview.trend
      open_issues = overview.open_issues
      latest_release = overview.latest_release

      issue_opts = issue_opts(socket, source.id)
      issue_total = IssueListing.count(scope, issue_opts)

      issue_total_pages = IssueListing.total_pages(issue_total, @issue_limit)
      issue_page = min(socket.assigns.issue_page, issue_total_pages)

      issues = IssueListing.list(scope, Keyword.put(issue_opts, :page, issue_page))

      release_total = ReleaseListing.count(scope, source.id)
      release_total_pages = IssueListing.total_pages(release_total, @release_limit)
      release_page = min(socket.assigns.release_page, release_total_pages)

      {releases, release_limit_reached?} =
        ReleaseListing.page(scope, source.id, release_page, @release_limit)

      release_health = ReleaseHealth.summaries(scope, releases)
      session_health = SessionHealth.summaries(scope, releases)
      correlation_release = List.first(releases)

      deployment_correlation =
        case correlation_release &&
               DeploymentCorrelation.correlate(correlation_release, scope,
                 window: window,
                 now: DateTime.utc_now()
               ) do
          {:ok, comparison} -> comparison
          _ -> nil
        end

      releases =
        Enum.map(releases, fn release ->
          health = Map.fetch!(release_health, release.id)
          session = Map.fetch!(session_health, release.id)

          %{
            release: release,
            health: health,
            session_health: session,
            # Kept for callers and tests that consume the old row shape.
            crash_free: session.result
          }
        end)

      socket
      |> assign(
        summary:
          Map.merge(overview, %{
            trend: trend,
            open_issues: open_issues,
            latest_release: latest_release
          }),
        issues: issues,
        issues_empty?: issues == [],
        issue_limit_reached?: issue_total > @issue_limit,
        issue_page: issue_page,
        issue_total_pages: issue_total_pages,
        releases: releases,
        deployment_correlation: deployment_correlation,
        release_page: release_page,
        release_total_pages: release_total_pages,
        release_limit_reached?: release_limit_reached?,
        unattributed_release_count: ReleaseHealth.unattributed_count(scope),
        load_failed?: false
      )
      |> stream(:issues, issues, reset: true)
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        require Logger
        Logger.error("observe detail load failed: #{Exception.message(error)}")
        assign(socket, load_failed?: true)
    end
  end

  # Merged issues are hidden from every list; they surface only on their
  # canonical issue's page. `IssueListing` owns that rule and every filter.
  defp issue_opts(socket, source_id) do
    [
      source_id: source_id,
      status: socket.assigns.status_filter,
      level: socket.assigns.level_filter,
      search: socket.assigns.search,
      tag: socket.assigns.tag_filter,
      page_size: @issue_limit
    ]
  end

  defp project_scope(socket, project), do: %{socket.assigns.scope | project_id: project.id}

  defp detail_path(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "status" => socket.assigns.status_filter,
        "level" => socket.assigns.level_filter,
        "q" => socket.assigns.search,
        "tag" => socket.assigns.tag_filter,
        "page" => socket.assigns.issue_page,
        "release_page" => socket.assigns.release_page
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {key, value} ->
        (key in ["q", "tag"] and value == "") or
          (key in ["page", "release_page"] and value in [1, "1"])
      end)
      |> Map.new()

    ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{socket.assigns.project.public_token}/observe/#{socket.assigns.source.id}?#{params}"
  end

  defp issue_pagination_path(%{source: nil}), do: ""

  defp issue_pagination_path(assigns) do
    params =
      %{
        "window" => assigns.window,
        "status" => assigns.status_filter,
        "level" => assigns.level_filter,
        "q" => assigns.search,
        "tag" => assigns.tag_filter
      }
      |> Enum.reject(fn {key, value} -> key in ["q", "tag"] and value == "" end)
      |> Map.new()

    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/observe/#{assigns.source.id}?#{params}"
  end

  defp release_pagination_path(%{source: nil}), do: ""

  defp release_pagination_path(assigns) do
    params =
      %{
        "window" => assigns.window,
        "status" => assigns.status_filter,
        "level" => assigns.level_filter,
        "q" => assigns.search,
        "tag" => assigns.tag_filter,
        "page" => assigns.issue_page
      }
      |> Enum.reject(fn {key, value} ->
        (key in ["q", "tag"] and value == "") or (key == "page" and value in [1, "1"])
      end)
      |> Map.new()

    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/observe/#{assigns.source.id}?#{params}"
  end

  defp status_tone(:open), do: "neutral"
  defp status_tone(:resolved), do: "success"
  defp status_tone(:ignored), do: "neutral"

  defp source_status_tone(:active), do: "success"
  defp source_status_tone(:revoked), do: "warning"
  defp source_status_tone(_status), do: "neutral"

  defp source_status_label(:active), do: "Active"
  defp source_status_label(:revoked), do: "Revoked"
  defp source_status_label(_status), do: "Unknown"

  # The Source detail answer, built only from values the summary already
  # carries. A Source with no release says so rather than implying one.
  defp source_answer(summary) do
    open = Map.get(summary, :open_issues, 0)

    issues =
      case open do
        0 -> "No open issues"
        1 -> "1 open issue"
        count -> "#{count} open issues"
      end

    case Map.get(summary, :latest_release) do
      nil -> "#{issues}, no release recorded"
      release -> "#{issues}, latest release #{release.version}"
    end
  end

  defp artifact_tone(:ready), do: "success"
  defp artifact_tone(:partial), do: "warning"
  defp artifact_tone(:none), do: "neutral"
  defp artifact_tone(_state), do: "neutral"

  defp artifact_label(%{state: :ready}), do: "Symbolication ready"
  defp artifact_label(%{state: :partial}), do: "Debug files only"
  defp artifact_label(_artifacts), do: "No artifacts"

  defp artifact_count_label(%{count: 0}), do: "No uploaded artifacts"
  defp artifact_count_label(%{count: 1}), do: "1 uploaded artifact"
  defp artifact_count_label(%{count: count}), do: "#{count} uploaded artifacts"
  defp artifact_count_label(_artifacts), do: "Artifact state unavailable"

  defp mobile_crash_free_label(%{state: :ready, result: {:ok, %{crash_free_pct: pct}}}),
    do: format_crash_free_pct(pct)

  defp mobile_crash_free_label(%{
         state: :not_enough_data,
         sessions: sessions,
         minimum_sessions: minimum
       }),
       do: "Not enough data (#{sessions}/#{minimum})"

  defp mobile_crash_free_label(_session_health), do: "Unavailable"

  defp comparison_tone(:improved), do: "success"
  defp comparison_tone(:regressed), do: "error"
  defp comparison_tone(:mixed), do: "warning"
  defp comparison_tone(:unchanged), do: "neutral"
  defp comparison_tone(:not_enough_history), do: "warning"
  defp comparison_tone(:unavailable), do: "neutral"
  defp comparison_tone(_state), do: "neutral"

  defp comparison_label(%{comparison_state: :improved}), do: "Improved"
  defp comparison_label(%{comparison_state: :regressed}), do: "Regressed"
  defp comparison_label(%{comparison_state: :mixed}), do: "Mixed"
  defp comparison_label(%{comparison_state: :unchanged}), do: "No change"
  defp comparison_label(%{comparison_state: :not_enough_history}), do: "Not enough history"
  defp comparison_label(%{comparison_state: :unavailable}), do: "No comparison"
  defp comparison_label(_health), do: "No comparison"

  # Sentry-style bands: >= 99% reads as healthy, >= 95% as a soft warning,
  # below that as an active problem worth the operator's attention.
  defp crash_free_tone({:ok, %{crash_free_pct: pct}}), do: crash_free_tone(pct)
  defp crash_free_tone(pct) when pct >= 99.0, do: "success"
  defp crash_free_tone(pct) when pct >= 95.0, do: "warning"
  defp crash_free_tone(_pct), do: "error"

  defp format_crash_free_pct(pct), do: "#{:erlang.float_to_binary(pct, decimals: 2)}%"

  defp issue_path(org_token, project, issue_id) do
    ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/observe/issues/#{issue_id}"
  end

  defp relative_time(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 2_592_000 -> "#{div(seconds, 86_400)}d ago"
      true -> format_utc(datetime)
    end
  end

  defp valid_window(window) when window in @windows, do: window
  defp valid_window(_window), do: "24h"

  defp valid_status(status) when status in @statuses, do: status
  defp valid_status(_status), do: "open"

  defp valid_level(level) when level in @levels, do: level
  defp valid_level(_level), do: "all"

  defp valid_page(page) when is_integer(page) and page > 0, do: page

  defp valid_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp valid_page(_page), do: 1

  # The labels carry the noun because the select labels are sr-only: a
  # sighted user reads "All levels", not a bare "All" with no context.

  defp valid_search(q) when is_binary(q), do: String.slice(String.trim(q), 0, @max_search_bytes)
  defp valid_search(_q), do: ""

  defp valid_tag(tag) when is_binary(tag) do
    trimmed = String.slice(String.trim(tag), 0, @max_search_bytes)

    case String.split(trimmed, ":", parts: 2) do
      [key, value] when key != "" and value != "" -> key <> ":" <> value
      _ -> ""
    end
  end

  defp valid_tag(_tag), do: ""
end
