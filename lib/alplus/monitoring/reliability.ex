defmodule Alplus.Monitoring.Reliability do
  @compile {:nowarn_unused_function, [rollups: 4, incidents: 4, pauses: 4, checks: 4]}
  @moduledoc """
  Builds the Monitor reliability objective read model.

  Reliability history is deliberately derived from durable daily rollups and
  the same incident, pause, and check evidence used by the Monitor activity
  page. A target is never inferred. Daily rows without evidence remain
  `:missing`, and paused time is removed by `Uptime.calculate/4` before any
  objective or budget arithmetic is performed.
  """

  alias Alplus.Monitoring.Uptime
  alias Alplus.Monitoring.Retention
  alias Alplus.Repo
  alias Alplus.Scope

  @history_days 90
  @burn_window_days 30
  @minimum_evidence_seconds 300
  @alert_burn_rate 1.0
  @microseconds_per_second 1_000_000

  @typedoc "A daily, incident-aware reliability history row."
  @type state :: :healthy | :degraded | :incident | :paused | :partial | :missing

  @type day :: %{
          day: Date.t(),
          state: state(),
          uptime: float() | nil,
          monitored_microseconds: non_neg_integer(),
          downtime_microseconds: non_neg_integer(),
          check_count: non_neg_integer(),
          incident_count: non_neg_integer(),
          pause_count: non_neg_integer(),
          degraded_check_count: non_neg_integer(),
          evidence?: boolean(),
          partial?: boolean(),
          historical_partial?: boolean()
        }

  @doc "Returns true only for an explicit ratio in the inclusive 0..1 contract."
  @spec valid_target?(term()) :: boolean()
  def valid_target?(target)
      when is_integer(target) or is_float(target),
      do: target > 0 and target <= 1

  def valid_target?(_target), do: false

  @doc "Returns the configured target as a percentage for display."
  @spec target_percent(number()) :: float()
  def target_percent(target) when is_number(target), do: Float.round(target * 100, 4)

  @doc "Loads a monitor's 90-day reliability history under its project scope."
  @spec history(map(), Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def history(monitor, %Scope{} = scope, options \\ [])
      when is_map(monitor) and is_list(options) do
    with :ok <- validate_scope(monitor, scope),
         {:ok, now} <- option_now(options),
         {:ok, raw_check_retention_days} <- retention_days(scope, options) do
      today = DateTime.to_date(now)
      first_day = Date.add(today, -(@history_days - 1))
      start = DateTime.new!(first_day, ~T[00:00:00], "Etc/UTC")
      rollups = rollups(scope, monitor.id, first_day, today)
      incidents = incidents(scope, monitor.id, start, now)
      pauses = pauses(scope, monitor.id, start, now)
      checks = checks(scope, monitor.id, start, now)

      days =
        for offset <- 0..(@history_days - 1) do
          day = Date.add(first_day, offset)

          build_day(
            day,
            today,
            now,
            rollups,
            incidents,
            pauses,
            checks,
            raw_check_retention_days
          )
        end

      summary = summary(days)

      {:ok,
       %{
         monitor_id: monitor.id,
         target: monitor.slo_target,
         days: days,
         summary: summary,
         budget: budget(monitor.slo_target, summary, days: days, now: now),
         first_day: first_day,
         today: today,
         generated_at: now
       }}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {:database, error}}
  end

  @doc "Loads bounded reliability histories for many monitors in four shared queries."
  @spec histories([map()], Scope.t(), keyword()) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def histories(monitors, %Scope{} = scope, options \\ [])
      when is_list(monitors) and is_list(options) do
    with true <- length(monitors) <= 300,
         :ok <-
           Enum.reduce_while(monitors, :ok, fn monitor, :ok ->
             case validate_scope(monitor, scope) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         {:ok, now} <- option_now(options),
         {:ok, raw_check_retention_days} <- retention_days(scope, options) do
      ids = Enum.map(monitors, & &1.id) |> Enum.uniq()
      today = DateTime.to_date(now)
      first_day = Date.add(today, -(@history_days - 1))
      window_start = DateTime.new!(first_day, ~T[00:00:00], "Etc/UTC")
      rollups = batch_rollups(scope, ids, first_day, today)
      incidents = batch_incidents(scope, ids, window_start, now)
      pauses = batch_pauses(scope, ids, window_start, now)
      checks = batch_checks(scope, ids, window_start, now)

      histories =
        Map.new(monitors, fn monitor ->
          days =
            for offset <- 0..(@history_days - 1) do
              day = Date.add(first_day, offset)

              build_day(
                day,
                today,
                now,
                Map.get(rollups, monitor.id, %{}),
                Map.get(incidents, monitor.id, []),
                Map.get(pauses, monitor.id, []),
                Map.get(checks, monitor.id, %{}),
                raw_check_retention_days
              )
            end

          summary = summary(days)

          {monitor.id,
           %{
             monitor_id: monitor.id,
             target: Map.get(monitor, :slo_target),
             days: days,
             summary: summary,
             budget: budget(Map.get(monitor, :slo_target), summary, days: days, now: now),
             first_day: first_day,
             today: today,
             generated_at: now
           }}
        end)

      {:ok, histories}
    else
      false -> {:error, :too_many_monitors}
      {:error, _} = error -> error
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:database, error}}
  end

  @doc "Calculates an error budget from pause-adjusted evidence."
  @spec budget(number() | nil, map(), keyword()) :: map() | nil
  def budget(target, period, options \\ [])

  def budget(nil, _period, _options), do: nil

  def budget(target, period, options) when is_map(period) and is_list(options) do
    if valid_target?(target) do
      days = Keyword.get(options, :days, [])
      now = Keyword.get(options, :now, DateTime.utc_now())
      monitored = integer_value(period, :monitored_microseconds)
      downtime = integer_value(period, :downtime_microseconds)
      burn = burn_period(days, now)
      allowed_failure_ratio = 1.0 - target
      allowed = round(monitored * allowed_failure_ratio)
      burn_allowed = round(burn.monitored_microseconds * allowed_failure_ratio)
      spent_ratio = ratio(downtime, allowed)
      burn_rate = ratio(burn.downtime_microseconds, burn_allowed)
      evidence_state = Map.get(period, :evidence_state, evidence_state(monitored))
      attainment = if evidence_state == :ready, do: ratio(monitored - downtime, monitored)

      exhausted? =
        monitored > 0 and
          ((allowed > 0 and downtime >= allowed) or (allowed == 0 and downtime > 0))

      alert? = not is_nil(burn_rate) and burn_rate >= @alert_burn_rate

      %{
        target: target,
        target_percent: target_percent(target),
        allowed_failure_ratio: allowed_failure_ratio,
        monitored_microseconds: monitored,
        downtime_microseconds: downtime,
        allowed_downtime_microseconds: allowed,
        spent_downtime_microseconds: downtime,
        remaining_downtime_microseconds: max(allowed - downtime, 0),
        spent_ratio: spent_ratio,
        attainment: attainment,
        burn_rate: burn_rate,
        burn_window_days: @burn_window_days,
        burn_monitored_microseconds: burn.monitored_microseconds,
        burn_downtime_microseconds: burn.downtime_microseconds,
        alert_threshold: @alert_burn_rate,
        alert?: alert?,
        exhausted?: exhausted?,
        evidence_state: evidence_state,
        state: budget_state(evidence_state, exhausted?, alert?),
        month_end: month_end(now)
      }
    end
  end

  def budget(_target, _period, _options), do: nil

  @doc "Calculates a budget directly from daily history rows."
  @spec budget_from_days(number() | nil, [day()], keyword()) :: map() | nil
  def budget_from_days(target, days, options \\ [])

  def budget_from_days(nil, _days, _options), do: nil

  def budget_from_days(target, days, options) when is_list(days) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    summary = summary(days)
    budget(target, summary, Keyword.put(options, :days, days) |> Keyword.put(:now, now))
  end

  @doc "Reduces daily rows to the evidence-backed summary used by the UI."
  @spec summary([day()]) :: map()
  def summary(days) when is_list(days) do
    evidence_days = Enum.filter(days, & &1.evidence?)
    monitored = Enum.sum(Enum.map(evidence_days, & &1.monitored_microseconds))
    downtime = Enum.sum(Enum.map(evidence_days, & &1.downtime_microseconds))
    incident_count = Enum.sum(Enum.map(days, & &1.incident_count))
    downtime_days = Enum.count(evidence_days, &(&1.downtime_microseconds > 0))
    evidence_seconds = div(monitored, @microseconds_per_second)

    %{
      uptime:
        if(evidence_state(monitored) == :ready,
          do: ratio(monitored - downtime, monitored),
          else: nil
        ),
      monitored_microseconds: monitored,
      downtime_microseconds: downtime,
      incident_count: incident_count,
      downtime_days: downtime_days,
      evidence_days: length(evidence_days),
      evidence_seconds: evidence_seconds,
      evidence_state: evidence_state(monitored)
    }
  end

  @doc "Classifies one daily row without relying on colour."
  @spec daily_state(map()) :: atom()
  def daily_state(day) when is_map(day) do
    cond do
      Map.get(day, :pause_count, 0) > 0 ->
        :paused

      Map.get(day, :downtime_microseconds, 0) > 0 ->
        :incident

      Map.get(day, :historical_partial?, false) ->
        :partial

      Map.get(day, :degraded_check_count, 0) > 0 ->
        :degraded

      Map.get(day, :evidence?, false) ->
        :healthy

      true ->
        :missing
    end
  end

  @doc "Returns the configured history and burn-window constants for UIs and tests."
  def history_days, do: @history_days
  def burn_window_days, do: @burn_window_days
  def minimum_evidence_seconds, do: @minimum_evidence_seconds

  defp build_day(day, today, now, rollups, incidents, pauses, checks, raw_retention_days) do
    day_start = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    day_end = if day == today, do: now, else: DateTime.add(day_start, 1, :day)
    incident_rows = intervals_for_day(incidents, day_start, day_end)
    pause_rows = intervals_for_day(pauses, day_start, day_end)
    raw_check = Map.get(checks, day)
    check = raw_check || %{count: 0, degraded_count: 0}
    rollup = Map.get(rollups, day)
    check_count = max(check.count, if(rollup, do: rollup.check_count, else: 0))

    retention_gap? =
      Date.compare(day, Date.add(today, -raw_retention_days)) == :lt and
        rollup != nil and rollup.check_count > 0 and is_nil(raw_check)

    result =
      case rollup do
        nil ->
          Uptime.calculate(day_start, day_end, incident_rows, pause_rows)

        rollup when day != today ->
          %{
            uptime: rollup.uptime,
            monitored_microseconds: rollup.monitored,
            downtime_microseconds: rollup.downtime
          }

        _rollup ->
          Uptime.calculate(day_start, day_end, incident_rows, pause_rows)
      end

    evidence? = check_count > 0 or incident_rows != [] or pause_rows != []

    day = %{
      day: day,
      state: :missing,
      uptime: if(evidence?, do: result.uptime, else: nil),
      monitored_microseconds: if(evidence?, do: result.monitored_microseconds, else: 0),
      downtime_microseconds: if(evidence?, do: result.downtime_microseconds, else: 0),
      check_count: check_count,
      incident_count: length(incident_rows),
      pause_count: length(pause_rows),
      degraded_check_count: check.degraded_count,
      evidence?: evidence?,
      partial?: day == today,
      historical_partial?: retention_gap?
    }

    %{day | state: daily_state(day)}
  end

  defp intervals_for_day(rows, day_start, day_end) do
    Enum.filter(rows, fn row ->
      started_at = row.started_at
      ended_at = row.resolved_at || day_end

      DateTime.compare(started_at, day_end) == :lt and
        DateTime.compare(ended_at, day_start) == :gt
    end)
  end

  defp burn_period(days, now) do
    first_day = Date.add(DateTime.to_date(now), -(@burn_window_days - 1))

    days
    |> Enum.filter(fn day -> Date.compare(day.day, first_day) != :lt and day.evidence? end)
    |> Enum.reduce(%{monitored_microseconds: 0, downtime_microseconds: 0}, fn day, acc ->
      %{
        monitored_microseconds: acc.monitored_microseconds + day.monitored_microseconds,
        downtime_microseconds: acc.downtime_microseconds + day.downtime_microseconds
      }
    end)
  end

  defp budget_state(:insufficient, _exhausted?, _alert?), do: :insufficient
  defp budget_state(_evidence_state, true, _alert?), do: :exhausted
  defp budget_state(_evidence_state, _exhausted?, true), do: :alert
  defp budget_state(_evidence_state, _exhausted?, _alert?), do: :healthy

  defp evidence_state(monitored)
       when monitored >= @minimum_evidence_seconds * @microseconds_per_second,
       do: :ready

  defp evidence_state(0), do: :missing
  defp evidence_state(_monitored), do: :insufficient

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp integer_value(map, key) do
    case Map.get(map, key, 0) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      _ -> 0
    end
  end

  defp month_end(now) do
    now
    |> DateTime.to_date()
    |> Date.end_of_month()
  end

  defp validate_scope(%{org_id: org_id, project_id: project_id}, %Scope{
         org_id: org_id,
         project_id: project_id
       })
       when is_binary(org_id) and is_binary(project_id),
       do: :ok

  defp validate_scope(_monitor, _scope), do: {:error, :out_of_scope}

  defp retention_days(%Scope{}, options) do
    case Keyword.get(options, :retention_days) do
      days when is_integer(days) and days > 0 ->
        {:ok, days}

      nil ->
        {:ok, Retention.detailed_check_retention_days()}

      _ ->
        {:error, :invalid_retention_days}
    end
  end

  defp option_now(options) do
    case Keyword.get(options, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, now}
      _ -> {:error, :invalid_now}
    end
  end

  defp rollups(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         monitor_id,
         first_day,
         today
       ) do
    Repo.query!(
      """
      SELECT day, uptime_ratio, monitored_microseconds, downtime_microseconds, check_count
      FROM monitor_daily_rollups
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = monitor_daily_rollups.org_id
            AND memberships.user_id = $4
        ))
        AND day >= $5 AND day <= $6
      """,
      [org_id, project_id, monitor_id, user_id, first_day, today]
    ).rows
    |> Map.new(fn [day, uptime, monitored, downtime, check_count] ->
      {day,
       %{
         uptime: uptime,
         monitored: integer_value(%{value: monitored}, :value),
         downtime: integer_value(%{value: downtime}, :value),
         check_count: check_count || 0
       }}
    end)
  end

  defp incidents(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         monitor_id,
         window_start,
         now
       ) do
    Repo.query!(
      """
      SELECT started_at, resolved_at
      FROM incidents
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = incidents.org_id
            AND memberships.user_id = $4
        ))
        AND started_at < $6 AND (resolved_at IS NULL OR resolved_at > $5)
      """,
      [org_id, project_id, monitor_id, user_id, window_start, now]
    ).rows
    |> Enum.map(fn [started_at, resolved_at] ->
      %{started_at: to_datetime(started_at), resolved_at: to_datetime(resolved_at)}
    end)
  end

  defp pauses(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         monitor_id,
         window_start,
         now
       ) do
    Repo.query!(
      """
      SELECT paused_at, resumed_at
      FROM monitor_pause_intervals
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = monitor_pause_intervals.org_id
            AND memberships.user_id = $4
        ))
        AND paused_at < $6 AND (resumed_at IS NULL OR resumed_at > $5)
      """,
      [org_id, project_id, monitor_id, user_id, window_start, now]
    ).rows
    |> Enum.map(fn [paused_at, resumed_at] ->
      %{started_at: to_datetime(paused_at), resolved_at: to_datetime(resumed_at)}
    end)
  end

  defp checks(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         monitor_id,
         window_start,
         now
       ) do
    Repo.query!(
      """
      SELECT checked_at::date, count(*)::bigint,
        count(*) FILTER (WHERE status = 'degraded')::bigint
      FROM monitor_checks
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = $3
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = monitor_checks.org_id
            AND memberships.user_id = $4
        ))
        AND checked_at >= $5 AND checked_at < $6
      GROUP BY checked_at::date
      """,
      [org_id, project_id, monitor_id, user_id, window_start, now]
    ).rows
    |> Map.new(fn [day, count, degraded_count] ->
      {day, %{count: count || 0, degraded_count: degraded_count || 0}}
    end)
  end

  defp batch_rollups(_scope, [], _first_day, _today), do: %{}

  defp batch_rollups(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         ids,
         first_day,
         today
       ) do
    Repo.query!(
      """
      SELECT monitor_id, day, uptime_ratio, monitored_microseconds, downtime_microseconds, check_count
      FROM monitor_daily_rollups
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = ANY($3::text[])
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = monitor_daily_rollups.org_id
            AND memberships.user_id = $4
        ))
        AND day >= $5 AND day <= $6
      """,
      [org_id, project_id, ids, user_id, first_day, today]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), fn [_id, day, uptime, monitored, downtime, count] ->
      {day,
       %{
         uptime: uptime,
         monitored: integer_value(%{value: monitored}, :value),
         downtime: integer_value(%{value: downtime}, :value),
         check_count: count || 0
       }}
    end)
    |> Map.new(fn {monitor_id, rows} -> {monitor_id, Map.new(rows)} end)
  end

  defp batch_incidents(_scope, [], _start, _now), do: %{}

  defp batch_incidents(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         ids,
         start_at,
         now
       ) do
    Repo.query!(
      """
      SELECT monitor_id, started_at, resolved_at
      FROM incidents
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = ANY($3::text[])
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = incidents.org_id
            AND memberships.user_id = $4
        ))
        AND started_at < $6 AND (resolved_at IS NULL OR resolved_at > $5)
      """,
      [org_id, project_id, ids, user_id, start_at, now]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), fn [_id, started, resolved] ->
      %{started_at: to_datetime(started), resolved_at: to_datetime(resolved)}
    end)
  end

  defp batch_pauses(_scope, [], _start, _now), do: %{}

  defp batch_pauses(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         ids,
         start_at,
         now
       ) do
    Repo.query!(
      """
      SELECT monitor_id, paused_at, resumed_at
      FROM monitor_pause_intervals
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = ANY($3::text[])
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = monitor_pause_intervals.org_id
            AND memberships.user_id = $4
        ))
        AND paused_at < $6 AND (resumed_at IS NULL OR resumed_at > $5)
      """,
      [org_id, project_id, ids, user_id, start_at, now]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), fn [_id, paused, resumed] ->
      %{started_at: to_datetime(paused), resolved_at: to_datetime(resumed)}
    end)
  end

  defp batch_checks(_scope, [], _start, _now), do: %{}

  defp batch_checks(
         %Scope{org_id: org_id, project_id: project_id, user_id: user_id},
         ids,
         start_at,
         now
       ) do
    Repo.query!(
      """
      SELECT monitor_id, checked_at::date, count(*)::bigint,
        count(*) FILTER (WHERE status = 'degraded')::bigint
      FROM monitor_checks
      WHERE org_id = $1 AND project_id = $2 AND monitor_id = ANY($3::text[])
        AND ($4::text IS NULL OR EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.org_id = monitor_checks.org_id
            AND memberships.user_id = $4
        ))
        AND checked_at >= $5 AND checked_at < $6
      GROUP BY monitor_id, checked_at::date
      """,
      [org_id, project_id, ids, user_id, start_at, now]
    ).rows
    |> Enum.group_by(&Enum.at(&1, 0), fn [_id, day, count, degraded] ->
      {day, %{count: count || 0, degraded_count: degraded || 0}}
    end)
    |> Map.new(fn {monitor_id, rows} -> {monitor_id, Map.new(rows)} end)
  end

  defp to_datetime(nil), do: nil
  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
end
