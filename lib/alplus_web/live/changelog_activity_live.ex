defmodule AlplusWeb.ChangelogActivityLive do
  @moduledoc """
  The Activity tab of Changelog: every agent action on this changelog,
  including denied attempts. Events are content-free rows kept
  indefinitely, so the list pages until it is exhausted. Any member may
  read it; activity here is project-scoped work, unlike the org audit log.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ChangelogComponents

  alias Alplus.Changelog
  alias Alplus.Changelog.ActivityEvent
  alias Alplus.Changelog.Entry
  alias Alplus.Mcp

  require Ash.Query

  @page_size 25

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket,
             page_title: "Changelog activity",
             active: :public
           ) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)
      scope = Alplus.Scope.put_project(socket.assigns.scope, project.id)

      changelog =
        case Changelog.get_changelog(project.id, actor: scope) do
          {:ok, changelog} -> changelog
          {:error, _} -> nil
        end

      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:project, project)
       |> assign(:changelog, changelog)
       |> assign(:page, 1)
       |> assign(:has_more?, false)
       |> stream(:events, [])
       |> load_events(1)}
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
      scope={@scope}
      current_user={@current_user}
      active={:changelog}
      page_title="Changelog activity"
      page_heading?={false}
      nav_project={@project}
      nav_projects={@nav_projects}
    >
      <.console_page id="changelog-activity-page">
        <:title>Changelog</:title>
        <:intro>
          Every agent action on this changelog, including denied attempts. Events
          record what happened, never the content itself.
        </:intro>
        <div id="changelog-activity" class="flex flex-col gap-4">
          <.data_panel id="activity-panel" title="Activity">
            <:actions>
              <.changelog_subnav
                org_token={@org_token}
                project_token={@project.public_token}
                active={:activity}
              />
            </:actions>
            <div class="overflow-x-auto" data-density="dense">
              <table class="w-full text-left text-body">
                <thead>
                  <tr class="border-b border-border-default text-label uppercase">
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Action</th>
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Entry</th>
                    <th scope="col" class="px-4 py-2 font-medium text-text-tertiary">Revision</th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary sm:table-cell"
                    >
                      Actor
                    </th>
                    <th
                      scope="col"
                      class="hidden px-4 py-2 font-medium text-text-tertiary sm:table-cell"
                    >
                      When
                    </th>
                    <th scope="col" class="px-4 py-2 text-right font-medium text-text-tertiary">
                      Outcome
                    </th>
                  </tr>
                </thead>
                <tbody id="activity-log" phx-update="stream" class="divide-y divide-border-default">
                  <tr id="activity-log-empty" class="hidden only:table-row">
                    <td colspan="6">
                      <.empty_state
                        id="activity-log-empty-state"
                        icon="hero-clipboard-document-list"
                        title="No activity yet"
                        description="Agent actions on this changelog show up here."
                        class="m-4"
                      />
                    </td>
                  </tr>
                  <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
                    <td class="px-4 py-3">
                      <span
                        id={"activity-action-#{event.id}"}
                        class="font-mono text-data text-text-primary"
                      >
                        {event.event_type}
                      </span>
                    </td>
                    <td class="px-4 py-3">
                      <p :if={event.entry_label} class="text-text-primary">{event.entry_label}</p>
                      <p
                        :if={event.entry_id}
                        class="max-w-[10rem] truncate font-mono text-data text-text-tertiary"
                        title={event.entry_id}
                      >
                        {event.entry_id}
                      </p>
                    </td>
                    <td class="px-4 py-3">
                      <span
                        :if={event.revision_id}
                        id={"activity-revision-#{event.id}"}
                        class="max-w-[10rem] truncate font-mono text-data text-text-tertiary"
                      >
                        {event.revision_id}
                      </span>
                    </td>
                    <td
                      id={"activity-actor-#{event.id}"}
                      class="hidden px-4 py-3 text-text-primary sm:table-cell"
                    >
                      {event.actor_label}
                    </td>
                    <td class="hidden px-4 py-3 text-text-tertiary sm:table-cell">
                      <.timestamp at={event.inserted_at} />
                    </td>
                    <td class="px-4 py-3 text-right">
                      <span id={"activity-outcome-#{event.id}"}>
                        <.status_badge tone={outcome_tone(event.outcome)} label={event.outcome} />
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@has_more?} class="border-t border-border-default px-4 py-3">
              <.button id="activity-load-more" variant="secondary" phx-click="load_more">
                Load more
              </.button>
            </div>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    {:noreply, load_events(socket, socket.assigns.page + 1)}
  end

  defp load_events(%{assigns: %{changelog: nil}} = socket, _page), do: socket

  defp load_events(socket, page) do
    scope = socket.assigns.scope
    changelog = socket.assigns.changelog

    events =
      ActivityEvent
      |> Ash.Query.for_read(:for_changelog, %{changelog_id: changelog.id}, actor: scope)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@page_size + 1)
      |> Ash.Query.offset((page - 1) * @page_size)
      |> Ash.read!()

    has_more? = length(events) > @page_size
    page_events = Enum.take(events, @page_size)
    titles = entry_titles(scope, page_events)
    actor_labels = actors(scope, page_events)
    rows = Enum.map(page_events, &row(&1, titles, actor_labels))

    socket
    |> stream(:events, rows, reset: page == 1)
    |> assign(:page, page)
    |> assign(:has_more?, has_more?)
  end

  # A deleted entry leaves no row to name, so the tombstone's frozen
  # public slug labels it instead. Never content, never a secret.
  defp row(event, titles, actor_labels) do
    %{
      id: event.id,
      event_type: event.event_type,
      entry_id: event.entry_id,
      revision_id: event.revision_id,
      entry_label: Map.get(titles, event.entry_id) || event.public_slug,
      actor_label: Map.get(actor_labels, event.id, "Unknown"),
      outcome: event.outcome,
      inserted_at: event.inserted_at
    }
  end

  defp entry_titles(scope, events) do
    case events |> Enum.map(& &1.entry_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      entry_ids ->
        Entry
        |> Ash.Query.filter(id in ^entry_ids)
        |> Ash.read!(actor: scope)
        |> Map.new(&{&1.id, &1.title})
    end
  end

  # The OAuth client names an agent action; a user names a dashboard action.
  # Owner/admin get includes revoked grants. A failed read falls back to
  # "Unknown" instead of raising.
  defp actors(scope, events) do
    grant_names = grant_client_names(scope, events)
    user_names = user_names(scope, events)

    Map.new(events, fn event ->
      label =
        Map.get(grant_names, event.grant_id) ||
          Map.get(user_names, event.actor_id) ||
          "Unknown"

      {event.id, label}
    end)
  end

  defp grant_client_names(scope, events) do
    ids = events |> Enum.map(& &1.grant_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      case Mcp.list_oauth_grant_labels(scope.project_id, ids, actor: scope) do
        {:ok, labels} -> Map.new(labels, &{&1.id, &1.client_display_name})
        {:error, _reason} -> %{}
      end
    end
  end

  defp user_names(scope, events) do
    case events |> Enum.map(& &1.actor_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        Alplus.Accounts.User
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read!(actor: scope)
        |> Map.new(&{&1.id, user_label(&1)})
    end
  end

  defp user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(%{email: email}) when not is_nil(email), do: to_string(email)
  defp user_label(_user), do: "Unknown"

  defp outcome_tone("success"), do: "success"
  defp outcome_tone(outcome) when outcome in ["denied", "failed"], do: "error"
  defp outcome_tone(_outcome), do: "neutral"
end
