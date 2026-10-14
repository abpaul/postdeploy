defmodule AlplusWeb.Marketing.HomepagePreview do
  @moduledoc """
  Deterministic example evidence for an unconfigured development instance.

  The map has exactly the same shape as `AlplusWeb.Marketing.HomepageData`
  builds for a designated vendor, so the template needs no special casing.
  The template labels the whole surface once, from `data.state == :preview`.
  The values below therefore carry no label of their own.

  This data is never selected for a designated vendor or for an unavailable
  data source.
  """

  alias AlplusWeb.Marketing.PackagePresenter

  # Ninety daily points so the preview fills the same 90-day axis as real data.
  @history_uptimes Enum.map(0..89, fn index ->
                     case rem(index, 30) do
                       7 -> 99.91
                       19 -> 99.97
                       _ -> 100.0
                     end
                   end)
  @first_day ~D[2026-05-23]
  @trend_first_day ~D[2026-08-14]

  @default_selection %{range: "24h", metric: :uptime, monitor: 0, traffic_range: "7d"}
  @ranges ["24h", "7d", "30d"]
  @traffic_ranges ["7d", "14d", "30d"]
  @metric_ids [:uptime, :response, :traffic, :errors]

  @doc "Returns the marketing homepage view model for the development preview."
  @spec data(map()) :: map()
  def data(selection \\ @default_selection) do
    {monitor, monitor_index} = monitor(selection.monitor)
    measure = measure(selection.traffic_range)
    observe = %{state: :ready, open_issues: 1}

    %{
      state: :preview,
      identity: %{name: "Example project", slug: "example"},
      selection: %{selection | monitor: monitor_index},
      overview: overview(selection),
      metrics: %{
        monitor: %{value: "99.99%", response_time_ms: 186, visitors: nil},
        measure: %{
          value: PackagePresenter.thousands(measure.pageviews),
          visitors: PackagePresenter.thousands(measure.visitors)
        },
        observe: %{open_issues: observe.open_issues},
        monitor_history: @history_uptimes
      },
      monitor: monitor,
      measure: measure,
      observe: observe,
      status: status(),
      changelog: changelog()
    }
  end

  defp monitor(index) do
    rows = [
      row("Example API", "HTTP, 60s", 99.98, 1_440, "Every check passed"),
      row("Example site", "HTTP, 60s", 100.0, 1_440, "Every check passed")
    ]

    selected_index = min(max(index, 0), length(rows) - 1)

    marked =
      Enum.with_index(rows, fn row, row_index ->
        Map.put(row, :selected?, row_index == selected_index)
      end)

    monitor = %{
      state: :ready,
      rows: marked,
      headline: %{total: 2, operational: 2, uptime: 99.99},
      response_time_ms: 186,
      history: history(),
      uptime_label: "Uptime, last 90 days",
      selected: Enum.at(marked, selected_index)
    }

    {monitor, selected_index}
  end

  defp row(name, type_label, uptime, checks_recent, caption) do
    %{
      name: name,
      type: "monitor",
      state: :up,
      uptime: uptime,
      history: history(),
      response_time_ms: 186,
      type_label: type_label,
      checks_recent: checks_recent,
      windows: windows(),
      caption: caption
    }
  end

  # Thirty six hourly windows, so the development preview draws the same strip
  # shape a real monitor draws. The values are fixed, like the rest of this
  # module, and the surface carries the preview label once.
  defp windows do
    Enum.map(0..35, fn index ->
      %{
        label: "hour #{index + 1}",
        value: 150 + rem(index * 37, 90),
        state: if(rem(index, 17) == 5, do: :degraded, else: :up)
      }
    end)
  end

  defp measure(traffic_range) do
    days = days_for(traffic_range)
    trend = trend(days)
    pageviews = trend |> Enum.map(& &1.pageviews) |> Enum.sum()
    visitors = trend |> Enum.map(& &1.visitors) |> Enum.sum()

    %{
      state: :ready,
      pageviews: pageviews,
      visitors: visitors,
      trend: trend,
      top_pages: [
        page("/", 1_080),
        page("/pricing", 760),
        page("/changelog", 570)
      ],
      ranges: @traffic_ranges,
      range: traffic_range
    }
  end

  defp days_for("14d"), do: 14
  defp days_for("30d"), do: 30
  defp days_for(_range), do: 7

  # The preview overview keeps the same shape and the same neutral naming as
  # the real projection, so the template needs no special casing.
  defp overview(selection) do
    points = points(selection.range, selection.metric)
    values = points |> Enum.map(& &1.value) |> Enum.filter(&is_number/1)

    %{
      state: :ready,
      ranges: @ranges,
      tiles: tiles(selection.metric),
      chart: %{
        kind: kind(selection.metric),
        unit: unit(selection.metric),
        points: points,
        peak: peak(selection.metric, values),
        caption: caption(selection.metric, selection.range),
        axis_start: axis_start(selection.range),
        axis_end: "now",
        table_caption: table_caption(selection.metric, selection.range),
        column_label: column_label(selection.metric),
        state: :ready
      }
    }
  end

  defp tiles(metric) do
    Enum.map(@metric_ids, fn id ->
      %{
        id: id,
        label: tile_label(id),
        value: tile_value(id),
        sub: tile_sub(id),
        tone: :ink,
        selected?: id == metric
      }
    end)
  end

  defp tile_label(:uptime), do: "Uptime"
  defp tile_label(:response), do: "Response"
  defp tile_label(:traffic), do: "Traffic"
  defp tile_label(:errors), do: "Errors"

  defp tile_value(:uptime), do: "99.99%"
  defp tile_value(:response), do: "186ms"
  defp tile_value(:traffic), do: "2,410"
  defp tile_value(:errors), do: "0"

  defp tile_sub(:uptime), do: "1,440 checks"
  defp tile_sub(:response), do: "Average per check"
  defp tile_sub(:traffic), do: "512 visitors"
  defp tile_sub(:errors), do: "No issues active"

  defp kind(:uptime), do: :ticks
  defp kind(:traffic), do: :wave
  defp kind(_metric), do: :bars

  defp unit(:uptime), do: "percent"
  defp unit(:response), do: "ms"
  defp unit(:traffic), do: "pageviews"
  defp unit(:errors), do: "issues"

  defp column_label(:uptime), do: "Uptime, percent"
  defp column_label(:response), do: "Average response, milliseconds"
  defp column_label(:traffic), do: "Traffic, pageviews"
  defp column_label(:errors), do: "Issues active, count"

  defp axis_start(range), do: "-" <> range

  defp window_label("24h"), do: {"hour", "24 hours"}
  defp window_label(range), do: {"day", String.replace(range, "d", " days")}

  defp table_caption(metric, range) do
    {noun, window} = window_label(range)
    "#{column_label(metric)} for each #{noun} in the last #{window}."
  end

  defp caption(:uptime, "24h"), do: "1,440 checks, every one passed"
  defp caption(:uptime, _range), do: "Every day reported full uptime"
  defp caption(:response, "24h"), do: "Average check latency per hour"
  defp caption(:response, _range), do: "Average check latency per day"
  defp caption(:traffic, "24h"), do: "Pageviews per hour"
  defp caption(:traffic, _range), do: "Pageviews per day"
  defp caption(:errors, _range), do: "No issues were active in this window"

  defp peak(:uptime, _values), do: 100
  defp peak(_metric, []), do: 0
  defp peak(_metric, values), do: Enum.max(values)

  defp bucket_count("24h"), do: 24
  defp bucket_count("7d"), do: 7
  defp bucket_count("14d"), do: 14
  defp bucket_count("30d"), do: 30

  defp points(range, metric) do
    count = bucket_count(range)

    Enum.map(0..(count - 1), fn index ->
      label = point_label(range, count, index)
      {value, state} = point_value(metric, index)
      %{label: label, value: value, state: state}
    end)
  end

  defp point_label("24h", count, index),
    do: String.pad_leading("#{rem(index + 24 - count + 1, 24)}", 2, "0") <> ":00"

  defp point_label(_range, count, index),
    do: Date.to_iso8601(Date.add(@trend_first_day, index - count + 1))

  defp point_value(:uptime, index), do: {Enum.at(@history_uptimes, rem(index, 90)), :up}
  defp point_value(:response, index), do: {170 + rem(index * 7, 40), :up}
  defp point_value(:traffic, index), do: {80 + rem(index * 23, 140), :up}
  defp point_value(:errors, _index), do: {0, :none}

  defp status do
    %{
      state: :ready,
      status: :operational,
      components: [
        %{name: "Example API", state: :up, uptime: 99.98, history: history()},
        %{name: "Example site", state: :up, uptime: 100.0, history: history()}
      ]
    }
  end

  defp changelog do
    %{
      state: :ready,
      entries: [
        %{
          title: "Example monitor coverage",
          slug: "example-monitor-coverage",
          published_at: "2026-08-20",
          excerpt: "Two example monitors now report uptime on this page.",
          area: "monitor",
          version: "2026.08.20"
        },
        %{
          title: "Example status update",
          slug: "example-status-update",
          published_at: "2026-08-18",
          excerpt: "The example status page lists every published service.",
          area: "platform",
          version: "2026.08.18"
        }
      ]
    }
  end

  defp page(path, pageviews) do
    %{label: path, path: path, value: path, count: pageviews, pageviews: pageviews}
  end

  defp history do
    Enum.with_index(@history_uptimes, fn uptime, index ->
      %{day: Date.add(@first_day, index), uptime: uptime}
    end)
  end

  defp trend(days) do
    counts = [220, 270, 310, 360, 380, 450, 420]

    Enum.map(0..(days - 1), fn index ->
      pageviews = Enum.at(counts, rem(index, length(counts)))

      %{
        bucket: Date.add(@trend_first_day, index - days + 7),
        pageviews: pageviews,
        visitors: div(pageviews, 5)
      }
    end)
  end
end
