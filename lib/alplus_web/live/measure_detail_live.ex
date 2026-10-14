defmodule AlplusWeb.MeasureDetailLive do
  @moduledoc """
  Analysis-only detail view for one Measure Source.

  The page is one hero chart and the minimum around it: four readings that
  are also the metric selector, one change line when the preceding period is
  comparable, one coverage caption when coverage is short, and under the
  chart the two breakdowns a reader opens this page for, what people looked
  at and who sent them. Events joins them only when this project has any
  configured.

  Source credentials, installation snippets, lifecycle controls, and share
  mutation forms never render here.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.DashboardComponents
  import AlplusWeb.ConsoleComponents
  import AlplusWeb.MeasureActivityComponents
  import AlplusWeb.Format, only: [window_words: 1]

  alias Alplus.Measure.{Dashboard, SourceOverview}
  alias Alplus.Observe.DeploymentCorrelation
  alias Alplus.Sources.Source

  on_mount {AlplusWeb.LiveUserAuth, :live_user_required}

  # Exactly the three ranges the window control offers. A deep link to a range
  # with no button reaches a display grid nothing on this screen describes, so
  # an unknown window falls back to the default rather than being honoured.
  @windows ~w(24h 7d 30d)
  @metrics ~w(visits pageviews bounce_rate avg_duration)
  @data_reuse_ms 30_000
  @panel_dimensions %{pages: "path", sources: "referrer", events: "event"}

  @impl true
  def mount(%{"org_token" => org_token, "project_token" => project_token}, _session, socket) do
    with {:ok, socket} <-
           AlplusWeb.OrgContext.mount(org_token, socket, page_title: "Traffic", active: :measure) do
      project = AlplusWeb.OrgContext.project_for_token!(socket, project_token)

      {:ok,
       assign(socket,
         projects: [project],
         project: project,
         source: nil,
         loading?: true,
         data_loaded_at: nil,
         source_overview: nil,
         window: "24h",
         metric: "visits",
         panel_pages: default_panel_pages(),
         panels: %{},
         events_configured?: false,
         analytics_unavailable?: false,
         analytics_engine_partial?: false,
         traffic_state: :waiting,
         summary: empty_summary(),
         comparison: empty_comparison(),
         load_failed?: false
       )}
    end
  end

  @impl true
  def handle_params(%{"source_id" => source_id} = params, _uri, socket) do
    project = socket.assigns.project
    project_scope = project_scope(socket, project)

    case Ash.get(Source, source_id, actor: project_scope) do
      {:ok, %Source{type: :measure} = source} ->
        window = valid_window(params["window"])
        previous_pages = socket.assigns.panel_pages
        reuse? = reusable_data?(socket, source, window)

        socket =
          socket
          |> assign(:source, source)
          |> assign(:window, window)
          |> assign(:metric, selected_metric(params))
          |> assign(:panel_pages, panel_pages(params))

        {:noreply,
         if(reuse?,
           do: load_changed_panels(socket, previous_pages),
           else: load_detail_data(socket)
         )}

      _ ->
        raise AlplusWeb.NotFoundError
    end
  end

  @impl true
  def handle_event("retry_measure", _params, socket) do
    {:noreply, load_detail_data(socket)}
  end

  def handle_event("pick_window", %{"window" => window}, socket) do
    {:noreply, push_patch(socket, to: detail_path(socket, %{"window" => valid_window(window)}))}
  end

  @impl true
  def render(assigns) do
    # Both maps address one source, so they exist exactly when it does. The
    # markup that reads them is inside the same `@source` guard.
    assigns =
      if assigns.source && assigns.source_overview do
        assigns
        |> assign(:metric_hrefs, metric_hrefs(assigns))
        |> assign(:panel_hrefs, panel_hrefs(assigns))
        |> assign(:empty_label, empty_label(assigns))
        |> assign(:caption, caption(assigns))
      else
        assign(assigns,
          metric_hrefs: %{},
          panel_hrefs: %{},
          empty_label: nil,
          caption: nil
        )
      end

    ~H"""
    <.dashboard_shell
      agent_connected?={@agent_connected?}
      flash={@flash}
      org={@org}
      organizations={@organizations}
      scope={@scope}
      current_user={@current_user}
      active={:measure}
      nav_project={@project}
      nav_projects={@nav_projects}
      project_scoped={false}
      page_heading?={false}
      window={@source && @window}
    >
      <.console_page id="measure-detail-page">
        <:title>{if @source, do: @source.name, else: "Traffic"}</:title>
        <div
          :if={@loading?}
          id="measure-detail-loading"
          role="status"
          aria-live="polite"
          class="grid gap-3 rounded-structural border border-border-default bg-surface-raised p-4"
        >
          <span class="sr-only">Loading traffic.</span>
          <.skeleton rows={3} />
        </div>

        <.error_boundary :if={@load_failed?} id="measure-detail-error" retry="retry_measure">
          Could not load traffic for this site.
        </.error_boundary>

        <div
          :if={not @load_failed? and not is_nil(@source) and not is_nil(@source_overview)}
          class="grid min-w-0 gap-6"
        >
          <section
            id={"measure-panel-#{@source.id}"}
            class={[
              "min-w-0 overflow-hidden rounded-frame border border-border-public bg-surface-raised shadow-frame",
              @source.status == :revoked && "opacity-75 grayscale"
            ]}
            aria-label={@source.name}
          >
            <div class="flex flex-wrap items-center justify-between gap-3 border-b border-border-default px-5 py-3.5">
              <p
                id="measure-detail-hostname"
                class="min-w-0 truncate font-mono text-data text-text-tertiary"
              >
                {@source_overview.identity.hostname || "No domain configured"}, {@source.environment}, last {window_words(
                  @window
                )}
              </p>
            </div>

            <.measure_metric_strip
              headlines={@comparison.headlines}
              metric={@metric}
              hrefs={@metric_hrefs}
              points={comparison_points(@comparison)}
            />

            <.measure_comparison_chart
              source={@source}
              series={@comparison}
              window={@window}
              metric={@metric}
              markers={@summary.release_markers}
              empty_label={@empty_label}
              state={if(@traffic_state == :waiting, do: :empty)}
            />

            <p
              :if={@caption}
              id="measure-detail-caption"
              class="border-t border-border-subtle px-5 py-3 text-center font-mono text-data text-text-tertiary"
            >
              {@caption}
            </p>
          </section>

          <div
            id="measure-detail-breakdown-grid"
            class="grid min-w-0 items-start gap-4 md:grid-cols-12"
          >
            <.measure_breakdown_panel
              id="measure-panel-pages"
              title="Top pages"
              data={@panels.pages}
              page_hrefs={@panel_hrefs.pages}
              class="min-w-0 md:col-span-6"
            />
            <.measure_breakdown_panel
              id="measure-panel-sources"
              title="Referrers"
              data={@panels.sources}
              page_hrefs={@panel_hrefs.sources}
              favicons?={true}
              class="min-w-0 md:col-span-6"
            />
            <.measure_breakdown_panel
              :if={events_worth_showing?(@panels.events, @events_configured?)}
              id="measure-panel-events"
              title="Events"
              data={@panels.events}
              page_hrefs={@panel_hrefs.events}
              empty_sentence={events_empty_sentence(@events_configured?)}
              class="min-w-0 md:col-span-12"
            />
          </div>
        </div>
      </.console_page>
    </.dashboard_shell>
    """
  end

  # An Events panel on a project that has never configured a custom event is a
  # promise of a report nobody asked for. Once one is configured the panel is
  # part of the screen and stays: a report that vanishes through a quiet week
  # reads as a feature that broke, not as a measured zero.
  defp events_worth_showing?(panel, configured?) do
    configured? or Map.get(panel, :unavailable?, false) or Map.get(panel, :rows, []) != []
  end

  defp events_empty_sentence(true),
    do: "Events are configured for this site and none were recorded in this range."

  defp events_empty_sentence(false), do: nil

  defp comparison_points(comparison) do
    Enum.map(Map.get(comparison, :slots, []), fn slot ->
      (slot.current || %{})
      |> Map.put(:bucket, slot.bucket)
      |> Map.put_new(:coverage, if(is_nil(slot.current), do: :unknown, else: :full))
    end)
  end

  # Every metric the tabs offer, resolved once per render so each cell is a
  # plain patch rather than a computation inside a `:for`.
  defp metric_hrefs(assigns),
    do: Map.new(metric_keys(), &{&1, detail_path(assigns, %{"metric" => &1})})

  defp panel_hrefs(assigns) do
    Map.new(@panel_dimensions, fn {panel, _dimension} ->
      page = Map.get(assigns.panels, panel, %{}) |> Map.get(:page, 1)
      param = panel_page_param(panel)

      {panel,
       %{
         previous: detail_path(assigns, %{param => max(page - 1, 1)}),
         next: detail_path(assigns, %{param => page + 1})
       }}
    end)
  end

  # Keep presentation changes on one recent snapshot. Every URL change still
  # authorizes the Source above. A range, Source, failure, or stale snapshot
  # requires a full read; explicit retry always refreshes the whole page.
  defp reusable_data?(socket, source, window) do
    previous = socket.assigns.source
    loaded_at = socket.assigns.data_loaded_at

    not is_nil(previous) and not is_nil(loaded_at) and
      System.monotonic_time(:millisecond) - loaded_at < @data_reuse_ms and
      socket.assigns.window == window and not socket.assigns.load_failed? and
      not socket.assigns.analytics_unavailable? and not socket.assigns.comparison.unavailable? and
      Enum.all?(
        [:id, :environment, :status, :updated_at],
        &(Map.get(previous, &1) == Map.get(source, &1))
      ) and
      Enum.all?(socket.assigns.panels, fn {_panel, data} ->
        not Map.get(data, :unavailable?, false)
      end)
  end

  defp load_changed_panels(socket, previous_pages) do
    scope = project_scope(socket, socket.assigns.project)

    panels =
      Enum.reduce(@panel_dimensions, socket.assigns.panels, fn {panel, dimension}, panels ->
        page = socket.assigns.panel_pages[panel]

        if previous_pages[panel] == page do
          panels
        else
          Map.put(
            panels,
            panel,
            load_panel(socket.assigns.source, socket.assigns.window, dimension, page, scope)
          )
        end
      end)

    assign(socket, :panels, panels)
  end

  defp load_detail_data(socket) do
    source = socket.assigns.source
    window = socket.assigns.window
    project_scope = project_scope(socket, socket.assigns.project)

    try do
      summary = Dashboard.summaries([source], window, project_scope) |> Map.fetch!(source.id)

      release_markers =
        DeploymentCorrelation.markers(project_scope, source.environment,
          now: DateTime.utc_now(),
          window_seconds: marker_window_seconds(window)
        )

      summary = Map.put(summary, :release_markers, release_markers)

      # One doubled-range read answers the hero completely: the same points
      # produce the headline totals, the change, and the plotted series.
      comparison = Dashboard.comparison(source, window, project_scope)

      panels =
        Map.new(@panel_dimensions, fn {panel, dimension} ->
          {panel,
           load_panel(
             source,
             window,
             dimension,
             socket.assigns.panel_pages[panel],
             project_scope
           )}
        end)

      assign(socket,
        loading?: false,
        data_loaded_at: System.monotonic_time(:millisecond),
        analytics_unavailable?: summary.unavailable?,
        analytics_engine_partial?: summary.analytics_engine_partial?,
        traffic_state: summary.traffic_state,
        summary: summary,
        panels: panels,
        comparison: comparison,
        source_overview: detail_source_overview(source, summary, socket),
        events_configured?: events_configured?(project_scope, socket.assigns.project),
        load_failed?: false
      )
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        require Logger
        Logger.error("measure detail load failed: #{Exception.message(error)}")
        assign(socket, loading?: false, load_failed?: true)
    end
  end

  defp load_panel(source, window, dimension, page, project_scope) do
    Dashboard.panel(source, window, dimension, page, project_scope)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      require Logger
      Logger.error("measure dimension load failed: #{Exception.message(error)}")

      %{
        rows: [],
        page: page,
        total_pages: 1,
        distinct_values: 0,
        capped?: false,
        cap_metadata: nil,
        partial?: false,
        previous?: false,
        next?: false,
        unavailable?: true
      }
  end

  # Whether this project has any custom event configured at all. The panel's
  # presence is a fact about the setup, so it is read from the definitions
  # rather than inferred from whether anything happened to fire this week.
  defp events_configured?(project_scope, project) do
    case Alplus.Measure.list_event_definitions(project.id, actor: project_scope) do
      {:ok, definitions} -> definitions != []
      {:error, _error} -> false
    end
  end

  defp project_scope(socket, project), do: %{socket.assigns.scope | project_id: project.id}

  defp detail_source_overview(source, summary, socket) do
    domains =
      Alplus.Projects.list_project_domains_for_project!(
        source.project_id,
        actor: project_scope(socket, socket.assigns.project)
      )

    [overview] = SourceOverview.build([source], %{source.id => summary}, domains)

    overview
  end

  defp detail_path(%{assigns: assigns}, overrides), do: detail_path(assigns, overrides)

  defp detail_path(assigns, overrides) do
    params =
      %{"window" => assigns.window, "metric" => assigns.metric}
      |> Map.merge(
        Map.new(assigns.panel_pages, fn {panel, page} -> {panel_page_param(panel), page} end)
      )
      |> Map.merge(overrides)

    ~p"/dashboard/orgs/#{assigns.org_token}/projects/#{assigns.project.public_token}/measure/#{assigns.source.id}?#{params}"
  end

  defp empty_summary do
    %{
      totals: %{
        pageviews: nil,
        visitors: nil,
        visits: nil,
        bounces: nil,
        duration_seconds: nil,
        bounce_rate: nil
      },
      trend: [],
      data_source: nil,
      data_source_key: nil,
      analytics_engine_state: nil,
      analytics_engine_partial?: false,
      analytics_engine_unavailable?: false,
      fallback?: false,
      unavailable?: false,
      traffic_state: :waiting,
      state: :waiting,
      evidence?: false,
      evidence: %{},
      release_markers: []
    }
  end

  defp marker_window_seconds("24h"), do: 86_400
  defp marker_window_seconds("7d"), do: 7 * 86_400
  defp marker_window_seconds("30d"), do: 30 * 86_400
  defp marker_window_seconds(_window), do: 86_400

  # The sentence inside the empty chart frame: what is absent, and the one
  # collection fact that explains it when there is one. A domain that cannot
  # send is the reason a new site stays empty, so it is said here, where the
  # reader is looking, and nowhere else.
  defp empty_label(%{traffic_state: :waiting} = assigns) do
    hostname = assigns.source_overview.identity.hostname || assigns.source.name

    case assigns.source_overview.domain.state do
      :missing -> "Waiting for the first pageview. #{hostname} is not on the allowed list yet."
      :not_configured -> "Waiting for the first pageview. No domain is set for this site."
      _state -> "Waiting for the first pageview from #{hostname}."
    end
  end

  defp empty_label(%{metric: metric, window: window}) when metric in ["visits", "pageviews"],
    do: "No #{String.downcase(metric_label(metric))} in the last #{window_words(window)}."

  defp empty_label(%{window: window}),
    do: "No visits to measure in the last #{window_words(window)}."

  # One caption under the chart, at most, in precedence order. Coverage
  # shortfalls are the chart's own caption, drawn by the component.
  defp caption(%{source: %{status: :revoked}}), do: "This site no longer collects traffic."

  defp caption(%{analytics_engine_partial?: true}),
    do: "Latest minutes are still catching up."

  defp caption(_assigns), do: nil

  defp empty_comparison do
    %{
      headlines: nil,
      slots: [],
      unavailable?: false,
      previous_available?: true
    }
  end

  defp valid_window(window) when window in @windows, do: window
  defp valid_window(_window), do: "24h"

  # One plotted metric at a time, and visits by default: "how many people
  # came" is the question this page is opened with, and pageviews qualifies it.
  defp selected_metric(%{"metric" => metric}) when metric in @metrics, do: metric

  defp selected_metric(_params), do: "visits"

  defp default_panel_pages, do: Map.new(@panel_dimensions, fn {panel, _} -> {panel, 1} end)

  defp panel_pages(params) do
    Map.new(@panel_dimensions, fn {panel, _} ->
      {panel, positive_page(params[panel_page_param(panel)])}
    end)
  end

  defp positive_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> min(page, 25)
      _other -> 1
    end
  end

  defp positive_page(value) when is_integer(value) and value > 0, do: min(value, 25)
  defp positive_page(_value), do: 1

  defp panel_page_param(panel), do: "#{panel}_page"
end
