defmodule AlplusWeb.MeasureShareHTML do
  use AlplusWeb, :html

  import AlplusWeb.MeasureActivityComponents, only: [measure_metric_chart: 1]

  embed_templates "measure_share_html/*"

  @plottable_metrics ~w(visits pageviews bounce_rate avg_duration)

  @doc """
  The one metric this share page plots. The dashboard still carries a list so
  an existing shared link keeps resolving; the first valid entry is drawn.
  """
  def plotted_metric(metrics) when is_list(metrics),
    do: Enum.find(metrics, "pageviews", &(&1 in @plottable_metrics))

  def plotted_metric(_metrics), do: "pageviews"

  def metric_value(nil, _metric), do: "Unavailable"
  def metric_value(value, "bounce_rate"), do: "#{value}%"
  def metric_value(value, "avg_duration"), do: format_duration(value)
  def metric_value(value, _metric), do: to_string(value)

  def change_label(nil, _metric), do: "No prior comparison"
  def change_label(value, "bounce_rate"), do: signed(value) <> " points"
  def change_label(value, _metric), do: signed(value) <> "%"

  def panel_title(:pages), do: "Top Pages"
  def panel_title(:sources), do: "Top Sources"
  def panel_title(:events), do: "Events"
  def panel_title(:countries), do: "Countries"
  def panel_title(:browsers), do: "Browsers"

  def panel_value_label(%{unavailable?: true}), do: "Unavailable"

  def panel_value_label(%{capped?: true, distinct_values: count}),
    do: "At least #{count} values"

  def panel_value_label(%{distinct_values: count}), do: "#{count} values"

  def panel_value_label(_panel), do: "Unavailable"

  def source_hostname(%{hostname: hostname}) when is_binary(hostname) and hostname != "",
    do: hostname

  def source_hostname(_source), do: "No domain configured"

  def dashboard_data_source(%{chart: %{data_source: data_source}}) when is_binary(data_source),
    do: data_source

  def dashboard_data_source(%{chart: %{unavailable?: true}}), do: "Data unavailable"
  def dashboard_data_source(_dashboard), do: "PostgreSQL rollups"

  def headline_data_source(%{data_source: data_source}) when is_binary(data_source),
    do: data_source

  def headline_data_source(_headlines), do: "PostgreSQL rollups"

  def chart_data_source(%{data_source: data_source}) when is_binary(data_source), do: data_source
  def chart_data_source(%{unavailable?: true}), do: "Data unavailable"
  def chart_data_source(_chart), do: "PostgreSQL rollups"

  def public_chart_summary(chart) do
    %{
      trend: Map.get(chart, :trend, []),
      totals: Map.get(chart, :totals, %{pageviews: 0, visitors: 0, visits: 0}),
      unavailable?: Map.get(chart, :unavailable?, false),
      partial?: Map.get(chart, :partial?, false)
    }
  end

  def panel_state(%{state: state}) when is_atom(state), do: state
  def panel_state(%{unavailable?: true}), do: :unavailable
  def panel_state(%{partial?: true}), do: :partial
  def panel_state(%{rows: []}), do: :empty
  def panel_state(_panel), do: :ready

  def state_value(state) when is_atom(state), do: Atom.to_string(state)
  def state_value(state), do: to_string(state)

  def dashboard_state_label(:ready), do: "Data available"
  def dashboard_state_label(:partial), do: "Data is partial"
  def dashboard_state_label(:unavailable), do: "Data unavailable"
  def dashboard_state_label(:empty), do: "No data in this window"
  def dashboard_state_label(_state), do: "Data state unavailable"

  def dashboard_state_class(:ready), do: "bg-status-live"
  def dashboard_state_class(:partial), do: "bg-status-late"
  def dashboard_state_class(:unavailable), do: "bg-status-error"
  def dashboard_state_class(:empty), do: "bg-status-neutral"
  def dashboard_state_class(_state), do: "bg-status-neutral"

  def dashboard_state_text_class(:ready), do: "text-status-live-ink"
  def dashboard_state_text_class(:partial), do: "text-status-late-ink"
  def dashboard_state_text_class(:unavailable), do: "text-status-error-ink"
  def dashboard_state_text_class(:empty), do: "text-status-neutral-ink"
  def dashboard_state_text_class(_state), do: "text-text-tertiary"

  def panel_query(window, metrics, panel, page) do
    %{"window" => window, "metrics" => metrics_param(metrics), panel_page_param(panel) => page}
  end

  def public_query_path(query), do: "?" <> URI.encode_query(query)

  def metrics_param(metrics), do: Enum.join(metrics, ",")

  def bar_width(value) when is_number(value) do
    value
    |> max(0)
    |> min(100)
    |> Float.round(1)
  end

  def bar_width(_value), do: 0

  defp signed(value) when value > 0, do: "+#{value}"
  defp signed(value), do: to_string(value)

  defp format_duration(seconds) do
    seconds = round(seconds)
    minutes = div(seconds, 60)
    remainder = rem(seconds, 60)
    if minutes > 0, do: "#{minutes}m #{remainder}s", else: "#{remainder}s"
  end

  defp panel_page_param(panel), do: "#{panel}_page"
end
