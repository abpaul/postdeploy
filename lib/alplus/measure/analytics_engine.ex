defmodule Alplus.Measure.AnalyticsEngine do
  @moduledoc """
  The non-authoritative recent-window analytics sink.

  PostgreSQL rollups remain Measure's durable truth. This boundary lets the
  ingest path stream privacy-safe aggregate points to Analytics Engine without
  coupling dashboard reads to one transport or vendor client.
  """

  @allowed_keys ~w(org_id project_id source_id hour pageviews visitors visits bounces duration_seconds)a

  @type point :: %{
          required(:org_id) => String.t(),
          required(:project_id) => String.t(),
          # The Measure Source (site, issue #34 Model A) this point is
          # attributed to. Two sites can share a project (and even an
          # environment), so `source_id` — not `project_id` — is the
          # partition key for every per-site read.
          required(:source_id) => String.t(),
          required(:hour) => DateTime.t(),
          required(:pageviews) => non_neg_integer(),
          required(:visitors) => non_neg_integer(),
          required(:visits) => non_neg_integer(),
          # A second pageview corrects a prior +1 bounce, so points carry a
          # signed delta. The adapter clamps the accumulated rollup at zero.
          required(:bounces) => integer(),
          required(:duration_seconds) => non_neg_integer()
        }

  @callback write([point()]) :: :ok | {:error, term()}
  @callback recent(String.t(), DateTime.t()) :: {:ok, [point()]} | {:error, term()}
  @callback recent_many([String.t()], DateTime.t()) ::
              {:ok, %{String.t() => [point()]}} | {:error, term()}

  @doc """
  The earliest instant this sink still guarantees it holds every point for.

  A reader cannot infer retention from the rows a query happens to return: an
  hour with no traffic and an hour the sink has dropped look identical. An
  adapter that knows its own boundary declares it here so a comparison against
  an earlier period can be refused when the sink never reached that far back.
  `:unknown` means the boundary cannot be established, which is never treated
  as coverage.
  """
  @callback coverage_since() :: {:ok, DateTime.t()} | :unknown

  @optional_callbacks coverage_since: 0

  @doc "Queues one already-aggregated point for the configured AE sink."
  @spec record(point()) :: :ok
  def record(point) do
    validate_point!(point)
    Alplus.Measure.AnalyticsEngine.Batcher.enqueue(point)
  end

  @doc """
  Loads a recent window from AE for one Measure Source (site). AE is a
  non-authoritative, optional sink: `Alplus.Measure.Dashboard` treats an
  `{:error, _}` return here as "read the durable PostgreSQL rollups
  instead," not as dashboard unavailability. Dashboard unavailable state is
  reserved for a failed durable read.
  """
  @spec recent(String.t(), DateTime.t()) :: {:ok, [point()]} | {:error, term()}
  def recent(source_id, %DateTime{} = since) when is_binary(source_id) do
    adapter().recent(source_id, since)
  end

  @doc """
  Loads a recent window for several Measure Sources in one call, so a card
  grid does not run one AE round trip per card (issue #34 Model A). Like
  `recent/2`, an `{:error, _}` return here is a normal "fall back to
  durable PostgreSQL rollups" signal, not dashboard unavailability.
  """
  @spec recent_many([String.t()], DateTime.t()) ::
          {:ok, %{String.t() => [point()]}} | {:error, term()}
  def recent_many(source_ids, %DateTime{} = since) when is_list(source_ids) do
    adapter().recent_many(source_ids, since)
  end

  @doc "Loads recent points with an exclusive upper bound."
  def recent_many(source_ids, %DateTime{} = since, %DateTime{} = until)
      when is_list(source_ids) do
    case recent_many(source_ids, since) do
      {:ok, points_by_source} ->
        {:ok,
         Map.new(points_by_source, fn {source_id, points} ->
           {source_id, Enum.filter(points, &(DateTime.compare(&1.hour, until) == :lt))}
         end)}

      error ->
        error
    end
  end

  @doc "The configured sink's own retention boundary, or `:unknown`."
  @spec coverage_since() :: {:ok, DateTime.t()} | :unknown
  def coverage_since do
    adapter = adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :coverage_since, 0) do
      adapter.coverage_since()
    else
      :unknown
    end
  end

  @doc false
  @spec adapter() :: module()
  def adapter, do: Application.fetch_env!(:alplus, :analytics_engine_adapter)

  @doc false
  @spec validate_point!(point()) :: :ok
  def validate_point!(point) when is_map(point) do
    if Map.keys(point) |> Enum.all?(&(&1 in @allowed_keys)) and
         Enum.all?(@allowed_keys, &Map.has_key?(point, &1)) and
         is_binary(point.org_id) and is_binary(point.project_id) and
         match?(%DateTime{}, point.hour) and
         Enum.all?(
           [point.pageviews, point.visitors, point.visits, point.duration_seconds],
           &(is_integer(&1) and &1 >= 0)
         ) and
         is_integer(point.bounces) do
      :ok
    else
      raise ArgumentError, "analytics points must contain only privacy-safe aggregate fields"
    end
  end

  def validate_point!(_), do: raise(ArgumentError, "analytics points must be maps")
end
