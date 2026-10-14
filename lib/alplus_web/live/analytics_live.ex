defmodule AlplusWeb.AnalyticsLive do
  @moduledoc """
  The product-analytics overview for one project.

  Four readings, the event-activity chart, the primary funnel, and the top
  events. Nothing else: a reader should learn whether people are getting
  through the product without studying the screen.

  Before the first event arrives the whole screen is the first-run state:
  the endpoint, the write key, and one command to paste.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.AnalyticsComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DashboardComponents

  alias Alplus.Analytics.{Queries, RetentionPolicy}
  alias AlplusWeb.Analytics.Context

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket), do: Context.mount(params, socket, "Analytics")

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Context.put_window(params) |> Context.put_source(params) |> load()}
  end

  @impl true
  def handle_event("retry_analytics", _params, socket), do: {:noreply, load(socket)}

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, patch(socket, %{"window" => Queries.valid_window(window)})}
  end

  def handle_event("pick_app", %{"source" => source}, socket) do
    {:noreply, patch(socket, %{"source" => source})}
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
      window={@has_events? && @window}
      windows={Queries.windows()}
    >
      <.console_page id="analytics-page">
        <:title>{headline(assigns)}</:title>

        <.app_select
          :if={not @loading? and not @load_failed? and @has_events?}
          sources={@analytics_sources}
          source_id={@source_id}
        />

        <.error_boundary :if={@load_failed?} id="analytics-error" retry="retry_analytics">
          Could not load analytics. Nothing is estimated while the read is failing.
        </.error_boundary>

        <div :if={@loading?} id="analytics-loading" role="status" aria-live="polite">
          <span class="sr-only">Loading analytics.</span>
          <.skeleton rows={4} />
        </div>

        <.analytics_first_run
          :if={not @loading? and not @load_failed? and not @has_events?}
          id="analytics-first-run"
          endpoint={@endpoint_url}
          source={List.first(@sources)}
          agent_state={@agent_state}
          connect_href={
            ~p"/dashboard/orgs/#{@org.public_token}/projects/#{@project.public_token}/connect"
          }
        />

        <div :if={not @loading? and not @load_failed? and @has_events?} class="grid gap-6">
          <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <.stat_card
              label="Users"
              value={count(@totals.users)}
              definition={users_help()}
              hint={change_hint(@totals.users, @previous_totals.users, :count)}
            />
            <.stat_card
              label="Events"
              value={count(@totals.events)}
              hint={change_hint(@totals.events, @previous_totals.events, :count)}
            />
            <.stat_card
              label="Activation"
              value={activation_value(@activation)}
              definition={activation_definition(@activation)}
              hint={activation_hint(@activation, @previous_activation)}
              placeholder={is_nil(@activation)}
            />
            <.stat_card
              label="D7 retention"
              value={retention_value(@retention)}
              definition="Of the people who did the activation event, how many did it again on day 7."
              hint={retention_hint(@activation)}
              placeholder={is_nil(@retention)}
            />
          </div>

          <.data_panel id="analytics-activity" title="Event activity" padded>
            <.activity_chart
              id="analytics-activity-chart"
              series={@series}
              window={@window}
              metric={:events}
            />
            <:footer>
              Events are kept for {RetentionPolicy.retention_days()} days. Every date and time on
              this screen is UTC.
            </:footer>
          </.data_panel>

          <.data_panel
            :if={@primary_funnel}
            id="analytics-primary-funnel"
            title={@primary_funnel.name}
            description="The funnel this project set as its primary."
            padded
          >
            <:actions>
              <.link navigate={Context.path(assigns, "/funnels")} class="text-label text-text-link">
                All funnels
              </.link>
            </:actions>
            <.funnel_steps id="analytics-primary-funnel-steps" entry={@primary_funnel.entry} />
          </.data_panel>

          <.data_panel id="analytics-top-events" title="Top events">
            <:actions>
              <.link navigate={Context.path(assigns, "/events")} class="text-label text-text-link">
                All events
              </.link>
            </:actions>
            <table class="w-full min-w-0 table-fixed">
              <caption class="sr-only">Top events in the {window_words(@window)}</caption>
              <thead>
                <tr class="border-b border-border-default text-left text-caption text-text-tertiary">
                  <th scope="col" class="px-5 py-2 font-normal">Event</th>
                  <th scope="col" class="w-28 px-5 py-2 text-right font-normal">Events</th>
                  <th scope="col" class="w-28 px-5 py-2 text-right font-normal">Users</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border-subtle">
                <tr :for={event <- @top_events}>
                  <td class="min-w-0 px-5 py-2.5">
                    <.link
                      navigate={Context.path(assigns, "/events/#{URI.encode(event.event_name)}")}
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
                </tr>
              </tbody>
            </table>
            <:footer>{users_help()}</:footer>
          </.data_panel>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  attr :id, :string, required: true
  attr :endpoint, :string, required: true
  attr :source, :any, default: nil
  attr :agent_state, :atom, default: nil
  attr :connect_href, :string, required: true

  @doc false
  def analytics_first_run(assigns) do
    ~H"""
    <div id={@id} class="grid gap-4">
      <.data_panel
        id={"#{@id}-panel"}
        title="Start sending analytics events"
        description="Send one event from your application. It appears here within seconds."
        padded
      >
        <div :if={@source} class="grid gap-3">
          <p class="text-body text-text-secondary">
            Your write key starts with <span class="font-mono">pda_{@source.secret_prefix}</span>. It was shown once, when the
            key was created. Ask your agent to rotate it if you no longer have it.
          </p>
          <pre class="overflow-x-auto rounded-control border border-border-control bg-surface-sunken p-4 font-mono text-data text-text-primary"><code>{curl_example(@endpoint)}</code></pre>
          <p class="text-caption text-text-secondary">
            Waiting for your first event. This screen fills in as soon as one arrives.
          </p>
        </div>

        <div :if={is_nil(@source)} class="grid gap-3">
          <p class="text-body text-text-secondary">
            This project has no analytics write key yet. Ask your connected agent to create one, then
            paste the command it gives you.
          </p>
          <pre class="overflow-x-auto rounded-control border border-border-control bg-surface-sunken p-4 font-mono text-data text-text-primary"><code>Create a product analytics source named iOS app for this project, and show me the write key.</code></pre>
        </div>

        <:footer>
          Send behaviour, never personal data. Keep names, email addresses, phone numbers, message
          content, health data and payment details out of event names, identifiers and properties.
        </:footer>
      </.data_panel>

      <.first_run_card
        :if={is_nil(@source)}
        id={"#{@id}-connect"}
        title="Connect an agent"
        description="Analytics is configured through MCP, like every other part of a project."
        state={@agent_state}
        task="Create a product analytics source for this project and show me the write key."
        action_href={@connect_href}
      />
    </div>
    """
  end

  defp curl_example(endpoint) do
    """
    curl #{endpoint}/v1/events \\
      -H "Authorization: Bearer pda_YOUR_WRITE_KEY" \\
      -H "Content-Type: application/json" \\
      -d '{
        "event": "onboarding_completed",
        "distinct_id": "anon_123"
      }'\
    """
  end

  # ---- Loading --------------------------------------------------------

  defp load(socket) do
    Context.load(socket, fn ->
      scope = socket.assigns.project_scope
      window = socket.assigns.window
      range = Queries.range(window)

      previous_range = Queries.previous_range(window)
      opts = Context.read_opts(socket)
      totals = Queries.totals(scope, range, opts)
      settings = Context.settings(scope)
      top_events = Queries.list_events(scope, range, Keyword.put(opts, :limit, 8))
      latest = Queries.latest_event(scope)

      [
        sources: socket.assigns.analytics_sources,
        has_events?: not is_nil(latest),
        totals: totals,
        previous_totals: Queries.totals(scope, previous_range, opts),
        activation: Queries.activation(scope, range, settings, opts),
        previous_activation: Queries.activation(scope, previous_range, settings, opts),
        retention: day_seven_retention(scope, range, settings, opts),
        series:
          Queries.time_series(
            scope,
            range,
            Keyword.put(opts, :interval, Queries.interval_for(window))
          ),
        top_events: top_events,
        primary_funnel: primary_funnel(scope, range, settings, opts),
        agent_state: AlplusWeb.AgentConnection.state(scope),
        endpoint_url: AlplusWeb.Endpoint.url()
      ]
    end)
  end

  # D7 retention answers "do the people who reached the core action come
  # back a week later". The activation event is that action, so retention
  # is only offered once the project has named it.
  defp day_seven_retention(_scope, _range, nil, _opts), do: nil

  defp day_seven_retention(_scope, _range, %{activation_event: nil}, _opts), do: nil

  defp day_seven_retention(scope, range, settings, opts) do
    %{periods: periods} =
      Queries.retention(scope, range, settings.activation_event, settings.activation_event, opts)

    Enum.find(periods, &(&1.period == 7))
  end

  defp primary_funnel(_scope, _range, nil, _opts), do: nil
  defp primary_funnel(_scope, _range, %{primary_funnel_id: nil}, _opts), do: nil

  defp primary_funnel(scope, range, settings, opts) do
    case Ash.get(Alplus.Analytics.Funnel, settings.primary_funnel_id, actor: scope) do
      {:ok, funnel} ->
        case Queries.funnel(
               scope,
               range,
               funnel.steps,
               opts ++ [window_hours: funnel.window_hours, filters: funnel.filters]
             ) do
          [entry | _rest] -> %{name: funnel.name, entry: Queries.with_conversions(entry)}
          [] -> nil
        end

      _error ->
        nil
    end
  end

  defp patch(socket, overrides) do
    params =
      %{"window" => socket.assigns.window, "source" => socket.assigns.source_id}
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    push_patch(socket, to: Context.path(socket.assigns, "", params))
  end

  # ---- Copy -----------------------------------------------------------

  defp headline(%{loading?: true}), do: "Analytics"
  defp headline(%{load_failed?: true}), do: "Analytics"
  defp headline(%{has_events?: false}), do: "Start sending analytics events"

  defp headline(assigns) do
    users = assigns.totals.users
    "#{count(users)} #{user_word(users)} in the #{window_words(assigns.window)}"
  end

  defp user_word(1), do: "user"
  defp user_word(_count), do: "users"

  defp activation_value(nil), do: "Not set"
  defp activation_value(%{rate: rate}), do: percent(rate)

  defp activation_definition(nil),
    do: "Ask your agent to set a starting event and an activation event."

  defp activation_definition(%{start_event: start_event, activation_event: event}),
    do: "Of the people who did #{start_event}, how many went on to do #{event}."

  # The comparison is the equal-length period immediately before this one, so
  # a reader sees a direction rather than one number with no context.
  defp change_hint(_current, 0, :count), do: "Nothing in the period before"
  defp change_hint(_current, nil, :count), do: "No period before to compare"

  defp change_hint(current, current, :count), do: "No change on the period before"

  defp change_hint(current, previous, :count) do
    change = (current - previous) * 100 / previous
    "#{signed(change)}% on the period before"
  end

  defp signed(value) when value >= 0,
    do: "+" <> :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp signed(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp activation_hint(nil, _previous), do: "No activation event"

  # A rate is compared in percentage points, never in percent. "Up 5%" and
  # "up 5 percentage points" are different claims, and only one of them is
  # what a reader means by a conversion rate moving.
  defp activation_hint(%{started: started, rate: rate}, %{rate: previous})
       when is_number(rate) and is_number(previous) do
    "#{count(started)} started, #{signed(rate - previous)} percentage points on the period before"
  end

  defp activation_hint(%{started: started}, _previous), do: "#{count(started)} started"

  defp retention_value(nil), do: "Not set"
  defp retention_value(%{rate: rate}), do: percent(rate)

  defp retention_hint(nil), do: "Needs an activation event"
  defp retention_hint(_activation), do: "Day 7, exact day"
end
