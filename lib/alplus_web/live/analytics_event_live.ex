defmodule AlplusWeb.AnalyticsEventLive do
  @moduledoc """
  One event: its totals, its trend, a property breakdown, and the most
  recent examples.

  The breakdown property is the control that answers "which variant, which
  platform, which release". It comes from the property names ingest has
  already seen on this event, so the picker offers only names that exist.
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
    with {:ok, socket} <- Context.mount(params, socket, "Event") do
      {:ok,
       assign(socket,
         event_name: params["event_name"],
         property: nil,
         property_keys: [],
         breakdown: [],
         totals: %{events: 0, users: 0},
         series: [],
         recent: []
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> Context.put_window(params)
      |> Context.put_source(params)
      |> assign(:event_name, params["event_name"])
      |> assign(:property, present(params["property"]))
      |> load()

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_analytics", _params, socket), do: {:noreply, load(socket)}

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, patch(socket, %{"window" => Queries.valid_window(window)})}
  end

  def handle_event("pick_app", %{"source" => source}, socket) do
    {:noreply, patch(socket, %{"source" => source})}
  end

  def handle_event("pick_property", %{"property" => property}, socket) do
    {:noreply, patch(socket, %{"property" => present(property)})}
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
      <.console_page id="analytics-event-page">
        <:title>{@event_name}</:title>
        <:intro>{window_words(@window) |> String.capitalize()}, in UTC.</:intro>

        <.app_select
          :if={not @loading? and not @load_failed?}
          sources={@analytics_sources}
          source_id={@source_id}
        />

        <.error_boundary :if={@load_failed?} id="analytics-event-error" retry="retry_analytics">
          Could not load this event.
        </.error_boundary>

        <div :if={@loading?} role="status" aria-live="polite">
          <span class="sr-only">Loading this event.</span>
          <.skeleton rows={4} />
        </div>

        <div :if={not @loading? and not @load_failed?} class="grid gap-6">
          <div class="grid gap-4 sm:grid-cols-3">
            <.stat_card label="Events" value={count(@totals.events)} />
            <.stat_card label="Users" value={count(@totals.users)} definition={users_help()} />
            <.stat_card
              label="Events per user"
              value={per_user(@totals)}
              definition="Events divided by unique distinct IDs."
            />
          </div>

          <.data_panel id="analytics-event-activity" title="Trend" padded>
            <.activity_chart
              id="analytics-event-chart"
              series={@series}
              window={@window}
              metric={:events}
              title={"#{@event_name} over time"}
            />
            <:footer>
              First seen {at(@first_seen)}. Last seen {at(@last_seen)}.
            </:footer>
          </.data_panel>

          <.data_panel id="analytics-event-breakdown" title="Break down by a property">
            <:actions>
              <form
                id="analytics-event-property-form"
                phx-change="pick_property"
                class="flex items-center gap-2"
              >
                <label for="analytics-event-property" class="sr-only">Breakdown property</label>
                <select
                  id="analytics-event-property"
                  name="property"
                  class="h-control-sm rounded-control border border-border-control bg-surface-raised px-2 text-ui text-text-primary"
                >
                  <option value="" selected={is_nil(@property)}>No breakdown</option>
                  <option :for={key <- @property_keys} value={key} selected={key == @property}>
                    {key}
                  </option>
                </select>
              </form>
            </:actions>

            <.breakdown_table
              :if={@property}
              id="analytics-event-breakdown-table"
              rows={@breakdown}
              property={@property}
              total={@totals.events}
            />

            <div :if={is_nil(@property)} class="p-5">
              <.empty_state
                id="analytics-event-breakdown-empty"
                title={breakdown_empty_title(@property_keys)}
                description={breakdown_empty_description(@property_keys)}
              />
            </div>

            <:footer>
              Values past the top {Alplus.Analytics.Limits.breakdown_max_values()} are collected into
              one (other) row. A property with a value per request, such as a request ID, shows up
              as one large (other).
            </:footer>
          </.data_panel>

          <.data_panel id="analytics-event-recent" title="Recent events">
            <ol :if={@recent != []} class="divide-y divide-border-subtle">
              <li :for={event <- @recent} class="grid gap-1 px-5 py-2.5">
                <div class="flex flex-wrap items-baseline gap-x-3">
                  <span class="font-mono text-data text-text-primary">{clock(event.occurred_at)}</span>
                  <span class="truncate font-mono text-caption text-text-secondary">
                    {event.distinct_id}
                  </span>
                </div>
                <.property_list
                  id={"analytics-event-recent-#{DateTime.to_unix(event.received_at, :microsecond)}"}
                  properties={event.properties}
                />
              </li>
            </ol>

            <div :if={@recent == []} class="p-5">
              <.empty_state
                id="analytics-event-recent-empty"
                title="Nothing in the last hour"
                description="Recent examples cover the last hour only. The totals above cover the whole range."
              />
            </div>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp breakdown_empty_title([]), do: "No properties on this event"

  defp breakdown_empty_title(_keys), do: "Pick a property"

  defp breakdown_empty_description([]),
    do: "Send properties with this event to compare variants, platforms, or app versions."

  defp breakdown_empty_description(_keys),
    do: "Choose a property above to see how this event splits across its values."

  defp per_user(%{users: 0}), do: "No users"

  defp per_user(%{events: events, users: users}),
    do: Float.round(events / users, 2) |> to_string()

  defp load(socket) do
    Context.load(socket, fn ->
      scope = socket.assigns.project_scope
      window = socket.assigns.window
      range = Queries.range(window)
      event_name = socket.assigns.event_name
      opts = Context.read_opts(socket) ++ [event_name: event_name]

      summary =
        scope
        |> Queries.list_events(
          range,
          Context.read_opts(socket) ++ [search: event_name, limit: 100]
        )
        |> Enum.find(&(&1.event_name == event_name))

      [
        totals: Queries.totals(scope, range, opts),
        series:
          Queries.time_series(
            scope,
            range,
            Keyword.put(opts, :interval, Queries.interval_for(window))
          ),
        property_keys: Queries.property_keys(scope, event_name),
        breakdown: breakdown(scope, range, socket.assigns.property, opts),
        recent:
          Queries.live_events(
            scope,
            Context.read_opts(socket) ++ [limit: 20, event_name: event_name]
          ),
        first_seen: summary && summary.first_seen,
        last_seen: summary && summary.last_seen
      ]
    end)
  end

  defp breakdown(_scope, _range, nil, _opts), do: []

  defp breakdown(scope, range, property, opts),
    do: Queries.breakdown(scope, range, property, opts)

  defp patch(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "source" => socket.assigns.source_id,
        "property" => socket.assigns.property
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    push_patch(socket,
      to:
        Context.path(
          socket.assigns,
          "/events/#{URI.encode(socket.assigns.event_name)}",
          params
        )
    )
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
