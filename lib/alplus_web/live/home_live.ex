defmodule AlplusWeb.HomeLive do
  @moduledoc """
  The marketing homepage at `/`, and the one marketing page that is a
  LiveView (ARCHITECTURE.md §9). Every other marketing page stays a
  server-rendered controller page in `AlplusWeb.PageController`.

  The reason is in-place switching. The hero range, the hero metric, the
  selected monitor and the Measure range are four switches over one live
  project overview. The initial URL selects the first frame; after that,
  buttons send LiveView events and update the frame over the websocket without
  changing the URL or reloading the document.

  The dead render stays complete. `mount/3` assigns the same title,
  description, canonical URL, OG fields and JSON-LD graphs the controller
  assigned, and `Phoenix.LiveView.Controller.live_render/3` merges the
  socket assigns into the root layout's assigns, so `<head>` is identical
  to the controller's for a crawler that never opens a socket.

  The initial selection is read from the URL in `mount/3`. After a switch,
  the normalised selection returned by `AlplusWeb.Marketing.HomepageData`
  stays in socket state. `HomepageData` owns the allow-list: a LiveView that
  validated the values too would give the page two contradicting definitions
  of a valid selection. Each switch re-reads through `HomepageData.load/1`,
  and the 30 second
  `Alplus.Measure.PublicCache` behind it is what makes a repeat switch
  cheap — nothing is cached in the socket, so nothing in the socket can go
  stale.

  `Content.get_page_by_path("/")` is total here, exactly as it was in the
  controller: a fresh database migrated without `priv/repo/seeds.exs` must
  render the built-in fallback page, never crash the first visitor.
  """

  use AlplusWeb, :live_view

  import AlplusWeb.MarketingComponents

  alias Alplus.Billing.Package
  alias Alplus.Content
  alias AlplusWeb.Marketing.{HomepageData, PackagePresenter, Seo}

  on_mount {AlplusWeb.LiveUserAuth, :current_user}

  @impl true
  def mount(params, _session, socket) do
    page =
      case Content.get_page_by_path("/") do
        {:ok, page} -> page
        {:error, _} -> fallback_home_page()
      end

    graph = %{
      "@context" => "https://schema.org",
      "@graph" => [
        Seo.organization_schema(),
        Seo.website_schema(),
        Seo.software_application_schema()
      ]
    }

    seo =
      Seo.seo_assigns(
        title: page.title,
        description: page.meta_description,
        path: "/",
        og_title: page.og_title,
        og_description: page.og_description,
        json_ld: [graph] ++ faq_graphs(page.faqs)
      )

    {:ok,
     socket
     |> assign(seo)
     |> assign(:page, page)
     |> assign(:homepage_data, HomepageData.load(params))}
  end

  defp faq_graphs([]), do: []
  defp faq_graphs(faqs), do: [Seo.faq_schema(faqs)]

  @impl true
  def handle_event("select_overview_range", %{"range" => range}, socket),
    do: select_homepage(socket, "range", range)

  def handle_event("select_metric", %{"metric" => metric}, socket),
    do: select_homepage(socket, "metric", metric)

  def handle_event("select_monitor", %{"monitor" => monitor}, socket),
    do: select_homepage(socket, "monitor", monitor)

  def handle_event("select_traffic_range", %{"traffic" => traffic}, socket),
    do: select_homepage(socket, "traffic", traffic)

  defp homepage_bar_pct(value, peak) when is_number(value) and value > 0 and peak > 0,
    do: max(8, round(value / peak * 100))

  defp homepage_bar_pct(_value, _peak), do: 0

  # A headline value reads "Unavailable" only when its section could not be
  # read. A section with no evidence yet says so instead of implying an error.
  defp homepage_metric(state, value, unit \\ "")
  defp homepage_metric(:unavailable, _value, _unit), do: "Unavailable"
  defp homepage_metric(_state, nil, _unit), do: "No data"

  defp homepage_metric(_state, value, unit) when is_float(value),
    do: "#{Float.round(value, 2)}#{unit}"

  defp homepage_metric(_state, value, unit), do: "#{value}#{unit}"

  # The console frame's identity caption. Both the project name and its public
  # slug are shown, so a reader can match the evidence to the published page.
  defp homepage_identity(%{name: name, slug: slug}) when is_binary(name) and is_binary(slug),
    do: "#{name} / #{slug}"

  defp homepage_identity(%{name: name}) when is_binary(name), do: name
  defp homepage_identity(%{slug: slug}) when is_binary(slug), do: slug
  defp homepage_identity(_identity), do: "PostDeploy project"

  # The homepage publishes what the designated project actually published.
  #
  # This used to substitute invented entries and invented uptime squares
  # whenever a surface read back empty, and only `:preview` mode draws the
  # visible "Example project evidence" label, so on the real vendor project a
  # visitor read "Example: Incident timeline improvements" as PostDeploy's own
  # changelog and two all-green components as PostDeploy's own uptime. Nothing
  # marked either as fabricated. Empty is evidence: both panels already carry
  # the sentence that says so ("No updates are published yet.", "No status page
  # published yet."), and the marketing surface never invents a row to fill
  # space (PRODUCT.md, "Show evidence, not theater").
  #
  # `:preview` mode is untouched. It runs only when no vendor project is
  # configured, `HomepagePreview` supplies its whole dataset including these
  # panels, and the console frame carries the visible example badge.
  defp homepage_publications(%{state: page_state, status: status, changelog: changelog}) do
    preview? = page_state == :preview

    %{
      status: status,
      changelog: changelog,
      status_example?: preview?,
      changelog_example?: preview?
    }
  end

  # The screen-reader table behind the uptime bars. Only measured days are
  # listed; a day without a reading is left out rather than shown as zero.
  defp homepage_history_rows(monitor) do
    monitor
    |> Map.get(:history, [])
    |> List.wrap()
    |> Enum.filter(&is_number(Map.get(&1, :uptime)))
    |> Enum.map(&{homepage_bucket_label(Map.get(&1, :day)), Map.get(&1, :uptime)})
  end

  # One square per day, coloured by that day's own state. The vocabulary and
  # the classes match the public status page, so both surfaces read alike.
  defp homepage_day_class(:up), do: "bg-status-live"
  defp homepage_day_class(:degraded), do: "bg-status-late"
  defp homepage_day_class(:down), do: "bg-status-error"
  defp homepage_day_class(:maintenance), do: "bg-status-info"
  defp homepage_day_class(_state), do: "bg-status-neutral"

  defp homepage_day_word(:up), do: "Operational"
  defp homepage_day_word(:degraded), do: "Degraded"
  defp homepage_day_word(:down), do: "Down"
  defp homepage_day_word(:maintenance), do: "Maintenance"
  defp homepage_day_word(_state), do: "No data"

  defp homepage_day_state(point), do: Map.get(point, :state) || :unknown

  defp homepage_bucket_label(%Date{} = day), do: Date.to_iso8601(day)
  defp homepage_bucket_label(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp homepage_bucket_label(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.to_date() |> Date.to_iso8601()

  defp homepage_bucket_label(value) when is_binary(value), do: value
  defp homepage_bucket_label(_value), do: "Unavailable"

  # --------------------------------------------------------------------
  # Homepage switches
  #
  # Each switch changes one value in the current normalised selection, then
  # reloads the projection in socket state. `AlplusWeb.Marketing.HomepageData`
  # normalises and allow-lists the event value before any read runs.
  # --------------------------------------------------------------------

  @home_ranges ["24h", "7d", "30d"]
  @home_measure_ranges ["7d", "14d", "30d"]

  defp homepage_selection(data) do
    selection = Map.get(data, :selection) || %{}

    %{
      range: Map.get(selection, :range) || "24h",
      metric: Map.get(selection, :metric) || :uptime,
      monitor: Map.get(selection, :monitor) || 0,
      traffic_range: Map.get(selection, :traffic_range) || "7d"
    }
  end

  defp select_homepage(socket, key, value) do
    params =
      socket.assigns.homepage_data
      |> homepage_selection()
      |> homepage_selection_params()
      |> Map.put(key, to_string(value))

    {:noreply, assign(socket, :homepage_data, HomepageData.load(params))}
  end

  defp homepage_selection_params(selection) do
    %{
      "range" => selection.range,
      "metric" => to_string(selection.metric),
      "monitor" => to_string(selection.monitor),
      "traffic" => selection.traffic_range
    }
  end

  defp homepage_overview(data), do: Map.get(data, :overview) || %{}

  defp homepage_ranges(overview) do
    case Map.get(overview, :ranges) do
      [_ | _] = ranges -> ranges
      _ -> @home_ranges
    end
  end

  defp homepage_tiles(overview, data, selection) do
    case Map.get(overview, :tiles) do
      [_ | _] = tiles -> Enum.map(tiles, &homepage_tile(&1, selection))
      _ -> Enum.map(homepage_fallback_tiles(data), &homepage_tile(&1, selection))
    end
  end

  defp homepage_tile(tile, selection) do
    id = Map.get(tile, :id)

    %{
      id: id,
      label: Map.get(tile, :label) || "",
      value: Map.get(tile, :value),
      sub: Map.get(tile, :sub) || "",
      tone: Map.get(tile, :tone) || :ink,
      selected?: Map.get(tile, :selected?) || id == selection.metric
    }
  end

  # Used until the projection carries `:overview`, and as the honest shape if
  # a section is ever missing from it. Each value comes from the same reads
  # the rest of the page uses, so no tile can claim more than the data holds.
  defp homepage_fallback_tiles(data) do
    metrics = data.metrics
    monitor = data.monitor
    measure = data.measure
    observe = data.observe

    [
      %{
        id: :uptime,
        label: "Uptime",
        value: homepage_metric(monitor.state, Map.get(monitor.headline, :uptime), "%"),
        sub: homepage_uptime_sub(monitor),
        tone: :ink
      },
      %{
        id: :response,
        label: "Response",
        value: homepage_metric(monitor.state, metrics.monitor.response_time_ms, "ms"),
        sub: "Recent production sample across public monitors",
        tone: :ink
      },
      %{
        id: :traffic,
        label: "Traffic",
        value: homepage_metric(measure.state, metrics.measure.value),
        sub: homepage_measure_sub(measure, metrics),
        tone: :ink
      },
      %{
        id: :errors,
        label: "Errors",
        value: homepage_metric(observe.state, Map.get(metrics.observe, :open_issues)),
        sub: homepage_observe_sub(observe, metrics),
        tone: :error
      }
    ]
  end

  defp homepage_uptime_sub(%{state: :unavailable}), do: "Unavailable"
  defp homepage_uptime_sub(%{state: :empty}), do: "No monitors published yet"

  defp homepage_uptime_sub(monitor),
    do: Map.get(monitor, :uptime_label) || "Weighted uptime, last 90 days"

  defp homepage_measure_sub(%{state: :unavailable}, _metrics), do: "Unavailable"

  defp homepage_measure_sub(_measure, metrics) do
    if metrics.measure.visitors,
      do: "#{metrics.measure.visitors} visitors, last 7 days",
      else: "No traffic recorded in the last 7 days"
  end

  defp homepage_observe_sub(%{state: :unavailable}, _metrics), do: "Unavailable"

  defp homepage_observe_sub(observe, metrics) do
    cond do
      Map.get(observe, :open_issues_lower_bound, false) -> "Open issues, 100 or more"
      metrics.observe.open_issues == 0 -> "No open issues"
      true -> "Open issues"
    end
  end

  defp homepage_chart(overview, data, selection) do
    chart = Map.get(overview, :chart) || %{}
    points = homepage_points(Map.get(chart, :points) || homepage_fallback_points(data, selection))

    %{
      kind: Map.get(chart, :kind) || homepage_chart_kind(selection.metric),
      unit: Map.get(chart, :unit) || "",
      points: points,
      peak: homepage_peak(points, Map.get(chart, :peak)),
      caption: Map.get(chart, :caption) || "Daily uptime, percent",
      axis_start: Map.get(chart, :axis_start) || "-90d",
      axis_end: Map.get(chart, :axis_end) || "now",
      table_caption:
        Map.get(chart, :table_caption) ||
          "Daily uptime for published monitors, in percent, last 90 days.",
      column_label: Map.get(chart, :column_label) || "Uptime (%)",
      state: Map.get(chart, :state) || Map.get(overview, :state) || data.monitor.state
    }
  end

  defp homepage_chart_kind(:uptime), do: :ticks
  defp homepage_chart_kind(:traffic), do: :wave
  defp homepage_chart_kind(_metric), do: :bars

  # Without `:overview` the hero can still plot the 90-day uptime history the
  # projection already publishes. Any other metric has no series to draw, so
  # the chart states that instead of inventing one.
  defp homepage_fallback_points(data, %{metric: :uptime}) do
    data.monitor
    |> homepage_history_rows()
    |> Enum.take(-36)
    |> Enum.map(fn {label, value} -> %{label: label, value: value, state: :up} end)
  end

  defp homepage_fallback_points(_data, _selection), do: []

  defp homepage_points(points) do
    points
    |> List.wrap()
    |> Enum.map(fn
      %{} = point ->
        value = Map.get(point, :value)

        %{
          label: Map.get(point, :label) || "",
          value: value,
          state: Map.get(point, :state) || if(is_number(value), do: :up, else: :none)
        }

      value when is_number(value) ->
        %{label: "", value: value, state: :up}

      _other ->
        %{label: "", value: nil, state: :none}
    end)
  end

  defp homepage_peak(points, declared) do
    values = points |> Enum.map(& &1.value) |> Enum.filter(&is_number/1)

    cond do
      is_number(declared) and declared > 0 -> declared
      values == [] -> 1
      true -> Enum.max([1 | values])
    end
  end

  # The public status page owns the verdict wording, so both surfaces read the
  # same. A projection that already carries a sentence is passed through.
  defp homepage_status_label(status) when is_atom(status) and not is_nil(status),
    do: AlplusWeb.StatusHTML.page_status_label(status)

  defp homepage_status_label(status) when is_binary(status), do: status

  defp homepage_tick_class(:up), do: "bg-status-live"
  defp homepage_tick_class(:degraded), do: "bg-status-late"
  defp homepage_tick_class(:down), do: "bg-status-error"
  defp homepage_tick_class(_state), do: "bg-status-neutral"

  # Colour follows the meaning of the metric, not the shape of the chart.
  # Uptime and monitor state are operational, so they use the state palette.
  # Response time and traffic are measurements, so they carry the brand
  # chartreuse. Errors stay quiet until a bucket actually holds one.
  defp homepage_chart_class(:uptime, point), do: homepage_tick_class(point.state)

  defp homepage_chart_class(:errors, point) do
    if is_number(point.value) and point.value > 0,
      do: "bg-status-error",
      else: "bg-surface-sunken"
  end

  defp homepage_chart_class(_metric, point) do
    if is_number(point.value), do: "bg-interactive-primary", else: "bg-surface-sunken"
  end

  # The traffic wave is drawn in a 100x40 viewBox with a non-scaling stroke,
  # so one path serves every viewport width. Returns `nil` when there is no
  # series to draw, and the caller shows the section's empty copy instead.
  defp homepage_wave(points, peak) do
    coords =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        value = if is_number(point.value), do: point.value, else: 0
        count = length(points)
        x = if count > 1, do: index / (count - 1) * 100, else: 50.0
        y = 38 - min(value / peak, 1.0) * 34

        {Float.round(x * 1.0, 2), Float.round(y * 1.0, 2)}
      end)

    case coords do
      [] ->
        nil

      [{first_x, _} | _] = coords ->
        line = "M " <> Enum.map_join(coords, " L ", fn {x, y} -> "#{x} #{y}" end)
        {last_x, _} = List.last(coords)

        %{line: line, area: line <> " L #{last_x} 40 L #{first_x} 40 Z"}
    end
  end

  # Monitor rows carry their own selection flag once the projection sets one.
  # Until then the index in the list decides, which is what the link sends.
  defp homepage_monitor_rows(monitor, selection) do
    monitor
    |> Map.get(:rows, [])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      row
      |> Map.put(:index, index)
      |> Map.put(:type_label, Map.get(row, :type_label) || Map.get(row, :type) || "monitor")
      |> Map.put(:checks_recent, List.wrap(Map.get(row, :checks_recent)))
      |> Map.put(:caption, Map.get(row, :caption) || "Recent checks, oldest first")
      |> Map.put(:selected?, Map.get(row, :selected?) || index == selection.monitor)
    end)
  end

  defp homepage_selected_monitor(monitor, rows) do
    Map.get(monitor, :selected) || Enum.find(rows, & &1.selected?) || List.first(rows)
  end

  defp homepage_monitor_state_label(:up), do: "Operational"
  defp homepage_monitor_state_label(:degraded), do: "Degraded"
  defp homepage_monitor_state_label(:down), do: "Down"
  defp homepage_monitor_state_label(:paused), do: "Paused"
  defp homepage_monitor_state_label(_state), do: "No data"

  defp homepage_monitor_state_class(:up), do: "bg-status-live-bg text-status-live-ink"
  defp homepage_monitor_state_class(:degraded), do: "bg-status-late-bg text-status-late-ink"
  defp homepage_monitor_state_class(:down), do: "bg-status-error-bg text-status-error-ink"

  defp homepage_monitor_state_class(_state),
    do: "bg-status-neutral-bg text-status-neutral-ink"

  defp homepage_measure_ranges(measure) do
    case Map.get(measure, :ranges) do
      [_ | _] = ranges -> ranges
      _ -> @home_measure_ranges
    end
  end

  # "Unavailable" is reserved for a section that could not be read. A section
  # with nothing to plot yet says what is missing instead.
  defp homepage_empty_copy(:unavailable, _metric), do: "Unavailable"
  defp homepage_empty_copy(_state, :uptime), do: "No monitors published yet"
  defp homepage_empty_copy(_state, :response), do: "No response times recorded yet"
  defp homepage_empty_copy(_state, :traffic), do: "No traffic recorded yet"
  defp homepage_empty_copy(_state, :errors), do: "No errors recorded yet"
  defp homepage_empty_copy(_state, _metric), do: "No data yet"

  # Ranges are written as `7d` on a control and as "7 days" in a sentence.
  defp homepage_range_words("24h"), do: "24 hours"
  defp homepage_range_words("7d"), do: "7 days"
  defp homepage_range_words("14d"), do: "14 days"
  defp homepage_range_words("30d"), do: "30 days"
  defp homepage_range_words(range) when is_binary(range), do: range

  # The fallback when `Content.get_page_by_path("/")` finds no `/` row (a
  # fresh database migrated without `priv/repo/seeds.exs`). A plain map, not
  # an `Alplus.Content.Page` struct: `home_live.html.heex` only ever reads
  # these fields with dot access, which works the same on either.
  defp fallback_home_page do
    %{
      title: "Production monitoring for the project you just shipped | PostDeploy",
      meta_description:
        "Uptime checks, cron heartbeats, error tracking and cookieless analytics in one project. Connect your coding agent, say what to watch, and review what it created.",
      og_title: "PostDeploy: production monitoring your coding agent sets up",
      og_description:
        "Uptime, cron, errors and analytics for the project you just shipped. One login, one flat price, a #{Package.trial_days()}-day free trial.",
      hero_heading: "Production monitoring for the project you just shipped.",
      summary:
        "PostDeploy is production monitoring for solo developers and small teams: uptime checks, cron heartbeats, error tracking and cookieless analytics in one project, set up by your coding agent.",
      body_sections: [],
      faqs: []
    }
  end
end
