defmodule AlplusWeb.MeasureActivityComponents do
  @moduledoc """
  The Measure portfolio and detail pieces.

  Three ideas hold this module together.

  **The chart is the screen.** The portfolio draws one hero chart of the
  whole project's pageviews; the detail page draws one hero chart of the
  metric its tabs select. A reading is a number beside the chart, at stat
  scale, and never a card of its own. Every qualification (a comparison, a
  coverage shortfall, a collection state) is one short line, present only
  when it is true.

  **A quiet bucket and a missing bucket are different facts.** Inside covered
  retention, ingest writes a rollup only when something was hit, so an absent
  hour or day is a *measured zero*: the backend materializes it and this
  module draws it on the baseline. A `nil` is a genuinely unmeasured bucket,
  before the site was connected, outside the package's retention, or a failed
  read, and nothing is drawn there at all. No zero stands in for it, no curve
  is interpolated across it. The shortfall is stated in one caption under the
  plot and the exact table lists every bucket.

  **A curve may not invent a value.** `series_path/2` is monotone cubic
  interpolation (Fritsch–Carlson), so the line between two readings stays
  between those two readings.

  """

  use AlplusWeb, :html

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DataDisplayComponents
  import AlplusWeb.Format

  @max_release_annotations 5

  # The 0-100 by 0-40 box `data_display/1` draws into. Values sit between 2
  # and 38 so a maximum reading is not clipped by the stroke width and a zero
  # reading is still visibly on the baseline rather than off the box.
  @plot_top 2.0
  @plot_bottom 38.0
  @plot_baseline 39.0
  @baseline_path "M0,39.0 L100,39.0"

  # A series with this many readings or fewer keeps a permanent dot on each
  # one. One reading has no line at all and two drawn as a bare hairline are
  # almost invisible; above this the dots become a field of noise over a shape
  # that already reads.
  @sparse_reading_cap 3

  # The metrics the detail tabs offer, in the order they show them. Visits
  # leads because "how many people came" is the question the page is opened
  # with; pageviews qualifies it.
  @metrics ~w(visits pageviews bounce_rate avg_duration)

  # The one ink every Measure mark is drawn in: the text-safe brand value for
  # the line and the dots, the brand lime (washed by `data_display/1` to 30
  # percent) for the area under a count.
  @line_class "stroke-interactive-strong fill-interactive-primary"

  @doc """
  Renders the shared Traffic trend from precomputed points.

  Aggregation stays in `Alplus.Measure.Dashboard`. This component owns the
  continuous chart, unknown rail, partial stroke, tooltips, and table.
  """
  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :metric, :string, required: true
  attr :range, :string, required: true
  attr :variant, :atom, default: :full, values: [:compact, :full]
  attr :coverage, :atom, default: nil
  attr :state, :atom, default: nil
  attr :release_markers, :list, default: []
  attr :title, :string, default: nil
  attr :empty_label, :string, default: nil
  attr :retry, :any, default: nil
  attr :class, :string, default: nil
  attr :plot_height, :atom, default: nil, values: [nil, :standard, :tall, :hero]

  def traffic_trend(assigns) do
    readings = traffic_readings(assigns.points, assigns.metric)
    scale_values = Enum.map(readings, &Map.get(&1, :plot_value))
    scale = metric_scale(assigns.metric, scale_values)
    full_values = Enum.map(readings, &if(&1.coverage == :full, do: &1.plot_value))
    partial_values = partial_series_values(readings)
    coverage = assigns.coverage || trend_coverage(readings)
    state = assigns.state || traffic_trend_state(readings, coverage)

    title =
      assigns.title || "#{metric_label(assigns.metric)}, last #{window_words(assigns.range)}"

    assigns =
      assign(assigns,
        readings: readings,
        scale: scale,
        coverage_state: coverage,
        state: state,
        resolved_title: title,
        plot_height:
          assigns.plot_height || if(assigns.variant == :full, do: :hero, else: :standard),
        svg_path: series_path(full_values, scale),
        svg_area: if(filled?(assigns.metric), do: measured_area(full_values, scale)),
        overlays:
          series_overlays(full_values, scale, assigns.metric) ++
            partial_overlays(partial_values, scale),
        x_labels: x_labels(Enum.map(assigns.points, &Map.get(&1, :bucket))),
        shades: untracked_spans(Enum.map(readings, & &1.coverage)),
        annotations: release_annotations(assigns.release_markers, assigns.points),
        line_class:
          if(filled?(assigns.metric), do: @line_class, else: "stroke-interactive-strong"),
        state_summary: traffic_state_summary(state)
      )

    ~H"""
    <div class={["min-w-0", @class]}>
      <.data_display
        id={@id}
        title={@resolved_title}
        heading={:assistive}
        kind={:line}
        variant={@variant}
        plot_height={@plot_height}
        state={@state}
        data={@readings}
        unit={metric_unit(@metric)}
        range={axis(@range)}
        axis={:bottom}
        x_labels={@x_labels}
        shades={@shades}
        annotations={@annotations}
        svg_path={@svg_path}
        svg_area={@svg_area}
        overlays={@overlays}
        line_class={@line_class}
        summary={@state_summary}
        line_width="2"
        empty_label={@empty_label || "No traffic data"}
        table={:assistive}
        table_columns={["Time", metric_label(@metric), "Coverage"]}
        description={"#{metric_label(@metric)} over the last #{window_words(@range)}."}
        retry_event={@retry}
      />
      <p
        :if={@state in [:ready, :partial] && coverage_words(@readings, @coverage_state)}
        id={"#{@id}-coverage"}
        class="mt-3 text-center text-caption text-text-secondary"
      >
        {coverage_words(@readings, @coverage_state)}
      </p>
    </div>
    """
  end

  defp traffic_readings(points, metric) do
    field = String.to_existing_atom(metric)

    Enum.map(points, fn point ->
      value = metric_value(point, field)
      coverage = Map.get(point, :coverage, if(is_number(value), do: :full, else: :unknown))
      known = known_metric_value(point, metric, value)
      plot_value = if(coverage == :partial, do: known, else: value)
      in_progress? = Map.get(point, :in_progress?, false) and coverage != :unknown
      sentence = traffic_point_words(point, metric, coverage, plot_value, in_progress?)

      %{
        id: bucket_iso(point.bucket),
        label: bucket_axis_label(point.bucket),
        value: value,
        plot_value: plot_value,
        coverage: coverage,
        in_progress?: in_progress?,
        tone: if(coverage == :full, do: "emphasis", else: "neutral"),
        tooltip: sentence,
        aria_label: sentence,
        table_cells: [
          bucket_label(point.bucket),
          traffic_table_value(metric, coverage, plot_value, in_progress?),
          coverage_label(point, coverage)
        ]
      }
    end)
  end

  defp known_metric_value(point, "pageviews", value),
    do: Map.get(point, :known_pageviews, Map.get(point, :known_value, value))

  defp known_metric_value(point, "visits", value),
    do: Map.get(point, :known_visits, Map.get(point, :known_value, value))

  defp known_metric_value(point, "bounce_rate", value),
    do: Map.get(point, :known_bounce_rate, Map.get(point, :known_value, value))

  defp known_metric_value(point, "avg_duration", value),
    do: Map.get(point, :known_avg_duration, Map.get(point, :known_value, value))

  # The bucket in progress states a lower bound ("so far"), so a low reading
  # at the right edge is never mistaken for a collapse.
  defp traffic_point_words(point, metric, :full, value, true),
    do: "#{bucket_label(point.bucket)}, #{metric_hover_value(metric, value)} so far, in progress"

  defp traffic_point_words(point, metric, :full, value, false),
    do: "#{bucket_label(point.bucket)}, #{metric_hover_value(metric, value)}"

  defp traffic_point_words(point, metric, :partial, value, in_progress?) do
    "#{bucket_label(point.bucket)}, #{metric_hover_value(metric, value)}, " <>
      coverage_label(point, :partial) <> if(in_progress?, do: ", in progress", else: "")
  end

  defp traffic_point_words(point, _metric, :unknown, _value, _in_progress?),
    do: "#{bucket_label(point.bucket)}, not measured"

  defp traffic_table_value(_metric, :unknown, _value, _in_progress?), do: "Not measured"

  defp traffic_table_value(metric, :partial, value, _in_progress?),
    do: metric_reading(value, metric)

  defp traffic_table_value(metric, :full, value, true),
    do: "#{metric_reading(value, metric)} so far"

  defp traffic_table_value(metric, :full, value, false), do: metric_reading(value, metric)

  defp coverage_label(point, :partial),
    do:
      "#{Map.get(point, :measured_sites, 0)} of #{Map.get(point, :expected_sites, 0)} sites measured"

  defp coverage_label(_point, :full), do: "Measured"
  defp coverage_label(_point, :unknown), do: "Not measured"

  defp trend_coverage([]), do: :unknown

  defp trend_coverage(readings) do
    states = Enum.map(readings, & &1.coverage)

    cond do
      Enum.all?(states, &(&1 == :full)) -> :full
      Enum.all?(states, &(&1 == :unknown)) -> :unknown
      true -> :partial
    end
  end

  defp traffic_trend_state([], _coverage), do: :empty
  defp traffic_trend_state(_readings, :partial), do: :partial
  defp traffic_trend_state(_readings, _coverage), do: :ready

  defp traffic_state_summary(:error), do: "Traffic could not be loaded."
  defp traffic_state_summary(:unavailable), do: "Traffic could not be loaded."
  defp traffic_state_summary(_state), do: nil

  defp partial_series_values(readings), do: partial_series_values(readings, nil)

  defp partial_series_values([], _previous), do: []

  defp partial_series_values([reading | rest], previous) do
    next = List.first(rest)

    bridged? =
      reading.coverage == :partial or
        (reading.coverage == :full and
           ((not is_nil(previous) and previous.coverage == :partial) or
              (not is_nil(next) and next.coverage == :partial)))

    [if(bridged?, do: reading.plot_value) | partial_series_values(rest, reading)]
  end

  defp partial_overlays(values, scale) do
    case partial_path(values, scale) do
      nil ->
        []

      path ->
        [%{path: path, class: "stroke-status-neutral", width: "2", dash: "4 3", linecap: "round"}]
    end
  end

  defp partial_path(values, scale) do
    values
    |> run_points(scale)
    |> Enum.map(fn
      [{x, y}] -> "M#{x},#{y} L#{x},#{y}"
      points -> curve(points)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> presence()
  end

  defp coverage_words(_readings, :full), do: nil
  defp coverage_words(_readings, :unknown), do: "Not measured in this period."

  # The caption names how much of the period was measured. The count itself
  # stays a plain number: a reading the product hedged in its own value read as
  # an estimate rather than as the evidence it is.
  defp coverage_words(readings, :partial) do
    measured = Enum.count(readings, &(&1.coverage == :full))
    unit = coverage_unit(readings, length(readings))
    "Measured on #{measured} of #{length(readings)} #{unit}."
  end

  defp coverage_unit(readings, count) do
    case readings do
      [%{id: id} | _] when is_binary(id) ->
        if String.contains?(id, "T"),
          do: if(count == 1, do: "hour", else: "hours"),
          else: if(count == 1, do: "day", else: "days")

      _readings ->
        "periods"
    end
  end

  # ---------------------------------------------------------------------------
  # Portfolio: readings, one hero chart
  # ---------------------------------------------------------------------------

  @doc "Renders the Traffic trend, readings, and site collection as sibling panels."
  attr :portfolio, :map, required: true, doc: "Alplus.Measure.Dashboard.portfolio/4"
  attr :window, :string, required: true
  attr :placeholder, :boolean, default: false
  attr :context, :string, required: true, doc: "the project, as the frame's mono context line"
  slot :rail, doc: "the connected site rows"

  attr :retry, :any,
    default: "retry_measure",
    doc: "the phx-click retry event, or false on a page with no LiveView bundle"

  def traffic_overview(assigns) do
    assigns =
      assign(assigns,
        totals: Map.get(assigns.portfolio, :totals, %{}),
        trend: Map.get(assigns.portfolio, :trend, []),
        coverage: Map.get(assigns.portfolio, :coverage, :unknown),
        trend_state: if(Map.get(assigns.portfolio, :unavailable?, false), do: :error),
        empty_label: portfolio_empty_label(assigns.placeholder, assigns.window)
      )

    ~H"""
    <div
      id="measure-traffic-overview"
      class="grid min-w-0 gap-4 lg:grid-cols-12"
    >
      <section
        id="measure-traffic"
        class="min-w-0 overflow-hidden rounded-frame border border-border-public bg-surface-raised shadow-frame lg:col-span-8"
        aria-label={"Pageviews, last #{window_words(@window)}"}
      >
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-border-default px-5 py-3.5">
          <p class="font-mono text-data text-text-tertiary">
            {@context}, last {window_words(@window)}
          </p>
        </div>

        <div class="min-w-0 overflow-hidden p-5 pt-6">
          <.traffic_trend
            id="measure-traffic-chart"
            points={@trend}
            metric="pageviews"
            range={@window}
            variant={:full}
            plot_height={:tall}
            coverage={@coverage}
            state={@trend_state}
            empty_label={@empty_label}
            retry={@retry || nil}
          />
        </div>
      </section>

      <.data_panel
        id="measure-traffic-readings"
        title="Readings"
        class="min-w-0 lg:col-span-4"
      >
        <div
          class="grid min-w-0 divide-y divide-border-default md:grid-cols-3 md:divide-x md:divide-y-0 lg:grid-cols-1 lg:divide-x-0 lg:divide-y"
          aria-label="Traffic readings"
        >
          <.reading
            id="measure-traffic-pageviews"
            label="Pageviews"
            caption={
              reading_caption(@totals[:pageviews], @placeholder) ||
                coverage_words(traffic_readings(@trend, "pageviews"), @coverage)
            }
            muted={@placeholder}
            points={@trend}
            metric="pageviews"
          >
            {reading_value(@totals[:pageviews], @placeholder)}
          </.reading>
          <.reading
            id="measure-traffic-visits"
            label="Visits"
            muted={@placeholder}
            points={@trend}
            metric="visits"
          >
            {reading_value(@totals[:visits], @placeholder)}
          </.reading>
          <.reading
            id="measure-traffic-sites"
            label="Sites with traffic"
            muted={@placeholder}
            points={@trend}
            metric="measured_sites"
          >
            {sites_reading(@totals)}
          </.reading>
        </div>
      </.data_panel>

      <.data_panel
        :if={@rail != []}
        id="measure-sites"
        title="Sites"
        class="min-w-0 lg:col-span-12"
      >
        {render_slot(@rail)}
      </.data_panel>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :caption, :string, default: nil
  attr :muted, :boolean, default: false
  attr :points, :list, default: []
  attr :metric, :string, default: nil
  slot :inner_block, required: true

  defp reading(assigns) do
    ~H"""
    <div class="grid min-h-[72px] min-w-0 grid-cols-[minmax(0,1fr)_6rem] items-center gap-4 px-5 py-3">
      <div class="min-w-0">
        <p class="text-label font-semibold text-text-primary">{@label}</p>
        <p
          id={@id}
          class={[
            "mt-1 whitespace-nowrap text-stat font-semibold tabular-nums",
            if(@muted, do: "text-text-tertiary", else: "text-text-primary")
          ]}
        >
          {render_slot(@inner_block)}
        </p>
        <p :if={@caption} class="mt-1 text-caption text-text-secondary">{@caption}</p>
      </div>
      <.mini_trend :if={@metric && @points != []} points={@points} metric={@metric} />
    </div>
    """
  end

  attr :points, :list, required: true
  attr :metric, :string, required: true

  defp mini_trend(assigns) do
    field = String.to_existing_atom(assigns.metric)
    values = Enum.map(assigns.points, &metric_value(&1, field))
    scale = metric_scale(assigns.metric, values)
    count = length(values)

    dots =
      values
      |> Enum.with_index()
      |> Enum.filter(fn {value, _index} -> is_number(value) end)
      |> Enum.map(fn {value, index} -> %{x: plot_x(index, count), y: plot_y(value, scale)} end)

    assigns = assign(assigns, path: series_path(values, scale), dots: dots)

    ~H"""
    <svg
      viewBox="0 0 100 40"
      preserveAspectRatio="none"
      aria-hidden="true"
      focusable="false"
      class="h-8 w-20 overflow-visible"
    >
      <path d="M0,39 L100,39" class="stroke-border-default" stroke-width="1" fill="none" />
      <path
        :if={@path}
        d={@path}
        class="stroke-interactive-strong"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
        fill="none"
      />
      <circle
        :for={dot <- @dots}
        :if={is_nil(@path)}
        cx={dot.x}
        cy={dot.y}
        r="2"
        class="fill-interactive-strong"
      />
    </svg>
    """
  end

  @doc """
  The site list under the portfolio chart: one row per connected site with
  its collection state, its name as the link to its own chart, and its
  pageviews for the range. Sites that need attention come first.
  """
  attr :sources, :list, required: true
  attr :portfolio, :map, required: true
  attr :org_token, :string, required: true
  attr :project, :any, required: true

  def measure_site_list(assigns) do
    assigns = assign(assigns, :rows, sort_sites(assigns.sources, assigns.portfolio))

    ~H"""
    <div id="measure-site-rows" class="divide-y divide-border-subtle">
      <div
        :for={{source, site} <- @rows}
        id={"measure-site-#{source.id}"}
        class={[
          "grid min-h-16 min-w-0 grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 px-5 py-2 sm:flex sm:h-11 sm:min-h-0 sm:justify-between sm:[@media(pointer:coarse)]:h-12",
          source.status == :revoked && "opacity-75"
        ]}
      >
        <.link
          id={"measure-site-name-#{source.id}"}
          navigate={measure_site_path(@org_token, @project, source)}
          class="inline-flex min-h-target-min min-w-0 flex-col items-start justify-center gap-y-0.5 hover:text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus sm:h-control-md sm:min-h-0 sm:flex-row sm:items-center sm:gap-x-3"
        >
          <span class="min-w-0 break-words text-body font-semibold text-text-primary sm:truncate">
            {source.name}
          </span>
          <span id={"measure-site-status-#{source.id}"} class="shrink-0">
            <.status_dot
              tone={site_state_tone(site_state(source, site, @portfolio))}
              label={site_state_label(site_state(source, site, @portfolio), site)}
            />
          </span>
        </.link>
        <p
          id={"measure-site-pageviews-#{source.id}"}
          class="shrink-0 font-mono text-data tabular-nums text-text-secondary"
        >
          {site_count_reading(site)}
        </p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Detail: tabs, one hero chart
  # ---------------------------------------------------------------------------

  @doc """
  The detail metric tabs: four readings, each a link that selects the metric
  the hero chart plots. The selected one carries ink and the brand underline,
  and `aria-current`, never colour alone.
  """
  attr :headlines, :map, default: nil
  attr :metric, :string, required: true
  attr :hrefs, :map, required: true, doc: "metric key => patch path"
  attr :points, :list, default: []

  def measure_metric_strip(assigns) do
    ~H"""
    <div
      id="measure-detail-metrics"
      role="group"
      aria-label="Choose the metric to plot"
      class="grid grid-cols-2 divide-x divide-border-default border-b border-border-default [&>*:nth-child(n+3)]:border-t [&>*:nth-child(n+3)]:border-border-default sm:grid-cols-4 sm:[&>*:nth-child(n+3)]:border-t-0"
    >
      <.link
        :for={metric <- metric_keys()}
        patch={Map.fetch!(@hrefs, metric)}
        id={"measure-detail-metric-#{metric}"}
        aria-current={metric == @metric && "true"}
        class={[
          "relative flex h-28 min-w-0 flex-col items-center px-3 py-2 text-center transition-colors duration-productive ease-productive focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus sm:h-[104px]",
          if(metric == @metric,
            do: "bg-surface-raised",
            else: "bg-surface-sunken hover:bg-surface-raised"
          )
        ]}
      >
        <span class={[
          "block text-label font-semibold",
          if(metric == @metric, do: "text-text-primary", else: "text-text-secondary")
        ]}>
          {metric_label(metric)}
          <span :if={metric == @metric} data-selected-indicator class="sr-only">, shown below</span>
        </span>
        <span class={[
          "mt-1 block text-metric-compact font-semibold tabular-nums",
          if(metric == @metric, do: "text-text-primary", else: "text-text-secondary")
        ]}>
          {headline_reading(@headlines, metric)}
        </span>
        <div :if={@points != []} class="mt-1 flex justify-center">
          <.mini_trend points={@points} metric={metric} />
        </div>
        <span
          :if={metric == @metric}
          aria-hidden="true"
          class="absolute inset-x-0 bottom-0 h-0.5 bg-interactive-primary"
        ></span>
      </.link>
    </div>
    """
  end

  @doc """
  The detail hero chart: the selected metric over this range as one bounded
  line on a scale that starts at zero. Counts carry a restrained wash under
  the line, because a count is a volume; a rate and an average are not
  volumes and carry no fill.

  A covered quiet bucket is a reading of zero and sits on the floor. A bucket
  nobody measured breaks the line and is drawn as nothing. The preceding
  period is stated as a number beside the chart, never drawn behind it.
  """
  attr :source, :any, required: true
  attr :series, :map, required: true, doc: "Alplus.Measure.Dashboard.comparison/4"
  attr :window, :string, required: true
  attr :metric, :string, default: "visits"
  attr :markers, :list, default: []
  attr :empty_label, :string, default: nil
  attr :state, :atom, default: nil, values: [nil, :empty, :error, :ready, :partial, :anomaly]

  attr :retry, :any,
    default: "retry_measure",
    doc: "the phx-click retry event, or false on a page with no LiveView bundle"

  def measure_comparison_chart(assigns) do
    trend =
      Enum.map(Map.get(assigns.series, :slots, []), fn slot ->
        (slot.current || %{})
        |> Map.put(:bucket, slot.bucket)
        |> Map.put_new(:coverage, if(is_nil(slot.current), do: :unknown, else: :full))
      end)

    assigns =
      assign(assigns,
        trend: trend,
        trend_state:
          cond do
            Map.get(assigns.series, :unavailable?, false) -> :error
            assigns.state -> assigns.state
            true -> nil
          end,
        change: selected_change(assigns.series, assigns.metric)
      )

    ~H"""
    <div
      id={"measure-comparison-panel-#{@source.id}"}
      data-metric={@metric}
      class="min-w-0 p-5 pt-6"
    >
      <.traffic_trend
        id={"measure-comparison-chart-#{@source.id}"}
        points={@trend}
        metric={@metric}
        range={@window}
        variant={:full}
        plot_height={:hero}
        release_markers={@markers}
        empty_label={@empty_label}
        state={@trend_state}
        retry={@retry || nil}
      />
      <p
        :if={@change}
        id="measure-detail-change"
        class="mt-3 text-center text-caption text-text-secondary"
      >
        {@change}
      </p>
    </div>
    """
  end

  @doc """
  One ranked breakdown: label, bar and count per row, and every honest state
  the read can be in. The count is printed on every row, so there is no
  second table behind a disclosure.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :data, :map, required: true, doc: "Alplus.Measure.Dashboard.panel/6"
  attr :page_hrefs, :map, default: %{}, doc: "%{previous: path, next: path}"
  attr :favicons?, :boolean, default: false
  attr :class, :any, default: nil

  attr :empty_sentence, :string,
    default: nil,
    doc: "the zero state's own wording, for a panel whose absence of rows is itself a fact"

  def measure_breakdown_panel(assigns) do
    ~H"""
    <.data_panel id={@id} title={@title} class={@class}>
      <.breakdown_body
        id={@id}
        title={@title}
        data={@data}
        page_hrefs={@page_hrefs}
        favicons?={@favicons?}
        empty_sentence={@empty_sentence}
      />
    </.data_panel>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :data, :map, required: true
  attr :page_hrefs, :map, default: %{}
  attr :favicons?, :boolean, default: false
  attr :empty_sentence, :string, default: nil

  defp breakdown_body(assigns) do
    ~H"""
    <div>
      <p
        :if={Map.get(@data, :unavailable?, false)}
        id={"#{@id}-unavailable"}
        class="px-5 py-5 text-caption text-status-error-ink"
        role="status"
      >
        Temporarily unavailable.
      </p>
      <p
        :if={not Map.get(@data, :unavailable?, false) and @data.rows == []}
        id={"#{@id}-empty"}
        class="px-5 py-5 text-caption text-text-tertiary"
      >
        {@empty_sentence || "Nothing recorded in this range."}
      </p>

      <div
        :if={not Map.get(@data, :unavailable?, false) and @data.rows != []}
        id={"#{@id}-bars"}
        class="divide-y divide-border-subtle"
      >
        <div
          :for={row <- Enum.take(@data.rows, 6)}
          class="flex h-10 min-w-0 items-center gap-4 px-5"
        >
          <div class="relative min-w-0 flex-1">
            <span
              aria-hidden="true"
              class="absolute inset-y-0 left-0 rounded-control-sm bg-interactive-wash"
              style={"width: #{bar_width(row.share)}%"}
              data-share={row.share}
            ></span>
            <span class="relative flex min-w-0 items-center gap-2 px-2 text-body text-text-primary">
              <svg :if={@favicons?} class="size-4 shrink-0" aria-hidden="true">
                <use href={AlplusWeb.ReferrerFavicon.sprite_href(row.value)} />
              </svg>
              <span class="truncate">{row.label}</span>
            </span>
          </div>
          <span class="shrink-0 font-mono text-data tabular-nums text-text-secondary">
            {row.count}
          </span>
        </div>
      </div>

      <p
        :if={Map.get(@data, :partial?, false)}
        id={"#{@id}-partial"}
        class="border-t border-border-subtle px-5 py-2.5 text-caption text-text-tertiary"
        role="status"
      >
        Some earlier visit counts are missing, so this list is partial.
      </p>

      <nav
        :if={@data.total_pages > 1}
        aria-label={"#{@title} pages"}
        class="flex items-center justify-between gap-3 border-t border-border-subtle px-5 py-2 text-caption"
      >
        <.link
          :if={@data.previous? and @page_hrefs[:previous]}
          patch={@page_hrefs[:previous]}
          class="inline-flex min-h-target-min items-center text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >Previous</.link>
        <span :if={not @data.previous?} aria-hidden="true"></span>
        <span class="text-text-tertiary">Page {@data.page} of {@data.total_pages}</span>
        <.link
          :if={@data.next? and @page_hrefs[:next]}
          patch={@page_hrefs[:next]}
          class="inline-flex min-h-target-min items-center text-interactive-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >Next</.link>
        <span :if={not @data.next?} aria-hidden="true"></span>
      </nav>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public share: one metric, bucket columns
  # ---------------------------------------------------------------------------

  @doc """
  One metric, plotted once as bucket columns. The public share carries this;
  counts, percentages and seconds never share a plot, because they cannot
  share an honest axis.
  """
  attr :source, :any, required: true
  attr :summary, :any, required: true
  attr :window, :string, required: true
  attr :metric, :string, default: "pageviews"

  attr :retry, :any,
    default: "retry_measure",
    doc: "the phx-click retry event, or false on a page with no LiveView bundle"

  def measure_metric_chart(assigns) do
    trend = Map.get(assigns.summary, :trend, [])
    bars = metric_bars(trend, assigns.metric)

    assigns =
      assign(assigns,
        bars: bars,
        state: chart_state(assigns.summary, bars),
        annotations: release_annotations(Map.get(assigns.summary, :release_markers, []), trend)
      )

    ~H"""
    <div id={"measure-site-chart-panel-#{@source.id}"} data-metric={@metric}>
      <.data_display
        id={"measure-site-chart-#{@source.id}"}
        title={chart_title(@metric)}
        kind={:bucket_bar}
        variant={:full}
        state={@state}
        data={@bars}
        unit={metric_unit(@metric)}
        range={window_axis(@window, "now (UTC)")}
        annotations={@annotations}
        table_columns={["Time", metric_label(@metric)]}
        summary={chart_summary(@state, @window, @source)}
        description={chart_description(@metric, @source, @state, @annotations)}
        retry_event={@retry || nil}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helpers the LiveViews read
  # ---------------------------------------------------------------------------

  @doc """
  The comparison with the preceding equal period as one short line, or `nil`
  when there is nothing comparable: a failed read, a preceding period nobody
  could see, and a preceding period that measured nothing all leave no
  percentage to state, and the chart's own caption already says why.
  """
  def change_text(%{previous: previous, change: change}, metric, window)
      when is_number(previous) and is_number(change) do
    period = "the previous #{window_words(window)}"
    was = metric_reading(previous, metric)

    cond do
      change > 0 -> "Up #{magnitude(change, metric)} on #{period} (#{was})"
      change < 0 -> "Down #{magnitude(abs(change), metric)} on #{period} (#{was})"
      true -> "Level with #{period} (#{was})"
    end
  end

  def change_text(_compared, _metric, _window), do: nil

  @doc "The direction glyph for a comparison `change_text/3` states, or `nil`."
  def change_glyph(%{previous: previous, change: change})
      when is_number(previous) and is_number(change) and change > 0,
      do: "▲"

  def change_glyph(%{previous: previous, change: change})
      when is_number(previous) and is_number(change) and change < 0,
      do: "▼"

  def change_glyph(_compared), do: nil

  @doc """
  The site list in reading order, as `{source, site_summary}` pairs: a site
  that cannot be read, has stopped, or has never sent comes first, then the
  biggest movement in pageviews, then the name.
  """
  def sort_sites(sources, portfolio) do
    sites = Map.get(portfolio, :sites, %{})

    sources
    |> Enum.map(&{&1, Map.get(sites, &1.id, empty_site())})
    |> Enum.sort_by(fn {source, site} ->
      {-site_attention_rank(source, site, portfolio), -abs_delta(site),
       String.downcase(source.name)}
    end)
  end

  @doc """
  The collection state of one site: a fact about the read, never a guess.

  A site that has ever sent a pageview but sent nothing in this period has
  `:stopped`, which is a different fact from `:not_sending` (never connected)
  and from `:quiet` (measured zero inside a covered period). Known pageviews
  under partial coverage still count as collecting: a lower bound above zero
  is evidence that traffic is arriving.
  """
  def site_state(source, site, portfolio) do
    pageviews = site[:pageviews]
    known = Map.get(site, :known_pageviews, pageviews)

    cond do
      Map.get(portfolio, :unavailable?, false) -> :unavailable
      source.status == :revoked -> :revoked
      is_number(known) and known > 0 and sending_now?(site) -> :collecting
      is_number(known) and known > 0 -> :stopped
      not Map.get(site, :evidence?, false) -> :not_sending
      is_number(pageviews) -> :quiet
      true -> :stopped
    end
  end

  # "Collecting traffic" is present tense. A 30-day window holds readings from
  # sites that stopped a week ago, and reading the total as evidence of a live
  # site told the reader the opposite of what the 24-hour window showed. The
  # site is collecting when its last reading is today or yesterday; otherwise
  # the row says when it stopped. A site with no dated evidence keeps the
  # benefit of the doubt rather than being called stopped on missing data.
  defp sending_now?(%{last_pageview_on: %Date{} = on}), do: Date.diff(Date.utc_today(), on) <= 1
  defp sending_now?(_site), do: true

  @doc "The plain-language collection state of one site."
  def site_state_label(state, site \\ %{})
  def site_state_label(:unavailable, _site), do: "Traffic unavailable"
  def site_state_label(:revoked, _site), do: "No longer collecting"
  def site_state_label(:collecting, _site), do: "Collecting traffic"
  def site_state_label(:not_sending, _site), do: "Not sending yet"
  def site_state_label(:quiet, _site), do: "No traffic in this period"

  def site_state_label(:stopped, %{last_pageview_on: %Date{} = on}),
    do: "Stopped sending #{stopped_ago(on)}"

  def site_state_label(:stopped, _site), do: "Stopped sending"

  defp stopped_ago(%Date{} = on) do
    case Date.diff(Date.utc_today(), on) do
      0 -> "today"
      1 -> "1 day ago"
      days -> "#{days} days ago"
    end
  end

  @doc """
  The bucket unit of a window, plural, e.g. `"24h"` -> `"hours"` and `"7d"` ->
  `"days"`: the unit the chart draws, which is the unit the label names.
  """
  def bucket_words(window), do: bucket_word(window) <> "s"

  @doc "The human label for a Measure metric key."
  def metric_label("visits"), do: "Visits"
  def metric_label("pageviews"), do: "Pageviews"
  def metric_label("bounce_rate"), do: "Bounce rate"
  def metric_label("avg_duration"), do: "Visit duration"

  @doc "The four detail metrics, in the order the tabs show them."
  def metric_keys, do: @metrics

  @doc "One reading of a metric, in that metric's own unit."
  def metric_reading(nil, _metric), do: "Unavailable"
  def metric_reading(value, "bounce_rate"), do: "#{value}%"
  def metric_reading(value, "avg_duration"), do: "#{Float.round(value * 1.0, 1)}s"
  def metric_reading(value, _metric), do: with_separators(value)

  def measure_site_path(org_token, project, source),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/measure/#{source.id}"

  def measure_index_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/measure"

  # ---------------------------------------------------------------------------
  # Portfolio internals
  # ---------------------------------------------------------------------------

  # A series with nothing above the floor is an empty period, and says so in
  # words rather than as a 420px frame around a flat line.
  defp any_signal?(values), do: Enum.any?(values, &(is_number(&1) and &1 > 0))

  defp portfolio_empty_label(true, _window),
    do: "Pageviews appear here once a site starts sending them."

  defp portfolio_empty_label(false, window),
    do: "No pageviews in the last #{window_words(window)}."

  # Painting order: the scale guides under everything, then the floor the
  # readings stand on, then the dots a sparse series needs to be visible at
  # all. The series itself is the display's own `svg_path`/`svg_area`.
  defp series_overlays(values, scale, metric) do
    scale_guides(scale, metric, values) ++
      Enum.filter(
        [
          %{path: @baseline_path, class: "stroke-border-control", width: "1"},
          overlay(reading_dots(values, scale), "stroke-interactive-strong", "6")
        ],
        &is_map/1
      )
  end

  defp overlay(nil, _class, _width), do: nil

  defp overlay(path, class, width),
    do: %{path: path, class: class, width: width, linecap: "round"}

  # Unknown time is a thin neutral rail above the baseline. It never occupies
  # the plot as a filled rectangle and never sits on zero.
  defp untracked_spans(coverage_states) do
    count = length(coverage_states)

    tracked =
      coverage_states
      |> Enum.with_index()
      |> Enum.reject(fn {coverage, _index} -> coverage == :unknown end)

    case tracked do
      [] ->
        [%{left: 0.0, width: 100.0, label: "Untracked"}]

      _tracked ->
        {_coverage, first} = hd(tracked)
        {_coverage, last} = List.last(tracked)

        [
          if(first > 0, do: leading_span(first, count)),
          if(last < count - 1, do: trailing_span(last, count))
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp leading_span(first, count) do
    width = (plot_x(first - 1, count) + plot_x(first, count)) / 2
    %{left: 0.0, width: round2(width), label: "Untracked", end_label: "Tracking started"}
  end

  defp trailing_span(last, count) do
    left = (plot_x(last, count) + plot_x(last + 1, count)) / 2
    %{left: round2(left), width: round2(100.0 - left), label: "Untracked"}
  end

  defp sites_reading(%{active_sites: active, connected_sites: connected}),
    do: "#{active} of #{connected}"

  defp sites_reading(_totals), do: "Unavailable"

  # The cell's own comparison, short enough to sit under its number.
  defp reading_caption(_compared, true), do: "Nothing yet"

  defp reading_caption(%{previous: previous, change: change}, _placeholder)
       when is_number(previous) and is_number(change),
       do: short_change(change, "count", previous)

  defp reading_caption(_compared, _placeholder), do: nil

  defp selected_change(series, metric) do
    headlines = Map.get(series, :headlines, %{})

    case Map.get(headlines, String.to_existing_atom(metric), %{}) do
      %{previous: previous, change: change} when is_number(previous) and is_number(change) ->
        short_change(change, metric, previous)

      _other ->
        nil
    end
  end

  defp short_change(change, metric, _previous) when change > 0,
    do: "Up #{magnitude(change, metric)} from the previous period"

  defp short_change(change, metric, _previous) when change < 0,
    do: "Down #{magnitude(abs(change), metric)} from the previous period"

  defp short_change(_change, _metric, _previous), do: "Level with the previous period"

  defp reading_value(_compared, true), do: "Not tracked"

  defp reading_value(%{coverage: :partial, known_value: value}, _placeholder)
       when is_number(value),
       do: count_reading(value)

  defp reading_value(%{coverage: :unknown}, _placeholder), do: "Not measured"
  defp reading_value(%{value: value}, _placeholder), do: count_reading(value)
  defp reading_value(_compared, _placeholder), do: "Unavailable"

  defp count_reading(nil), do: "Not measured"
  defp count_reading(value), do: with_separators(value)

  defp site_count_reading(%{coverage: :partial, known_pageviews: value}) when is_number(value),
    do: count_reading(value)

  defp site_count_reading(site), do: count_reading(Map.get(site, :pageviews))

  # 15969 reads as a code; 15,969 reads as a count.
  defp with_separators(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp with_separators(value), do: to_string(value)

  # A whole percentage is printed whole. "75.0%" is a float leaking into the
  # sentence, not a reading.
  defp magnitude(change, "bounce_rate"), do: "#{trim_float(change)} points"
  defp magnitude(change, _metric), do: "#{trim_float(change)}%"

  defp trim_float(value) when is_float(value) do
    rounded = Float.round(value, 1)
    if rounded == Float.round(rounded, 0), do: to_string(round(rounded)), else: to_string(rounded)
  end

  defp trim_float(value), do: to_string(value)

  # ---------------------------------------------------------------------------
  # Site rows
  # ---------------------------------------------------------------------------

  defp empty_site do
    %{
      pageviews: nil,
      visits: nil,
      pageviews_previous: nil,
      pageviews_delta: nil,
      pageviews_change: nil,
      active?: false,
      trend: []
    }
  end

  defp site_attention_rank(source, site, portfolio) do
    case site_state(source, site, portfolio) do
      :unavailable -> 4
      :stopped -> 3
      :revoked -> 2
      :not_sending -> 1
      :quiet -> 0
      :collecting -> 0
    end
  end

  defp abs_delta(site) do
    case site[:pageviews_delta] do
      value when is_number(value) -> abs(value)
      _other -> 0
    end
  end

  defp site_state_tone(:unavailable), do: "error"
  defp site_state_tone(:stopped), do: "warning"
  defp site_state_tone(:revoked), do: "paused"
  defp site_state_tone(:collecting), do: "success"
  defp site_state_tone(_state), do: "neutral"

  # ---------------------------------------------------------------------------
  # Detail internals
  # ---------------------------------------------------------------------------

  defp headline_reading(nil, _metric), do: "Unavailable"

  # A rate or an average with no visits behind it has no denominator. That
  # is a measured nothing, so it reads as the zero of its own unit rather
  # than as a failed read.
  defp headline_reading(headlines, metric) do
    reading = Map.get(headlines, String.to_existing_atom(metric), %{})
    value = Map.get(reading, :value)
    visits = headlines |> Map.get(:visits, %{}) |> Map.get(:value)

    case {Map.get(reading, :coverage), Map.get(reading, :known_value), value, metric, visits} do
      {:partial, known, nil, metric, _visits}
      when is_number(known) and metric in ["visits", "pageviews"] ->
        metric_reading(known, metric)

      {_coverage, _known, nil, "bounce_rate", 0} ->
        "0%"

      {_coverage, _known, nil, "avg_duration", 0} ->
        "0s"

      _other ->
        metric_reading(value, metric)
    end
  end

  # A count is a volume and may carry a fill under its line. A rate and an
  # average are not volumes: the area under 40% has no meaning, so it is not
  # drawn.
  defp filled?(metric), do: metric in ["visits", "pageviews"]

  defp bar_width(value) when is_number(value), do: value |> max(0) |> min(100) |> Float.round(1)
  defp bar_width(_value), do: 0

  # ---------------------------------------------------------------------------
  # Plot geometry
  # ---------------------------------------------------------------------------

  # The top of the axis is the first round number at or above the tallest
  # reading (1, 2, 2.5, 5 times a power of ten), so the guides carry values a
  # reader can hold ("2.5k", "5k") rather than a quarter of 16. A zero-only
  # series still needs a denominator.
  defp plot_scale(values) do
    largest = values |> Enum.filter(&is_number/1) |> Enum.max(fn -> 0 end)
    if largest > 0, do: nice_ceiling(largest), else: 1
  end

  defp nice_ceiling(value) do
    magnitude = :math.pow(10, :math.floor(:math.log10(value)))
    step = Enum.find([1, 2, 2.5, 5, 10], &(&1 * magnitude >= value))
    round_scale(step * magnitude)
  end

  defp round_scale(scale) when scale >= 10, do: round(scale)
  defp round_scale(scale), do: scale

  # Compact numerals for the axis: 1200 reads "1.2k" beside a 420px plot.
  defp compact(value) when is_float(value), do: compact_float(value)
  defp compact(value) when value >= 1_000_000, do: "#{trim_float(value / 1_000_000)}M"
  defp compact(value) when value >= 1_000, do: "#{trim_float(value / 1_000)}k"
  defp compact(value), do: to_string(value)

  defp compact_float(value) do
    if value == Float.round(value, 0),
      do: compact(round(value)),
      else: to_string(Float.round(value, 1))
  end

  # Up to six date ticks along the bottom, evenly spaced through the buckets
  # and each on the x of the reading it names.
  defp x_labels(buckets) when length(buckets) < 2, do: []

  defp x_labels(buckets) do
    count = length(buckets)
    step = max(div(count - 1, 5), 1)

    buckets
    |> Enum.with_index()
    |> Enum.filter(fn {_bucket, index} -> rem(index, step) == 0 end)
    |> Enum.map(fn {bucket, index} ->
      %{position: plot_x(index, count), label: tick_label(bucket)}
    end)
  end

  defp tick_label(%DateTime{} = bucket), do: Calendar.strftime(bucket, "%H:%M")
  defp tick_label(%Date{} = bucket), do: Calendar.strftime(bucket, "%b %-d")

  # Bounce rate is a share of visits, so it is read against the whole scale it
  # can occupy: fitted to its own maximum, a series swinging between twenty and
  # forty percent fills the plot to the ceiling and reads as a collapse.
  defp metric_scale("bounce_rate", _values), do: 100
  defp metric_scale(_metric, values), do: plot_scale(values)

  # Five quiet guides off the vertical scale, each a dotted hairline carrying
  # its own round value at the right edge, so a magnitude can be read without
  # hovering a point. Fifths of a 1, 2, 2.5, 5 or 10 scale are always clean
  # numbers. The floor rule carries the zero.
  defp scale_guides(scale, metric, values) do
    if any_signal?(values) do
      [1.0, 0.8, 0.6, 0.4, 0.2]
      |> Enum.map(&{plot_y(scale * &1, scale), guide_label(scale * &1, metric)})
      |> Enum.uniq_by(fn {_y, label} -> label end)
      |> Enum.map(fn {y, label} ->
        %{
          path: "M0,#{y} L100,#{y}",
          class: "stroke-border-control",
          width: "1",
          dash: "1 3",
          label: label,
          label_y: "#{Float.round(y / 40 * 100, 2)}%"
        }
      end)
    else
      []
    end
  end

  defp guide_label(value, "bounce_rate"), do: "#{round(value)}%"
  defp guide_label(value, "avg_duration"), do: "#{compact(value)}s"
  defp guide_label(value, _metric), do: compact(value)

  defp plot_x(_index, count) when count < 2, do: 50.0
  defp plot_x(index, count), do: Float.round(index / (count - 1) * 100, 2)

  defp plot_y(value, scale),
    do: Float.round(@plot_bottom - value / scale * (@plot_bottom - @plot_top), 2)

  # Contiguous runs of measured buckets, each with its slot index. A `nil` ends
  # a run: the path restarts on the far side rather than spanning it, because
  # a line across an unmeasured stretch is an invented reading.
  defp measured_runs(values) do
    values
    |> Enum.with_index()
    |> Enum.chunk_by(fn {value, _index} -> is_nil(value) end)
    |> Enum.reject(fn [{value, _index} | _rest] -> is_nil(value) end)
  end

  defp run_points(values, scale) do
    count = length(values)

    values
    |> measured_runs()
    |> Enum.map(fn run ->
      Enum.map(run, fn {value, index} -> {plot_x(index, count), plot_y(value, scale)} end)
    end)
  end

  # Each measured stretch is one curve through its own readings, and a gap
  # ends a stretch. A stretch of one reading draws no line at all: its dot is
  # the whole of what was measured.
  # A series of three readings or fewer is its dots: a line between two lone
  # readings is a wall, not a trend, and the hatch beside them already says
  # the rest of the range was not tracked.
  defp series_path(values, scale) do
    if sparse?(values), do: nil, else: dense_path(values, scale)
  end

  defp sparse?(values), do: Enum.count(values, &is_number/1) <= @sparse_reading_cap

  defp dense_path(values, scale) do
    values
    |> run_points(scale)
    |> Enum.map(&curve/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> presence()
  end

  defp curve(points) when length(points) < 2, do: ""

  # Monotone cubic interpolation. Each segment's tangents are clamped by the
  # Fritsch-Carlson condition, so the curve between two readings stays between
  # those two readings: a spike cannot bulge past its own peak and a return to
  # zero cannot dip below the floor.
  defp curve(points) do
    slopes = monotone_slopes(points)
    pairs = Enum.zip(points, slopes)

    segments =
      pairs
      |> Enum.zip(Enum.drop(pairs, 1))
      |> Enum.map_join(" ", fn {{{x1, y1}, m1}, {{x2, y2}, m2}} ->
        third = (x2 - x1) / 3

        "C#{round2(x1 + third)},#{round2(y1 + m1 * third)} " <>
          "#{round2(x2 - third)},#{round2(y2 - m2 * third)} #{round2(x2)},#{round2(y2)}"
      end)

    {first_x, first_y} = List.first(points)
    "M#{round2(first_x)},#{round2(first_y)} " <> segments
  end

  defp monotone_slopes(points) do
    secants =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{x1, y1}, {x2, y2}] -> (y2 - y1) / (x2 - x1) end)

    count = length(points)
    first = List.first(secants)
    last = List.last(secants)

    # A local extremum gets a flat tangent, which is what stops the curve
    # turning a peak into a taller peak.
    initial =
      Map.new(0..(count - 1), fn
        0 ->
          {0, first}

        index when index == count - 1 ->
          {index, last}

        index ->
          before = Enum.at(secants, index - 1)
          after_ = Enum.at(secants, index)
          {index, if(before * after_ <= 0, do: 0.0, else: (before + after_) / 2)}
      end)

    slopes =
      Enum.reduce(0..(count - 2), initial, fn index, acc ->
        secant = Enum.at(secants, index)
        left = Map.fetch!(acc, index)
        right = Map.fetch!(acc, index + 1)

        if secant == 0 do
          acc |> Map.put(index, 0.0) |> Map.put(index + 1, 0.0)
        else
          alpha = left / secant
          beta = right / secant
          radius = alpha * alpha + beta * beta

          if radius > 9 do
            factor = 3 / :math.sqrt(radius)

            acc
            |> Map.put(index, factor * alpha * secant)
            |> Map.put(index + 1, factor * beta * secant)
          else
            acc
          end
        end
      end)

    Enum.map(0..(count - 1), &Map.fetch!(slopes, &1))
  end

  # Fill is volume, so it belongs only under readings that exist: it follows
  # the same curve and stops at the edges of the stretch that produced it.
  defp measured_area(values, scale) do
    if sparse?(values), do: nil, else: dense_area(values, scale)
  end

  defp dense_area(values, scale) do
    values
    |> run_points(scale)
    |> Enum.reject(&(length(&1) < 2))
    |> Enum.map_join(" ", fn points ->
      {first_x, _first_y} = List.first(points)
      {last_x, _last_y} = List.last(points)

      "M#{round2(first_x)},#{@plot_baseline} " <>
        String.replace_prefix(curve(points), "M", "L") <>
        " L#{round2(last_x)},#{@plot_baseline} Z"
    end)
    |> presence()
  end

  # A zero-length subpath with a round cap is a dot, so one path carries every
  # marker without a shape per reading. A dense series gets none: the curve
  # already shows where its readings are.
  defp reading_dots(values, scale) do
    points = values |> run_points(scale) |> List.flatten()

    if points != [] and sparse?(values) do
      Enum.map_join(points, " ", fn {x, y} -> "M#{x},#{y} L#{x},#{y}" end)
    else
      nil
    end
  end

  defp round2(value), do: Float.round(value * 1.0, 2)

  defp presence(""), do: nil
  defp presence(string), do: string

  # ---------------------------------------------------------------------------
  # Bucket series (public share)
  # ---------------------------------------------------------------------------

  defp chart_state(%{unavailable?: true}, _bars), do: :error
  defp chart_state(_summary, []), do: :empty
  defp chart_state(_summary, _bars), do: :ready

  defp chart_title("pageviews"), do: "Pageviews over time"
  defp chart_title(metric), do: "#{metric_label(metric)} over time"

  defp chart_summary(:error, _window, source),
    do: "Traffic for #{source.name} is temporarily unavailable."

  defp chart_summary(:empty, window, _source),
    do: "Nothing recorded in the last #{window_words(window)} yet."

  defp chart_summary(_state, _window, _source), do: nil

  defp chart_description(metric, source, state, annotations) do
    [
      "#{metric_label(metric)} recorded for #{source.name}.",
      "A time nobody measured is left blank rather than shown as zero.",
      markers_drawn?(state, annotations) && "Release markers show deploys during this period."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp markers_drawn?(state, annotations),
    do: state in [:ready, :partial, :anomaly] and annotations != []

  defp metric_bars([], _metric), do: []

  defp metric_bars(trend, metric) do
    field = String.to_existing_atom(metric)
    values = trend |> Enum.map(&metric_value(&1, field)) |> Enum.reject(&is_nil/1)

    if values == [] do
      []
    else
      metric_bars(trend, metric, field, metric_scale(metric, values))
    end
  end

  defp metric_bars(trend, metric, field, max_v) do
    Enum.map(trend, fn point ->
      value = metric_value(point, field)
      readable = if is_nil(value), do: "Not recorded", else: metric_hover_value(metric, value)
      sentence = "#{bucket_label(point.bucket)}, #{metric_label(metric)}: #{readable}"

      %{
        id: bucket_iso(point.bucket),
        label: bucket_axis_label(point.bucket),
        value: value,
        measured?: is_number(value),
        height: if(is_nil(value), do: nil, else: value / max_v * 100),
        tone: if(is_nil(value), do: "neutral", else: "emphasis"),
        tooltip: sentence,
        aria_label: sentence,
        table_cells: [bucket_label(point.bucket), readable]
      }
    end)
  end

  defp metric_value(point, :visits), do: Map.get(point, :visits, Map.get(point, :visitors))
  defp metric_value(point, field), do: Map.get(point, field)

  # ---------------------------------------------------------------------------
  # Buckets, axes and release markers
  # ---------------------------------------------------------------------------

  # A release marker sits where the release actually landed inside the plotted
  # range. A release outside the range is not drawn rather than pinned to an
  # edge, and only the most recent few are labelled so the pills stay readable.
  defp release_annotations(markers, trend) when is_list(markers) and length(trend) > 1 do
    first = trend |> List.first() |> Map.fetch!(:bucket) |> bucket_unix()
    last = trend |> List.last() |> Map.fetch!(:bucket) |> bucket_unix()
    span = last - first

    if span <= 0 do
      []
    else
      markers
      |> Enum.filter(&match?(%{deployed_at: %DateTime{}}, &1))
      |> Enum.sort_by(&DateTime.to_unix(&1.deployed_at), :desc)
      |> Enum.take(@max_release_annotations)
      |> Enum.flat_map(fn marker ->
        offset = DateTime.to_unix(marker.deployed_at) - first

        if offset < 0 or offset > span do
          []
        else
          [%{label: Map.get(marker, :version) || "Release", position: offset / span * 100}]
        end
      end)
      |> Enum.sort_by(& &1.position)
    end
  end

  defp release_annotations(_markers, _trend), do: []

  defp bucket_unix(%DateTime{} = bucket), do: DateTime.to_unix(bucket)

  defp bucket_unix(%Date{} = bucket),
    do: bucket |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  defp bucket_iso(%DateTime{} = bucket), do: DateTime.to_iso8601(bucket)
  defp bucket_iso(%Date{} = bucket), do: Date.to_iso8601(bucket)

  # The unit the chart actually draws: one hour for 24h, one calendar day for
  # every longer range, exactly as many as the label counts.
  defp bucket_word("24h"), do: "hour"
  defp bucket_word(_window), do: "day"

  # The hero axis: where the range starts, and "now" with the clock it is on.
  # The middle cell is deliberately blank; there is one series and its unit
  # is in the readings above the plot.
  defp axis(window), do: %{start: "#{window_words(window)} ago", mid: "", end: "now (UTC)"}

  defp metric_unit("visits"), do: "visits"
  defp metric_unit("pageviews"), do: "pageviews"
  defp metric_unit("bounce_rate"), do: "%"
  defp metric_unit("avg_duration"), do: "seconds"

  defp metric_hover_value("bounce_rate", value), do: "#{value}%"
  defp metric_hover_value("avg_duration", value), do: "#{value} seconds"
  defp metric_hover_value("pageviews", 1), do: "1 pageview"
  defp metric_hover_value("pageviews", value), do: "#{value} pageviews"
  defp metric_hover_value("visits", 1), do: "1 visit"
  defp metric_hover_value("visits", value), do: "#{value} visits"
  defp metric_hover_value(_metric, value), do: to_string(value)

  defp bucket_label(%DateTime{} = bucket), do: format_utc(bucket)
  defp bucket_label(%Date{} = bucket), do: Calendar.strftime(bucket, "%b %-d UTC")

  defp bucket_axis_label(%DateTime{} = bucket), do: Calendar.strftime(bucket, "%H:%M")
  defp bucket_axis_label(%Date{} = bucket), do: Calendar.strftime(bucket, "%m-%d")
end
