defmodule AlplusWeb.MeasureShareController do
  use AlplusWeb, :controller

  alias Alplus.Measure.{DashboardShare, PublicDashboard, RateLimiter}
  alias Alplus.Sources.Source

  @windows ~w(24h 7d 30d 90d)
  @panel_params %{
    pages: "pages_page",
    sources: "sources_page",
    events: "events_page",
    countries: "countries_page",
    browsers: "browsers_page"
  }

  def show(conn, %{"token" => token} = params) do
    with {:ok, share, actor} <- DashboardShare.resolve(token),
         :ok <- RateLimiter.check_share(share.id),
         {:ok, %Source{} = source} <-
           Ash.get(Source, actor.source_id, action: :read_measure_share, actor: actor) do
      window = valid_window(params["window"])
      metrics = selected_metrics(params)

      dashboard =
        PublicDashboard.load(share, source, actor, window, metrics, pages(params))

      conn =
        conn
        |> assign(:page_title, "Shared Measure dashboard")
        |> assign(:robots, "noindex,nofollow")

      render(conn, :show,
        flash: %{},
        share: share,
        source: source,
        token: token,
        window: window,
        windows: @windows,
        dashboard: dashboard,
        retention_elapsed?: PublicDashboard.empty?(dashboard)
      )
    else
      {:error, retry_after} when is_integer(retry_after) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(:too_many_requests, "Too many requests")

      _not_found ->
        raise AlplusWeb.NotFoundError
    end
  end

  defp pages(params) do
    Map.new(@panel_params, fn {panel, param} -> {panel, positive_integer(params[param])} end)
  end

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> min(number, 25)
      _other -> 1
    end
  end

  defp positive_integer(_value), do: 1

  defp valid_window(window) when window in @windows, do: window
  defp valid_window(_window), do: "24h"

  defp selected_metrics(%{"metrics" => metrics}) when is_binary(metrics) do
    selected = metrics |> String.split(",") |> Enum.filter(&(&1 in PublicDashboard.metrics()))

    case Enum.filter(PublicDashboard.metrics(), &(&1 in selected)) do
      [] -> ["visits"]
      metrics -> metrics
    end
  end

  defp selected_metrics(%{"metric" => metric})
       when metric in ~w(visits pageviews bounce_rate avg_duration),
       do: [metric]

  defp selected_metrics(_params), do: PublicDashboard.metrics()
end
