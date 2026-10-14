defmodule AlplusWeb.ProjectLive do
  @moduledoc """
  The project overview: one cell per pillar — monitors, issues, traffic — read
  over the same range, and the few facts that need the operator's attention.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.ConsoleComponents, only: [console_page: 1]
  import AlplusWeb.DashboardComponents
  import AlplusWeb.DataDisplayComponents
  import AlplusWeb.MonitorActivityComponents, only: [monitor_timeline: 1]
  import AlplusWeb.MeasureActivityComponents, only: [traffic_trend: 1]
  import AlplusWeb.Format, only: [window_axis: 1]

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  @empty_trend %{state: :empty, points: [], unavailable?: false}

  @empty_summary %{
    monitors: %{total: 0, up: 0, down: 0, degraded: 0, unknown: 0},
    uptime: nil,
    issues_open: 0,
    pageviews: nil,
    measure_installed?: false,
    monitor: %{
      state: :empty,
      unavailable?: false,
      monitors: %{total: 0, up: 0, down: 0, degraded: 0, unknown: 0, unavailable?: false},
      uptime: nil,
      trend: @empty_trend
    },
    observe: %{
      state: :empty,
      unavailable?: false,
      issues_open: 0,
      latest_release: nil,
      trend: @empty_trend
    },
    measure: %{
      state: :empty,
      unavailable?: false,
      installed?: false,
      pageviews: nil,
      trend: @empty_trend
    },
    monitor_trend: @empty_trend,
    observe_trend: @empty_trend,
    measure_trend: @empty_trend
  }

  @impl true
  def mount(
        %{"org_token" => _org_token, "project_token" => _project_token},
        _session,
        %{assigns: %{current_user: %{confirmed_at: nil}}} = socket
      ) do
    {:ok,
     socket
     |> put_flash(:info, "Confirm your email before viewing project analysis.")
     |> push_navigate(to: ~p"/dashboard")}
  end

  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Project", active: :projects) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      socket =
        socket
        |> assign(:project, project)
        |> assign(:summary, @empty_summary)
        |> assign(:window, AlplusWeb.ProjectSignals.default_window())
        |> assign(:loading, true)

      {:ok, socket}
    end
  end

  # The time range lives in the query string, like every sibling screen, so a
  # reload or a shared link keeps the range the reader chose.
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:window, valid_window(params["window"]))

    socket = if connected?(socket), do: load_summary(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_signals", _params, socket) do
    {:noreply, load_summary(socket)}
  end

  # The page header's time range. Every pillar on this screen is read over the
  # same window, so switching it re-reads all three rather than re-labelling a
  # chart that was loaded over a different period. It routes through the URL,
  # so `handle_params/3` does the re-read in one place.
  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply,
     push_patch(socket,
       to: overview_path(socket.assigns, valid_window(window))
     )}
  end

  # The sidebar no longer lists every sibling project (design system v3 §04:
  # a flat, single-project nav); the topbar's `project_select/1` is now the
  # only project switcher, so the hub needs its own handler for the same
  # event `MonitorLive`/`ObserveLive` already implement.
  def handle_event("pick_project", %{"project_id" => project_id}, socket)
      when is_binary(project_id) do
    case Enum.find(socket.assigns.nav_projects, &(&1.id == project_id)) do
      nil ->
        {:noreply, socket}

      project ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/dashboard/orgs/#{socket.assigns.org_token}/projects/#{project.public_token}"
         )}
    end
  end

  def handle_event("pick_project", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :attention_items,
        if(assigns.loading,
          do: [],
          else: attention_items(assigns.summary, assigns.org, assigns.project)
        )
      )

    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:projects}
      page_title="Overview"
      page_heading?={false}
      nav_project={@project}
      nav_projects={@nav_projects}
      project_scoped={true}
      projects={@nav_projects}
      project={@project}
      window={@window}
    >
      <.console_page id="project-page">
        <:title>{if @loading, do: "Overview", else: hub_headline(@summary)}</:title>
        <section id="project-hub" class="min-w-0">
          <div :if={@loading} id="project-hub-loading" class="space-y-3">
            <.skeleton rows={4} />
          </div>

          <div :if={not @loading} id="project-hub-content" class="flex min-w-0 flex-col gap-4">
            <p id="project-hub-status" role="status" class="sr-only">{hub_status(@summary)}</p>
            <p id="project-hub-summary" class="sr-only">{hub_headline(@summary)}</p>

            <%!-- The exceptions the headline names, as the links that open
                  them. One row, not a second panel restating the h1. --%>
            <ul
              :if={@attention_items != []}
              id="project-attention"
              class="flex flex-wrap items-center gap-x-6 gap-y-2"
              aria-label="Needs attention"
            >
              <li
                :for={item <- @attention_items}
                id={"project-attention-#{item.key}"}
                class="flex min-w-0 items-center gap-2"
              >
                <span class={["size-2 shrink-0 rounded-dot", item.dot]} aria-hidden="true" />
                <.link
                  navigate={item.path}
                  class="inline-flex h-control-md items-center gap-1 text-body font-medium text-text-primary hover:text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  <span class="sr-only">{item.state}, </span>{item.action}
                </.link>
              </li>
            </ul>

            <%!-- One cell per pillar, read over the same range: is it up, is
                  it erroring, is anyone using it. The fleet strip leads and
                  takes the width its one tick per bucket needs; errors and
                  traffic answer their own question beside each other. --%>
            <div
              id="project-signals"
              class="grid min-w-0 items-start gap-4 lg:grid-cols-12"
              aria-label="Project signals"
            >
              <section
                id="project-signal-monitor"
                class="min-w-0 overflow-hidden rounded-frame border border-border-public bg-surface-raised shadow-frame lg:col-span-12"
                aria-labelledby="project-signal-monitor-heading"
              >
                <div class="flex flex-wrap items-baseline justify-between gap-3 p-5 pb-0">
                  <h2
                    id="project-signal-monitor-heading"
                    class="text-heading-03 font-semibold text-text-primary"
                  >
                    Monitors
                  </h2>
                  <p
                    id="project-signal-monitor-value"
                    class={[
                      "text-metric-compact font-semibold tabular-nums",
                      monitor_value_class(@summary)
                    ]}
                  >
                    {monitor_headline(@summary)}
                  </p>
                </div>
                <div class="min-w-0 overflow-hidden p-5">
                  <.monitor_timeline
                    id="project-monitor-timeline"
                    buckets={@summary.monitor_trend.points}
                    range={@window}
                    variant={:full}
                    scope={:fleet}
                    legend={true}
                    table={:assistive}
                  />
                </div>
                <.signal_link
                  id="project-signal-monitor-link"
                  path={signal_path(@org, @project, :monitor)}
                  label="All monitors"
                />
              </section>

              <section
                id="project-signal-issues"
                class="min-w-0 overflow-hidden rounded-structural border border-border-default bg-surface-raised lg:col-span-6"
                aria-labelledby="project-signal-issues-heading"
              >
                <div class="flex flex-wrap items-baseline justify-between gap-3 p-5 pb-0">
                  <h2
                    id="project-signal-issues-heading"
                    class="text-heading-03 font-semibold text-text-primary"
                  >
                    Issues
                  </h2>
                  <p
                    id="project-signal-issues-value"
                    class={[
                      "text-metric-compact font-semibold tabular-nums",
                      issues_value_class(@summary)
                    ]}
                  >
                    {issues_headline(@summary)}
                  </p>
                </div>
                <div class="min-w-0 overflow-hidden p-5">
                  <.data_display
                    id="project-issues-chart"
                    title={signal_title("issues", @window)}
                    heading={:assistive}
                    kind={:bucket_bar}
                    variant={:full}
                    plot_height={:standard}
                    state={signal_state("issues", @summary)}
                    data={normalize_bars(@summary.observe_trend.points)}
                    unit="errors"
                    range={window_axis(@window)}
                    annotations={signal_annotations("issues", @summary)}
                    table={:assistive}
                    table_columns={["Day", "Errors"]}
                    empty_label={signal_empty_label("issues", @window)}
                    retry_event="retry_signals"
                  />
                </div>
                <.signal_link
                  id="project-signal-issues-link"
                  path={signal_path(@org, @project, :observe)}
                  label="All issues"
                />
              </section>

              <section
                id="project-signal-traffic"
                class="min-w-0 overflow-hidden rounded-structural border border-border-default bg-surface-raised lg:col-span-6"
                aria-labelledby="project-signal-traffic-heading"
              >
                <div class="flex flex-wrap items-baseline justify-between gap-3 p-5 pb-0">
                  <h2
                    id="project-signal-traffic-heading"
                    class="text-heading-03 font-semibold text-text-primary"
                  >
                    Traffic
                  </h2>
                  <p
                    id="project-signal-traffic-value"
                    class="text-metric-compact font-semibold tabular-nums text-text-primary"
                  >
                    {traffic_headline(@summary)}
                  </p>
                </div>
                <div class="min-w-0 overflow-hidden p-5">
                  <.traffic_trend
                    id="project-traffic-trend"
                    points={@summary.measure_trend.points}
                    metric="pageviews"
                    range={@window}
                    variant={:full}
                    plot_height={:standard}
                    coverage={Map.get(@summary.measure, :coverage)}
                    state={signal_state("traffic", @summary)}
                    retry="retry_signals"
                  />
                </div>
                <.signal_link
                  id="project-signal-traffic-link"
                  path={signal_path(@org, @project, :measure)}
                  label="All traffic"
                />
              </section>
            </div>
          </div>
        </section>
      </.console_page>
    </.dashboard_shell>
    """
  end

  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true

  # Every cell ends the same way: the screen that holds the whole of what the
  # cell summarised. The link is the cell's footer strip, not a button.
  defp signal_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      id={@id}
      class="flex h-control-lg items-center border-t border-border-default px-5 text-body font-medium text-text-secondary transition-colors duration-productive ease-productive hover:bg-surface-sunken hover:text-text-primary focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
    >
      {@label}
    </.link>
    """
  end

  # ---- Cell headlines -------------------------------------------------------

  # Each cell states its own answer above its plot. Nothing is inferred: a
  # signal the loader could not read says so rather than reading as a zero.
  defp monitor_headline(%{monitor: %{state: :unavailable}}), do: "Unavailable"
  defp monitor_headline(%{monitors: %{total: 0}}), do: "No checks yet"

  defp monitor_headline(%{monitors: %{down: down, total: total}})
       when is_integer(down) and down > 0,
       do: "#{down} of #{total} down"

  defp monitor_headline(%{monitors: %{degraded: degraded, total: total}})
       when is_integer(degraded) and degraded > 0,
       do: "#{degraded} of #{total} degraded"

  defp monitor_headline(%{uptime: nil}), do: "Awaiting checks"

  defp monitor_headline(%{uptime: uptime}),
    do: "#{AlplusWeb.ProjectSignals.uptime_label(uptime)} up"

  defp monitor_value_class(%{monitors: %{down: down}}) when is_integer(down) and down > 0,
    do: "text-status-error-ink"

  defp monitor_value_class(%{monitors: %{degraded: degraded}})
       when is_integer(degraded) and degraded > 0,
       do: "text-status-late-ink"

  defp monitor_value_class(_summary), do: "text-text-primary"

  defp issues_headline(%{observe: %{state: :unavailable}}), do: "Unavailable"
  defp issues_headline(%{issues_open: 0}), do: "None open"

  defp issues_headline(%{issues_open: open}) when is_integer(open),
    do: "#{open} open"

  defp issues_headline(_summary), do: "Unavailable"

  defp issues_value_class(%{issues_open: open}) when is_integer(open) and open > 0,
    do: "text-status-late-ink"

  defp issues_value_class(_summary), do: "text-text-primary"

  defp traffic_headline(%{measure: %{state: :unavailable}}), do: "Unavailable"
  defp traffic_headline(%{measure_installed?: false}), do: "Not connected"
  defp traffic_headline(%{pageviews: nil}), do: "No traffic yet"

  defp traffic_headline(%{pageviews: pageviews}),
    do: "#{AlplusWeb.Marketing.PackagePresenter.thousands(pageviews)} views"

  defp signal_label("issues"), do: "Issues"

  defp signal_title(signal, window), do: "#{signal_label(signal)}, last #{range_words(window)}"

  defp signal_state(signal, summary) do
    case signal_trend(signal, summary).state do
      :available -> :ready
      :unavailable -> :unavailable
      _state -> :empty
    end
  end

  defp signal_trend("monitor", summary), do: summary.monitor_trend
  defp signal_trend("issues", summary), do: summary.observe_trend
  defp signal_trend("traffic", summary), do: summary.measure_trend

  defp normalize_bars([]), do: []

  defp normalize_bars(points) do
    maximum = points |> Enum.map(&Map.get(&1, :value, 0)) |> Enum.max(fn -> 0 end)

    Enum.map(points, fn point ->
      Map.put(point, :height, if(maximum > 0, do: point.value / maximum * 100, else: 2))
    end)
  end

  defp signal_empty_label(signal, window),
    do: "No #{String.downcase(signal_label(signal))} data in the last #{range_words(window)}."

  defp signal_annotations("issues", %{observe: %{latest_release: marker}, observe_trend: trend})
       when not is_nil(marker),
       do: deploy_annotation(marker, trend.points)

  defp signal_annotations(_signal, _summary), do: []

  defp deploy_annotation(marker, [first | _] = points) do
    last = List.last(points)
    first_at = Alplus.Observe.Dashboard.bucket_start(first.bucket)
    span = DateTime.diff(Alplus.Observe.Dashboard.bucket_end(last.bucket), first_at, :second)
    offset = DateTime.diff(marker.released_at, first_at, :second)

    cond do
      offset < 0 or offset > span -> []
      span == 0 -> [%{label: marker.version, position: 50.0}]
      true -> [%{label: marker.version, position: offset / span * 100}]
    end
  end

  defp deploy_annotation(_marker, _points), do: []

  defp range_words("24h"), do: "24 hours"
  defp range_words("7d"), do: "7 days"
  defp range_words("30d"), do: "30 days"
  defp range_words(window), do: window

  # ---- Needs attention ------------------------------------------------------

  # Only facts the loader actually returned. Nothing here is inferred, and a
  # signal that failed to load says so instead of reading as a healthy zero.
  defp attention_items(summary, org, project) do
    monitor_path = signal_path(org, project, :monitor)
    observe_path = signal_path(org, project, :observe)

    []
    |> maybe_down(summary, monitor_path)
    |> maybe_issues(summary, observe_path)
    |> maybe_unavailable(summary, monitor_path)
    |> Enum.reverse()
  end

  defp maybe_down(items, %{monitors: %{down: down}}, path)
       when is_integer(down) and down > 0 do
    [
      %{
        key: "monitors-down",
        dot: "bg-status-error",
        state: "Down",
        title: "#{down} #{plural(down, "monitor")} #{plural_verb(down)} down",
        action: "Open monitors",
        path: path
      }
      | items
    ]
  end

  defp maybe_down(items, %{monitors: %{unknown: unknown, down: down}}, path)
       when is_integer(unknown) and unknown > 0 and down in [0, nil] do
    [
      %{
        key: "monitors-unknown",
        dot: "bg-status-neutral",
        state: "No data",
        title:
          "#{unknown} #{plural(unknown, "monitor")} #{plural_verb(unknown, "has")} no recent checks",
        action: "Open monitors",
        path: path
      }
      | items
    ]
  end

  defp maybe_down(items, _summary, _path), do: items

  defp maybe_issues(items, %{issues_open: open}, path) when is_integer(open) and open > 0 do
    [
      %{
        key: "open-issues",
        dot: "bg-status-late",
        state: "Open",
        title: "#{open} open #{plural(open, "issue")}",
        action: "Open issues",
        path: path
      }
      | items
    ]
  end

  defp maybe_issues(items, _summary, _path), do: items

  defp maybe_unavailable(items, summary, path) do
    if Enum.any?([summary.monitor, summary.observe, summary.measure], &(&1.state == :unavailable)) do
      [
        %{
          key: "signals-unavailable",
          dot: "bg-status-neutral",
          state: "Unavailable",
          title: "Some signals could not be loaded",
          action: "Review signals",
          path: path
        }
        | items
      ]
    else
      items
    end
  end

  # The org is nil only while the shell is still resolving it, and a cell
  # footer renders before that resolves.
  defp signal_path(nil, _project, _feature), do: "#"

  defp signal_path(org, project, feature),
    do: feature_path(org.public_token, project.public_token, feature)

  defp plural_verb(count, singular \\ "is")
  defp plural_verb(1, "is"), do: "is"
  defp plural_verb(1, "has"), do: "has"
  defp plural_verb(_, "is"), do: "are"
  defp plural_verb(_, "has"), do: "have"

  # One sentence that answers "what is happening right now", in the order the
  # operator cares about. Nothing here is inferred: each clause is a value the
  # loader returned.
  defp hub_headline(%{monitor: %{state: :unavailable}}), do: "Some signals could not be loaded."
  defp hub_headline(%{observe: %{state: :unavailable}}), do: "Some signals could not be loaded."
  defp hub_headline(%{measure: %{state: :unavailable}}), do: "Some signals could not be loaded."

  # A project with no monitors has no uptime evidence, so this clause comes
  # before every other one: without a check running, the page cannot say
  # everything is up.
  defp hub_headline(%{monitors: %{total: 0}}), do: "Ready for your first check."

  # The headline and the strip read the same normalized bucket, so a mixed
  # fleet states its ratio, and monitors without recent checks are named as
  # incomplete rather than folded into "up".
  defp hub_headline(%{monitors: %{down: down, total: total}} = summary)
       when is_integer(down) and down > 0,
       do:
         "#{down} of #{total} #{plural(total, "monitor")} #{plural_verb(down)} down." <>
           issues_clause(summary)

  defp hub_headline(%{monitors: %{degraded: degraded, total: total}} = summary)
       when is_integer(degraded) and degraded > 0,
       do:
         "#{degraded} of #{total} #{plural(total, "monitor")} #{plural_verb(degraded)} degraded." <>
           issues_clause(summary)

  defp hub_headline(%{monitors: %{unknown: unknown}} = summary)
       when is_integer(unknown) and unknown > 0,
       do: "Monitor status is incomplete." <> issues_clause(summary)

  defp hub_headline(%{issues_open: issues} = summary) when is_integer(issues) and issues > 0,
    do: "Everything is up." <> issues_clause(summary)

  defp hub_headline(_summary), do: "Everything is up. Nothing needs you."

  defp issues_clause(%{issues_open: issues}) when is_integer(issues) and issues > 0,
    do: " #{issues} #{plural(issues, "issue")} #{plural_verb(issues)} open."

  defp issues_clause(_summary), do: ""
  defp hub_status(%{monitor: %{state: :unavailable}}), do: "Some project signals are unavailable."
  defp hub_status(%{observe: %{state: :unavailable}}), do: "Some project signals are unavailable."
  defp hub_status(%{measure: %{state: :unavailable}}), do: "Some project signals are unavailable."

  defp hub_status(%{
         monitor: %{state: :empty},
         observe: %{state: :empty},
         measure: %{state: :empty}
       }),
       do: "No project signals are available yet."

  defp hub_status(_summary), do: "Project signals are available."

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp valid_window(window) do
    if window in AlplusWeb.ProjectSignals.windows(),
      do: window,
      else: AlplusWeb.ProjectSignals.default_window()
  end

  defp overview_path(assigns, window) do
    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}?#{%{"window" => window}}"
  end

  defp load_summary(socket) do
    summary =
      AlplusWeb.ProjectSignals.load(
        socket.assigns.project,
        socket.assigns.scope,
        socket.assigns.window
      )

    socket
    |> assign(:summary, summary)
    |> assign(:loading, false)
  end

  defp feature_path(org_token, project_token, :monitor),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/monitor"

  defp feature_path(org_token, project_token, :measure),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/measure"

  defp feature_path(org_token, project_token, :observe),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project_token}/observe"
end
