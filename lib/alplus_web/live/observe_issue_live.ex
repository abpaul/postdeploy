defmodule AlplusWeb.ObserveIssueLive do
  @moduledoc """
  One issue's status, impact, timeline, and bounded evidence.

  The route carries the project public token and issue id. Without a valid
  project token naming a project in this org, the issue cannot be resolved
  under any project scope, so it 404s rather than guessing across projects.

  Evidence renders from a selected occurrence (default: the most recent).
  Occurrence rows are selectable, so a dev can compare the latest event
  against an older one without leaving the page.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.ObserveIssueComponents

  alias Alplus.Observe.{
    Issue,
    IssueEvidence,
    PayloadStore,
    Release,
    ReleaseListing
  }

  alias AlplusWeb.Observe.Evidence

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Issues", active: :observe) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       socket
       |> assign(:projects, [project])
       |> assign(:project, project)
       |> assign(:environments, [])
       |> assign(:issue, nil)
       |> assign(:occurrences, [])
       |> assign(:occurrence_columns, [:received])
       |> assign(:selected_occurrence, nil)
       |> assign(:users_affected, 0)
       |> assign(:merged_children, [])
       |> assign(:merged_children_count, 0)
       |> assign(:merged_children_more?, false)
       |> assign(:merged_children_page, 1)
       |> assign(:merged_parent, nil)
       |> assign(:group_event_count, 0)
       |> assign(:full_payload, nil)
       |> assign(:full_payload_error, nil)
       |> assign(:full_payload_loading?, false)
       |> assign(:load_failed?, false)
       |> assign(:issue_tab, "event")
       |> assign(:stack_order, :oldest_first)
       |> assign(:stack_view, :full)
       |> assign(:stack_in_app_only, false)
       |> assign(:comments, [])
       |> assign(:comments_count, 0)
       |> assign(:comments_more?, false)
       |> assign(:comments_page, 1)
       |> assign(:user_reports, [])
       |> assign(:reports_count, 0)
       |> assign(:reports_more?, false)
       |> assign(:reports_page, 1)
       |> assign(:latest_release, nil)
       |> assign(:resolved_release, nil)}
    end
  end

  @impl true
  def handle_params(%{"issue_id" => issue_id} = params, _uri, socket) do
    project = socket.assigns.project

    case project do
      nil ->
        raise AlplusWeb.NotFoundError

      project ->
        socket =
          assign(socket,
            project: project,
            issue_id: issue_id,
            issue_tab: valid_tab(params["tab"])
          )

        case fetch_issue(project_scope(socket), issue_id) do
          {:ok, issue} ->
            {:noreply,
             socket
             |> assign(issue: issue, load_failed?: false)
             |> load_evidence()}

          {:error, :not_found} ->
            raise AlplusWeb.NotFoundError

          {:error, :load_failed} ->
            {:noreply, assign(socket, issue: nil, load_failed?: true)}
        end
    end
  end

  def handle_event("set_issue_tab", %{"tab" => tab}, socket)
      when tab in ["event", "comments", "reports"] do
    {:noreply,
     push_patch(socket,
       to:
         issue_tab_path(
           socket.assigns.org_token,
           socket.assigns.project,
           socket.assigns.issue,
           tab
         )
     )}
  end

  def handle_event("load_more_merged_children", _params, socket) do
    scope = project_scope(socket)
    next_page = socket.assigns.merged_children_page + 1
    page = IssueEvidence.merged_children_page(scope, socket.assigns.issue.id, next_page)

    {:noreply,
     socket
     |> assign(:merged_children, socket.assigns.merged_children ++ page.results)
     |> assign(:merged_children_more?, page.more?)
     |> assign(:merged_children_page, next_page)}
  end

  def handle_event("load_more_comments", _params, socket) do
    {:noreply, load_discussion_page(socket, :comments, socket.assigns.comments_page + 1)}
  end

  def handle_event("load_more_reports", _params, socket) do
    {:noreply, load_discussion_page(socket, :reports, socket.assigns.reports_page + 1)}
  end

  @impl true

  def handle_event("select_occurrence", %{"event-id" => event_id}, socket) do
    case Enum.find(socket.assigns.occurrences, &(&1.event_id == event_id)) do
      nil ->
        {:noreply, socket}

      occurrence ->
        {:noreply,
         socket
         |> cancel_async(:full_payload)
         |> assign(
           selected_occurrence: occurrence,
           full_payload: nil,
           full_payload_error: nil,
           full_payload_loading?: false
         )}
    end
  end

  def handle_event("retry_issue", _params, %{assigns: %{project: project, issue: nil}} = socket)
      when not is_nil(project) do
    case fetch_issue(project_scope(socket), socket.assigns.issue_id) do
      {:ok, issue} ->
        {:noreply, socket |> assign(issue: issue, load_failed?: false) |> load_evidence()}

      _ ->
        {:noreply, assign(socket, load_failed?: true)}
    end
  end

  def handle_event("retry_issue", _params, socket), do: {:noreply, socket}

  # Authorization here is implicit: the S3 key comes only from an occurrence
  # already loaded under this actor's project scope in `load_evidence/1`,
  # never from client-supplied params, so there is no cross-tenant key to
  # authorize against.
  def handle_event("fetch_full_payload", _params, socket) do
    case socket.assigns.selected_occurrence do
      %{payload_s3_key: key} when is_binary(key) ->
        socket =
          socket
          |> cancel_async(:full_payload)
          |> assign(full_payload: nil, full_payload_error: nil, full_payload_loading?: true)

        {:noreply, start_async(socket, :full_payload, fn -> PayloadStore.fetch(key) end)}

      _ ->
        {:noreply, assign(socket, full_payload_loading?: false)}
    end
  end

  def handle_event("set_stack_order", %{"order" => order}, socket)
      when order in ["oldest_first", "newest_first"] do
    {:noreply, assign(socket, :stack_order, String.to_existing_atom(order))}
  end

  def handle_event("set_stack_view", %{"view" => view}, socket) when view in ["full", "raw"] do
    {:noreply, assign(socket, :stack_view, String.to_existing_atom(view))}
  end

  def handle_event("toggle_in_app_only", _params, socket) do
    {:noreply, assign(socket, :stack_in_app_only, !socket.assigns.stack_in_app_only)}
  end

  def handle_event("select_adjacent_occurrence", %{"dir" => dir}, socket)
      when dir in ["older", "newer"] do
    selected = socket.assigns.selected_occurrence

    {older, newer} =
      Evidence.adjacent_event_ids(socket.assigns.occurrences, selected && selected.event_id)

    target_id = if dir == "older", do: older, else: newer

    case Enum.find(socket.assigns.occurrences, &(&1.event_id == target_id)) do
      nil ->
        {:noreply, socket}

      occurrence ->
        {:noreply,
         socket
         |> cancel_async(:full_payload)
         |> assign(
           selected_occurrence: occurrence,
           full_payload: nil,
           full_payload_error: nil,
           full_payload_loading?: false
         )}
    end
  end

  @impl true
  def handle_async(:full_payload, {:ok, {:ok, payload}}, socket) do
    {:noreply,
     assign(socket,
       full_payload: payload,
       full_payload_error: nil,
       full_payload_loading?: false
     )}
  end

  def handle_async(:full_payload, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       full_payload: nil,
       full_payload_error: reason,
       full_payload_loading?: false
     )}
  end

  def handle_async(:full_payload, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       full_payload: nil,
       full_payload_error: reason,
       full_payload_loading?: false
     )}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :issue_presentation, issue_presentation(assigns.issue))

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
      page_heading?={false}
    >
      <.console_page id="observe-issue-screen">
        <:title><span class="break-words">{@issue_presentation.heading}</span></:title>
        <.error_boundary :if={@load_failed?} id="observe-issue-error" retry="retry_issue">
          Could not load this issue.
        </.error_boundary>

        <div
          :if={not @load_failed? && @issue}
          id="observe-issue-page"
          class="flex flex-col gap-4"
        >
          <.merged_banner org_token={@org_token} project={@project} merged_parent={@merged_parent} />

          <.issue_header
            issue={@issue}
            selected_occurrence={@selected_occurrence}
            issue_presentation={@issue_presentation}
            group_event_count={@group_event_count}
            users_affected={@users_affected}
            latest_release={@latest_release}
            resolved_release={@resolved_release}
            members={@members}
          />

          <.tabs
            id="observe-issue-tabs"
            tabs={issue_tabs(@comments_count, @reports_count)}
            active={@issue_tab}
            on_change="set_issue_tab"
            aria_label="Issue views"
            class="border-b border-border-default"
          />

          <.comments_panel
            issue_tab={@issue_tab}
            comments={@comments}
            comments_more?={@comments_more?}
          />

          <.reports_panel
            issue_tab={@issue_tab}
            user_reports={@user_reports}
            reports_more?={@reports_more?}
          />

          <.event_panel
            issue_tab={@issue_tab}
            issue={@issue}
            selected_occurrence={@selected_occurrence}
            occurrences={@occurrences}
            occurrence_columns={@occurrence_columns}
            stack_order={@stack_order}
            stack_view={@stack_view}
            stack_in_app_only={@stack_in_app_only}
            merged_children={@merged_children}
            merged_children_count={@merged_children_count}
            merged_children_more?={@merged_children_more?}
            full_payload={@full_payload}
            full_payload_error={@full_payload_error}
            full_payload_loading?={@full_payload_loading?}
            org_token={@org_token}
            project={@project}
          />
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp load_evidence(socket) do
    scope = project_scope(socket)
    page = IssueEvidence.page(scope, socket.assigns.issue)

    selected_event_id =
      socket.assigns.selected_occurrence && socket.assigns.selected_occurrence.event_id

    selected_occurrence =
      Enum.find(page.occurrences, &(&1.event_id == selected_event_id)) ||
        List.first(page.occurrences)

    socket
    |> cancel_async(:full_payload)
    |> assign(:merged_children, page.merged_children)
    |> assign(:merged_children_count, page.merged_children_count)
    |> assign(:merged_children_more?, page.merged_children_more?)
    |> assign(:merged_children_page, 1)
    |> assign(:merged_parent, page.merged_parent)
    |> assign(:group_event_count, page.group_event_count)
    |> assign(:occurrences, page.occurrences)
    |> assign(:occurrence_columns, Evidence.occurrence_columns(page.occurrences))
    |> assign(:selected_occurrence, selected_occurrence)
    |> assign(:users_affected, page.users_affected)
    |> assign(:members, load_members(socket))
    |> assign(:full_payload, nil)
    |> assign(:full_payload_error, nil)
    |> assign(:full_payload_loading?, false)
    |> assign(:latest_release, load_latest_release(scope, socket.assigns.issue))
    |> assign(:resolved_release, load_resolved_release(scope, socket.assigns.issue))
    |> load_discussion()
  end

  defp load_discussion(socket) do
    socket
    |> load_discussion_page(:comments, 1)
    |> load_discussion_page(:reports, 1)
  end

  defp load_discussion_page(socket, kind, page_number) when kind in [:comments, :reports] do
    scope = project_scope(socket)
    issue = socket.assigns.issue
    {rows, count, more?} = IssueEvidence.discussion_page(scope, issue.id, kind, page_number)

    case kind do
      :comments ->
        comments = if page_number == 1, do: rows, else: socket.assigns.comments ++ rows

        assign(socket,
          comments: comments,
          comments_count: count,
          comments_more?: more?,
          comments_page: page_number
        )

      :reports ->
        reports = if page_number == 1, do: rows, else: socket.assigns.user_reports ++ rows

        assign(socket,
          user_reports: reports,
          reports_count: count,
          reports_more?: more?,
          reports_page: page_number
        )
    end
  end

  defp load_latest_release(scope, issue),
    do: ReleaseListing.latest(scope, issue.source_id)

  defp load_resolved_release(_scope, %{resolved_in_release_id: nil}), do: nil

  defp load_resolved_release(scope, %{resolved_in_release_id: release_id}) do
    case Ash.get(Release, release_id, actor: scope) do
      {:ok, release} -> release
      _ -> nil
    end
  end

  defp load_members(socket) do
    case Alplus.Orgs.list_org_members(socket.assigns.scope, socket.assigns.org.id) do
      {:ok, memberships} ->
        memberships
        |> Enum.map(&%{id: &1.user_id, label: Evidence.member_display_name(&1.user)})
        |> Enum.sort_by(& &1.label)

      {:error, _reason} ->
        []
    end
  end

  defp fetch_issue(scope, issue_id) do
    case Ash.get(Issue, issue_id, actor: scope) do
      {:ok, issue} -> {:ok, issue}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :not_found}
      {:error, _other} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :load_failed}
  end

  # Framework diagnostics can be essential evidence without being a useful
  # page title. Keep the precise captured message behind a disclosure, and put
  # the operational problem plus its recovery at the top of the issue.
  defp issue_presentation(nil),
    do: %{heading: "Issue", summary: nil, recovery_steps: [], technical_details: nil}

  defp issue_presentation(%{title: title}) do
    case socket_origin(title) do
      {:ok, origin} ->
        %{
          heading: "Socket connection blocked",
          summary:
            "The live connection from #{origin} is not allowed by the app configuration. Add this host to the allowed origins, then reload.",
          recovery_steps: [
            "Set the endpoint URL host to the hostname that serves the LiveView page.",
            "Add #{origin} to the endpoint's allowed origins.",
            "Deploy the configuration change, then reload the page."
          ],
          technical_details: title
        }

      :error ->
        %{heading: title, summary: nil, recovery_steps: [], technical_details: nil}
    end
  end

  defp socket_origin(title) when is_binary(title) do
    case Regex.run(
           ~r/^Could not check origin for Phoenix\.Socket transport\.\s+Origin of the request: (https?:\/\/[^\s]+)/,
           title
         ) do
      [_, origin] -> {:ok, origin}
      _ -> :error
    end
  end

  defp socket_origin(_title), do: :error

  defp project_scope(socket),
    do: Alplus.Scope.put_project(socket.assigns.scope, socket.assigns.project.id)

  defp valid_tab(tab) when tab in ["event", "comments", "reports"], do: tab
  defp valid_tab(_), do: "event"

  defp issue_tab_path(org_token, project, issue, tab) do
    ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/observe/issues/#{issue.id}?#{%{tab: tab}}"
  end
end
