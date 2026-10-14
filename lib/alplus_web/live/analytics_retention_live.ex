defmodule AlplusWeb.AnalyticsRetentionLive do
  @moduledoc """
  Retention for one starting event and one return event.

  Exact-period retention: somebody counts at day N only if they did the
  return event during that exact day. A period that has not finished for a
  cohort is left out of its denominator, so a fresh cohort never drags the
  curve down.

  The two event names come from the URL, defaulting to the project's
  activation event. Both controls are reads, so the screen stays read-only.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.AnalyticsComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Analytics.Queries
  alias AlplusWeb.Analytics.Context

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @granularities ~w(daily weekly)

  @impl true
  def mount(params, _session, socket) do
    with {:ok, socket} <- Context.mount(params, socket, "Retention") do
      {:ok,
       assign(socket,
         start_event: nil,
         return_event: nil,
         granularity: "daily",
         event_names: [],
         periods: []
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> Context.put_window(params)
      |> Context.put_source(params)
      |> assign(:requested_start, present(params["start_event"]))
      |> assign(:requested_return, present(params["return_event"]))
      |> assign(:granularity, granularity(params["granularity"]))
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

  def handle_event("pick_events", params, socket) do
    {:noreply,
     patch(socket, %{
       "start_event" => present(params["start_event"]),
       "return_event" => present(params["return_event"]),
       "granularity" => granularity(params["granularity"])
     })}
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
      <.console_page id="analytics-retention-page">
        <:title>Retention</:title>
        <:intro>
          Of the people who first did the starting event, how many did the return event on each
          later {period_word(@granularity)}.
        </:intro>

        <.error_boundary :if={@load_failed?} id="analytics-retention-error" retry="retry_analytics">
          Could not load retention.
        </.error_boundary>

        <div :if={@loading?} role="status" aria-live="polite">
          <span class="sr-only">Loading retention.</span>
          <.skeleton rows={4} />
        </div>

        <.empty_state
          :if={not @loading? and not @load_failed? and @event_names == []}
          id="analytics-retention-empty"
          title="No events to measure yet"
          description="Retention needs at least one event name. Send events first, then come back."
        />

        <div :if={not @loading? and not @load_failed? and @event_names != []} class="grid gap-6">
          <.app_select sources={@analytics_sources} source_id={@source_id} />

          <.data_panel id="analytics-retention-controls" title="What to measure" padded>
            <form
              id="analytics-retention-form"
              phx-change="pick_events"
              class="grid gap-4 sm:grid-cols-3"
            >
              <div class="grid gap-1.5">
                <label for="retention-start" class="text-label text-text-secondary">
                  Starting event
                </label>
                <select
                  id="retention-start"
                  name="start_event"
                  class="h-control-md rounded-control border border-border-control bg-surface-raised px-2 text-ui text-text-primary"
                >
                  <option :for={name <- @event_names} value={name} selected={name == @start_event}>
                    {name}
                  </option>
                </select>
              </div>

              <div class="grid gap-1.5">
                <label for="retention-return" class="text-label text-text-secondary">
                  Return event
                </label>
                <select
                  id="retention-return"
                  name="return_event"
                  class="h-control-md rounded-control border border-border-control bg-surface-raised px-2 text-ui text-text-primary"
                >
                  <option :for={name <- @event_names} value={name} selected={name == @return_event}>
                    {name}
                  </option>
                </select>
              </div>

              <div class="grid gap-1.5">
                <label for="retention-granularity" class="text-label text-text-secondary">
                  Cohorts
                </label>
                <select
                  id="retention-granularity"
                  name="granularity"
                  class="h-control-md rounded-control border border-border-control bg-surface-raised px-2 text-ui text-text-primary"
                >
                  <option
                    :for={value <- @granularities}
                    value={value}
                    selected={value == @granularity}
                  >
                    {String.capitalize(value)}
                  </option>
                </select>
              </div>
            </form>
          </.data_panel>

          <.data_panel id="analytics-retention-table" title="Retention">
            <table class="w-full min-w-0 table-fixed">
              <caption class="sr-only">
                Retention from {@start_event} to {@return_event}
              </caption>
              <thead>
                <tr class="border-b border-border-default text-left text-caption text-text-tertiary">
                  <th scope="col" class="px-5 py-2 font-normal">
                    {String.capitalize(period_word(@granularity))}
                  </th>
                  <th scope="col" class="w-28 px-5 py-2 text-right font-normal">Cohort</th>
                  <th scope="col" class="w-28 px-5 py-2 text-right font-normal">Returned</th>
                  <th scope="col" class="w-28 px-5 py-2 text-right font-normal">Rate</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border-subtle">
                <tr :for={period <- @periods}>
                  <td class="px-5 py-2.5 font-mono text-data text-text-primary">
                    {period_label(@granularity, period.period)}
                  </td>
                  <td class="px-5 py-2.5 text-right text-data text-text-secondary">
                    {count(period.cohort)}
                  </td>
                  <td class="px-5 py-2.5 text-right text-data text-text-primary">
                    {count(period.retained)}
                  </td>
                  <td class="px-5 py-2.5 text-right text-data text-text-primary">
                    {percent(period.rate)}
                  </td>
                </tr>
              </tbody>
            </table>
            <:footer>
              A {period_word(@granularity)} with nobody in its cohort has not finished for anyone
              yet, so it reports no rate rather than zero. {users_help()}
            </:footer>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  defp period_word("weekly"), do: "week"
  defp period_word(_daily), do: "day"

  defp period_label(granularity, period),
    do: "#{String.capitalize(period_word(granularity))} #{period}"

  defp granularity(value) when value in @granularities, do: value
  defp granularity(_value), do: "daily"

  defp load(socket) do
    Context.load(socket, fn ->
      scope = socket.assigns.project_scope
      range = Queries.range(socket.assigns.window)
      opts = Context.read_opts(socket)

      event_names =
        scope
        |> Queries.list_events(range, Keyword.put(opts, :limit, 100))
        |> Enum.map(& &1.event_name)

      settings = Context.settings(scope)
      start_event = choose(socket.assigns[:requested_start], settings, event_names)

      return_event =
        choose(socket.assigns[:requested_return], settings, event_names) || start_event

      periods =
        if start_event do
          %{periods: periods} =
            Queries.retention(
              scope,
              range,
              start_event,
              return_event,
              Keyword.put(opts, :granularity, socket.assigns.granularity)
            )

          periods
        else
          []
        end

      [
        event_names: event_names,
        granularities: @granularities,
        start_event: start_event,
        return_event: return_event,
        periods: periods
      ]
    end)
  end

  # The URL wins, then the project's activation event, then the most common
  # event. A screen that opened on nothing would make the reader configure
  # before it could show anything.
  defp choose(requested, settings, event_names) do
    cond do
      requested in event_names -> requested
      settings && settings.activation_event in event_names -> settings.activation_event
      true -> List.first(event_names)
    end
  end

  defp patch(socket, overrides) do
    params =
      %{
        "window" => socket.assigns.window,
        "source" => socket.assigns.source_id,
        "start_event" => socket.assigns.start_event,
        "return_event" => socket.assigns.return_event,
        "granularity" => socket.assigns.granularity
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    push_patch(socket, to: Context.path(socket.assigns, "/retention", params))
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
