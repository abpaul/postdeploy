defmodule Alplus.Measure.PublicEvidence do
  @moduledoc "Safe, bounded Measure aggregate for the public homepage."

  @days 7
  @max_sources 5
  @max_top_pages 5
  @max_path_length 128

  @spec load(struct(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def load(actor, days \\ @days) do
    with {:ok, source_ids} <- source_ids(actor) do
      load_for_sources(actor, source_ids, days)
    end
  end

  @doc "Lists the public production Measure source ids for the vendor actor."
  @spec source_ids(struct()) :: {:ok, [String.t()]} | {:error, term()}
  def source_ids(actor) do
    with {:ok, sources} <- Alplus.Sources.list_public_homepage_measure_sources(actor: actor) do
      {:ok, sources |> Enum.take(@max_sources) |> Enum.map(& &1.id)}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  @doc "Aggregates a day window for source ids the caller already resolved."
  @spec load_for_sources(struct(), [String.t()], pos_integer()) :: {:ok, map()} | {:error, term()}
  def load_for_sources(_actor, [], _days),
    do: {:ok, %{pageviews: nil, visitors: nil, trend: [], top_pages: []}}

  def load_for_sources(actor, source_ids, days) do
    {since, until} = date_range(days)

    with {:ok, day_rows} <- days(source_ids, since, until, actor),
         {:ok, top_pages} <- top_pages(source_ids, since, until, actor) do
      {:ok, project(day_rows, top_pages)}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  @doc "Reads the last 24 hours of public production traffic, bucketed by hour."
  @spec load_hour_buckets(struct(), [String.t()], DateTime.t(), DateTime.t()) :: [map()]
  def load_hour_buckets(_actor, [], _since, _until), do: []

  def load_hour_buckets(actor, source_ids, since, until) do
    case Alplus.Measure.list_public_homepage_hours(source_ids, since, until, actor: actor) do
      {:ok, hours} ->
        hours
        |> Enum.group_by(& &1.hour)
        |> Enum.sort_by(&elem(&1, 0), DateTime)
        |> Enum.map(fn {hour, rows} ->
          %{
            at: hour,
            pageviews: Enum.sum(Enum.map(rows, & &1.pageviews)),
            visitors: Enum.sum(Enum.map(rows, & &1.visitors))
          }
        end)

      _error ->
        []
    end
  end

  @doc """
  Reads a day window of public production traffic for the hero chart.

  The hero chart needs no page ranking, so this runs the day query alone.
  """
  @spec load_day_buckets(struct(), [String.t()], pos_integer()) :: [map()]
  def load_day_buckets(_actor, [], _days), do: []

  def load_day_buckets(actor, source_ids, days) do
    {since, until} = date_range(days)

    case days(source_ids, since, until, actor) do
      {:ok, rows} ->
        rows
        |> Enum.group_by(& &1.date)
        |> Enum.sort_by(&elem(&1, 0), Date)
        |> Enum.map(fn {date, day_rows} ->
          %{
            at: date,
            pageviews: Enum.sum(Enum.map(day_rows, & &1.pageviews)),
            visitors: Enum.sum(Enum.map(day_rows, & &1.visitors))
          }
        end)

      _error ->
        []
    end
  end

  defp date_range(days) do
    today = Date.utc_today()
    {Date.add(today, -(days - 1)), Date.add(today, 1)}
  end

  defp days(source_ids, since, until, actor) do
    Alplus.Measure.list_public_homepage_days(source_ids, since, until, actor: actor)
  end

  # Aggregate before ranking so split traffic across days/sources is counted.
  # sobelow_skip ["SQL.Query"]
  defp top_pages(source_ids, since, until, actor) do
    result =
      Alplus.Repo.query!(
        """
        SELECT value, SUM(pageviews)::bigint AS pageviews
        FROM analytics_dimensions
        WHERE org_id = $1
          AND project_id = $2
          AND source_id = ANY($3::text[])
          AND environment = 'production'
          AND dimension = 'path'
          AND value <> $6
          AND value ~ '^/[^[:space:]]*$'
          AND date >= $4
          AND date < $5
        GROUP BY value
        ORDER BY pageviews DESC, value ASC
        LIMIT $7
        """,
        [
          actor.org_id,
          actor.project_id,
          source_ids,
          since,
          until,
          Alplus.Measure.Rollups.other_value(),
          @max_top_pages
        ]
      )

    pages =
      result.rows
      |> Enum.flat_map(fn [path, pageviews] ->
        case safe_path(path) do
          nil ->
            []

          path ->
            [%{label: path, path: path, value: path, count: pageviews, pageviews: pageviews}]
        end
      end)

    {:ok, pages}
  end

  defp safe_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and
         not String.contains?(path, [" ", "\t", "\r", "\n"]) do
      String.slice(path, 0, @max_path_length)
    end
  end

  defp safe_path(_), do: nil

  defp project([], _top_pages), do: %{pageviews: nil, visitors: nil, trend: [], top_pages: []}

  defp project(days, top_pages) do
    totals =
      Enum.reduce(days, %{pageviews: 0, visitors: 0}, fn day, totals ->
        %{pageviews: totals.pageviews + day.pageviews, visitors: totals.visitors + day.visitors}
      end)

    trend =
      days
      |> Enum.group_by(& &1.date)
      |> Enum.sort_by(&elem(&1, 0), Date)
      |> Enum.map(fn {date, rows} ->
        %{
          bucket: date,
          pageviews: Enum.sum(Enum.map(rows, & &1.pageviews)),
          visitors: Enum.sum(Enum.map(rows, & &1.visitors))
        }
      end)

    %{pageviews: totals.pageviews, visitors: totals.visitors, trend: trend, top_pages: top_pages}
  end
end
