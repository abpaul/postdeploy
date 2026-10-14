defmodule Alplus.Monitoring.Rollup do
  @moduledoc """
  Finalizes daily Monitor uptime from durable incident intervals.

  This is a documented direct PostgreSQL maintenance path. It needs a
  transaction and an idempotent upsert; loading every check or incident through
  Ash would be needlessly expensive. Every query repeats the organization and
  project predicates from the supplied scope.
  """

  alias Alplus.Billing.Package
  alias Alplus.Monitoring.Uptime
  alias Alplus.Repo
  alias Alplus.Scope

  @spec build(Date.t(), [map()], [map()], non_neg_integer()) :: map()
  def build(%Date{} = day, incidents, paused_intervals, check_count)
      when is_list(incidents) and is_list(paused_intervals) and is_integer(check_count) and
             check_count >= 0 do
    {window_start, window_end} = day_window(day)
    uptime = Uptime.calculate(window_start, window_end, incidents, paused_intervals)

    %{
      day: day,
      uptime_ratio: uptime.uptime,
      monitored_microseconds: uptime.monitored_microseconds,
      downtime_microseconds: uptime.downtime_microseconds,
      check_count: check_count
    }
  end

  @doc """
  Finalizes a completed UTC day for one scoped monitor.

  Open incidents are clipped at the end of `day`. Re-running the finalizer
  safely replaces that day's row, which corrects a formerly open incident once
  it resolves. Pass persisted pause intervals when monitor pause history lands;
  this module never invents pause time from a monitor's current status.
  """
  @spec finalize(Scope.t(), String.t(), Date.t(), [map()]) ::
          {:ok, map()} | {:error, :not_found | :open_day}
  def finalize(
        %Scope{org_id: org_id, project_id: project_id} = scope,
        monitor_id,
        %Date{} = day,
        paused_intervals \\ []
      )
      when is_binary(org_id) and is_binary(project_id) and is_binary(monitor_id) and
             is_list(paused_intervals) do
    if Date.compare(day, Date.utc_today()) != :lt do
      {:error, :open_day}
    else
      Repo.transaction(fn -> finalize_transaction(scope, monitor_id, day, paused_intervals) end)
      |> unwrap_transaction()
    end
  end

  @doc "Deletes expired daily rollups for one scoped project, using package retention."
  @spec prune(Scope.t(), Date.t()) :: %{
          deleted: non_neg_integer(),
          cutoff: Date.t()
        }
  def prune(%Scope{org_id: org_id, project_id: project_id}, %Date{} = today)
      when is_binary(org_id) and is_binary(project_id) do
    months = Package.limit(:uptime_incident_rollup_months)
    cutoff = Date.shift(today, month: -months)

    result =
      Repo.query!(
        """
        DELETE FROM monitor_daily_rollups
        WHERE org_id = $1 AND project_id = $2 AND day < $3
        """,
        [org_id, project_id, cutoff]
      )

    %{deleted: result.num_rows, cutoff: cutoff}
  end

  @spec day_window(Date.t()) :: {DateTime.t(), DateTime.t()}
  def day_window(%Date{} = day) do
    window_start = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    {window_start, DateTime.add(window_start, 1, :day)}
  end

  defp finalize_transaction(
         %Scope{org_id: org_id, project_id: project_id},
         monitor_id,
         day,
         paused
       ) do
    case monitor(scope: {org_id, project_id}, id: monitor_id) do
      nil ->
        Repo.rollback(:not_found)

      monitor ->
        {window_start, window_end} = day_window(day)
        incidents = incidents(org_id, project_id, monitor_id, window_start, window_end)

        persisted_pauses =
          pause_intervals(org_id, project_id, monitor_id, window_start, window_end)

        check_count = check_count(org_id, project_id, monitor_id, window_start, window_end)
        rollup = build(day, incidents, persisted_pauses ++ paused, check_count)
        persist!(monitor, rollup)
        Map.merge(rollup, monitor)
    end
  end

  defp monitor(scope: {org_id, project_id}, id: monitor_id) do
    case Repo.query!(
           """
           SELECT id, environment FROM monitors
           WHERE id = $1 AND org_id = $2 AND project_id = $3
           FOR UPDATE
           """,
           [monitor_id, org_id, project_id]
         ).rows do
      [[id, environment]] ->
        %{id: id, org_id: org_id, project_id: project_id, environment: environment}

      [] ->
        nil
    end
  end

  defp incidents(org_id, project_id, monitor_id, window_start, window_end) do
    Repo.query!(
      """
      SELECT started_at, resolved_at FROM incidents
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
        AND started_at < $5 AND (resolved_at IS NULL OR resolved_at > $4)
      """,
      [org_id, project_id, monitor_id, window_start, window_end]
    ).rows
    |> Enum.map(fn [started_at, resolved_at] ->
      %{started_at: to_utc_datetime(started_at), resolved_at: to_utc_datetime(resolved_at)}
    end)
  end

  defp check_count(org_id, project_id, monitor_id, window_start, window_end) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM monitor_checks
        WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
          AND checked_at >= $4 AND checked_at < $5
        """,
        [org_id, project_id, monitor_id, window_start, window_end]
      )

    count
  end

  defp pause_intervals(org_id, project_id, monitor_id, window_start, window_end) do
    Repo.query!(
      """
      SELECT paused_at, resumed_at FROM monitor_pause_intervals
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
        AND paused_at < $5 AND (resumed_at IS NULL OR resumed_at > $4)
      """,
      [org_id, project_id, monitor_id, window_start, window_end]
    ).rows
    |> Enum.map(fn [paused_at, resumed_at] ->
      %{started_at: to_utc_datetime(paused_at), resolved_at: to_utc_datetime(resumed_at)}
    end)
  end

  # `started_at`/`resolved_at`/`paused_at`/`resumed_at` are `:utc_datetime_usec`
  # columns, which Ecto stores as a bare `timestamp` (UTC assumed). A raw
  # `Repo.query!` bypasses Ecto's type layer, so Postgrex hands the value
  # back as a `NaiveDateTime`. `Uptime.calculate/4` pattern-matches on
  # `%DateTime{}`, so coerce at this boundary.
  defp to_utc_datetime(nil), do: nil
  defp to_utc_datetime(%DateTime{} = value), do: value
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp persist!(monitor, rollup) do
    Repo.query!(
      """
      INSERT INTO monitor_daily_rollups
        (id, org_id, project_id, monitor_id, environment, day, uptime_ratio,
         monitored_microseconds, downtime_microseconds, check_count, inserted_at, updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,now(),now())
      ON CONFLICT (monitor_id, day) DO UPDATE
      SET uptime_ratio = EXCLUDED.uptime_ratio,
          monitored_microseconds = EXCLUDED.monitored_microseconds,
          downtime_microseconds = EXCLUDED.downtime_microseconds,
          check_count = EXCLUDED.check_count,
          environment = EXCLUDED.environment,
          updated_at = now()
      """,
      [
        Alplus.Id.generate(:monitor_check_rollup),
        monitor.org_id,
        monitor.project_id,
        monitor.id,
        monitor.environment,
        rollup.day,
        rollup.uptime_ratio,
        rollup.monitored_microseconds,
        rollup.downtime_microseconds,
        rollup.check_count
      ]
    )
  end

  defp unwrap_transaction({:ok, rollup}), do: {:ok, rollup}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
