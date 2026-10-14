defmodule AlplusWeb.ObserveLive do
  @moduledoc """
  Project-scoped Observe index listing every issue in this project.

  The list hides merged children and links each row to `ObserveIssueLive`.
  Source management stays outside this analysis surface.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.Observe.Display
  import AlplusWeb.Format, only: [window_words: 1]

  alias Alplus.Observe.{Dashboard, IssueListing}
  alias AlplusWeb.AgentConnection
  alias AlplusWeb.Observe.Evidence

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @windows Dashboard.windows()
  @statuses ~w(open resolved ignored all)
  @levels ~w(all fatal error warning info)

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Observe", active: :observe) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       socket
       |> assign(:projects, [project])
       |> assign(:project, project)
       |> assign(:window, "24h")
       |> assign(:windows, @windows)
       |> assign(:observe_topic, nil)
       |> assign(:loading, false)
       |> assign(:load_failed?, false)
       |> assign(:sources, [])
       |> assign(:summaries, %{})
       |> assign(:agent_state, nil)
       |> assign(:issues, [])
       |> assign(:statuses, @statuses)
       |> assign(:levels, @levels)
       |> assign(:status_filter, "open")
       |> assign(:level_filter, "all")
       |> assign(:environment_filter, "all")
       |> assign(:search, "")
       |> assign(:issues_empty?, true)
       |> assign(:resolved_count, 0)
       |> assign(:issue_limit_reached?, false)
       |> assign(:issue_page, 1)
       |> assign(:issue_total_pages, 1)
       |> stream(:issues, [])}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    project = socket.assigns.project

    socket =
      socket
      |> assign(:project, project)
      |> assign(:window, valid_window(params["window"]))
      |> assign(:status_filter, valid_status(params["status"]))
      |> assign(:level_filter, valid_level(params["level"]))
      |> assign(:environment_filter, valid_environment(params["environment"]))
      |> assign(:search, IssueListing.clamp_search(params["q"]))
      |> assign(:issue_page, valid_page(params["page"]))
      |> assign(:loading, not is_nil(project))
      |> subscribe_to_project()

    socket = if project, do: load_grid_data(socket), else: clear_grid_data(socket)

    socket = maybe_activate_observe(socket)

    {:noreply, socket}
  end

  # Fires the "now live" milestone exactly once per project (issue #33): a
  # persisted `observe_activated_at` (not an ephemeral session flag) gates
  # it, so a reload, reconnect, navigation back, or a second session never
  # re-fires it. Only the transition this LiveView itself observes —
  # not-yet-activated with an open issue now present — writes the marker.
  defp maybe_activate_observe(socket) do
    project = socket.assigns.project

    if project && is_nil(project.observe_activated_at) && not socket.assigns.load_failed? &&
         has_open_issues?(socket, project) do
      case Alplus.Projects.activate_observe(project, actor: socket.assigns.scope) do
        {:ok, activated_project} ->
          socket
          |> assign(:project, activated_project)
          |> put_flash(
            :info,
            "Your first error arrived. Observe is now live for this project."
          )

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  @impl true
  def handle_event("retry_observe", _params, socket) do
    {:noreply, if(socket.assigns.project, do: load_grid_data(socket), else: socket)}
  end

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, %{"window" => valid_window(window)}))}
  end

  def handle_event("pick_environment", %{"environment" => environment}, socket) do
    {:noreply,
     push_patch(
       socket,
       to: index_path(socket, %{"environment" => valid_environment(environment)})
     )}
  end

  def handle_event("pick_project", %{"project_id" => project_id}, socket)
      when is_binary(project_id) do
    case Enum.find(socket.assigns.nav_projects, &(&1.id == project_id)) do
      nil -> {:noreply, socket}
      project -> {:noreply, push_navigate(socket, to: observe_project_path(socket, project))}
    end
  end

  def handle_event("pick_project", _params, socket), do: {:noreply, socket}

  def handle_event("filter_issues", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         index_path(socket, %{
           "q" => IssueListing.clamp_search(Map.get(params, "q", socket.assigns.search)),
           "level" => valid_level(Map.get(params, "level", socket.assigns.level_filter)),
           "status" => valid_status(Map.get(params, "status", socket.assigns.status_filter)),
           "environment" =>
             valid_environment(Map.get(params, "environment", socket.assigns.environment_filter)),
           "page" => 1
         })
     )}
  end

  @impl true
  def handle_info(
        {:observe_updated, project_id},
        %{assigns: %{project: %{id: project_id}}} = socket
      ) do
    {:noreply, socket |> load_grid_data() |> maybe_activate_observe()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:issue_pagination_path, issue_pagination_path(assigns))
      |> assign(:issue_reset_path, issue_reset_path(assigns))
      |> assign(:filters_active?, filters_active?(assigns))
      |> assign(:wider_window, wider_window(assigns.window))
      |> assign(:issue_resolved_path, issue_resolved_path(assigns))
      |> assign(
        :issue_wider_window_path,
        assigns.window |> wider_window() |> then(&issue_window_path(assigns, &1))
      )

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
      project_scoped={true}
      projects={@nav_projects}
      project={@project}
      environments={source_environments(@sources)}
      environment={if(@environment_filter == "all", do: nil, else: @environment_filter)}
      page_heading?={false}
      window={@project && @window}
    >
      <.console_page id="observe-page">
        <:title>{issues_answer(@sources, @summaries, @loading)}</:title>
        <div :if={@project && @loading} id="observe-loading" class="mt-2">
          <.skeleton rows={5} />
        </div>

        <.error_boundary
          :if={@project && not @loading && @load_failed?}
          id="observe-error"
          retry="retry_observe"
        >
          Could not load Observe data for this project.
        </.error_boundary>

        <div :if={@project && not @loading && not @load_failed?} class="grid gap-6">
          <.first_run_card
            :if={@sources == []}
            id="observe-sources-empty"
            title="No errors reported yet"
            description="Grouped errors and the events behind them appear here once a source starts reporting."
            state={@agent_state}
            task="Inspect this project's current health and recent changes."
            action_href={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
          />

          <section :if={@sources != []} id="observe-issues" class="min-w-0" aria-label="Issues">
            <form
              id="observe-issues-filters"
              phx-change="filter_issues"
              phx-submit="filter_issues"
              class="mb-3 flex min-w-0 max-w-full flex-wrap items-center gap-2"
            >
              <label for="observe-issues-search-input" class="sr-only">Search issues</label>
              <input
                id="observe-issues-search-input"
                type="search"
                name="q"
                value={@search}
                placeholder="Search issues"
                phx-debounce="300"
                class="h-control-sm min-w-0 w-full rounded-input border border-border-control bg-surface-raised px-3 text-body text-text-primary sm:w-64"
              />
              <input type="hidden" name="environment" value={@environment_filter} />
              <label for="observe-issues-level-filter" class="sr-only">Filter by severity</label>
              <select
                id="observe-issues-level-filter"
                name="level"
                class="h-control-sm min-w-0 flex-1 rounded-input border border-border-control bg-surface-raised px-3 text-body text-text-primary sm:flex-none"
              >
                <option :for={level <- @levels} value={level} selected={@level_filter == level}>
                  {if(level == "all", do: "All severities", else: String.capitalize(level))}
                </option>
              </select>
              <label for="observe-issues-status-filter" class="sr-only">Filter by status</label>
              <select
                id="observe-issues-status-filter"
                name="status"
                class="h-control-sm min-w-0 flex-1 rounded-input border border-border-control bg-surface-raised px-3 text-body text-text-primary sm:flex-none"
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

            <%!-- An empty list has two very different causes, and the screen
                  used to call both of them "No issues match this filter" and
                  offer to clear filters that were never set. A narrowed list
                  says so and offers the reset. An empty default list is the
                  good news the title already stated, so this states the
                  evidence behind it: whether events are arriving at all, which
                  is what separates "nothing is broken" from "nothing is
                  reporting". --%>
            <div
              :if={@issues_empty?}
              id="observe-issues-empty"
              class="border-y border-border-default py-12"
            >
              <div :if={@filters_active?} class="min-w-0">
                <p class="text-body text-text-secondary">No issues match this filter.</p>
                <.link
                  id="observe-issues-clear-filters"
                  patch={@issue_reset_path}
                  class="mt-2 inline-flex min-h-target-min items-center text-body font-medium text-interactive-strong hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  Clear filters
                </.link>
              </div>

              <div :if={not @filters_active?} class="min-w-0">
                <p id="observe-issues-quiet" class="max-w-prose text-body-long text-text-secondary">
                  {quiet_evidence(@summaries, @sources, @window)}
                </p>
                <div class="mt-4 flex flex-wrap items-center gap-x-6 gap-y-2">
                  <.link
                    :if={@resolved_count > 0}
                    id="observe-issues-see-resolved"
                    patch={@issue_resolved_path}
                    class="inline-flex min-h-target-min items-center text-body font-medium text-interactive-strong hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  >
                    See {@resolved_count} resolved {plural(@resolved_count, "issue")}
                  </.link>
                  <.link
                    :if={@wider_window}
                    id="observe-issues-widen-window"
                    patch={@issue_wider_window_path}
                    class="inline-flex min-h-target-min items-center text-body font-medium text-interactive-strong hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  >
                    Look at the last {window_words(@wider_window)}
                  </.link>
                </div>
              </div>
            </div>

            <div :if={not @issues_empty?} class="min-w-0 border-y border-border-default">
              <table id="observe-issues-table" class="w-full table-fixed border-collapse text-left">
                <caption class="sr-only">Project issues</caption>
                <%!-- The title owns the width. Severity is a dot and a word,
                      never a pill per row, and the status column only exists
                      when the list mixes statuses: filtered to Open, every
                      row saying "Open" was a wall of identical pills. --%>
                <thead class="bg-surface-sunken text-label font-semibold uppercase text-text-tertiary">
                  <tr class="h-11 [@media(pointer:coarse)]:h-12">
                    <th scope="col" class="hidden w-28 px-5 sm:table-cell">Severity</th>
                    <th scope="col" class="px-5">Issue</th>
                    <th scope="col" class="hidden w-44 px-5 lg:table-cell">Source</th>
                    <th scope="col" class="hidden w-20 px-5 text-right sm:table-cell">Events</th>
                    <th scope="col" class="w-28 px-5 text-right">Last seen</th>
                    <th
                      :if={@status_filter == "all"}
                      scope="col"
                      class="hidden w-28 px-5 text-right sm:table-cell"
                    >
                      Status
                    </th>
                  </tr>
                </thead>
                <tbody
                  id="observe-issue-rows"
                  phx-update="stream"
                  class="divide-y divide-border-subtle"
                >
                  <tr
                    :for={{dom_id, issue} <- @streams.issues}
                    id={dom_id}
                    class="group transition-colors duration-productive hover:bg-interactive-wash focus-within:bg-interactive-wash"
                  >
                    <td class="hidden px-5 align-middle sm:table-cell">
                      <.status_dot
                        tone={level_tone(issue.level)}
                        label={String.capitalize(issue.level)}
                        compact
                      />
                    </td>
                    <td class="min-w-0 px-5 py-2 align-middle">
                      <.link
                        id={"observe-issue-row-#{issue.id}"}
                        navigate={
                          ~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/observe/issues/#{issue.id}"
                        }
                        title={issue.title}
                        class="flex min-h-target-min min-w-0 items-center text-body font-semibold text-text-primary group-hover:text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                      >
                        <span class="line-clamp-2 min-w-0 break-words">{issue.title}</span>
                      </.link>
                      <%!-- Below `lg` the source column folds into the row, so an
                            issue never loses its project and environment. --%>
                      <div class="flex flex-wrap gap-x-2 text-caption text-text-secondary lg:hidden">
                        <span class="sm:hidden">{String.capitalize(issue.level)}</span>
                        <span :if={@status_filter == "all"} class="sm:hidden">
                          {status_label(issue.status)}
                        </span>
                        <span class="sm:hidden">{issue.event_count} {if issue.event_count == 1,
                          do: "event",
                          else: "events"}</span>
                        <span>{issue_context(issue)}</span>
                      </div>
                    </td>
                    <td class="hidden px-5 align-middle text-caption text-text-secondary lg:table-cell">
                      <span id={"observe-issue-source-#{issue.id}"}>{issue_context(issue)}</span>
                    </td>
                    <td class="hidden px-5 text-right align-middle font-mono text-data tabular-nums text-text-secondary sm:table-cell">
                      {issue.event_count}
                    </td>
                    <td class="whitespace-nowrap px-5 text-right align-middle font-mono text-data tabular-nums text-text-secondary">
                      <time
                        id={"observe-issue-last-seen-#{issue.id}"}
                        datetime={DateTime.to_iso8601(issue.last_seen_at)}
                        title={Calendar.strftime(issue.last_seen_at, "%Y-%m-%d %H:%M:%S UTC")}
                      >
                        {Evidence.relative_time(issue.last_seen_at)}
                      </time>
                    </td>
                    <td
                      :if={@status_filter == "all"}
                      class="hidden px-5 text-right align-middle sm:table-cell"
                    >
                      <.status_dot
                        tone={issue_status_tone(issue.status)}
                        label={status_label(issue.status)}
                        compact
                        class="justify-end"
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.pagination
              :if={not @issues_empty? and @issue_total_pages > 1}
              id="observe-issues-pagination"
              path={@issue_pagination_path}
              current_page={@issue_page}
              total_pages={@issue_total_pages}
              page_param="page"
              aria_label="Observe issue pages"
              class="border-b border-border-default px-5 py-3"
            />
          </section>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # The screen's title is its answer: how many issues are open right now.
  defp issues_answer(_sources, _summaries, true), do: "Issues"
  defp issues_answer([], _summaries, _loading), do: "Issues"

  defp issues_answer(_sources, summaries, _loading) do
    open =
      summaries
      |> Map.values()
      |> Enum.map(&(Map.get(&1, :open_issues) || 0))
      |> Enum.sum()

    case open do
      0 -> "No open issues"
      1 -> "1 open issue"
      n -> "#{n} open issues"
    end
  end

  defp load_grid_data(socket) do
    project = socket.assigns.project
    scope = socket.assigns.scope
    window = socket.assigns.window
    project_scope = Alplus.Scope.put_project(scope, project.id)

    try do
      sources =
        Alplus.Sources.list_sources_for_project!(project.id, actor: project_scope)
        |> Enum.filter(&(&1.type == :observe))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

      summaries =
        if sources == [], do: %{}, else: Dashboard.summaries(sources, window, project_scope)

      issue_opts = [
        status: socket.assigns.status_filter,
        level: socket.assigns.level_filter,
        environment: socket.assigns.environment_filter,
        search: socket.assigns.search
      ]

      issue_total =
        if sources == [], do: 0, else: IssueListing.count(project_scope, issue_opts)

      issue_total_pages = IssueListing.total_pages(issue_total, IssueListing.page_size())
      issue_page = min(socket.assigns.issue_page, issue_total_pages)

      issues =
        if sources == [] do
          []
        else
          IssueListing.list(
            project_scope,
            issue_opts ++ [page: issue_page, page_size: IssueListing.page_size()]
          )
        end

      # Only paid for when the screen has an empty default list to explain.
      resolved_count =
        if issues == [] and sources != [] and not filters_active?(socket.assigns) do
          IssueListing.count(project_scope,
            status: "resolved",
            environment: socket.assigns.environment_filter
          )
        else
          0
        end

      socket
      |> assign(
        sources: sources,
        summaries: summaries,
        resolved_count: resolved_count,
        # Only the first-run card reads this, so the extra read is paid for
        # only when the screen has nothing else to draw.
        agent_state: if(sources == [], do: AgentConnection.state(project_scope), else: nil),
        issues: issues,
        issues_empty?: issues == [],
        issue_limit_reached?: issue_total > IssueListing.page_size(),
        issue_page: issue_page,
        issue_total_pages: issue_total_pages,
        loading: false,
        load_failed?: false
      )
      |> stream(:issues, issues, reset: true)
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        require Logger
        Logger.error("observe grid load failed: #{Exception.message(error)}")
        assign(socket, loading: false, load_failed?: true)
    end
  end

  defp clear_grid_data(socket) do
    socket
    |> assign(
      sources: [],
      summaries: %{},
      agent_state: nil,
      issues: [],
      issues_empty?: true,
      resolved_count: 0,
      issue_limit_reached?: false,
      issue_page: 1,
      issue_total_pages: 1,
      loading: false,
      load_failed?: false
    )
    |> stream(:issues, [], reset: true)
  end

  defp has_open_issues?(socket, project) do
    if socket.assigns.status_filter == "open" do
      not socket.assigns.issues_empty?
    else
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)
      IssueListing.list(scope, status: "open") != []
    end
  end

  defp source_name(%{source: %{name: name}}) when is_binary(name) and name != "", do: name
  defp source_name(_issue), do: "No source"

  defp issue_context(issue) do
    [source_name(issue), environment_caption(issue)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp environment_caption(%{environment: env, source: %{name: name}})
       when is_binary(env) and env != "" do
    if String.downcase(env) == String.downcase(name), do: nil, else: env
  end

  defp environment_caption(%{environment: env}) when is_binary(env) and env != "", do: env
  defp environment_caption(_issue), do: nil

  defp subscribe_to_project(socket) do
    next_topic = socket.assigns.project && "observe:#{socket.assigns.project.id}"
    previous_topic = socket.assigns.observe_topic

    if connected?(socket) and previous_topic != next_topic do
      if previous_topic, do: Phoenix.PubSub.unsubscribe(Alplus.PubSub, previous_topic)
      if next_topic, do: Phoenix.PubSub.subscribe(Alplus.PubSub, next_topic)
    end

    assign(socket, :observe_topic, next_topic)
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

  defp valid_environment(nil), do: "all"
  defp valid_environment(""), do: "all"

  defp valid_environment(environment) when is_binary(environment) do
    String.slice(String.trim(environment), 0, 64)
  end

  defp valid_environment(_environment), do: "all"

  defp source_environments(sources) do
    sources
    |> Enum.map(& &1.environment)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp index_path(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "status" => socket.assigns.status_filter,
        "level" => socket.assigns.level_filter,
        "environment" => socket.assigns.environment_filter,
        "q" => socket.assigns.search,
        "page" => socket.assigns.issue_page
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {key, value} ->
        (key == "q" and value == "") or (key == "environment" and value == "all") or
          (key == "page" and value in [1, "1"])
      end)
      |> Map.new()

    ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{socket.assigns.project.public_token}/observe?#{params}"
  end

  defp issue_pagination_path(assigns) do
    params =
      %{
        "window" => assigns.window,
        "status" => assigns.status_filter,
        "level" => assigns.level_filter,
        "environment" => assigns.environment_filter,
        "q" => assigns.search
      }
      |> Enum.reject(fn {key, value} ->
        (key == "q" and value == "") or (key == "environment" and value == "all")
      end)
      |> Map.new()

    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/observe?#{params}"
  end

  # The screen opens filtered to Open, because open issues are what it is for.
  # That default is the view, not a narrowing the reader chose, so it never
  # counts as an active filter and never offers to be cleared.
  defp filters_active?(assigns) do
    assigns.search != "" or assigns.level_filter != "all" or assigns.status_filter != "open"
  end

  # The one fact that separates "nothing is broken" from "nothing is
  # reporting". Both look like an empty list, and only one of them is good
  # news.
  defp quiet_evidence(summaries, sources, window) do
    events =
      summaries
      |> Map.values()
      |> Enum.map(&(Map.get(&1, :event_count) || 0))
      |> Enum.sum()

    range = window_words(window)

    if events > 0 do
      "#{source_words(sources)} reported #{with_separators(events)} #{plural(events, "event")} in the last #{range}. None of them opened an issue."
    else
      "No events arrived in the last #{range}, so there is nothing to group into an issue."
    end
  end

  defp source_words([_source]), do: "Your source"
  defp source_words(sources), do: "Your #{length(sources)} sources"

  defp with_separators(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  # A quiet window is often just a short one, so the empty state offers the
  # next range up rather than leaving the reader to find the control.
  defp wider_window("24h"), do: "7d"
  defp wider_window("7d"), do: "30d"
  defp wider_window(_window), do: nil

  defp issue_resolved_path(assigns) do
    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/observe?#{%{"window" => assigns.window, "status" => "resolved"}}"
  end

  defp issue_window_path(_assigns, nil), do: nil

  defp issue_window_path(assigns, window) do
    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/observe?#{%{"window" => window}}"
  end

  defp issue_reset_path(assigns) do
    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/observe?#{%{"window" => assigns.window}}"
  end

  defp observe_project_path(socket, project),
    do: ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{project.public_token}/observe"

  defp issue_status_tone(:resolved), do: "success"
  defp issue_status_tone(:open), do: "warning"
  defp issue_status_tone(_status), do: "neutral"
end
