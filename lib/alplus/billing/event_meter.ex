defmodule Alplus.Billing.EventMeter do
  @moduledoc """
  The one metering implementation for every per-product event quota
  (issue #55): the atomic usage-period upsert and the drop-at-130%-of-limit
  ceiling decision, parameterised by metric.

  This is a direct PostgreSQL escape hatch for the public ingest hot path.
  The row-locked usage-period update makes the 130% decision atomic, for one
  event or for a whole batch. ETS only caches completed usage reads for the
  dashboard; it never authorizes a write.
  """

  alias Alplus.Billing.{Access, EntitlementError, Package}
  alias Alplus.Billing.UsageCache
  alias Alplus.Repo

  @type metric :: :analytics_events | :error_events | :product_events

  @type status :: :within_limit | :warning | :notice | :dropped

  @type decision :: %{
          accepted?: boolean(),
          accepted: non_neg_integer(),
          metric: metric(),
          count: non_neg_integer(),
          dropped: non_neg_integer(),
          limit: non_neg_integer(),
          period_start: Date.t(),
          status: status()
        }

  # Fixed, compile-time column mapping per metric — never request data. The
  # interpolated identifiers below come only from this map.
  @metrics %{
    analytics_events: %{
      count_column: "analytics_events",
      dropped_column: "dropped_analytics_events",
      limit_key: :analytics_events_per_month
    },
    error_events: %{
      count_column: "error_events",
      dropped_column: "dropped_error_events",
      limit_key: :error_events_per_month
    },
    product_events: %{
      count_column: "product_events",
      dropped_column: "dropped_product_events",
      limit_key: :product_events_per_month
    }
  }

  @doc """
  Meters one event for `metric`. Accepts it while the period count is under
  the package's grace ceiling; drops (but still counts) everything past it.

  An inactive organization (issue #61) is refused outright: no access, so no
  usage write. The refusal is a `decision` with
  `accepted?: false`, the same shape every caller already matches on.
  """
  @spec consume(String.t(), metric(), DateTime.t()) :: decision()
  def consume(org_id, metric, %DateTime{} = now), do: consume(org_id, metric, now, 1)

  @doc """
  Meters `count` events of `metric` in one call, for a batch ingest request.

  Accepts the prefix of the batch that still fits under the grace ceiling and
  drops the rest, so a 100-event batch that straddles the ceiling is partly
  written rather than wholly refused. `:accepted` is how many the caller may
  persist.
  """
  @spec consume(String.t(), metric(), DateTime.t(), pos_integer()) :: decision()
  def consume(org_id, metric, %DateTime{} = now, count)
      when is_map_key(@metrics, metric) and is_integer(count) and count > 0 do
    case Access.check(org_id) do
      {:ok, _access} ->
        meter(org_id, metric, now, count)

      {:error, %EntitlementError{reason: :plan_inactive}} ->
        refused(metric, now)
    end
  end

  defp meter(org_id, metric, now, requested) do
    %{count_column: count_column, dropped_column: dropped_column, limit_key: limit_key} =
      Map.fetch!(@metrics, metric)

    limit = Package.limit(limit_key)
    ceiling = quota_ceiling(limit)
    period_start = month_start(DateTime.to_date(now))

    {count, dropped, accepted} =
      upsert!(org_id, period_start, count_column, dropped_column, ceiling, requested)

    decision =
      decision(%{
        metric: metric,
        count: count,
        dropped: dropped,
        accepted: accepted,
        limit: limit,
        ceiling: ceiling,
        period_start: period_start
      })

    cache_usage(org_id, period_start, count_column, dropped_column, count, dropped, now)
    decision
  end

  defp refused(metric, now) do
    %{
      accepted?: false,
      accepted: 0,
      metric: metric,
      count: 0,
      dropped: 0,
      limit: 0,
      period_start: month_start(DateTime.to_date(now)),
      status: :dropped
    }
  end

  @doc """
  Returns the current period's raw usage columns for both metrics, with a
  short-lived ETS read cache for dashboard display.
  """
  @spec current(String.t(), DateTime.t()) :: map()
  def current(org_id, %DateTime{} = now) when is_binary(org_id) do
    period_start = month_start(DateTime.to_date(now))
    now_ms = now_ms(now)

    case UsageCache.fetch(org_id, period_start, now_ms) do
      {:ok, usage} -> usage
      :miss -> load_current(org_id, period_start, now_ms)
    end
  end

  @doc "Returns the first UTC date of the given date's billing month."
  @spec month_start(Date.t()) :: Date.t()
  def month_start(%Date{} = date), do: Date.beginning_of_month(date)

  # Two statements in one transaction, because the accepted count must be
  # exact for a batch. The first makes the period row exist; the second locks
  # that row (`FOR UPDATE` inside its own `FROM` subquery), so two concurrent
  # ingests serialize and neither can cross the ceiling. A single
  # `INSERT ... ON CONFLICT DO UPDATE` cannot return how many of `requested`
  # it took, because `RETURNING` never sees the pre-update row.
  # `count_column`/`dropped_column` come from the fixed compile-time
  # `@metrics` map (guarded by `is_map_key/2` at the call site), never from
  # request data. Both statements are parameterized.
  # sobelow_skip ["SQL.Query"]
  defp upsert!(org_id, period_start, count_column, dropped_column, ceiling, requested) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO usage_periods (id, org_id, period_start, inserted_at, updated_at)
          VALUES ($1, $2, $3, now(), now())
          ON CONFLICT (org_id, period_start) DO NOTHING
          """,
          [Alplus.Id.generate(:usage_period), org_id, period_start]
        )

        %{rows: [[count, dropped, accepted]]} =
          Repo.query!(
            """
            UPDATE usage_periods AS u
            SET #{count_column} = u.#{count_column} + LEAST($4, GREATEST(0, $3 - prior.taken)),
                #{dropped_column} =
                  u.#{dropped_column} + $4 - LEAST($4, GREATEST(0, $3 - prior.taken)),
                updated_at = now()
            FROM (
              SELECT #{count_column} AS taken
              FROM usage_periods
              WHERE org_id = $1 AND period_start = $2
              FOR UPDATE
            ) AS prior
            WHERE u.org_id = $1 AND u.period_start = $2
            RETURNING u.#{count_column}, u.#{dropped_column},
                      LEAST($4, GREATEST(0, $3 - prior.taken))
            """,
            [org_id, period_start, ceiling, requested]
          )

        {count, dropped, accepted}
      end)

    result
  end

  defp load_current(org_id, period_start, now_ms) do
    usage =
      case Repo.query!(
             """
             SELECT analytics_events, dropped_analytics_events, error_events, dropped_error_events,
                    product_events, dropped_product_events
             FROM usage_periods
             WHERE org_id = $1 AND period_start = $2
             """,
             [org_id, period_start]
           ).rows do
        [
          [
            analytics_events,
            dropped_analytics_events,
            error_events,
            dropped_error_events,
            product_events,
            dropped_product_events
          ]
        ] ->
          %{
            analytics_events: analytics_events,
            dropped_analytics_events: dropped_analytics_events,
            error_events: error_events,
            dropped_error_events: dropped_error_events,
            product_events: product_events,
            dropped_product_events: dropped_product_events
          }

        [] ->
          %{
            analytics_events: 0,
            dropped_analytics_events: 0,
            error_events: 0,
            dropped_error_events: 0,
            product_events: 0,
            dropped_product_events: 0
          }
      end

    UsageCache.put(org_id, period_start, usage, now_ms)
    usage
  end

  # Refresh the dashboard read-cache with the just-metered counts. ETS-only
  # merge: on a cold cache we publish just this metric's pair rather than
  # paying an extra database read inside the ingest hot path; a later
  # `current/2` miss loads the full row anyway.
  defp cache_usage(org_id, period_start, count_column, dropped_column, count, dropped, now) do
    cached =
      case UsageCache.fetch(org_id, period_start, now_ms(now)) do
        {:ok, usage} -> usage
        :miss -> %{}
      end

    {count_key, dropped_key} = cache_keys(count_column, dropped_column)

    UsageCache.put(
      org_id,
      period_start,
      Map.merge(cached, %{count_key => count, dropped_key => dropped}),
      now_ms(now)
    )
  end

  defp cache_keys("analytics_events", "dropped_analytics_events"),
    do: {:analytics_events, :dropped_analytics_events}

  defp cache_keys("error_events", "dropped_error_events"),
    do: {:error_events, :dropped_error_events}

  defp cache_keys("product_events", "dropped_product_events"),
    do: {:product_events, :dropped_product_events}

  defp decision(%{
         metric: metric,
         count: count,
         dropped: dropped,
         accepted: accepted,
         limit: limit,
         ceiling: ceiling,
         period_start: period_start
       }) do
    status =
      cond do
        dropped > 0 and count >= ceiling -> :dropped
        count >= limit -> :notice
        count * 100 >= limit * 80 -> :warning
        true -> :within_limit
      end

    %{
      accepted?: accepted > 0,
      accepted: accepted,
      metric: metric,
      count: count,
      dropped: dropped,
      limit: limit,
      period_start: period_start,
      status: status
    }
  end

  defp quota_ceiling(limit), do: Package.event_ceiling(limit)
  defp now_ms(now), do: DateTime.to_unix(now, :millisecond)
end
