defmodule AlplusWeb.AnalyticsEventsLive do
  @moduledoc """
  The event explorer: every event name in the range, ranked by count.

  Search narrows the list. A property filter narrows what counts as a
  matching event. Both live in the URL, so a filtered view is a link
  somebody can send.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.AnalyticsComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Analytics.Queries
  alias AlplusWeb.Analytics.Context

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    with {:ok, socket} <- Context.mount(params, socket, "Events") do
      {:ok,
       assign(socket,
         search: "",
         filter_property: nil,
         filter_value: nil,
         events: [],
         trends: %{}
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> Context.put_window(params)
      |> Context.put_source(params)
      |> assign(:search, params["search"] || "")
      |> assign(:filter_property, present(params["property"]))
      |> assign(:filter_value, present(params["value"]))
      |> load()

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_analytics", _params, socket), do: {:noreply, load(socket)}

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, patch(socket, %{"window" => Queries.valid_window(window)})}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, patch(socket, %{"search" => search})}
  end

  def handle_event("pick_app", %{"source" => source}, socket) do
    {:noreply, patch(socket, %{"source" => source})}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, patch(socket, %{"property" => nil, "value" => nil})}
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
      active={:analytics}
      nav_project={@project}
      nav_projects={@nav_projects}
      page_heading?={false}
      window={@window}
      windows={Queries.windows()}
    >
      <.console_page id="analytics-events-page">
        <:title>Events</:title>
        <:intro>
          Every event name your application sent in the {window_words(@window)}, ranked by how often
          it happened.
        </:intro>

        <.error_boundary :if={@load_failed?} id="analytics-events-error" retry="retry_analytics">
          Could not load events.
        </.error_boundary>

        <div :if={@loading?} role="status" aria-live="polite">
          <span class="sr-only">Loading events.</span>
          <.skeleton rows={4} />
        </div>

        <.data_panel :if={not @loading? and not @load_failed?} id="analytics-events-list">
          <:actions>
            <.app_select sources={@analytics_sources} source_id={@source_id} />
            <.link
              href={Context.path(assigns, "/export", %{"window" => @window, "format" => "ndjson"})}
              class="text-label text-text-link"
            >
              Export NDJSON
            </.link>
            <.link
              href={Context.path(assigns, "/export", export_params(assigns, "csv"))}
              class="text-label text-text-link"
            >
              Export CSV
            </.link>
            <form
              id="analytics-events-search-form"
              phx-change="search"
              phx-submit="search"
              class="flex items-center gap-2"
            >
              <label for="analytics-events-search" class="sr-only">Search event names</label>
              <input
                type="search"
                id="analytics-events-search"
                name="search"
                value={@search}
                placeholder="Search event names"
                phx-debounce="300"
                class="h-control-sm rounded-control border border-border-control bg-surface-raised px-3 text-ui text-text-primary"
              />
            </form>
          </:actions>

          <div
            :if={@filter_property}
            class="flex flex-wrap items-center gap-2 border-b border-border-default px-5 py-3"
          >
            <span class="text-caption text-text-secondary">Filtered to</span>
            <span class="rounded-dot bg-surface-sunken px-2 py-0.5 font-mono text-caption text-text-primary">
              {@filter_property} = {@filter_value}
            </span>
            <button
              type="button"
              phx-click="clear_filter"
              class="cursor-pointer text-caption text-text-link"
            >
              Clear filter
            </button>
          </div>

          <table :if={@events != []} class="w-full min-w-0 table-fixed">
            <caption class="sr-only">Events in the {window_words(@window)}</caption>
            <thead>
              <tr class="border-b border-border-default text-left text-caption text-text-tertiary">
                <th scope="col" class="px-5 py-2 font-normal">Event</th>
                <th scope="col" class="w-24 px-5 py-2 text-right font-normal">Count</th>
                <th scope="col" class="w-24 px-5 py-2 text-right font-normal">Users</th>
                <th scope="col" class="w-32 px-5 py-2 font-normal">Trend</th>
                <th scope="col" class="w-48 px-5 py-2 text-right font-normal">Last seen</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-border-subtle">
              <tr :for={event <- @events}>
                <td class="min-w-0 px-5 py-2.5">
                  <.link
                    navigate={event_path(assigns, event.event_name)}
                    class="block truncate font-mono text-data text-text-link"
                  >
                    {event.event_name}
                  </.link>
                </td>
                <td class="px-5 py-2.5 text-right text-data text-text-primary">
                  {count(event.events)}
                </td>
                <td class="px-5 py-2.5 text-right text-data text-text-secondary">
                  {count(event.users)}
                </td>
                <td class="min-w-0 px-5 py-2.5">
                  <.sparkline
                    id={"analytics-events-trend-#{slug(event.event_name)}"}
                    label={event.event_name}
                    points={Map.get(@trends, event.event_name, [])}
                  />
                </td>
                <td class="px-5 py-2.5 text-right font-mono text-caption text-text-secondary">
                  {at(event.last_seen)}
                </td>
              </tr>
            </tbody>
          </table>

          <div :if={@events == []} class="p-5">
            <.empty_state
              id="analytics-events-empty"
              title={empty_title(@search)}
              description={empty_description(@search, @window)}
            />
          </div>

          <:footer>
            {users_help()} An export carries the raw events for the selected range.
          </:footer>
        </.data_panel>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp empty_title(""), do: "No events in this range"
  defp empty_title(_search), do: "No event names match"

  defp empty_description("", window),
    do: "Nothing was recorded in the #{window_words(window)}. Try a longer range."

  defp empty_description(search, _window),
    do: "No event name contains #{search} in this range."

  defp event_path(assigns, event_name) do
    params =
      %{"window" => assigns.window, "source" => assigns.source_id}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Context.path(assigns, "/events/#{URI.encode(event_name)}", params)
  end

  # One page, and one trend query for every name on it. A trend query per row
  # would be fifty round trips for one screen.
  @page_limit 50

  defp load(socket) do
    Context.load(socket, fn ->
      scope = socket.assigns.project_scope
      window = socket.assigns.window
      range = Queries.range(window)

      opts = Context.read_opts(socket)

      events =
        Queries.list_events(
          scope,
          range,
          opts ++
            [
              search: socket.assigns.search,
              filters: filters(socket.assigns),
              limit: @page_limit
            ]
        )

      [
        events: events,
        trends:
          Queries.trend_by_event(
            scope,
            range,
            Enum.map(events, & &1.event_name),
            Queries.interval_for(window),
            opts
          )
      ]
    end)
  end

  # An event name is customer input, so it cannot be a DOM id on its own.
  defp slug(event_name),
    do: event_name |> String.replace(~r/[^A-Za-z0-9_-]/, "-") |> String.slice(0, 120)

  defp filters(%{filter_property: property, filter_value: value})
       when is_binary(property) and is_binary(value),
       do: %{property => value}

  defp filters(_assigns), do: %{}

  defp patch(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "source" => socket.assigns.source_id,
        "search" => socket.assigns.search,
        "property" => socket.assigns.filter_property,
        "value" => socket.assigns.filter_value
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    push_patch(socket, to: Context.path(socket.assigns, "/events", params))
  end

  defp export_params(assigns, format) do
    %{"window" => assigns.window, "format" => format, "source" => assigns.source_id}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
