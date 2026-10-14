defmodule AlplusWeb.DataDisplayComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AlplusWeb.DataDisplayComponents

  @kinds [
    :bucket_bar,
    :ticks,
    :step,
    :wave,
    :line,
    :stacked,
    :histogram,
    :ranked_bar,
    :proportional_meter,
    :day_grid
  ]

  @data [
    %{
      label: "First",
      value: 1,
      state: :up,
      tone: :live,
      height: "height: 50%",
      width: "width: 50%",
      tooltip: "First, 1 ms",
      table_cells: ["First", "1 ms"]
    },
    %{
      label: "Second",
      value: 2,
      state: :missing,
      tone: :neutral,
      height: "height: 25%",
      width: "width: 25%",
      tooltip: "Second, 2 ms",
      table_cells: ["Second", "2 ms"]
    }
  ]

  test "renders every documented display kind through the shared grammar" do
    for kind <- @kinds do
      html =
        render_component(&DataDisplayComponents.data_display/1,
          id: "display-#{kind}",
          title: "Example #{kind}",
          kind: kind,
          data: @data,
          svg_path: "M 0 0 L 100 20",
          svg_area: "M 0 0 L 100 20 L 100 40 L 0 40 Z"
        )

      assert html =~ "data-display-kind=\"#{kind}\""
      assert html =~ "data-touch-tooltip=\"true\""
      assert html =~ "data-keyboard-tooltip=\"true\""
    end
  end

  test "full displays expose units, range, annotations, thresholds, focus tooltips, and the exact table" do
    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "latency-display",
        title: "Response latency",
        kind: :line,
        variant: :full,
        state: :partial,
        data: @data,
        unit: "ms",
        range: %{start: "00:00 UTC", end: "01:00 UTC"},
        thresholds: [%{label: "Warning", value: 500}],
        annotations: [%{label: "Deploy"}],
        summary: "Partial coverage",
        description: "Response latency for the selected range.",
        svg_path: "M 0 0 L 100 20",
        table_columns: ["Sample", "Value"]
      )

    assert html =~ "Unit: ms"
    assert html =~ "Range start: 00:00 UTC"
    assert html =~ "Warning"
    assert html =~ "Deploy"
    refute html =~ "Partial data. Some intervals were not measured."
    assert html =~ "View data table"
    assert html =~ "First"
    assert html =~ "1 ms"
    assert html =~ "group-focus-within:block"
    # One Tab stop enters the plot; the other points are reached with arrows.
    assert length(Regex.scan(~r/tabindex="0"/, html)) == 1
    assert html =~ "tabindex=\"-1\""
    assert html =~ "Use the left and right arrow keys"
    assert html =~ "data-display-selected"
    assert html =~ "scope=\"col\""
    assert length(Regex.scan(~r/data-display-point=\"true\"/, html)) == 2
    [tbody] = Regex.run(~r/<tbody>(.*?)<\/tbody>/s, html, capture: :all_but_first)
    assert length(Regex.scan(~r/<tr\b/, tbody)) == 2
  end

  test "rejects a full display without an exact table alternative" do
    assert_raise ArgumentError, ~r/table_cells/, fn ->
      render_component(&DataDisplayComponents.data_display/1,
        id: "invalid-table-rows",
        title: "Latency",
        kind: :line,
        variant: :full,
        data: [%{label: "First", value: 1}],
        table_columns: ["Sample", "Value"]
      )
    end

    assert_raise ArgumentError, ~r/table_columns/, fn ->
      render_component(&DataDisplayComponents.data_display/1,
        id: "invalid-table-columns",
        title: "Latency",
        kind: :line,
        variant: :full,
        data: @data
      )
    end

    assert_raise ArgumentError, ~r/arbitrary table_rows/, fn ->
      render_component(&DataDisplayComponents.data_display/1,
        id: "invalid-table-record",
        title: "Latency",
        kind: :line,
        variant: :full,
        data: @data,
        table_columns: ["Sample", "Value"],
        table_rows: [%{cells: ["Wrong", "999"]}]
      )
    end
  end

  test "renders explicit loading, empty, and error states" do
    loading =
      render_component(&DataDisplayComponents.data_display/1,
        id: "loading-display",
        title: "Uptime",
        kind: :ticks,
        state: :loading
      )

    assert loading =~ "Loading data"
    refute loading =~ "animate-pulse"

    empty =
      render_component(&DataDisplayComponents.data_display/1,
        id: "empty-display",
        title: "Uptime",
        kind: :ticks,
        state: :empty
      )

    assert empty =~ "No data in this range yet."
    assert empty =~ "border-dashed"

    error =
      render_component(&DataDisplayComponents.data_display/1,
        id: "error-display",
        title: "Uptime",
        kind: :ticks,
        state: :error,
        retry_event: "retry_display"
      )

    assert error =~ "We couldn't load this chart. Try again."
    assert error =~ "phx-click=\"retry_display\""
    assert error =~ "border-status-error"
  end

  test "renders explicit disabled, permission, and unavailable states" do
    for {state, message, icon} <- [
          {:disabled, "This data is disabled.", "hero-pause-circle"},
          {:permission, "You do not have permission to view this data.", "hero-lock-closed"},
          {:unavailable, "This data is temporarily unavailable. Try again.",
           "hero-exclamation-triangle"}
        ] do
      html =
        render_component(&DataDisplayComponents.data_display/1,
          id: "#{state}-display",
          title: "Uptime",
          kind: :ticks,
          state: state,
          data: @data
        )

      assert html =~ ~s(data-display-state="#{state}")
      assert html =~ message
      assert html =~ icon
      assert html =~ ~s(role="status")
      refute html =~ ~s(data-display-point="true")
    end
  end

  test "keeps every visual point at the shared keyboard and touch target floor" do
    for kind <- @kinds do
      html =
        render_component(&DataDisplayComponents.data_display/1,
          id: "target-#{kind}",
          title: "Example #{kind}",
          kind: kind,
          data: @data
        )

      point_tags =
        ~r/<button\b[^>]*data-display-point="true"[^>]*>/s
        |> Regex.scan(html)
        |> List.flatten()

      assert length(point_tags) == length(@data)

      assert Enum.all?(point_tags, fn tag ->
               tag =~ "absolute" and tag =~ "bg-transparent" and
                 tag =~ "min-h-target-min" and tag =~ target_width_class(kind)
             end)
    end
  end

  # Every plot tiles its pointer targets across its own cells so that a dense
  # series can never stack 44px-wide targets on top of one another: at 24
  # hourly buckets in a 326px column the cells are 13.6px apart, and centred
  # 44px targets swallowed three neighbours each. A target is its cell, which
  # never overlaps a neighbour, and the visible table below `sm` is the
  # conforming path for a finger. The ranked bar and the day grid keep a
  # fixed-width target because their items are already wide.
  defp target_width_class(kind) when kind in [:ranked_bar, :day_grid], do: "min-w-target-min"
  defp target_width_class(_kind), do: "inset-x-0"

  test "keeps dense tooltip points at the shared keyboard and touch target floor" do
    for kind <- [:ticks, :bucket_bar, :step, :wave, :line] do
      html =
        render_component(&DataDisplayComponents.data_display/1,
          id: "target-#{kind}",
          title: "Example #{kind}",
          kind: kind,
          data: @data
        )

      point_tags =
        ~r/<button\b[^>]*data-display-point="true"[^>]*>/s
        |> Regex.scan(html)
        |> List.flatten()

      assert length(point_tags) == length(@data)

      assert Enum.all?(point_tags, fn tag ->
               tag =~ "absolute" and tag =~ "min-h-target-min" and
                 tag =~ target_width_class(kind)
             end)
    end
  end

  test "a dense line bounds its focus targets and keeps every row in the table" do
    data =
      for index <- 1..168 do
        %{
          id: "b#{index}",
          label: "Bucket #{index}",
          value: index,
          tooltip: "Bucket #{index}, #{index} ms",
          table_cells: ["Bucket #{index}", "#{index} ms"]
        }
      end

    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "dense-line",
        title: "Dense line",
        kind: :line,
        variant: :full,
        data: data,
        svg_path: "M0,20 L100,20",
        table_columns: ["Bucket", "Value"]
      )

    targets =
      ~r/<button\b[^>]*data-display-point="true"[^>]*>/s
      |> Regex.scan(html)
      |> List.flatten()

    # Bounded focus targets, each a real bucket rather than a merged summary,
    # spanning the whole series from its first sample to its last. A full
    # plot keeps the full tick allowance, thirty-six.
    assert length(targets) == 36
    assert Enum.at(targets, 0) =~ "Bucket 1,"
    assert Enum.at(targets, 35) =~ "Bucket 168,"

    # Nothing is dropped from the textual alternative.
    rows = Regex.scan(~r/<tr\b/, html) |> length()
    assert rows == 169
  end

  test "a sampled line keeps each sample's own x and splits hits at the midpoints" do
    data =
      for index <- 1..168 do
        %{
          id: "b#{index}",
          label: "Bucket #{index}",
          value: index,
          tooltip: "Bucket #{index}, #{index} ms",
          table_cells: ["Bucket #{index}", "#{index} ms"]
        }
      end

    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "sampled-line",
        title: "Sampled line",
        kind: :line,
        variant: :full,
        data: data,
        svg_path: "M0,20 L100,20",
        table_columns: ["Bucket", "Value"]
      )

    # The plot fills its box, so a viewBox x is the same percentage in the
    # hit layer. A letterboxed plot would put every target beside its point.
    assert html =~ ~s(preserveAspectRatio="none")

    xs =
      ~r/data-display-point-x="([0-9.]+)"/
      |> Regex.scan(html)
      |> Enum.map(fn [_match, x] -> String.to_float(x) end)

    regions =
      ~r/data-display-region="([0-9.]+) ([0-9.]+)"/
      |> Regex.scan(html)
      |> Enum.map(fn [_match, left, width] ->
        {String.to_float(left), String.to_float(width)}
      end)

    # Thirty-six evenly stepped samples of the original 168, each keeping the
    # x it is drawn at rather than being re-laid-out at equal spacing.
    assert length(xs) == 36
    assert Enum.at(xs, 0) == 0.0
    assert Enum.at(xs, 1) == Float.round(round(167 / 35) / 167 * 100, 2)
    assert Enum.at(xs, 35) == 100.0

    # Each region runs from the midpoint behind to the midpoint ahead, edges
    # included, so the regions tile the plot exactly once.
    assert Enum.at(regions, 0) == {0.0, Float.round(Enum.at(xs, 1) / 2, 2)}

    {second_left, second_width} = Enum.at(regions, 1)
    assert second_left == Float.round(Enum.at(xs, 1) / 2, 2)

    assert abs(second_width - ((Enum.at(xs, 1) + Enum.at(xs, 2)) / 2 - second_left)) < 0.02

    {last_left, last_width} = Enum.at(regions, 35)
    assert last_left == Float.round((Enum.at(xs, 34) + 100.0) / 2, 2)
    assert last_width == Float.round(100.0 - last_left, 2)

    edges = Enum.map(regions, fn {left, width} -> Float.round(left + width, 2) end)

    assert Enum.zip(Enum.drop(edges, -1), Enum.drop(Enum.map(regions, &elem(&1, 0)), 1))
           |> Enum.all?(fn {edge, next_left} -> abs(edge - next_left) < 0.02 end)

    assert List.last(edges) == 100.0

    # A sample sitting on the plot edge only gets half a span, so the two end
    # targets reach into the card's gutter to stay hittable. Every interior
    # boundary stays exactly on its midpoint.
    assert html =~
             ~s|style="left: -12px; width: calc(#{Float.round(Enum.at(xs, 1) / 2, 2)}% + 12px)"|

    assert html =~ ~s|width: calc(#{last_width}% + 12px)|
    assert html =~ ~s|style="left: #{second_left}%; width: #{second_width}%"|
  end

  test "keeps first and last tooltips inside a visible plot layer" do
    for kind <- [:ticks, :bucket_bar, :step, :wave, :line] do
      html =
        render_component(&DataDisplayComponents.data_display/1,
          id: "edge-#{kind}",
          title: "Example #{kind}",
          kind: kind,
          data: @data
        )

      tooltip_classes =
        ~r/<span\s+role="tooltip"\s+aria-hidden="true"\s+class="([^"]+)"/s
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      assert length(tooltip_classes) == length(@data)
      assert List.first(tooltip_classes) =~ "left-0 translate-x-0"
      assert List.last(tooltip_classes) =~ "right-0 translate-x-0"
      assert html =~ "min-w-0 overflow-visible"
      assert html =~ "max-w-[min(18rem,calc(100vw-2rem))]"
      assert html =~ "whitespace-normal"
    end
  end

  test "uses the shared tick and plot height tiers" do
    compact_ticks =
      render_component(&DataDisplayComponents.data_display/1,
        id: "compact-ticks",
        title: "Compact ticks",
        kind: :ticks,
        variant: :compact,
        data: @data
      )

    full_ticks =
      render_component(&DataDisplayComponents.data_display/1,
        id: "full-ticks",
        title: "Full ticks",
        kind: :ticks,
        variant: :full,
        data: @data,
        table_columns: ["Sample", "Value"]
      )

    hero =
      render_component(&DataDisplayComponents.data_display/1,
        id: "hero-line",
        title: "Hero line",
        kind: :line,
        variant: :full,
        plot_height: :hero,
        data: @data,
        table_columns: ["Sample", "Value"]
      )

    assert compact_ticks =~ "h-6"
    assert full_ticks =~ "h-8"
    assert hero =~ "h-60 sm:h-64 lg:h-80"
    refute hero =~ "lg:h-[420px]"
  end

  test "compact displays keep a visible summary and keyboard focus targets" do
    accessibility_data = [
      %{
        label: "00:00 UTC to 00:01 UTC",
        value: "Up",
        aria_label: "00:00 UTC to 00:01 UTC, Up, 3 checks",
        tooltip: "00:00 UTC to 00:01 UTC, Up, 3 checks",
        tone: :live
      }
    ]

    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "compact-display",
        title: "Uptime",
        kind: :bucket_bar,
        state: :anomaly,
        summary: "Anomalous evidence",
        data: accessibility_data,
        legend: [%{label: "Up", tone: :live, count: 1}]
      )

    assert html =~ "Anomalous evidence"
    assert html =~ "data-display-point=\"true\""
    assert html =~ "focus-visible:border-focus"
    assert html =~ "role=\"group\""
    refute html =~ "role=\"img\""
    assert html =~ "aria-label=\"00:00 UTC to 00:01 UTC, Up, 3 checks\""
    assert html =~ "00:00 UTC to 00:01 UTC, Up, 3 checks"

    # A compact strip's textual equivalent is its summary sentence plus the
    # per-point aria-label. The table alternative belongs to `:full`, so an
    # index row list is never buried under one table per row.
    refute html =~ "View data table"
    refute html =~ "<tbody"

    # The caller's summary already names the condition, so the generic verdict
    # is not printed a second time beside it on a compact strip.
    refute html =~ "Anomalous values need review"
  end

  test "a compact display with no summary still states its condition in words" do
    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "compact-bare",
        title: "Uptime",
        kind: :bucket_bar,
        state: :anomaly,
        data: [%{label: "00:00 UTC", value: "Up", tone: :live}]
      )

    assert html =~ "Anomalous values need review"
  end

  test "a full display keeps both its summary and the generic state verdict" do
    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "full-display",
        title: "Uptime",
        kind: :bucket_bar,
        variant: :full,
        state: :anomaly,
        summary: "Anomalous evidence",
        range: %{start: "-24h", end: "now"},
        table_columns: ["Time", "State"],
        data: [
          %{label: "00:00 UTC", value: "Up", tone: :live, table_cells: ["00:00 UTC", "Up"]}
        ]
      )

    assert html =~ "Anomalous evidence"
    assert html =~ "Anomalous values need review"
    assert html =~ "View data table"
  end

  test "the axis names the unit alone, never how the chart was drawn" do
    html =
      render_component(&DataDisplayComponents.data_display/1,
        id: "axis-display",
        title: "Pageviews",
        kind: :bucket_bar,
        variant: :full,
        unit: "pageviews",
        range: %{start: "-7d", end: "now"},
        table_columns: ["Time", "Pageviews"],
        data: [
          %{label: "Mon", value: 3, tone: :emphasis, table_cells: ["Mon", "3"]}
        ]
      )

    assert html =~ "pageviews"
    refute html =~ "zero-based"
  end
end
