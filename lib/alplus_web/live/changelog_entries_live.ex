defmodule AlplusWeb.ChangelogEntriesLive do
  @moduledoc """
  The Entries tab of Changelog: the list of agent-written entries with
  status counts and a status filter. Agents write and publish entries over
  MCP; people review publication state and history here. There is no create
  button anywhere on this surface.

  Also owns the `:redirect` action for the bare `/changelog` URL, which
  lands on this tab.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ChangelogComponents
  import AlplusWeb.MonitorActivityComponents, only: [filter_select: 1]
  import AlplusWeb.OrgContext, only: [can_manage?: 1]

  alias Alplus.Changelog
  alias Alplus.Mcp
  alias Alplus.PublicPages

  require Ash.Query

  @statuses ~w(draft published archived)
  @page_size 25

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Changelog",
             active: :public
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)

      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:project, project)
       |> assign(:status, "")
       |> assign(:page, 1)
       |> assign(:total_pages, 1)
       |> assign(:public_page, nil)
       |> assign(:public_page_error, nil)
       |> assign(:oauth_grant?, false)
       |> assign(:load_error, nil)
       |> assign(:total, 0)
       |> assign(:published, 0)
       |> assign(:drafts, 0)
       |> assign(:archived, 0)
       |> stream(:entries, [])}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :redirect ->
        {:noreply,
         push_navigate(socket,
           to:
             changelog_path(
               socket.assigns.org_token,
               socket.assigns.project.public_token,
               :entries
             )
         )}

      :index ->
        status = validate_status(params["status"])
        page = validate_page(params["page"])

        {:noreply,
         socket
         |> assign(:status, status)
         |> assign(:page, page)
         |> load_data()}
    end
  end

  # The status filter applies in place. It writes the same `status` query
  # parameter the GET form used to submit, so the URL still round-trips, a
  # shared link still reproduces the view, and `handle_params/3` remains the
  # one place that validates the filter. Page resets to 1, exactly as a fresh
  # GET did.
  @impl true
  def handle_event("filter_entries", params, socket) do
    status = validate_status(params["status"])

    {:noreply,
     push_patch(socket,
       to: pagination_path(socket.assigns.org_token, socket.assigns.project.public_token, status)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:changelog}
      page_title="Changelog"
      page_heading?={false}
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <:context_actions>
        <.link
          :if={public?(@public_page, @published)}
          id="open-public-changelog"
          href={public_changelog_path(@public_page.public_slug)}
          target="_blank"
          rel="noopener"
          class="inline-flex min-h-target-min items-center text-caption font-medium text-text-secondary underline underline-offset-2 hover:text-text-primary"
        >
          Open public changelog
        </.link>
      </:context_actions>
      <.console_page id="changelog-entries-page">
        <:title>{changelog_answer(@total, @drafts, @published)}</:title>
        <div :if={@live_action != :redirect} id="changelog-entries" class="flex flex-col gap-4">
          <p id="changelog-summary" class="sr-only">{entries_description(@scope)}</p>

          <.alert
            :if={@public_page_error}
            id="changelog-public-page-error"
            kind="error"
            title="Public page unavailable"
            message={@public_page_error}
          />

          <%!-- No entries yet: one card, the agent action, nothing else. --%>
          <.first_run_card
            :if={is_nil(@load_error) and @total == 0}
            id={if(@oauth_grant?, do: "changelog-entries-empty", else: "changelog-needs-credential")}
            title={if(@oauth_grant?, do: "No updates published yet", else: "Connect an agent first")}
            description={changelog_first_run_description(@scope, @oauth_grant?)}
            state={if(@oauth_grant?, do: :awaiting_evidence, else: :not_connected)}
            task="Write and publish the first customer update. Include the release or change it describes, and return the public URL."
            action_href={~p"/dashboard/orgs/#{@org_token}/projects/#{@project.public_token}/connect"}
          />

          <.data_panel :if={@total > 0} id="changelog-entry-list" class="min-w-0">
            <:actions>
              <.changelog_subnav
                org_token={@org_token}
                project_token={@project.public_token}
                active={:entries}
              />
              <form
                id="changelog-filters"
                phx-change="filter_entries"
                phx-submit="filter_entries"
                class="flex min-w-0 max-w-full flex-wrap items-center gap-2"
              >
                <.filter_select
                  label="Filter by status"
                  name="status"
                  value={@status}
                  options={[
                    {"All entries", ""},
                    {"Drafts", "draft"},
                    {"Published", "published"},
                    {"Archived", "archived"}
                  ]}
                />
              </form>
            </:actions>
            <ol id="changelog-entries-body" phx-update="stream" class="divide-y divide-border-subtle">
              <li
                id="changelog-entries-none"
                class="hidden px-5 py-5 text-body text-text-secondary only:block"
              >
                No entries match this filter.
              </li>
              <li
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 px-5 py-4"
              >
                <div class="flex min-w-0 items-center gap-x-3">
                  <.link
                    id={"review-entry-#{entry.id}"}
                    navigate={entry_path(@org_token, @project.public_token, entry.id)}
                    class="min-w-0 truncate text-body font-semibold text-text-primary hover:text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  >
                    {entry.title}
                  </.link>
                  <.entry_status_badge status={entry.status} />
                </div>
                <span class="shrink-0 text-caption text-text-tertiary">
                  <.timestamp at={entry.updated_at} />
                </span>
              </li>
            </ol>

            <.pagination
              :if={@total_pages > 1}
              id="changelog-entries-pagination"
              path={pagination_path(@org_token, @project.public_token, @status)}
              current_page={@page}
              total_pages={@total_pages}
              page_param="page"
              aria_label="Changelog entry pages"
              class="border-t border-border-default px-4 py-3"
            />
            <:footer :if={@oauth_grant? and public_page_unpublished?(@public_page)}>
              <span id="changelog-publication-state">{public_page_message(@public_page)}</span>
            </:footer>
          </.data_panel>

          <.alert
            :if={@load_error}
            id="changelog-load-error"
            kind="error"
            title="Entries unavailable"
            message={@load_error}
          />
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # The screen's title is its answer.
  defp changelog_answer(0, _drafts, _published), do: "Changelog"
  defp changelog_answer(_total, drafts, published), do: summary_headline(drafts, published)

  defp load_data(socket) do
    scope = socket.assigns.scope
    project = socket.assigns.project

    {public_page, public_page_error} = public_page(scope, project.id)

    page = max(socket.assigns.page, 1)
    offset = (page - 1) * @page_size

    entries_result =
      Changelog.list_entries(project.id,
        actor: scope,
        limit: @page_size,
        offset: offset,
        status: blank_to_nil(socket.assigns.status)
      )

    {entries, load_error} =
      case entries_result do
        {:ok, entries} -> {entries, nil}
        {:error, _reason} -> {[], "We could not load Changelog entries. Try again."}
      end

    counts = entry_counts(scope, project.id)
    total = filtered_total(counts, socket.assigns.status)
    total_pages = max(div(total + @page_size - 1, @page_size), 1)
    page = min(page, total_pages)

    rows =
      entries
      |> Enum.map(fn entry ->
        %{
          id: entry.id,
          title: entry.title,
          status: entry.status,
          public_slug: entry.public_slug,
          updated_at: entry.updated_at,
          source_count: entry.source_count || 0
        }
      end)

    socket
    |> assign(:public_page, public_page)
    |> assign(:public_page_error, public_page_error)
    |> assign(:load_error, load_error)
    |> assign(:page, page)
    |> assign(:total_pages, total_pages)
    |> assign(:oauth_grant?, oauth_grant?(scope))
    |> assign(:total, total)
    |> assign(:published, Map.get(counts, :published, 0))
    |> assign(:drafts, Map.get(counts, :draft, 0))
    |> assign(:archived, Map.get(counts, :archived, 0))
    |> stream(:entries, rows, reset: true)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(status), do: status

  defp entry_counts(scope, project_id) do
    case Changelog.entry_counts(project_id, actor: scope) do
      {:ok, counts} -> counts
      {:error, _reason} -> %{draft: 0, published: 0, archived: 0}
    end
  end

  defp filtered_total(counts, "draft"), do: counts.draft
  defp filtered_total(counts, "published"), do: counts.published
  defp filtered_total(counts, "archived"), do: counts.archived
  defp filtered_total(counts, _status), do: counts.draft + counts.published + counts.archived

  defp public_page(scope, project_id) do
    case PublicPages.get_for_project(scope, project_id) do
      {:ok, public_page} -> {public_page, nil}
      {:error, :not_found} -> {nil, nil}
      {:error, _reason} -> {nil, "We could not load the shared Public page."}
    end
  end

  defp oauth_grant?(scope) do
    query =
      Mcp.OAuthGrant
      |> Ash.Query.filter(org_id == ^scope.org_id and project_id == ^scope.project_id)
      |> Ash.Query.limit(1)

    # list/1 is owner/admin; connection evidence is member-readable.
    case Mcp.list_oauth_grants(query: query, actor: scope, authorize?: false) do
      {:ok, grants} -> grants != []
      {:error, _} -> false
    end
  end

  defp validate_status(status) when status in @statuses, do: status
  defp validate_status(_status), do: ""

  defp public?(nil, _published), do: false
  defp public?(public_page, _published), do: not is_nil(public_page.published_at)

  defp public_page_unpublished?(nil), do: true
  defp public_page_unpublished?(public_page), do: is_nil(public_page.published_at)

  defp public_page_message(nil),
    do: "Set the public name and address before customers can read these updates."

  defp public_page_message(_public_page),
    do: "Publish the public page before customers can read these updates."

  defp changelog_first_run_description(scope, true) do
    if can_manage?(scope) do
      "Updates your agent writes appear here as drafts you can review and publish. Each one links the release or change it describes."
    else
      "Updates your agents write appear here. Ask an owner or admin to request the first one."
    end
  end

  defp changelog_first_run_description(scope, false) do
    if can_manage?(scope) do
      "Connect an agent, then ask it to write the first customer update."
    else
      "Ask an owner or admin to connect an agent before updates can arrive."
    end
  end

  defp entries_description(_scope),
    do: "Agents write updates. Review, publish, and read the history here."

  defp validate_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp validate_page(_page), do: 1

  defp pagination_path(org_token, project_token, "") do
    changelog_path(org_token, project_token, :entries)
  end

  defp pagination_path(org_token, project_token, status) do
    changelog_path(org_token, project_token, :entries) <> "?status=" <> URI.encode(status)
  end

  defp summary_headline(1, _published), do: "1 draft waits for review"

  defp summary_headline(drafts, _published) when drafts > 0,
    do: "#{drafts} drafts wait for review"

  defp summary_headline(_drafts, published) when published > 0, do: "All entries are published"
  defp summary_headline(_drafts, _published), do: "All entries are archived"
end
