defmodule AlplusWeb.AnalyticsLiveEventsLive do
  @moduledoc """
  The last hour of incoming events, newest first.

  This exists to verify instrumentation: send an event, watch it land, see
  exactly which properties arrived. It is deliberately not the analytics
  interface, so it is bounded to one hour and one page of rows and it
  refreshes on demand rather than streaming.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.AnalyticsComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Analytics.{Limits, Queries}
  alias AlplusWeb.Analytics.Context

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @refresh_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    with {:ok, socket} <- Context.mount(params, socket, "Live events") do
      if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)
      {:ok, assign(socket, events: [])}
    end
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> Context.put_source(params) |> load()}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("retry_analytics", _params, socket), do: {:noreply, load(socket)}

  def handle_event("pick_app", %{"source" => source}, socket) do
    params = if source in [nil, ""], do: %{}, else: %{"source" => source}
    {:noreply, push_patch(socket, to: Context.path(socket.assigns, "/live", params))}
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
    >
      <.console_page id="analytics-live-page">
        <:title>Live events</:title>
        <:intro>
          Events received in the last {Limits.live_events_window_minutes()} minutes, newest first.
          Use this to check that your instrumentation sends what you expect.
        </:intro>

        <.error_boundary :if={@load_failed?} id="analytics-live-error" retry="retry_analytics">
          Could not load recent events.
        </.error_boundary>

        <div :if={@loading?} role="status" aria-live="polite">
          <span class="sr-only">Loading recent events.</span>
          <.skeleton rows={4} />
        </div>

        <.app_select sources={@analytics_sources} source_id={@source_id} />

        <.data_panel :if={not @loading? and not @load_failed?} id="analytics-live-feed">
          <ol :if={@events != []} class="divide-y divide-border-subtle" aria-live="polite">
            <li :for={event <- @events} class="grid gap-1 px-5 py-3">
              <div class="flex flex-wrap items-baseline gap-x-3">
                <span class="font-mono text-data text-text-tertiary">{clock(event.received_at)}</span>
                <span class="min-w-0 truncate font-mono text-data-strong text-text-primary">
                  {event.event_name}
                </span>
                <span class="min-w-0 truncate font-mono text-caption text-text-secondary">
                  {event.distinct_id}
                </span>
              </div>
              <.property_list
                id={"analytics-live-props-#{DateTime.to_unix(event.received_at, :microsecond)}"}
                properties={event.properties}
              />
            </li>
          </ol>

          <div :if={@events == []} class="p-5">
            <.empty_state
              id="analytics-live-empty"
              title="Waiting for your first event"
              description="Send one event with your write key. It appears here within seconds."
            />
          </div>

          <:footer>
            Recent events are a debugging view, not storage. Counts, funnels and retention read the
            whole retention window.
          </:footer>
        </.data_panel>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp load(socket) do
    Context.load(socket, fn ->
      [events: Queries.live_events(socket.assigns.project_scope, Context.read_opts(socket))]
    end)
  end
end
