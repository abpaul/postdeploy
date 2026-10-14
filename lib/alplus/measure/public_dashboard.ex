defmodule Alplus.Measure.PublicDashboard do
  @moduledoc "Loads only the panels granted by one resolved dashboard share."

  alias Alplus.Measure.{Dashboard, PublicCache}

  @panel_dimensions %{
    pages: "path",
    sources: "referrer",
    events: "event",
    countries: "country",
    browsers: "browser"
  }
  @metrics ~w(visits pageviews bounce_rate avg_duration)

  def metrics, do: @metrics

  def load(share, source, actor, window, metrics, page_params) do
    load(share, source, actor, window, metrics, page_params, [])
  end

  def load(share, source, actor, window, metrics, page_params, opts) when is_list(opts) do
    metrics = Enum.filter(@metrics, &(&1 in metrics))
    requested_panels = Keyword.get(opts, :panels, share.panels)

    dashboard =
      share.panels
      |> Enum.filter(&(&1 in requested_panels))
      |> Enum.reduce(%{metrics: metrics}, fn panel, dashboard ->
        Map.put(
          dashboard,
          panel,
          load_panel(panel, share, source, actor, window, metrics, page_params, opts)
        )
      end)

    Map.put(dashboard, :state, state_for(dashboard))
  end

  def empty?(dashboard) do
    state_for(dashboard) == :empty
  end

  @doc "Returns the public dashboard state without treating unavailable data as empty."
  def state_for(dashboard) when is_map(dashboard) do
    panels = Map.take(dashboard, [:headline_cards, :chart | Map.keys(@panel_dimensions)])
    values = Map.values(panels)

    cond do
      Enum.any?(values, &unavailable?/1) -> :unavailable
      Enum.any?(values, &partial?/1) -> :partial
      Enum.any?(values, &has_data?/1) -> :ready
      values == [] -> :empty
      true -> :empty
    end
  end

  defp load_panel(:headline_cards, share, source, actor, window, _metrics, _page_params, opts) do
    load_cached(
      share,
      window,
      :headline_cards,
      nil,
      fn ->
        headlines = Dashboard.headlines(source, window, actor, opts)
        unavailable? = Map.get(headlines, :unavailable?, false)
        partial? = Map.get(headlines, :partial?, false)

        Map.merge(headlines, %{
          state:
            if(unavailable?, do: :unavailable, else: if(partial?, do: :partial, else: :ready)),
          unavailable?: unavailable?,
          partial?: partial?
        })
      end,
      &unavailable_headlines/0
    )
  end

  defp load_panel(:chart, share, source, actor, window, metrics, _page_params, _opts) do
    load_cached(
      share,
      window,
      :chart,
      Enum.join(metrics, ","),
      fn ->
        %{
          trend: trend,
          data_source: data_source,
          data_source_key: data_source_key,
          unavailable?: unavailable?,
          partial?: partial?
        } =
          Dashboard.trend_with_metadata(source, window, actor)

        %{
          metrics: metrics,
          trend: trend,
          totals: trend_totals(trend),
          data_source: data_source,
          data_source_key: data_source_key,
          state:
            if(unavailable?,
              do: :unavailable,
              else: if(partial?, do: :partial, else: if(trend == [], do: :empty, else: :ready))
            ),
          unavailable?: unavailable?,
          partial?: partial?
        }
      end,
      fn -> unavailable_chart(metrics) end
    )
  end

  defp load_panel(panel, share, source, actor, window, _metrics, page_params, _opts)
       when is_map_key(@panel_dimensions, panel) do
    page = Map.get(page_params, panel, 1)
    dimension = Map.fetch!(@panel_dimensions, panel)

    load_cached(
      share,
      window,
      panel,
      page,
      fn ->
        Dashboard.panel(source, window, dimension, page, actor)
        |> Map.put_new(:state, :ready)
        |> Map.put_new(:unavailable?, false)
      end,
      fn -> unavailable_panel(page) end
    )
  end

  defp load_cached(share, window, panel, variant, fun, unavailable) do
    cached(share, window, panel, variant, fun)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      require Logger
      Logger.warning("public Measure panel unavailable: #{Exception.message(error)}")
      unavailable.()

    error in [Ash.Error.Unknown, Ash.Error.Unknown.UnknownError, Ash.Error.Invalid.Unavailable] ->
      if database_unavailable_error?(error) do
        require Logger
        Logger.warning("public Measure panel unavailable: #{Exception.message(error)}")
        unavailable.()
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp cached(share, window, panel, variant, fun) do
    PublicCache.fetch({share.id, share.updated_at, window, panel, variant}, fun)
  end

  defp trend_totals(trend) do
    Enum.reduce(
      trend,
      %{pageviews: 0, visitors: 0, visits: 0, bounces: 0, duration_seconds: 0},
      fn point, totals ->
        %{
          pageviews: totals.pageviews + (point.pageviews || 0),
          visitors: totals.visitors + (point.visitors || 0),
          visits: totals.visits + (point.visits || 0),
          bounces: totals.bounces + (Map.get(point, :bounces) || 0),
          duration_seconds: totals.duration_seconds + (Map.get(point, :duration_seconds) || 0)
        }
      end
    )
  end

  defp unavailable_headlines do
    unavailable_metric = %{value: nil, previous: nil, change: nil}

    %{
      visits: unavailable_metric,
      visitors: unavailable_metric,
      pageviews: unavailable_metric,
      bounce_rate: unavailable_metric,
      avg_duration: unavailable_metric,
      state: :unavailable,
      unavailable?: true,
      partial?: false
    }
  end

  defp unavailable_chart(metrics) do
    %{
      metrics: metrics,
      trend: [],
      totals: trend_totals([]),
      data_source: "Data unavailable",
      data_source_key: :unavailable,
      state: :unavailable,
      unavailable?: true,
      partial?: false
    }
  end

  defp unavailable_panel(page) do
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
      state: :unavailable,
      unavailable?: true
    }
  end

  defp unavailable?(%{unavailable?: true}), do: true
  defp unavailable?(_value), do: false

  defp partial?(%{partial?: true}), do: true
  defp partial?(_value), do: false

  defp has_data?(%{rows: rows}), do: rows != []
  defp has_data?(%{trend: trend}), do: trend != []

  defp has_data?(%{visits: %{value: value}, pageviews: %{value: pageviews}}),
    do: is_number(value) and is_number(pageviews) and (value != 0 or pageviews != 0)

  defp has_data?(_value), do: false

  defp database_unavailable_error?(%Ash.Error.Unknown{errors: errors}),
    do: Enum.any?(errors, &database_unavailable_error?/1)

  defp database_unavailable_error?(%Ash.Error.Unknown.UnknownError{error: error}),
    do: database_unavailable_error?(error)

  defp database_unavailable_error?(%Ash.Error.Invalid.Unavailable{}), do: true
  defp database_unavailable_error?(%DBConnection.ConnectionError{}), do: true
  defp database_unavailable_error?(%Postgrex.Error{}), do: true
  defp database_unavailable_error?(_error), do: false
end
