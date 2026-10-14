defmodule AlplusWeb.ProjectSignals do
  @moduledoc """
  Per-project pillar signals for the org project list and the project hub.

  The loader keeps the existing scalar values used by the console and adds a
  small read model for each pillar. A read model distinguishes `:available`,
  `:empty`, and `:unavailable`; a missing rollup is never rendered as zero.

  Trends use only durable rows already owned by the relevant project. Monitor
  and Measure use policy-scoped Ash reads. Observe uses a bounded daily event
  read with explicit project/Source pairs and repeats org membership checks in
  SQL because its raw event table has no Ash resource.

  Tenancy: `load/2` runs every read with a project-scoped actor, while
  `load_many/2` uses explicit project-id batch actions with an org-scoped
  actor. Those actions each enforce the current org, membership, and caller
  supplied project set; no batch read is an unbounded org health query.
  """

  require Ash.Query
  require Logger

  alias Alplus.Observe.Issue
  alias Alplus.Observe.Dashboard, as: ObserveDashboard

  @uptime_days 30
  @traffic_days 7
  @observe_trend_window "7d"

  # The Overview's time range (design source §04). `load/3` reads every pillar
  # over the same window so the page's chart, tiles and sentences describe one
  # period instead of three. `load_many/2` keeps the fixed index windows above:
  # the project list compares projects, and a per-project range there would
  # make its columns incomparable.
  @windows %{
    "24h" => %{days: 1, observe: "24h"},
    "7d" => %{days: 7, observe: "7d"},
    "30d" => %{days: 30, observe: "30d"}
  }
  @default_window "24h"

  @doc "The Overview's selectable ranges."
  def windows, do: Map.keys(@windows)

  @doc "The default Overview range."
  def default_window, do: @default_window

  @doc "The window's length in days, for a caller writing a label."
  def window_days(window), do: spec(window).days

  defp spec(window), do: Map.get(@windows, window, @windows[@default_window])

  @type state :: :available | :empty | :unavailable

  @type trend :: %{
          state: state(),
          points: [map()],
          unavailable?: boolean()
        }

  @type t :: %{
          monitors: map(),
          uptime: float() | nil,
          issues_open: non_neg_integer() | nil,
          pageviews: non_neg_integer() | nil,
          measure_installed?: boolean(),
          monitor: map(),
          observe: map(),
          measure: map(),
          monitor_trend: map(),
          observe_trend: map(),
          measure_trend: map()
        }

  @doc "The uptime window, in days, for labels."
  def uptime_days, do: @uptime_days

  @doc "The traffic window, in days, for labels."
  def traffic_days, do: @traffic_days

  @spec load(map(), Alplus.Scope.t(), String.t()) :: t()
  def load(project, scope, window \\ @default_window) do
    spec = spec(window)
    project_scope = Alplus.Scope.put_project(scope, project.id)
    monitor = load_monitor(project.id, project_scope, window)
    observe = load_observe(project.id, project_scope, spec.observe)
    measure = load_measure(project.id, project_scope, window)

    %{
      monitors: monitor.monitors,
      uptime: monitor.uptime,
      issues_open: observe.issues_open,
      pageviews: measure.pageviews,
      measure_installed?: measure.installed?,
      monitor: monitor,
      observe: observe,
      measure: measure,
      monitor_trend: monitor.trend,
      observe_trend: observe.trend,
      measure_trend: measure.trend
    }
  end

  @doc "Loads one signal map per project with fixed resource reads for one org."
  @spec load_many([map()], Alplus.Scope.t()) :: %{optional(String.t()) => t()}
  def load_many(projects, scope) when is_list(projects) do
    projects = Enum.filter(projects, &(&1.org_id == scope.org_id))
    project_ids = Enum.map(projects, & &1.id)

    if project_ids == [] do
      %{}
    else
      monitors = batch_monitors(project_ids, scope)
      monitor_rollups = batch_monitor_rollups(project_ids, scope)
      sources = batch_sources(project_ids, scope)
      issues = batch_open_issues(project_ids, scope)
      observe_trends = batch_observe_trends(sources, project_ids, scope)
      measure_days = batch_measure_days(sources, project_ids, scope)

      Map.new(projects, fn project ->
        monitor = build_batch_monitor(project.id, monitors, monitor_rollups)

        observe =
          build_batch_observe(
            project.id,
            sources,
            issues,
            observe_trends
          )

        measure = build_batch_measure(project.id, sources, measure_days)

        {project.id,
         %{
           monitors: monitor.monitors,
           uptime: monitor.uptime,
           issues_open: observe.issues_open,
           pageviews: measure.pageviews,
           measure_installed?: measure.installed?,
           monitor: monitor,
           observe: observe,
           measure: measure,
           monitor_trend: monitor.trend,
           observe_trend: observe.trend,
           measure_trend: measure.trend
         }}
      end)
    end
  end

  @doc "Returns an explicit unavailable signal when a batch read cannot produce a row."
  @spec unavailable() :: t()
  def unavailable do
    monitor = unavailable_monitor_signal()
    observe = unavailable_observe_signal()
    measure = unavailable_measure_signal()

    %{
      monitors: monitor.monitors,
      uptime: monitor.uptime,
      issues_open: observe.issues_open,
      pageviews: measure.pageviews,
      measure_installed?: measure.installed?,
      monitor: monitor,
      observe: observe,
      measure: measure,
      monitor_trend: monitor.trend,
      observe_trend: observe.trend,
      measure_trend: measure.trend
    }
  end

  # The project index is an org-scoped read model. Each action below has its
  # own explicit project-id filter and an org-membership policy; no action is
  # allowed to infer tenancy from a caller-provided list alone. Keeping the
  # batch boundary here means LiveViews only render already-grouped signals.
  defp batch_monitors(project_ids, scope) do
    batch_read(:monitors, scope, fn ->
      project_ids
      |> Alplus.Monitoring.list_monitors_for_projects!(actor: scope)
      |> Enum.group_by(& &1.project_id)
    end)
  end

  defp batch_monitor_rollups(project_ids, scope) do
    cutoff = Date.add(Date.utc_today(), -@uptime_days)

    batch_read(:monitor_rollups, scope, fn ->
      project_ids
      |> Alplus.Monitoring.list_daily_rollups_for_projects!(
        actor: scope,
        query: [filter: [day: [greater_than_or_equal: cutoff]]]
      )
      |> Enum.group_by(& &1.project_id)
    end)
  end

  defp batch_sources(project_ids, scope) do
    batch_read(:sources, scope, fn ->
      project_ids
      |> Alplus.Sources.list_sources_for_projects!(actor: scope)
      |> Enum.filter(&(&1.status == :active))
      |> Enum.group_by(& &1.project_id)
    end)
  end

  defp batch_open_issues(project_ids, scope) do
    batch_read(:observe_issues, scope, fn ->
      project_ids
      |> Alplus.Observe.list_issues_for_projects!(
        actor: scope,
        query: [filter: [status: :open]]
      )
      |> Enum.group_by(& &1.project_id)
    end)
  end

  defp batch_observe_trends({:error, _reason}, _project_ids, _scope), do: {:error, :unavailable}

  defp batch_observe_trends({:ok, sources_by_project}, project_ids, scope) do
    observe_sources =
      Map.new(project_ids, fn project_id ->
        {project_id,
         Enum.filter(Map.get(sources_by_project, project_id, []), &(&1.type == :observe))}
      end)

    if Enum.any?(observe_sources, fn {_project_id, sources} -> sources != [] end) do
      batch_read(:observe_trends, scope, fn ->
        ObserveDashboard.trends_for_projects(observe_sources, @observe_trend_window, scope)
      end)
    else
      {:ok, %{}}
    end
  end

  defp batch_measure_days({:error, _reason}, _project_ids, _scope), do: {:error, :unavailable}

  defp batch_measure_days({:ok, sources_by_project}, project_ids, scope) do
    measure_sources =
      sources_by_project
      |> Enum.into(%{}, fn {project_id, sources} ->
        {project_id, Enum.filter(sources, &(&1.type == :measure))}
      end)

    source_ids =
      measure_sources
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    if source_ids == [] do
      {:ok, %{}}
    else
      since = Date.add(Date.utc_today(), -(@traffic_days - 1))

      batch_read(:measure_rollups, scope, fn ->
        project_ids
        |> Alplus.Measure.list_days_for_projects!(
          source_ids,
          since,
          Date.add(Date.utc_today(), 1),
          actor: scope
        )
        |> Enum.group_by(& &1.project_id)
      end)
    end
  end

  defp build_batch_monitor(_project_id, {:error, _reason}, _rollups),
    do: unavailable_monitor_signal()

  defp build_batch_monitor(project_id, {:ok, monitors_by_project}, {:error, _reason}) do
    monitors = Map.get(monitors_by_project, project_id, [])

    if monitors == [] do
      empty_monitor_signal()
    else
      %{
        state: :available,
        unavailable?: false,
        monitors: monitor_counts(monitors),
        uptime: nil,
        trend: unavailable_trend()
      }
    end
  end

  defp build_batch_monitor(project_id, {:ok, monitors_by_project}, {:ok, rollups_by_project}) do
    monitors = Map.get(monitors_by_project, project_id, [])
    rollups = Map.get(rollups_by_project, project_id, [])
    {uptime, trend} = monitor_rollup_signal(rollups)

    state = if monitors == [], do: :empty, else: :available

    %{
      state: state,
      unavailable?: false,
      monitors: monitor_counts(monitors),
      uptime: uptime,
      trend: trend
    }
  end

  defp unavailable_monitor_signal do
    %{
      state: :unavailable,
      unavailable?: true,
      monitors: unavailable_monitor_counts(),
      uptime: nil,
      trend: unavailable_trend()
    }
  end

  defp empty_monitor_signal do
    %{
      state: :empty,
      unavailable?: false,
      monitors: monitor_counts([]),
      uptime: nil,
      trend: empty_trend()
    }
  end

  defp build_batch_observe(_project_id, _sources, {:error, _reason}, _trends),
    do: unavailable_observe_signal()

  defp build_batch_observe(_project_id, {:error, _reason}, _issues, _trends),
    do: unavailable_observe_signal()

  defp build_batch_observe(_project_id, _sources, _issues, {:error, _reason}),
    do: unavailable_observe_signal()

  defp build_batch_observe(
         project_id,
         {:ok, sources_by_project},
         {:ok, issues_by_project},
         {:ok, trends_by_project}
       ) do
    sources = Enum.filter(Map.get(sources_by_project, project_id, []), &(&1.type == :observe))
    issues = Map.get(issues_by_project, project_id, [])
    points = Map.get(trends_by_project, project_id, [])
    trend = observe_trend_signal(points)
    issues_open = length(issues)

    state =
      cond do
        sources == [] and issues_open == 0 -> :empty
        trend.state == :empty and issues_open == 0 -> :empty
        true -> :available
      end

    %{
      state: state,
      unavailable?: false,
      issues_open: issues_open,
      trend: trend,
      # The project index compares projects; it never draws a deploy-annotated
      # chart, so it does not pay for the release read `load/3` gets free.
      latest_release: nil,
      installed?: sources != []
    }
  end

  defp observe_trend_signal([]), do: empty_trend()

  defp observe_trend_signal(points) do
    if Enum.any?(points, &(&1.event_count > 0)),
      do: trend_from_points(points),
      else: empty_trend()
  end

  defp unavailable_observe_signal do
    %{
      state: :unavailable,
      unavailable?: true,
      issues_open: nil,
      trend: unavailable_trend(),
      latest_release: nil,
      installed?: false
    }
  end

  defp build_batch_measure(_project_id, {:error, _reason}, _days),
    do: unavailable_measure_signal()

  defp build_batch_measure(_project_id, _sources, {:error, _reason}),
    do: unavailable_measure_signal()

  defp build_batch_measure(project_id, {:ok, sources_by_project}, {:ok, days_by_project}) do
    sources = Enum.filter(Map.get(sources_by_project, project_id, []), &(&1.type == :measure))
    source_ids = MapSet.new(Enum.map(sources, & &1.id))

    rows =
      days_by_project
      |> Map.get(project_id, [])
      |> Enum.filter(&MapSet.member?(source_ids, &1.source_id))

    {pageviews, trend} = measure_rollup_signal(rows)
    state = if sources == [] or rows == [], do: :empty, else: :available

    %{
      state: state,
      unavailable?: false,
      installed?: sources != [],
      pageviews: pageviews,
      trend: trend
    }
  end

  defp unavailable_measure_signal do
    %{
      state: :unavailable,
      unavailable?: true,
      installed?: false,
      pageviews: nil,
      trend: unavailable_trend()
    }
  end

  defp batch_read(label, scope, fun) do
    {:ok, fun.()}
  rescue
    exception ->
      Logger.warning(
        "project signal batch unavailable",
        signal: label,
        org_id: scope.org_id,
        reason: Exception.message(exception)
      )

      {:error, :unavailable}
  catch
    kind, reason ->
      Logger.warning(
        "project signal batch unavailable",
        signal: label,
        org_id: scope.org_id,
        reason: inspect({kind, reason})
      )

      {:error, :unavailable}
  end

  @doc ~S(A "99.98%"-style label, or nil when no uptime evidence exists yet.)
  @spec uptime_label(float() | nil) :: String.t() | nil
  def uptime_label(nil), do: nil

  def uptime_label(ratio) do
    (ratio * 100)
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
    |> String.replace_suffix(".00", "")
    |> Kernel.<>("%")
  end

  defp load_monitor(project_id, scope, window) do
    monitor_result =
      read_signal(:monitors, project_id, fn ->
        Alplus.Monitoring.list_monitors_for_project!(project_id, actor: scope)
      end)

    rollup_result =
      read_signal(:monitor_rollups, project_id, fn ->
        cutoff = Date.add(Date.utc_today(), -spec(window).days)

        Alplus.Monitoring.list_daily_rollups!(
          actor: scope,
          query: [filter: [project_id: project_id, day: [greater_than_or_equal: cutoff]]]
        )
      end)

    timeline_result =
      read_signal(:monitor_timeline, project_id, fn ->
        Alplus.Monitoring.MonitorOverview.fleet_timeline!(project_id, scope, window)
      end)

    monitors =
      case monitor_result do
        {:ok, rows} -> rows |> monitor_counts() |> with_current_bucket(timeline_result)
        {:error, _reason} -> unavailable_monitor_counts()
      end

    uptime =
      case rollup_result do
        {:ok, rows} -> rows |> monitor_rollup_signal() |> elem(0)
        {:error, _reason} -> nil
      end

    trend =
      case timeline_result do
        {:ok, %{buckets: buckets}} ->
          %{
            state: if(buckets == [] or monitors.total == 0, do: :empty, else: :available),
            points: buckets,
            unavailable?: false
          }

        {:error, _reason} ->
          unavailable_trend()
      end

    state =
      cond do
        monitor_result == {:error, :unavailable} or timeline_result == {:error, :unavailable} ->
          :unavailable

        monitors.total == 0 ->
          :empty

        true ->
          :available
      end

    %{
      state: state,
      unavailable?: state == :unavailable,
      monitors: monitors,
      uptime: uptime,
      trend: trend
    }
  end

  defp monitor_counts(monitors) do
    %{
      total: length(monitors),
      up: Enum.count(monitors, &(&1.status == "active" and &1.last_known_status == "up")),
      down: Enum.count(monitors, &(&1.status == "active" and &1.last_known_status == "down")),
      degraded: 0,
      unknown: 0,
      unavailable?: false
    }
  end

  # The headline, the strip and the rows must agree, so the counts the page
  # states come from the same normalized bucket the strip draws last: the one
  # in progress. A monitor with no evidence in it is `unknown`, never up and
  # never down.
  defp with_current_bucket(counts, {:ok, %{buckets: buckets}}) when buckets != [] do
    current = List.last(buckets)

    %{
      counts
      | up: Map.get(current, :healthy, counts.up),
        down: Map.get(current, :down, counts.down),
        degraded: Map.get(current, :degraded, 0),
        unknown: Map.get(current, :unknown, 0)
    }
  end

  defp with_current_bucket(counts, _timeline_result), do: counts

  defp unavailable_monitor_counts do
    %{total: nil, up: nil, down: nil, degraded: nil, unknown: nil, unavailable?: true}
  end

  # Time-weighted across every monitor's finalized daily rollups: uptime is
  # (monitored - downtime) / monitored, never a check-row count.
  defp monitor_rollup_signal([]), do: {nil, empty_trend()}

  defp monitor_rollup_signal(rollups) do
    {daily, monitored, downtime} =
      Enum.reduce(rollups, {%{}, 0, 0}, fn rollup, {daily, monitored, downtime} ->
        day = rollup.day
        day_monitored = rollup.monitored_microseconds
        day_downtime = rollup.downtime_microseconds

        daily =
          Map.update(
            daily,
            day,
            %{monitored: day_monitored, downtime: day_downtime},
            &%{
              monitored: &1.monitored + day_monitored,
              downtime: &1.downtime + day_downtime
            }
          )

        {daily, monitored + day_monitored, downtime + day_downtime}
      end)

    points =
      daily
      |> Enum.sort_by(fn {day, _values} -> day end, {:asc, Date})
      |> Enum.flat_map(fn {day, %{monitored: day_monitored, downtime: day_downtime}} ->
        if day_monitored > 0 do
          ratio = (day_monitored - day_downtime) / day_monitored
          label = Date.to_iso8601(day)

          [
            %{
              id: "monitor-#{label}",
              label: label,
              bucket: day,
              value: ratio,
              ratio: ratio,
              # Bar height as a percentage of the plot. Without it every bar
              # fell back to the 2px minimum, so the console's primary chart
              # drew a flat line whatever the uptime was. The 4% floor keeps a
              # fully-down day visible as a red tick rather than as nothing.
              height: max(ratio * 100, 4),
              tone: if(ratio == 0, do: :down, else: :up),
              tooltip: "#{label}: #{uptime_label(ratio)} uptime",
              aria_label: "#{label}, #{uptime_label(ratio)} uptime",
              table_cells: [label, "#{uptime_label(ratio)} uptime"]
            }
          ]
        else
          []
        end
      end)

    uptime = if monitored > 0, do: (monitored - downtime) / monitored
    {uptime, trend_from_points(points)}
  end

  defp load_observe(project_id, scope, observe_window) do
    issue_result =
      read_signal(:observe_issues, project_id, fn -> open_issue_count(project_id, scope) end)

    source_result =
      read_signal(:observe_sources, project_id, fn ->
        Alplus.Sources.list_sources_for_project!(project_id, actor: scope)
        |> Enum.filter(&(&1.type == :observe and &1.status == :active))
      end)

    summary_result =
      case source_result do
        {:ok, []} ->
          {:ok, %{}}

        {:ok, sources} ->
          read_signal(:observe_trend, project_id, fn ->
            ObserveDashboard.summaries(sources, observe_window, scope)
          end)

        {:error, _reason} ->
          {:error, :unavailable}
      end

    trend_result =
      case summary_result do
        {:ok, summaries} -> {:ok, aggregate_observe_points(summaries)}
        {:error, reason} -> {:error, reason}
      end

    issues_open = if_match(issue_result, 0)

    trend =
      case trend_result do
        {:ok, points} when points == [] ->
          empty_trend()

        {:ok, points} ->
          if Enum.any?(points, &(&1.event_count > 0)),
            do: trend_from_points(points),
            else: empty_trend()

        {:error, _reason} ->
          unavailable_trend()
      end

    state =
      cond do
        issue_result == {:error, :unavailable} or source_result == {:error, :unavailable} ->
          :unavailable

        source_result == {:ok, []} and issues_open == 0 ->
          :empty

        true ->
          :available
      end

    %{
      state: state,
      unavailable?: state == :unavailable,
      issues_open: issues_open,
      trend: trend,
      # The most recent release seen in this window, for the Overview chart's
      # deploy marker. It rides on the summaries read above, so annotating the
      # chart costs no extra query. `nil` means no release is recorded, and the
      # chart then draws no marker rather than an invented one.
      latest_release: latest_release(summary_result),
      installed?:
        case source_result do
          {:ok, sources} -> sources != []
          {:error, _reason} -> false
        end
    }
  end

  defp latest_release({:ok, summaries}) when is_map(summaries) do
    summaries
    |> Map.values()
    |> Enum.flat_map(&Map.get(&1, :release_markers, []))
    |> Enum.reject(&is_nil(Map.get(&1, :released_at)))
    |> Enum.max_by(& &1.released_at, DateTime, fn -> nil end)
  end

  defp latest_release(_result), do: nil

  defp aggregate_observe_points(summaries) do
    summaries
    |> Map.values()
    |> Enum.flat_map(& &1.trend)
    |> Enum.group_by(& &1.bucket)
    |> Enum.map(fn {bucket, points} ->
      event_count = Enum.sum(Enum.map(points, & &1.event_count))
      label = ObserveDashboard.bucket_label(bucket)

      %{
        id: "observe-#{label}",
        label: label,
        bucket: bucket,
        value: event_count,
        event_count: event_count,
        tone: if(event_count > 0, do: :error, else: :neutral),
        tooltip: "#{label}: #{event_count} errors",
        aria_label: "#{label}, #{event_count} errors",
        table_cells: [label, "#{event_count} errors"]
      }
    end)
    |> Enum.sort_by(&DateTime.to_unix(ObserveDashboard.bucket_start(&1.bucket)))
  end

  defp open_issue_count(project_id, scope) do
    Issue
    |> Ash.Query.for_read(:list_for_project, %{project_id: project_id}, actor: scope)
    |> Ash.Query.filter(status == :open)
    |> Ash.count!(actor: scope)
  end

  defp load_measure(project_id, scope, window) do
    source_result =
      read_signal(:measure_sources, project_id, fn ->
        Alplus.Sources.list_sources_for_project!(project_id, actor: scope)
        |> Enum.filter(&(&1.type == :measure and &1.status == :active))
      end)

    portfolio_result =
      case source_result do
        {:ok, []} ->
          {:ok, nil}

        {:ok, sources} ->
          read_signal(:measure_portfolio, project_id, fn ->
            Alplus.Measure.Dashboard.portfolio(sources, window, scope)
          end)

        {:error, _reason} ->
          {:error, :unavailable}
      end

    sources = if_match(source_result, [])
    portfolio = if_match(portfolio_result, nil)

    pageviews =
      portfolio
      |> case do
        nil -> nil
        value -> get_in(value, [:totals, :pageviews, :value])
      end

    trend =
      case portfolio_result do
        {:ok, nil} ->
          empty_trend()

        {:ok, value} ->
          %{
            state: if(value.trend == [], do: :empty, else: :available),
            points: value.trend,
            unavailable?: value.unavailable?
          }

        {:error, _reason} ->
          unavailable_trend()
      end

    state =
      cond do
        source_result == {:error, :unavailable} or portfolio_result == {:error, :unavailable} ->
          :unavailable

        sources == [] ->
          :empty

        true ->
          :available
      end

    %{
      state: state,
      unavailable?: state == :unavailable,
      installed?: sources != [],
      pageviews: pageviews,
      coverage: portfolio && Map.get(portfolio, :coverage),
      trend: trend
    }
  end

  defp measure_rollup_signal([]), do: {nil, empty_trend()}

  defp measure_rollup_signal(rows) do
    daily =
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(acc, row.date, row.pageviews, &(&1 + row.pageviews))
      end)

    points =
      daily
      |> Enum.sort_by(fn {date, _count} -> date end, {:asc, Date})
      |> Enum.map(fn {date, count} ->
        label = Date.to_iso8601(date)

        %{
          id: "measure-#{label}",
          label: label,
          bucket: date,
          value: count,
          pageviews: count,
          tone: if(count > 0, do: :live, else: :neutral),
          tooltip: "#{label}: #{count} pageviews",
          aria_label: "#{label}, #{count} pageviews",
          table_cells: [label, "#{count} pageviews"]
        }
      end)

    {Enum.sum(Enum.map(rows, & &1.pageviews)), trend_from_points(points)}
  end

  defp if_match({:ok, value}, _default), do: value
  defp if_match({:error, :unavailable}, _default), do: nil

  defp read_signal(label, project_id, fun) do
    {:ok, fun.()}
  rescue
    exception ->
      Logger.warning(
        "project signal unavailable",
        signal: label,
        project_id: project_id,
        reason: Exception.message(exception)
      )

      {:error, :unavailable}
  catch
    kind, reason ->
      Logger.warning(
        "project signal unavailable",
        signal: label,
        project_id: project_id,
        reason: inspect({kind, reason})
      )

      {:error, :unavailable}
  end

  defp trend_from_points([]), do: empty_trend()

  defp trend_from_points(points),
    do: %{state: :available, points: points, unavailable?: false}

  defp empty_trend, do: %{state: :empty, points: [], unavailable?: false}
  defp unavailable_trend, do: %{state: :unavailable, points: [], unavailable?: true}
end
