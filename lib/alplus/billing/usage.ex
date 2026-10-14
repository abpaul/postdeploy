defmodule Alplus.Billing.Usage do
  @moduledoc """
  Read-only usage meters for the Billing page (ARCHITECTURE.md §8, §11).

  Each meter compares real consumption this billing period against the
  org's plan limit, from the cheap authoritative source that already
  exists for that metric: `usage_periods` for the Measure, Observe, and
  product analytics event quotas, and the existing org-scoped domain reads
  for structural counts.

  A metric never gets a fabricated zero. When its source can't be read,
  the meter's `status` is `:unavailable` and `used` is `nil`. A resolved plan
  still supplies its exact limit, so the caller can explain what is missing
  without rendering a fake usage value.

  The 130%-drop ladder step only applies to metered event quotas
  (analytics/error events), which `Alplus.Billing.EventMeter` actually
  drops past 130%. Structural caps (projects/members/monitors) can't be
  exceeded — creation is blocked at the cap — so they only ever reach
  "at capacity" (:notice) at 100%, never :dropped.
  """

  require Logger

  alias Alplus.Billing.EventMeter
  alias Alplus.Billing.Package
  alias Alplus.Repo

  @type status :: :within_limit | :warning | :notice | :dropped | :unavailable
  @type state :: :within_limit | :warning | :capacity | :dropped | :unavailable

  @type meter :: %{
          metric: atom(),
          label: String.t(),
          used: non_neg_integer() | nil,
          limit: pos_integer() | nil,
          dropped: non_neg_integer() | nil,
          status: status(),
          state: state(),
          tone: String.t()
        }

  # {metric, label, plan limit key, kind}
  @metrics [
    {:analytics_events, "Web analytics events", :analytics_events_per_month, :event},
    {:product_events, "Product analytics events", :product_events_per_month, :event},
    {:error_events, "Error events", :error_events_per_month, :event},
    {:projects, "Projects", :projects, :capacity},
    {:members, "Team members", :members, :capacity},
    {:uptime_monitors, "Uptime monitors", :uptime_monitors, :capacity}
  ]

  @doc """
  Returns one meter per tracked metric for `org_id`'s current billing
  period (the calendar month containing `now`), scoped by `scope`.

  Never raises. When the caller has no live membership, or a single
  metric's read fails, the affected meter(s) come back `:unavailable`.
  """
  @spec meters(Alplus.Scope.t(), String.t(), DateTime.t()) :: [meter()]
  def meters(scope, org_id, now \\ DateTime.utc_now()) when is_binary(org_id) do
    case live_scope(scope, org_id) do
      {:ok, live_scope} ->
        # Limits come from the one package, so a read-only organization still
        # sees its real usage against them.
        period = period_usage(org_id, now)

        Enum.map(@metrics, fn {metric, label, limit_key, kind} ->
          build_meter(
            metric,
            label,
            Package.limit(limit_key),
            kind,
            used(metric, kind, live_scope, org_id, period)
          )
        end)

      :error ->
        # A meter read is not an authorization boundary by itself. Refuse the
        # read before any usage-period query when the caller no
        # longer has a live membership in this organization.
        unavailable_meters()
    end
  rescue
    error ->
      Logger.warning(
        "Alplus.Billing.Usage: billing read failed for org #{org_id}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      unavailable_meters()
  end

  defp live_scope(%Alplus.Scope{user_id: user_id}, org_id) when is_binary(user_id) do
    case Alplus.Orgs.build_scope(Alplus.Scope.for_user(user_id), org_id) do
      {:ok, live_scope} -> {:ok, live_scope}
      {:error, :not_found} -> :error
    end
  end

  defp live_scope(_scope, _org_id), do: :error

  defp unavailable_meters do
    Enum.map(@metrics, fn {metric, label, _limit_key, _kind} ->
      unavailable_meter(metric, label)
    end)
  end

  defp period_usage(org_id, now) do
    period_start = EventMeter.month_start(DateTime.to_date(now))

    case Repo.query(
           """
           SELECT analytics_events, dropped_analytics_events, error_events, dropped_error_events,
                  product_events, dropped_product_events
           FROM usage_periods
           WHERE org_id = $1 AND period_start = $2
           """,
           [org_id, period_start]
         ) do
      {:ok,
       %{
         rows: [
           [
             analytics_events,
             dropped_analytics_events,
             error_events,
             dropped_error_events,
             product_events,
             dropped_product_events
           ]
         ]
       }} ->
        %{
          analytics_events: analytics_events,
          dropped_analytics_events: dropped_analytics_events,
          error_events: error_events,
          dropped_error_events: dropped_error_events,
          product_events: product_events,
          dropped_product_events: dropped_product_events
        }

      {:ok, %{rows: []}} ->
        %{
          analytics_events: 0,
          dropped_analytics_events: 0,
          error_events: 0,
          dropped_error_events: 0,
          product_events: 0,
          dropped_product_events: 0
        }

      {:error, reason} ->
        Logger.warning(
          "Alplus.Billing.Usage: usage_periods read failed for org #{org_id}: #{inspect(reason)}"
        )

        :unavailable
    end
  end

  defp used(:analytics_events, :event, _scope, _org_id, :unavailable), do: :unavailable

  defp used(:analytics_events, :event, _scope, _org_id, period),
    do: {:ok, period.analytics_events, period.dropped_analytics_events}

  defp used(:product_events, :event, _scope, _org_id, :unavailable), do: :unavailable

  defp used(:product_events, :event, _scope, _org_id, period),
    do: {:ok, period.product_events, period.dropped_product_events}

  defp used(:error_events, :event, _scope, _org_id, :unavailable), do: :unavailable

  defp used(:error_events, :event, _scope, _org_id, period),
    do: {:ok, period.error_events, period.dropped_error_events}

  defp used(:projects, :capacity, scope, org_id, _period) do
    safe_count(:projects, fn ->
      length(Alplus.Projects.list_projects_for_org!(org_id, actor: scope))
    end)
  end

  defp used(:members, :capacity, scope, org_id, _period) do
    safe_count(:members, fn ->
      length(Alplus.Orgs.list_memberships_for_org!(org_id, actor: scope))
    end)
  end

  defp used(:uptime_monitors, :capacity, _scope, org_id, _period) do
    safe_count(:uptime_monitors, fn -> monitor_count(org_id) end)
  end

  defp safe_count(metric, fun) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.warning(
        "Alplus.Billing.Usage: #{metric} usage read failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :unavailable
  end

  # Monitor is a project-scoped Ash resource whose read policy requires a
  # project actor, so there is no org-wide Ash read to reuse here. This
  # mirrors `Access`'s own direct, org-scoped Postgres read.
  defp monitor_count(org_id) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM monitors WHERE org_id = $1", [org_id])
    count
  end

  defp build_meter(metric, label, limit, _kind, :unavailable),
    do: unavailable_meter(metric, label, limit)

  defp build_meter(metric, label, limit, :event, {:ok, used, dropped_count}) do
    status = event_status(used, limit, dropped_count)
    to_meter(metric, label, used, limit, dropped_count, status)
  end

  defp build_meter(metric, label, limit, :capacity, {:ok, used}) do
    status = capacity_status(used, limit)
    to_meter(metric, label, used, limit, nil, status)
  end

  defp to_meter(metric, label, used, limit, dropped, status) do
    %{
      metric: metric,
      label: label,
      used: used,
      limit: limit,
      dropped: dropped,
      status: status,
      state: state_for(status),
      tone: tone_for(status)
    }
  end

  defp unavailable_meter(metric, label, limit \\ nil) do
    %{
      metric: metric,
      label: label,
      used: nil,
      limit: limit,
      dropped: nil,
      status: :unavailable,
      state: :unavailable,
      tone: "warning"
    }
  end

  # The full 80/100/130 ladder (ARCHITECTURE.md §8, §11): warning at 80%,
  # notice at 100%, dropped once actual drops have occurred past the 130%
  # ceiling — mirrors `Alplus.Billing.EventMeter`'s own decision, which
  # also requires a real dropped count, not just crossing the ceiling
  # (avoids misclassifying "just reached the cap" as "dropped" for a small
  # limit where the grace ceiling equals the limit).
  defp event_status(used, limit, dropped_count) do
    cond do
      dropped_count > 0 and used >= ceiling(limit) -> :dropped
      used >= limit -> :notice
      used * 100 >= limit * 80 -> :warning
      true -> :within_limit
    end
  end

  # Structural caps stop at 100% by construction (creation is blocked at
  # the limit elsewhere) — "at capacity", never "dropped".
  defp capacity_status(used, limit) do
    cond do
      used >= limit -> :notice
      used * 100 >= limit * 80 -> :warning
      true -> :within_limit
    end
  end

  defp ceiling(limit), do: Package.event_ceiling(limit)

  defp tone_for(:within_limit), do: "neutral"
  defp tone_for(:warning), do: "warning"
  defp tone_for(:notice), do: "error"
  defp tone_for(:dropped), do: "error"

  # `:notice` is retained in `status` for compatibility with EventMeter's
  # decision vocabulary. The billing read model also exposes the product term
  # `:capacity`, which is what the console renders to operators.
  defp state_for(:within_limit), do: :within_limit
  defp state_for(:warning), do: :warning
  defp state_for(:notice), do: :capacity
  defp state_for(:dropped), do: :dropped
end
