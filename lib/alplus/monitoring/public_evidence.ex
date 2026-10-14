defmodule Alplus.Monitoring.PublicEvidence do
  @moduledoc "Safe, bounded monitor evidence for the public marketing homepage."

  @max_monitors 20
  @max_history_days 90

  @type row :: %{
          name: String.t(),
          state: atom(),
          uptime: float() | nil,
          history: list()
        }

  @spec load(struct()) ::
          {:ok,
           %{
             rows: list(),
             history: list(),
             monitor_ids: [String.t()],
             uptime: float() | nil,
             response_time_ms: number() | nil
           }}
          | {:error, term()}
  def load(actor) do
    today = Date.utc_today()
    since_day = Date.add(today, -(@max_history_days - 1))
    until_day = Date.add(today, 1)

    with {:ok, monitors} <- Alplus.Monitoring.list_public_homepage_monitors(actor: actor) do
      monitors = Enum.take(monitors, @max_monitors)
      monitor_ids = Enum.map(monitors, & &1.id)

      with {:ok, rollups} <- rollups(monitor_ids, since_day, until_day, actor),
           {:ok, checks} <- checks(monitor_ids, actor) do
        schedules = load_schedules(actor, monitors)
        recent = load_recent_checks(actor, monitor_ids)
        windows = load_monitor_windows(actor, monitor_ids, window_since())
        {:ok, project(monitors, rollups, checks, schedules, recent, windows)}
      end
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  @recent_hours 24
  @window_hours 36

  @doc """
  Reads the configured protocol cadence for the given public monitors.

  One read per distinct monitor type, never one per monitor. Only the
  schedule fields are selected.
  """
  @spec load_schedules(struct(), list()) :: %{optional(String.t()) => map()}
  def load_schedules(_actor, []), do: %{}

  def load_schedules(actor, monitors) do
    monitor_ids = Enum.map(monitors, & &1.id)

    monitors
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.flat_map(&schedule_rows(&1, monitor_ids, actor))
    |> Map.new()
  end

  defp schedule_rows(type, monitor_ids, actor) do
    case schedule_reader(type) do
      nil ->
        []

      reader ->
        case reader.(monitor_ids, actor: actor) do
          {:ok, rows} ->
            Enum.map(rows, fn row ->
              {row.monitor_id,
               %{
                 interval_seconds: Map.get(row, :interval_seconds),
                 cron_expression: Map.get(row, :cron_expression)
               }}
            end)

          _error ->
            []
        end
    end
  end

  defp schedule_reader("http"), do: &Alplus.Monitoring.list_public_homepage_http_configs/2
  defp schedule_reader("keyword"), do: &Alplus.Monitoring.list_public_homepage_http_configs/2
  defp schedule_reader("tcp"), do: &Alplus.Monitoring.list_public_homepage_tcp_configs/2
  defp schedule_reader("dns"), do: &Alplus.Monitoring.list_public_homepage_dns_configs/2

  defp schedule_reader("heartbeat"),
    do: &Alplus.Monitoring.list_public_homepage_heartbeat_configs/2

  defp schedule_reader(_other), do: nil

  @doc """
  Counts the last 24 hours of checks for each public monitor in one query.

  Ash reads cannot express a grouped count without loading every check row,
  and the production window holds thousands of rows per day.
  """
  @spec load_recent_checks(struct(), [String.t()]) :: %{optional(String.t()) => map()}
  def load_recent_checks(_actor, []), do: %{}

  # sobelow_skip ["SQL.Query"]
  def load_recent_checks(actor, monitor_ids) do
    since = DateTime.add(DateTime.utc_now(), -@recent_hours * 3_600, :second)

    result =
      Alplus.Repo.query!(
        """
        SELECT monitor_id,
               COUNT(*)::bigint AS checks,
               COUNT(*) FILTER (WHERE status <> 'up')::bigint AS failed
        FROM monitor_checks
        WHERE org_id = $1
          AND project_id = $2
          AND environment = 'production'
          AND monitor_id = ANY($3::text[])
          AND checked_at >= $4
        GROUP BY monitor_id
        """,
        [actor.org_id, actor.project_id, monitor_ids, since]
      )

    Map.new(result.rows, fn [monitor_id, checks, failed] ->
      {monitor_id, %{checks: checks, failed: failed}}
    end)
  end

  @doc """
  Buckets public production checks by hour or by day in one query.

  The same row set answers both the uptime chart and the average response
  chart, so a range costs one check query however many monitors exist.
  """
  @spec load_check_buckets(struct(), [String.t()], :hour | :day, DateTime.t()) :: [map()]
  def load_check_buckets(_actor, [], _unit, _since), do: []

  # sobelow_skip ["SQL.Query"]
  def load_check_buckets(actor, monitor_ids, unit, since) when unit in [:hour, :day] do
    result =
      Alplus.Repo.query!(
        """
        SELECT date_trunc($5::text, checked_at) AS bucket,
               COUNT(*)::bigint AS checks,
               COUNT(*) FILTER (WHERE status <> 'up')::bigint AS failed,
               AVG(latency_ms)::float AS latency_ms
        FROM monitor_checks
        WHERE org_id = $1
          AND project_id = $2
          AND environment = 'production'
          AND monitor_id = ANY($3::text[])
          AND checked_at >= $4
        GROUP BY 1
        ORDER BY 1
        """,
        [actor.org_id, actor.project_id, monitor_ids, since, Atom.to_string(unit)]
      )

    Enum.map(result.rows, fn [bucket, checks, failed, latency_ms] ->
      %{at: bucket, checks: checks, failed: failed, latency_ms: latency_ms}
    end)
  end

  @doc """
  Reads the recent check windows for each monitor, one bucket per hour.

  The public monitor card draws one tick per window, so the series has to be
  per monitor rather than per project. Buckets carry counts and an average
  latency only: no target, no status code, no payload.
  """
  @spec load_monitor_windows(struct(), [String.t()], DateTime.t()) ::
          %{optional(String.t()) => [map()]}
  def load_monitor_windows(_actor, [], _since), do: %{}

  # sobelow_skip ["SQL.Query"]
  def load_monitor_windows(actor, monitor_ids, since) do
    result =
      Alplus.Repo.query!(
        """
        SELECT monitor_id,
               date_trunc('hour', checked_at) AS bucket,
               COUNT(*)::bigint AS checks,
               COUNT(*) FILTER (WHERE status <> 'up')::bigint AS failed,
               AVG(latency_ms)::float AS latency_ms
        FROM monitor_checks
        WHERE org_id = $1
          AND project_id = $2
          AND environment = 'production'
          AND monitor_id = ANY($3::text[])
          AND checked_at >= $4
        GROUP BY 1, 2
        ORDER BY 1, 2
        """,
        [actor.org_id, actor.project_id, monitor_ids, since]
      )

    result.rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {monitor_id, rows} ->
      {monitor_id,
       Enum.map(rows, fn [_id, bucket, checks, failed, latency_ms] ->
         %{at: bucket, checks: checks, failed: failed, latency_ms: latency_ms}
       end)}
    end)
  end

  @doc "Reads the public daily uptime rollups for a bounded day window."
  @spec load_rollup_buckets(struct(), [String.t()], Date.t(), Date.t()) :: [map()]
  def load_rollup_buckets(_actor, [], _since, _until), do: []

  def load_rollup_buckets(actor, monitor_ids, since, until) do
    case rollups(monitor_ids, since, until, actor) do
      {:ok, rollups} ->
        rollups
        |> Enum.group_by(& &1.day)
        |> Enum.sort_by(&elem(&1, 0), Date)
        |> Enum.map(fn {day, day_rollups} ->
          {monitored, downtime} =
            Enum.reduce(day_rollups, {0, 0}, fn rollup, {monitored, downtime} ->
              {monitored + rollup.monitored_microseconds, downtime + rollup.downtime_microseconds}
            end)

          %{day: day, monitored: monitored, downtime: downtime}
        end)

      _error ->
        []
    end
  end

  defp rollups(monitor_ids, since, until, actor) do
    Alplus.Monitoring.list_public_homepage_monitor_rollups(monitor_ids, since, until,
      actor: actor
    )
  end

  defp checks([], _actor), do: {:ok, []}

  defp checks(monitor_ids, actor) do
    Alplus.Monitoring.list_public_homepage_monitor_checks(monitor_ids, actor: actor)
  end

  defp project(monitors, rollups, checks, schedules, recent, windows) do
    rollups_by_monitor = Enum.group_by(rollups, & &1.monitor_id)

    rows =
      Enum.map(monitors, fn monitor ->
        monitor_rollups = Map.get(rollups_by_monitor, monitor.id, [])
        monitor_state = state(monitor.last_known_status)
        recent_checks = Map.get(recent, monitor.id, %{checks: 0, failed: 0})

        %{
          name: monitor.name,
          state: monitor_state,
          uptime: uptime(monitor_rollups),
          history: history(monitor_rollups),
          response_time_ms: nil,
          type_label: type_label(monitor.type, Map.get(schedules, monitor.id)),
          checks_recent: recent_checks.checks,
          windows: check_windows(Map.get(windows, monitor.id, [])),
          caption: row_caption(recent_checks, monitor_state)
        }
      end)

    %{
      rows: rows,
      history: overall_history(rollups),
      uptime: uptime(rollups),
      response_time_ms: response_time(checks),
      monitor_ids: Enum.map(monitors, & &1.id)
    }
  end

  # One tick per hour over the recent window. Every hour is present, so a gap
  # in the checks reads as a gap, not as a shorter history. Height carries the
  # average latency; colour carries whether the checks passed.
  defp check_windows(buckets) do
    by_hour = Map.new(buckets, &{DateTime.truncate(to_datetime(&1.at), :second), &1})
    now = DateTime.utc_now() |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})

    for offset <- (@window_hours - 1)..0//-1 do
      at = DateTime.add(now, -offset * 3_600, :second)
      bucket = Map.get(by_hour, DateTime.truncate(at, :second))

      %{
        label: window_label(at),
        value: bucket && bucket.latency_ms && round(bucket.latency_ms),
        state: window_state(bucket)
      }
    end
  end

  defp window_state(nil), do: :none

  defp window_state(%{checks: checks, failed: failed}) do
    cond do
      checks == 0 -> :none
      failed == 0 -> :up
      failed < checks -> :degraded
      true -> :down
    end
  end

  defp window_label(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:00 UTC")

  defp to_datetime(%DateTime{} = at), do: at
  defp to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp window_since, do: DateTime.add(DateTime.utc_now(), -@window_hours * 3_600, :second)

  defp state("up"), do: :up
  defp state("down"), do: :down
  defp state("degraded"), do: :degraded
  defp state(_), do: :unknown

  defp uptime([]), do: nil

  defp uptime(rollups) do
    {monitored, downtime} =
      Enum.reduce(rollups, {0, 0}, fn rollup, {monitored, downtime} ->
        {monitored + rollup.monitored_microseconds, downtime + rollup.downtime_microseconds}
      end)

    if monitored > 0, do: Float.round((monitored - downtime) / monitored * 100, 2), else: nil
  end

  defp history(rollups) do
    rollups
    |> Enum.sort_by(& &1.day, Date)
    |> Enum.take(-@max_history_days)
    |> Enum.map(fn rollup ->
      %{day: rollup.day, uptime: uptime_ratio(rollup)}
    end)
  end

  defp uptime_ratio(%{uptime_ratio: ratio}) when is_number(ratio),
    do: Float.round(ratio * 100, 2)

  defp uptime_ratio(_), do: nil

  defp response_time([]), do: nil

  defp response_time([%{latency_ms: latency_ms} | _]) when is_number(latency_ms), do: latency_ms
  defp response_time(_), do: nil

  defp overall_history(rollups) do
    rollups
    |> Enum.group_by(& &1.day)
    |> Enum.sort_by(&elem(&1, 0), Date)
    |> Enum.map(fn {day, day_rollups} ->
      {monitored, downtime} =
        Enum.reduce(day_rollups, {0, 0}, fn rollup, {monitored, downtime} ->
          {monitored + rollup.monitored_microseconds, downtime + rollup.downtime_microseconds}
        end)

      %{
        day: day,
        uptime:
          if(monitored > 0,
            do: Float.round((monitored - downtime) / monitored * 100, 2),
            else: nil
          )
      }
    end)
    |> Enum.take(-@max_history_days)
  end

  @type_names %{
    "http" => "HTTP",
    "keyword" => "Keyword",
    "tcp" => "TCP",
    "dns" => "DNS",
    "heartbeat" => "Heartbeat"
  }

  defp type_label(type, schedule) do
    name = Map.get(@type_names, type) || "Monitor"

    case cadence(schedule) do
      nil -> name
      cadence -> name <> ", " <> cadence
    end
  end

  defp cadence(nil), do: nil

  defp cadence(%{interval_seconds: seconds}) when is_integer(seconds) and seconds > 0,
    do: interval(seconds)

  defp cadence(%{cron_expression: cron}) when is_binary(cron), do: cron_cadence(cron)
  defp cadence(_schedule), do: nil

  defp interval(seconds) when seconds < 3_600, do: "#{seconds}s"
  defp interval(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h"
  defp interval(seconds), do: "#{div(seconds, 86_400)}d"

  defp cron_cadence(cron) do
    case String.split(cron, ~r/\s+/, trim: true) do
      [_minute, "*", "*", "*", "*"] -> "hourly"
      [_minute, _hour, "*", "*", "*"] -> "daily"
      [_minute, _hour, "*", "*", _weekday] -> "weekly"
      [_minute, _hour, _day, "*", "*"] -> "monthly"
      _other -> "on a schedule"
    end
  end

  defp row_caption(%{checks: 0}, _state), do: "No checks in the last 24 hours"
  defp row_caption(%{failed: 0}, _state), do: "Every check passed"

  defp row_caption(%{failed: failed}, :up),
    do: "#{failed} #{pluralize(failed, "failed check")}, recovered"

  defp row_caption(%{failed: failed}, _state),
    do: "#{failed} #{pluralize(failed, "failed check")} in the last 24 hours"

  defp pluralize(1, noun), do: noun
  defp pluralize(_count, noun), do: noun <> "s"
end
