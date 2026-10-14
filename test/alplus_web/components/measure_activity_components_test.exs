defmodule AlplusWeb.MeasureActivityComponentsTest do
  use AlplusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Alplus.Sources.Source
  alias AlplusWeb.MeasureActivityComponents

  @project %{public_token: "proj_public"}

  defp source(attrs) do
    struct(
      Source,
      Map.merge(
        %{
          id: "src_measure",
          name: "Docs",
          environment: "production",
          status: :active,
          measure_token: "mtok"
        },
        attrs
      )
    )
  end

  defp empty_summary do
    %{unavailable?: false, totals: %{pageviews: 0, visitors: 0}, trend: []}
  end

  defp busy_summary do
    %{
      unavailable?: false,
      totals: %{pageviews: 7, visitors: 3},
      trend: [
        %{bucket: ~D[2026-01-01], pageviews: 2, visitors: 1, bounce_rate: 40, avg_duration: 30},
        %{bucket: ~D[2026-01-02], pageviews: 5, visitors: 2, bounce_rate: 20, avg_duration: 45}
      ]
    }
  end

  # Copy assertions must read what a person reads, not the machine attributes
  # (`data-display-kind="bucket_bar"`) that ride alongside it.
  defp visible_text(html), do: String.replace(html, ~r/<[^>]*>/, " ")

  defp compared(value, previous, change),
    do: %{value: value, previous: previous, change: change}

  defp trend_point(bucket, pageviews, visits),
    do: %{bucket: bucket, pageviews: pageviews, visits: visits}

  defp site_summary(attrs \\ %{}) do
    Map.merge(
      %{
        pageviews: 7,
        visits: 3,
        pageviews_previous: 4,
        pageviews_delta: 3,
        pageviews_change: 75.0,
        active?: true,
        trend: [
          trend_point(~D[2026-01-01], 2, 1),
          trend_point(~D[2026-01-02], 5, 2)
        ]
      },
      attrs
    )
  end

  defp portfolio(attrs \\ %{}) do
    Map.merge(
      %{
        totals: %{
          pageviews: compared(7, 4, 75.0),
          visits: compared(3, 2, 50.0),
          active_sites: 1,
          connected_sites: 1
        },
        trend: [
          trend_point(~D[2026-01-01], 2, 1),
          trend_point(~D[2026-01-02], 5, 2)
        ],
        sites: %{"src_measure" => site_summary()},
        unavailable?: false,
        coverage: :full,
        partial?: false
      },
      attrs
    )
  end

  defp overview(attrs) do
    render_component(
      &MeasureActivityComponents.traffic_overview/1,
      Keyword.merge(
        [portfolio: portfolio(), window: "30d", retry: false, context: "Docs, all sites"],
        attrs
      )
    )
  end

  test "three readings, one change line and one hero chart" do
    html =
      overview(
        portfolio:
          portfolio(%{
            trend: [
              trend_point(~D[2026-01-01], 2, 1),
              trend_point(~D[2026-01-02], 5, 2),
              trend_point(~D[2026-01-03], 4, 2),
              trend_point(~D[2026-01-04], 6, 3)
            ]
          })
      )

    text = visible_text(html)

    assert html =~ ~s(id="measure-traffic-pageviews")
    assert text =~ "Pageviews"
    assert text =~ "Visits"
    assert text =~ "Sites with traffic"
    assert text =~ "1 of 1"

    # The comparison is one short line on the primary reading. Percentages
    # stay whole and secondary readings do not repeat the comparison.
    assert text =~ "Up 75% from the previous period"
    refute text =~ "75.0%"
    assert text =~ "Docs, all sites, last 30 days"
    assert html =~ "shadow-frame"

    # One chart, at hero height, in the brand ink, with the exact numbers
    # behind it. No second series, so no legend and no axis hint.
    assert length(Regex.scan(~r/data-display-kind=/, html)) == 1
    assert html =~ ~s(data-display-kind="line")
    assert html =~ ~s(data-display-variant="full")
    assert html =~ "h-40 lg:h-[248px]"
    assert html =~ "stroke-interactive-strong"
    assert html =~ "fill-interactive-primary"
    refute html =~ "stroke-chart-visits"
    refute text =~ "thin line = visits"
    # The exact table is assistive from `sm` up and a visible disclosure below.
    assert html =~ ~s(id="measure-traffic-chart-table" class="sr-only hidden sm:block")
    assert html =~ ~s(id="measure-traffic-chart-table-narrow")
    assert text =~ "30 days ago"
    assert text =~ "now (UTC)"

    assert html =~ ~s(id="measure-traffic-chart-title" class="sr-only")
    assert text =~ "Pageviews, last 30 days"

    # Nothing is missing here, so nothing claims a shortfall.
    refute html =~ ~s(id="measure-traffic-coverage")
    refute text =~ "cookies"
  end

  test "comparison captions state direction without relying on arrows" do
    totals = portfolio().totals

    for {reading, caption} <- [
          {compared(7, 4, 75.0), "Up 75% from the previous period"},
          {compared(3, 4, -25.0), "Down 25% from the previous period"},
          {compared(4, 4, 0.0), "Level with the previous period"}
        ] do
      html = overview(portfolio: portfolio(%{totals: %{totals | pageviews: reading}}))
      assert visible_text(html) =~ caption
    end
  end

  test "a covered zero sits on the baseline and an unmeasured bucket is drawn as nothing" do
    html =
      overview(
        portfolio:
          portfolio(%{
            trend: [
              trend_point(~D[2026-01-01], 4, 2),
              trend_point(~D[2026-01-02], 0, 0),
              trend_point(~D[2026-01-03], nil, nil)
            ],
            coverage: :partial
          })
      )

    text = visible_text(html)

    assert html =~ ~s(id="measure-traffic-chart-coverage")
    assert text =~ "Measured on 2 of 3 days"
    assert text =~ "Untracked"

    # A measured zero remains on the baseline. The trailing unknown span is a
    # thin neutral rail, never a zero or a filled empty rectangle.
    assert html =~ ~s(d="M0,39.0 L100,39.0")
    assert html =~ ~s(data-display-shade="true")
    assert html =~ "border-dashed"
    refute html =~ "chart-untracked"
  end

  test "a measured zero remains a real baseline reading" do
    html =
      overview(
        portfolio:
          portfolio(%{
            trend: [trend_point(~D[2026-01-01], 0, 0), trend_point(~D[2026-01-02], 0, 0)]
          })
      )

    assert html =~ ~s(data-display-state="ready")
    assert html =~ ~s(d="M0,39.0 L100,39.0")
    refute visible_text(html) =~ "Unavailable"
  end

  test "a project with no site keeps the same panel with placeholder readings" do
    html =
      overview(
        portfolio:
          portfolio(%{
            totals: %{
              pageviews: compared(nil, nil, nil),
              visits: compared(nil, nil, nil),
              active_sites: 0,
              connected_sites: 0
            },
            trend: []
          }),
        placeholder: true
      )

    text = visible_text(html)

    assert html =~ ~s(data-display-state="empty")
    assert text =~ "Pageviews appear here once a site starts sending them."
    assert text =~ "0 of 0"
    refute text =~ "Unavailable"
  end

  test "a failed portfolio read is an error state, never a zero" do
    html =
      overview(
        portfolio:
          portfolio(%{
            unavailable?: true,
            totals: %{
              pageviews: compared(nil, nil, nil),
              visits: compared(nil, nil, nil),
              active_sites: 0,
              connected_sites: 1
            },
            trend: []
          }),
        window: "24h"
      )

    assert html =~ ~s(data-display-state="error")
    assert visible_text(html) =~ "Traffic could not be loaded."
    refute visible_text(html) =~ "0 pageviews"
  end

  test "the site list ranks by attention and carries one row per site" do
    busy = source(%{id: "src_measure", name: "Docs", hostname: "docs.example.com"})
    stopped = source(%{id: "src_revoked", name: "Old", status: :revoked})
    quiet = source(%{id: "src_quiet", name: "Blog"})

    html =
      render_component(&MeasureActivityComponents.measure_site_list/1,
        sources: [busy, stopped, quiet],
        portfolio:
          portfolio(%{
            sites: %{
              busy.id => site_summary(),
              stopped.id =>
                site_summary(%{
                  pageviews: 0,
                  visits: 0,
                  pageviews_previous: nil,
                  pageviews_delta: nil,
                  pageviews_change: nil,
                  active?: false,
                  trend: [trend_point(~D[2026-01-01], 0, 0)]
                }),
              quiet.id =>
                site_summary(%{
                  pageviews: 0,
                  visits: 0,
                  pageviews_previous: 0,
                  pageviews_delta: 0,
                  pageviews_change: 0.0,
                  active?: false,
                  evidence?: true,
                  trend: [trend_point(~D[2026-01-01], 0, 0)]
                })
            }
          }),
        org_token: "org_tok",
        project: @project
      )

    text = visible_text(html)

    assert text =~ "Docs"
    assert text =~ "No longer collecting"
    assert text =~ "Collecting traffic"
    assert text =~ "No traffic in this period"
    assert text =~ "7"

    # A site that has stopped collecting is what the reader came for, so it
    # sorts above the movers; a quiet site ranks with them and below the one
    # that moved.
    positions =
      Enum.map(
        ~w(measure-site-src_revoked measure-site-src_measure measure-site-src_quiet),
        &(:binary.match(html, &1) |> elem(0))
      )

    assert positions == Enum.sort(positions)

    # No sort controls, no second table, no sparkline: the row is the list.
    refute html =~ "aria-sort"
    refute html =~ "View data table"
    refute html =~ "<svg"
    assert html =~ ~s(href="/dashboard/orgs/org_tok/projects/proj_public/measure/src_measure")
  end

  test "the metric chart plots exactly one series, in its own unit, for its own site" do
    site = source(%{})

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: busy_summary(),
        window: "30d",
        metric: "bounce_rate"
      )

    assert html =~ ~s(data-metric="bounce_rate")
    assert html =~ "Bounce rate"
    assert html =~ ~s(data-display-unit="%")
    assert length(Regex.scan(~r/data-display-kind=/, html)) == 1
    refute html =~ "Pageviews"

    # This chart is one site's series on that site's public share. It must
    # never describe itself as covering every site.
    assert html =~ "Bounce rate recorded for Docs."
    refute html =~ "all connected sites"

    # A period with no deploy makes no claim about release markers.
    refute html =~ "Release markers"
  end

  test "the site chart mentions release markers only when it drew one" do
    site = source(%{})

    summary =
      Map.put(busy_summary(), :release_markers, [
        %{id: "rel_1", version: "2.0.0", deployed_at: ~U[2026-01-02 00:00:00Z]}
      ])

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: summary,
        window: "30d"
      )

    assert html =~ "Pageviews recorded for Docs."
    assert html =~ "Release markers show deploys during this period."
    refute html =~ "all connected sites"
  end

  test "a metric with no values never claims markers the empty chart cannot draw" do
    site = source(%{})

    summary = %{
      unavailable?: false,
      totals: %{pageviews: 8, visitors: 4},
      release_markers: [
        %{id: "rel_1", version: "2.0.0", deployed_at: ~U[2026-01-02 00:00:00Z]}
      ],
      trend: [
        %{bucket: ~D[2026-01-01], pageviews: 5, visitors: 2, bounce_rate: nil},
        %{bucket: ~D[2026-01-03], pageviews: 3, visitors: 2, bounce_rate: nil}
      ]
    }

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: summary,
        window: "30d",
        metric: "bounce_rate"
      )

    assert html =~ ~s(data-display-state="empty")
    refute html =~ ~s(data-display-annotation=)
    refute html =~ "Release markers show deploys during this period."

    plotted =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: summary,
        window: "30d",
        metric: "pageviews"
      )

    assert plotted =~ ~s(data-display-annotation="2.0.0")
    assert plotted =~ "Release markers show deploys during this period."
  end

  test "each metric labels its samples with its own unit, never pageviews" do
    site = source(%{})

    for {metric, unit} <- [
          {"visits", "visits"},
          {"pageviews", "pageviews"},
          {"bounce_rate", "%"},
          {"avg_duration", "seconds"}
        ] do
      html =
        render_component(&MeasureActivityComponents.measure_metric_chart/1,
          source: site,
          summary: busy_summary(),
          window: "30d",
          metric: metric
        )

      assert html =~ ~s(data-display-unit="#{unit}"),
             "#{metric} should expose the #{unit} unit"
    end

    visits_html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: busy_summary(),
        window: "30d",
        metric: "visits"
      )

    refute visits_html =~ "pageviews"
  end

  test "a measured zero is a mark, an hour nobody measured is not, and neither is the other" do
    site = source(%{})

    summary = %{
      unavailable?: false,
      totals: %{pageviews: 5, visitors: 2},
      trend: [
        %{bucket: ~D[2026-01-01], pageviews: 5, visitors: 2, bounce_rate: nil},
        %{bucket: ~D[2026-01-02], pageviews: 3, visitors: 1, bounce_rate: 25},
        %{bucket: ~D[2026-01-03], pageviews: 2, visitors: 1, bounce_rate: 0}
      ]
    }

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: summary,
        window: "30d",
        metric: "bounce_rate"
      )

    assert html =~ "Not recorded"
    assert html =~ ~s(style="height: 2px")
    assert length(Regex.scan(~r/data-display-measured="true"/, html)) == 2
    assert length(Regex.scan(~r/data-display-measured="false"/, html)) == 1
    assert length(Regex.scan(~r/border-dashed border-border-empty/, html)) == 1
    refute html =~ "height: 0.0%"
  end

  test "missing and failed traffic use the settled chart states, never a filled slab" do
    site = source(%{})

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: %{empty_summary() | unavailable?: true},
        window: "7d"
      )

    assert html =~ ~s(data-display-state="error")
    assert html =~ "Traffic for Docs is temporarily unavailable."
    assert html =~ "Retry"
    refute html =~ "bg-surface-sunken"

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: empty_summary(),
        window: "7d"
      )

    assert html =~ ~s(data-display-state="empty")
    assert html =~ "No data in this range yet."
    assert html =~ "Nothing recorded in the last 7 days yet."
    assert html =~ "border-dashed"
    assert html =~ "min-h-30 lg:min-h-40"
    refute html =~ "bg-surface-sunken"
  end

  test "a release marker is anchored to when it landed" do
    site = source(%{})

    summary =
      Map.put(busy_summary(), :release_markers, [
        %{id: "rel_1", version: "2.0.0", deployed_at: ~U[2026-01-02 00:00:00Z]},
        %{id: "rel_0", version: "1.0.0", deployed_at: ~U[2025-11-01 00:00:00Z]}
      ])

    html =
      render_component(&MeasureActivityComponents.measure_metric_chart/1,
        source: site,
        summary: summary,
        window: "30d"
      )

    assert html =~ ~s(data-display-annotation="2.0.0")
    refute html =~ "1.0.0"
  end

  defp comparison_slot(bucket, current, previous) do
    point = fn value ->
      value &&
        %{pageviews: value, visitors: value, visits: value, bounce_rate: 10, avg_duration: 5}
    end

    %{
      bucket: bucket,
      previous_bucket: Date.add(bucket, -4),
      current: point.(current),
      previous: point.(previous)
    }
  end

  # Three of four days measured, with a hole in the middle: the sparse shape
  # the hero actually gets.
  defp comparison_series do
    %{
      unavailable?: false,
      previous_available?: true,
      slots: [
        comparison_slot(~D[2026-01-01], 4, 2),
        comparison_slot(~D[2026-01-02], nil, 3),
        comparison_slot(~D[2026-01-03], 8, nil),
        comparison_slot(~D[2026-01-04], 6, 5)
      ]
    }
  end

  defp detail_chart(attrs) do
    render_component(
      &MeasureActivityComponents.measure_comparison_chart/1,
      Keyword.merge(
        [
          source: source(%{}),
          series: comparison_series(),
          window: "30d",
          metric: "pageviews",
          retry: false
        ],
        attrs
      )
    )
  end

  test "the hero is one graph: a monotone line, a dot on every reading, nothing across a gap" do
    html = detail_chart([])

    assert html =~ ~s(data-display-kind="line")
    assert html =~ "h-60 sm:h-64 lg:h-80"

    paths = Regex.scan(~r/<path[^>]*>/, html) |> List.flatten()

    # Three readings with a hole between them are three dots and nothing
    # else: no line across the gap, and no wall between the measured pair.
    refute html =~ "C77.78"
    refute html =~ ~s(d="M0.0,23.6 L66.67,9.2")

    # A dot on each of the three readings, in the brand ink, and none
    # anywhere else.
    assert Enum.any?(
             paths,
             &(&1 =~ ~s(d="M0.0,23.6 L0.0,23.6 M66.67,9.2 L66.67,9.2 M100.0,16.4 L100.0,16.4") and
                 &1 =~ ~s(stroke-linecap="round") and &1 =~ "stroke-interactive-strong")
           )

    refute html =~ "fill-interactive-primary\""
    # The hole is inside the tracked stretch: a break in the line, no block.
    refute html =~ ~s(data-display-shade="true")

    assert Enum.any?(paths, &(&1 =~ ~s(d="M0,39.0 L100,39.0")))

    # The preceding period is a number beside the chart, never a second line
    # behind it, so there is no legend and no axis hint to decode.
    refute html =~ "stroke-chart-previous"
    refute html =~ ~s(stroke-dasharray="4 3")
    refute html =~ ~s(aria-label="Legend")

    text = visible_text(html)
    assert text =~ "30 days ago"
    assert text =~ "now (UTC)"
    refute text =~ "dashed gray"
    assert text =~ "Measured on 3 of 4 days"
  end

  test "no reading is called zero and no gap is called a reading" do
    series = %{
      unavailable?: false,
      previous_available?: true,
      slots: [
        comparison_slot(~D[2026-01-01], 3, nil),
        comparison_slot(~D[2026-01-02], 0, nil),
        comparison_slot(~D[2026-01-03], nil, nil)
      ]
    }

    html = detail_chart(series: series)
    text = visible_text(html)

    assert text =~ ~r/Jan 2 UTC\s+0\s+Measured/
    assert text =~ ~r/Jan 3 UTC\s+Not measured\s+Not measured/
    assert html =~ "L50.0,38.0"
    assert text =~ "Measured on 2 of 3 days"
  end

  test "the table carries current values and truthful coverage" do
    html = detail_chart(window: "7d")
    text = visible_text(html)

    assert text =~ ~r/Time\s+Pageviews\s+Coverage/
    assert text =~ ~r/Jan 2 UTC\s+Not measured\s+Not measured/
    assert text =~ ~r/Jan 3 UTC\s+8\s+Measured/
    assert text =~ "Measured on 3 of 4 days"
  end

  test "an untracked metric keeps the hero frame and neutral rail" do
    series = %{
      unavailable?: false,
      previous_available?: false,
      slots: [comparison_slot(~D[2026-01-01], nil, nil)]
    }

    html = detail_chart(series: series, empty_label: "Waiting for the first pageview from Docs.")

    assert html =~ ~s(data-display-state="ready")
    assert html =~ "lg:min-h-80"
    assert visible_text(html) =~ "Untracked"
    refute visible_text(html) =~ "Waiting for the first pageview from Docs."
    refute html =~ "stroke-dasharray"
  end

  test "a rate carries no fill and reads against the whole scale a share can occupy" do
    slots =
      [20, 40, 30, 25]
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        bucket = Date.add(~D[2026-01-01], index)

        %{
          bucket: bucket,
          previous_bucket: Date.add(bucket, -4),
          current: %{bounce_rate: value, visits: 5, pageviews: 5, visitors: 5, avg_duration: 5},
          previous: nil
        }
      end)

    html =
      detail_chart(
        series: %{unavailable?: false, previous_available?: true, slots: slots},
        metric: "bounce_rate"
      )

    # Twenty percent is a fifth of the way up the axis (y = 38 - 0.2 * 36),
    # and the 40 percent peak reaches 23.6, not the ceiling.
    assert html =~ "M0.0,30.8"
    assert html =~ "23.6"
    refute html =~ ~s(d="M0.0,2.0)
    refute html =~ "fill-interactive-primary"

    text = visible_text(html)
    assert text =~ "100%"
    assert text =~ "60%"
  end

  test "the scale is labelled at its top and its middle, once each" do
    html =
      overview(
        portfolio:
          portfolio(%{
            trend: [
              trend_point(~D[2026-01-01], 10, 4),
              trend_point(~D[2026-01-02], 6, 2),
              trend_point(~D[2026-01-03], 8, 3),
              trend_point(~D[2026-01-04], 4, 1)
            ]
          })
      )

    assert html =~ ~s(d="M0,2.0 L100,2.0")
    assert html =~ ~s(d="M0,16.4 L100,16.4")

    assert guide_labels(html) == [
             {"5.0%", "10"},
             {"23.0%", "8"},
             {"41.0%", "6"},
             {"59.0%", "4"},
             {"77.0%", "2"}
           ]

    # Dates read along the bottom, on the x of the reading they name.
    assert html =~ ~s(data-display-x-labels="true")
    assert visible_text(html) =~ "Jan 1"
    assert visible_text(html) =~ "Jan 4"
  end

  defp guide_labels(html) do
    ~r|style="top: ([\d.]+%)"[^>]*>\s*([^<\s]+)\s*</span>|
    |> Regex.scan(html)
    |> Enum.map(fn [_match, position, value] -> {position, value} end)
  end

  test "the change line says nothing when there is nothing comparable" do
    assert MeasureActivityComponents.change_text(compared(7, 4, 75.0), "pageviews", "30d") ==
             "Up 75% on the previous 30 days (4)"

    assert MeasureActivityComponents.change_text(compared(3, 4, -25.0), "visits", "24h") ==
             "Down 25% on the previous 24 hours (4)"

    assert MeasureActivityComponents.change_text(compared(40, 30, 10.0), "bounce_rate", "7d") ==
             "Up 10 points on the previous 7 days (30%)"

    assert MeasureActivityComponents.change_text(compared(4, 4, 0.0), "visits", "7d") ==
             "Level with the previous 7 days (4)"

    assert is_nil(MeasureActivityComponents.change_text(compared(4, nil, nil), "visits", "7d"))
    assert is_nil(MeasureActivityComponents.change_text(compared(4, 0, nil), "visits", "7d"))
    assert is_nil(MeasureActivityComponents.change_text(nil, "visits", "7d"))
  end

  test "every window names the reading the chart actually draws" do
    for {window, plural} <- [
          {"24h", "hours"},
          {"7d", "days"},
          {"30d", "days"}
        ] do
      assert MeasureActivityComponents.bucket_words(window) == plural
    end
  end

  defp breakdown_data(attrs) do
    Map.merge(
      %{
        rows: [],
        page: 1,
        total_pages: 1,
        distinct_values: 0,
        capped?: false,
        cap_metadata: nil,
        partial?: false,
        previous?: false,
        next?: false,
        unavailable?: true
      },
      attrs
    )
  end

  test "a breakdown is label, bar and count, and can state its own zero" do
    rows =
      render_component(&MeasureActivityComponents.measure_breakdown_panel/1,
        id: "measure-panel-pages",
        title: "Top pages",
        data:
          breakdown_data(%{
            unavailable?: false,
            rows: [%{label: "/pricing", value: "/pricing", count: 3, share: 100.0}],
            distinct_values: 1
          })
      )

    text = visible_text(rows)

    assert text =~ "/pricing"
    assert text =~ "3"
    assert rows =~ ~s(data-share="100.0")
    refute rows =~ "View data table"
    refute text =~ "1 value"
    assert rows =~ ~s(id="measure-panel-pages")
    assert rows =~ "h-10"

    configured =
      render_component(&MeasureActivityComponents.measure_breakdown_panel/1,
        id: "measure-panel-events",
        title: "Events",
        data: breakdown_data(%{unavailable?: false}),
        empty_sentence:
          "Events are configured for this site and none were recorded in this range."
      )

    text = visible_text(configured)

    assert text =~ "Events are configured for this site and none were recorded in this range."
    refute text =~ "Nothing recorded in this range."

    failed =
      render_component(&MeasureActivityComponents.measure_breakdown_panel/1,
        id: "measure-panel-events",
        title: "Events",
        data: breakdown_data(%{})
      )

    assert failed =~ ~s(id="measure-panel-events-unavailable")
  end

  test "shared traffic trend distinguishes zero, partial lower bounds, and unknown periods" do
    html =
      render_component(&MeasureActivityComponents.traffic_trend/1,
        id: "shared-traffic-trend",
        metric: "pageviews",
        range: "24h",
        coverage: :partial,
        points: [
          %{bucket: ~U[2026-02-12 10:00:00Z], pageviews: nil, coverage: :unknown},
          %{bucket: ~U[2026-02-12 11:00:00Z], pageviews: 0, coverage: :full},
          %{
            bucket: ~U[2026-02-12 12:00:00Z],
            pageviews: nil,
            known_pageviews: 3,
            coverage: :partial,
            measured_sites: 1,
            expected_sites: 2
          }
        ]
      )

    text = visible_text(html)
    assert text =~ "3"
    assert text =~ "Untracked"
    assert html =~ ~s(stroke-dasharray="4 3")
    assert html =~ ~s(d="M50.0,38.0 C66.67,30.8 83.33,23.6 100.0,16.4")
    assert html =~ "border-dashed"
    assert text =~ "Tracking started"
    refute text =~ "Untracked 0"
  end

  test "site paths" do
    site = source(%{})
    assert MeasureActivityComponents.measure_site_path("org", @project, site) =~ site.id
    assert MeasureActivityComponents.measure_index_path("org", @project) =~ "measure"
  end
end
