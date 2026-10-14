defmodule AlplusWeb.ObserveActivityComponents do
  @moduledoc """
  The deploy-anchored error-volume chart for one Observe Source.

  Every plot goes through `AlplusWeb.DataDisplayComponents.data_display/1`.
  A `:observe` Source is identity by `(project, source id)`; environment is
  display metadata, not a join key. `error_events` is the only Observe
  time-series backed by stored per-event rows today (`Issue.event_count` is a
  running counter, not time-bucketable), so every trend here comes from
  `Alplus.Observe.Dashboard`.
  """

  use AlplusWeb, :html

  import AlplusWeb.DataDisplayComponents
  import AlplusWeb.Format, only: [window_axis: 1]

  alias Alplus.Observe.Dashboard

  # More deploy pills than this stop reading as markers and start reading as a
  # second series. The chart names how many it drew.
  @max_deploy_annotations 5

  @doc """
  The deploy-anchored error-volume chart for one Source, shared between the
  Observe detail page and any caller that scopes the same series.
  """
  attr :source, :any, required: true
  attr :summary, :any, required: true
  attr :window, :string, required: true
  attr :variant, :atom, default: :full, values: [:compact, :full]

  def observe_error_chart(assigns) do
    # Every bucket of the window, quiet ones included: a compressed step
    # series dropped the zero days and with them the time axis, so distance
    # on the plot no longer meant time (audit 2026-08-30).
    trend = Map.get(assigns.summary, :trend, [])

    event_count = Map.get(assigns.summary, :event_count, 0)
    data_state = Map.get(assigns.summary, :data_state, :ready)

    bars = error_bars(trend)

    chart_state =
      cond do
        data_state == :missing -> :empty
        data_state == :partial -> :partial
        bars == [] and event_count > 0 -> :partial
        bars == [] -> :empty
        true -> :ready
      end

    annotations = deploy_annotations(Map.get(assigns.summary, :release_markers, []), trend)

    assigns =
      assign(assigns,
        bars: bars,
        chart_state: chart_state,
        annotations: annotations
      )

    ~H"""
    <div>
      <div
        :if={@bars == []}
        id={"observe-source-insufficient-#{@source.id}"}
        class="rounded-control border border-dashed border-border-control p-4"
      >
        <p :if={@chart_state == :empty} class="text-body text-text-secondary">
          Waiting for data. No retained events in this window.
        </p>
        <p :if={@chart_state == :partial} class="text-body text-status-late-ink">
          Partial data. The trend needs another retained bucket.
        </p>
      </div>

      <div :if={@bars != []} class="min-w-0 overflow-hidden">
        <.data_display
          id={"observe-source-chart-#{@source.id}"}
          title="Error volume"
          kind={:bucket_bar}
          variant={@variant}
          state={@chart_state}
          data={@bars}
          unit="errors"
          range={window_axis(@window)}
          annotations={@annotations}
          table_columns={["Day", "Errors"]}
          summary={"Error events per #{bucket_unit_word(@window)}, #{String.downcase(window_label(@window))} (UTC)."}
          description="Error events per bucket for this source, starting at zero, with a marker on each recent deploy."
        />
      </div>

      <p
        :if={@chart_state == :partial and @bars != []}
        class="mt-2 text-data text-status-late-ink"
      >
        Partial data. Some retained buckets are unavailable.
      </p>
    </div>
    """
  end

  defp bucket_hover_title(%{bucket: bucket, event_count: event_count}) do
    "#{Dashboard.bucket_label(bucket)}, #{event_count} #{ngettext("error", "errors", event_count)}"
  end

  defp bucket_axis_label(%Date{} = bucket), do: Calendar.strftime(bucket, "%m-%d")
  defp bucket_axis_label(%DateTime{} = bucket), do: Calendar.strftime(bucket, "%H:%M")

  defp bucket_unit_word("24h"), do: "hour"
  defp bucket_unit_word(_window), do: "day"

  defp window_label("24h"), do: "Last 24 hours"
  defp window_label("7d"), do: "Last 7 days"
  defp window_label("30d"), do: "Last 30 days"
  defp window_label("90d"), do: "Last 90 days"

  defp error_bars(trend) do
    max_v = trend |> Enum.map(& &1.event_count) |> Enum.max(fn -> 1 end) |> max(1)

    Enum.map(trend, fn point ->
      %{
        id: to_string(point.bucket),
        label: bucket_axis_label(point.bucket),
        value: point.event_count,
        height: point.event_count / max_v * 100,
        tone: if(point.event_count > 0, do: "error", else: "neutral"),
        tooltip: bucket_hover_title(point),
        aria_label: bucket_hover_title(point),
        table_cells: [Dashboard.bucket_label(point.bucket), Integer.to_string(point.event_count)]
      }
    end)
  end

  defp deploy_annotations(markers, trend) when is_list(markers) and is_list(trend) do
    with [first | _] <- trend,
         last when not is_nil(last) <- List.last(trend) do
      first_at = Dashboard.bucket_start(first.bucket)
      span = DateTime.diff(Dashboard.bucket_end(last.bucket), first_at, :second)

      markers
      |> Enum.filter(&marker_datetime/1)
      |> Enum.sort_by(&DateTime.to_unix(marker_datetime(&1)), :desc)
      |> Enum.take(@max_deploy_annotations)
      |> Enum.flat_map(fn marker ->
        offset = DateTime.diff(marker_datetime(marker), first_at, :second)

        cond do
          offset < 0 or offset > span ->
            []

          span == 0 ->
            [%{label: marker_label(marker), position: 50.0}]

          true ->
            [%{label: marker_label(marker), position: Float.round(offset / span * 100, 2)}]
        end
      end)
      |> Enum.sort_by(& &1.position)
    else
      _ -> []
    end
  end

  defp deploy_annotations(_markers, _trend), do: []

  defp marker_datetime(%{deployed_at: %DateTime{} = at}), do: at
  defp marker_datetime(%{released_at: %DateTime{} = at}), do: at
  defp marker_datetime(_marker), do: nil

  defp marker_label(marker), do: Map.get(marker, :version) || Map.get(marker, :label) || "Deploy"

  @doc "The per-Source detail route, with optional query overrides (e.g. a default tab)."
  def observe_source_path(org_token, project, source, params \\ %{}) do
    base = ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/observe/#{source.id}"
    if params == %{}, do: base, else: base <> "?#{URI.encode_query(params)}"
  end

  def observe_index_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/observe"

  def observe_new_path(org_token, project),
    do: ~p"/dashboard/orgs/#{org_token}/projects/#{project.public_token}/observe/new"
end
