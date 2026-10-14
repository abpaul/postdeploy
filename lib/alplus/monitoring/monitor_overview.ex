defmodule Alplus.Monitoring.MonitorOverview do
  @moduledoc """
  Project-scoped read model for the Monitor activity workspace.

  The boundary keeps fleet counts independent from collection filters, pages the
  collection in the database, and enriches only the visible page (each row gets
  its own activity window). Every read runs through Ash policies with the
  project-scoped actor.
  """

  alias Alplus.Monitoring.{
    DailyRollup,
    Incident,
    Monitor,
    MonitorCheck,
    MonitorDisplay,
    PauseInterval,
    Uptime,
    UptimeTracer
  }

  alias Alplus.Repo

  require Ash.Query

  @page_size 20
  @sample_limit 120

  defstruct [
    :rows,
    :filtered_total,
    :health,
    :incidents,
    :environments,
    :activities,
    :next_cursor
  ]

  defmodule Row do
    @moduledoc false

    @type state :: :up | :down | :degraded | :late | :waiting | :missing | :paused

    defstruct [
      :monitor,
      :config,
      :latest_check,
      :open_incident,
      :target,
      :interval_seconds,
      :state
    ]

    @type t :: %__MODULE__{
            monitor: Monitor.t(),
            config: struct() | nil,
            latest_check: MonitorCheck.t() | nil,
            open_incident: Incident.t() | nil,
            target: String.t() | nil,
            interval_seconds: pos_integer() | nil,
            state: :up | :down | :degraded | :late | :waiting | :missing | :paused
          }
  end

  defmodule Activity do
    @moduledoc false
    defstruct [
      :row,
      :checks,
      :check_count,
      :incidents,
      :incident_count,
      :pauses,
      :rollups,
      :evidence_start,
      :window_start,
      :window_end,
      :uptime,
      :uptime_trace,
      :state
    ]

    @type t :: %__MODULE__{
            row: Alplus.Monitoring.MonitorOverview.Row.t(),
            checks: [MonitorCheck.t()],
            check_count: non_neg_integer(),
            incidents: [Incident.t()],
            incident_count: non_neg_integer(),
            pauses: [PauseInterval.t()],
            rollups: [DailyRollup.t()],
            evidence_start: DateTime.t() | nil,
            window_start: DateTime.t(),
            window_end: DateTime.t(),
            uptime: float() | nil,
            uptime_trace: UptimeTracer.t(),
            state: Row.state()
          }
  end

  @spec load!(map(), map(), map()) :: %__MODULE__{}
  def load!(project, scope, filters) do
    health_query = fleet_query(project.id, filters, scope)
    environments = environments!(project.id, scope)
    health = health!(health_query, scope)
    incidents = recent_incidents!(project.id, filters.environment, scope)

    target_ids = search_target_ids!(project.id, filters.query, scope)
    state_ids = state_filter_ids!(project.id, filters, scope)

    collection_query =
      project.id
      |> collection_query(filters, target_ids, state_ids, scope)
      # Newest-created first, stable — monitors must not reorder as their status
      # updates (was attention_priority-sorted, which shuffled the page live).
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.page(page_options(filters.cursor))

    page = Ash.read!(collection_query, actor: scope)
    rows = enrich_rows!(page.results, scope)

    # Batched: one read per activity data type for the whole page (sampled
    # checks, bounded database-side uptime evidence, incidents, pauses,
    # rollups), grouped by monitor_id. Raw uptime checks never enter BEAM.
    activities = activities!(rows, filters.window, scope)

    %__MODULE__{
      rows: rows,
      filtered_total: page.count,
      health: health,
      incidents: incidents,
      environments: environments,
      activities: activities,
      next_cursor:
        if(page.more?,
          do: page.results |> List.last() |> Ash.Resource.get_metadata(:keyset)
        )
    }
  end

  @doc """
  The same `Row`/`Activity` shape as `load!/3`'s batched page, for a single
  already-fetched, already-scoped monitor (the detail page). Reuses
  `enrich_rows!/2` and `activities!/3` directly rather than hand-rolling a
  parallel single-monitor query path.
  """
  @spec activity_for(Monitor.t(), map(), String.t()) :: {Row.t(), Activity.t()}
  def activity_for(monitor, scope, window) do
    [row] = enrich_rows!([monitor], scope)
    activities = activities!([row], window, scope)
    {row, Map.fetch!(activities, row.monitor.id)}
  end

  @doc """
  Builds the exact fleet timeline used by Overview.

  Aggregation stays in the read model. Components receive display-ready
  buckets and only own wording and presentation.
  """
  @spec fleet_timeline!(String.t(), map(), String.t(), keyword()) :: map()
  def fleet_timeline!(project_id, scope, window, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    monitors =
      Monitor
      |> Ash.Query.for_read(:list_for_project, %{project_id: project_id}, actor: scope)
      |> Ash.Query.filter(org_id == ^scope.org_id and project_id == ^project_id)
      |> Ash.read!(actor: scope)

    rows = enrich_rows!(monitors, scope)
    activities = activities!(rows, window, scope, now)
    {start_at, end_at, interval, expected_count} = UptimeTracer.timeline_bounds(window, now)

    buckets =
      start_at
      |> timeline_starts(end_at, interval)
      |> Enum.with_index()
      |> Enum.map(fn {bucket_start, index} ->
        bucket_end = DateTime.add(bucket_start, interval, :second)
        current? = index == expected_count - 1

        evidence =
          rows
          |> Enum.filter(&monitor_active_before?(&1.monitor, bucket_end))
          |> Enum.map(fn row ->
            activity = Map.fetch!(activities, row.monitor.id)
            {Enum.at(activity.uptime_trace.buckets, index), activity.state}
          end)

        fleet_bucket(bucket_start, bucket_end, evidence, current?)
      end)

    %{
      buckets: buckets,
      range: window,
      state: if(buckets == [], do: :empty, else: :ready),
      bucket_count: length(buckets)
    }
  end

  defp timeline_starts(start_at, end_at, interval) do
    Stream.iterate(start_at, &DateTime.add(&1, interval, :second))
    |> Enum.take_while(&(DateTime.compare(&1, end_at) == :lt))
  end

  defp monitor_active_before?(%{inserted_at: %DateTime{} = inserted_at}, bucket_end),
    do: DateTime.compare(inserted_at, bucket_end) == :lt

  defp monitor_active_before?(_monitor, _bucket_end), do: true

  defp fleet_bucket(start_at, end_at, evidence, current?) do
    counts =
      Enum.reduce(evidence, %{healthy: 0, down: 0, degraded: 0, unknown: 0}, fn
        {%{state: :down}, _current_state}, acc ->
          Map.update!(acc, :down, &(&1 + 1))

        {_bucket, :down}, acc when current? ->
          Map.update!(acc, :down, &(&1 + 1))

        {%{state: state}, _current_state}, acc when state in [:slow, :anomaly] ->
          Map.update!(acc, :degraded, &(&1 + 1))

        {_bucket, state}, acc when current? and state in [:degraded, :late] ->
          Map.update!(acc, :degraded, &(&1 + 1))

        {%{state: state}, _current_state}, acc when state in [:missing, :partial] ->
          Map.update!(acc, :unknown, &(&1 + 1))

        {%{state: :up}, _current_state}, acc ->
          Map.update!(acc, :healthy, &(&1 + 1))

        {_bucket, _current_state}, acc ->
          Map.update!(acc, :unknown, &(&1 + 1))
      end)

    monitor_count = length(evidence)
    missing_checks = Enum.sum(Enum.map(evidence, &fleet_missing_checks/1))

    # The bucket's own word is its worst observed state; the strip draws the
    # ratio behind it, so one down monitor beside three healthy ones reads as
    # a quarter red, never as a whole red hour.
    state =
      cond do
        counts.down > 0 -> :down
        counts.degraded > 0 -> :degraded
        counts.healthy > 0 -> :healthy
        true -> :unknown
      end

    segments =
      [
        %{tone: "live", ratio: ratio(counts.healthy, monitor_count)},
        %{tone: "late", ratio: ratio(counts.degraded, monitor_count)},
        %{tone: "error", ratio: ratio(counts.down, monitor_count)},
        %{tone: "neutral", ratio: ratio(counts.unknown, monitor_count)}
      ]
      |> Enum.reject(&(&1.ratio == 0))

    %{
      id: Integer.to_string(DateTime.to_unix(start_at)),
      start_at: start_at,
      end_at: end_at,
      state: state,
      tone: fleet_tone(state),
      segments: segments,
      in_progress?: current?,
      monitor_count: monitor_count,
      healthy: counts.healthy,
      down: counts.down,
      degraded: counts.degraded,
      unknown: counts.unknown,
      missing_checks: missing_checks,
      current?: current?,
      table_cells: [
        DateTime.to_iso8601(start_at),
        Integer.to_string(monitor_count),
        Integer.to_string(counts.healthy),
        Integer.to_string(counts.down),
        Integer.to_string(counts.degraded),
        Integer.to_string(counts.unknown)
      ]
    }
  end

  defp fleet_missing_checks({%{missing_interval_count: count}, _state}) when is_integer(count),
    do: count

  defp fleet_missing_checks({_bucket, _state}), do: 1

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, whole), do: part / whole

  defp fleet_tone(:down), do: "error"
  defp fleet_tone(:degraded), do: "late"
  defp fleet_tone(:healthy), do: "live"
  defp fleet_tone(:unknown), do: "neutral"

  defp page_options(nil), do: [limit: @page_size, count: true]
  defp page_options(cursor), do: [limit: @page_size, after: cursor, count: true]

  defp fleet_query(project_id, filters, scope) do
    Monitor
    |> Ash.Query.for_read(:list_for_project, %{project_id: project_id}, actor: scope)
    |> Ash.Query.filter(org_id == ^scope.org_id and project_id == ^project_id)
    |> maybe_environment(filters.environment)
  end

  defp collection_query(project_id, filters, target_ids, state_ids, scope) do
    project_id
    |> fleet_query(filters, scope)
    |> maybe_type(filters.type)
    |> maybe_search(filters.query, target_ids)
    |> maybe_status(filters.status, state_ids)
    |> maybe_view(Map.get(filters, :view), state_ids)
  end

  defp maybe_environment(query, nil), do: query

  defp maybe_environment(query, environment),
    do: Ash.Query.filter(query, environment == ^environment)

  defp maybe_type(query, nil), do: query
  defp maybe_type(query, type), do: Ash.Query.filter(query, type == ^type)

  defp maybe_status(query, nil, _state_ids), do: query
  defp maybe_status(query, "active", _state_ids), do: Ash.Query.filter(query, status == "active")

  defp maybe_status(query, status, state_ids)
       when status in ["up", "down", "degraded", "late", "missing", "waiting", "paused"],
       do: Ash.Query.filter(query, id in ^state_ids)

  defp maybe_view(query, view, _state_ids) when view in [nil, "all"], do: query
  defp maybe_view(query, "incidents", _state_ids), do: Ash.Query.filter(query, false)

  defp maybe_view(query, view, state_ids) when view in ["attention", "healthy"],
    do: Ash.Query.filter(query, id in ^state_ids)

  defp maybe_search(query, nil, _target_ids), do: query

  defp maybe_search(query, term, target_ids) do
    downcased = String.downcase(term)
    Ash.Query.filter(query, contains(string_downcase(name), ^downcased) or id in ^target_ids)
  end

  defp health!(query, scope) do
    monitors =
      query
      |> Ash.Query.select([:type, :status, :last_known_status, :last_check_at])
      |> Ash.read!(actor: scope)
      |> Ash.load!([:http_config, :heartbeat_config, :tcp_config, :dns_config, :latest_check],
        actor: scope
      )

    fleet_health(monitors)
  end

  defp state_filter_ids!(project_id, filters, scope) do
    wanted_states =
      cond do
        filters.status in ["up", "down", "degraded", "late", "missing", "waiting", "paused"] ->
          [state_filter_state(filters.status)]

        Map.get(filters, :view) == "attention" ->
          [:down, :degraded, :late, :missing]

        Map.get(filters, :view) == "healthy" ->
          [:up]

        Map.get(filters, :view) == "incidents" ->
          []

        true ->
          nil
      end

    if is_nil(wanted_states) do
      nil
    else
      now = DateTime.utc_now()

      project_id
      |> fleet_query(filters, scope)
      |> Ash.Query.select([:type, :status, :last_known_status, :last_check_at])
      |> Ash.read!(actor: scope)
      |> Ash.load!([:http_config, :heartbeat_config, :tcp_config, :dns_config, :latest_check],
        actor: scope
      )
      |> Enum.filter(fn monitor ->
        state(
          monitor,
          present(monitor.latest_check),
          interval(config_for(monitor)),
          0,
          now
        ) in wanted_states
      end)
      |> Enum.map(& &1.id)
    end
  end

  defp state_filter_state("up"), do: :up
  defp state_filter_state("down"), do: :down
  defp state_filter_state("degraded"), do: :degraded
  defp state_filter_state("late"), do: :late
  defp state_filter_state("missing"), do: :missing
  defp state_filter_state("waiting"), do: :waiting
  defp state_filter_state("paused"), do: :paused

  @doc """
  Fleet health counts from already-loaded monitors. Shared by `load!/3`'s
  health read and surfaces that hold the full monitor list anyway (the
  status pages index), so the two can never disagree.
  """
  @spec fleet_health([Monitor.t()], DateTime.t()) :: map()
  def fleet_health(monitors, now \\ DateTime.utc_now()) do
    active = Enum.count(monitors, &(&1.status == "active"))
    paused = Enum.count(monitors, &(&1.status == "paused"))

    states =
      Enum.map(monitors, fn monitor ->
        state(
          monitor,
          present(monitor.latest_check),
          interval(config_for(monitor)),
          0,
          now
        )
      end)

    # Heartbeats are counted separately as well as inside the fleet totals.
    # Uptime checks and heartbeats share one screen, so the screen has to keep
    # answering "are my scheduled jobs still pinging?" without a second page.
    heartbeat_states =
      monitors
      |> Enum.zip(states)
      |> Enum.filter(fn {monitor, _state} -> monitor.type == "heartbeat" end)
      |> Enum.map(fn {_monitor, state} -> state end)

    state_counts = Enum.frequencies(states)
    down = Map.get(state_counts, :down, 0)
    degraded = Map.get(state_counts, :degraded, 0)
    waiting = Map.get(state_counts, :waiting, 0)
    late = Map.get(state_counts, :late, 0)
    missing = Map.get(state_counts, :missing, 0)

    latest_check_at =
      monitors
      |> Enum.map(&monitor_evidence_at/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    %{
      total: active + paused,
      active: active,
      down: down,
      degraded: degraded,
      paused: paused,
      waiting: waiting,
      late: late,
      missing: missing,
      late_or_waiting: late + waiting + missing,
      operational: Map.get(state_counts, :up, 0),
      heartbeat_total: length(heartbeat_states),
      heartbeat_on_time: Enum.count(heartbeat_states, &(&1 == :up)),
      heartbeat_late: Enum.count(heartbeat_states, &(&1 in [:late, :down, :degraded, :missing])),
      latest_check_at: latest_check_at
    }
  end

  @doc "Builds fleet health from a bounded projection without exposing monitor rows."
  @spec fleet_health_for_project(Alplus.Scope.t()) :: map()
  def fleet_health_for_project(%Alplus.Scope{} = scope) do
    monitors =
      Monitor
      |> Ash.Query.for_read(:list_for_project, %{project_id: scope.project_id}, actor: scope)
      |> Ash.Query.select([:id, :type, :status, :last_known_status, :last_check_at])
      |> Ash.Query.load([
        :latest_check,
        :http_config,
        :heartbeat_config,
        :tcp_config,
        :dns_config
      ])
      |> Ash.read!(actor: scope)

    fleet_health(monitors)
  end

  defp environments!(project_id, scope) do
    Monitor
    |> Ash.Query.for_read(:list_for_project, %{project_id: project_id}, actor: scope)
    |> Ash.Query.filter(
      org_id == ^scope.org_id and project_id == ^project_id and not is_nil(environment)
    )
    |> Ash.Query.select([:environment])
    |> Ash.Query.distinct(:environment)
    |> Ash.Query.sort(environment: :asc)
    |> Ash.read!(actor: scope)
    |> Enum.map(& &1.environment)
  end

  defp recent_incidents!(project_id, environment, scope) do
    base =
      Incident
      |> Ash.Query.filter(org_id == ^scope.org_id and project_id == ^project_id)
      |> maybe_incident_environment(environment)

    open =
      base
      |> Ash.Query.filter(status == :open)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(20)
      |> Ash.read!(actor: scope)

    resolved =
      base
      |> Ash.Query.filter(status != :open)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(20)
      |> Ash.read!(actor: scope)

    (open ++ resolved)
    |> Enum.take(20)
    |> attach_incident_monitors!(project_id, scope)
  end

  # Attaches each open incident's affected monitor (name, type, target) in one
  # batched read keyed by `monitor_id`, instead of a query per incident row.
  # The monitor load is re-scoped by `project_id` (not just trusted off the
  # incident row) so a cross-tenant `monitor_id` can never surface here.
  defp attach_incident_monitors!([], _project_id, _scope), do: []

  defp attach_incident_monitors!(incidents, project_id, scope) do
    monitor_ids = incidents |> Enum.map(& &1.monitor_id) |> Enum.uniq()

    monitors_by_id =
      Monitor
      |> Ash.Query.filter(
        id in ^monitor_ids and org_id == ^scope.org_id and project_id == ^project_id
      )
      |> Ash.read!(actor: scope)
      |> Ash.load!([:http_config, :heartbeat_config, :tcp_config, :dns_config, :latest_check],
        actor: scope
      )
      |> Map.new(&{&1.id, &1})

    Enum.map(incidents, fn incident ->
      monitor = Map.get(monitors_by_id, incident.monitor_id)
      target = monitor && target(monitor.type, config_for(monitor))

      incident
      |> Map.put(:monitor, monitor)
      |> Map.put(:target, target)
      |> Map.put(
        :monitor_state,
        if(monitor,
          do: state(monitor, present(monitor.latest_check), interval(config_for(monitor)), 0),
          else: nil
        )
      )
    end)
  end

  defp maybe_incident_environment(query, nil), do: query

  defp maybe_incident_environment(query, environment),
    do: Ash.Query.filter(query, environment == ^environment)

  defp search_target_ids!(_project_id, nil, _scope), do: []

  defp search_target_ids!(project_id, term, scope) do
    downcased = String.downcase(term)

    http_ids =
      Alplus.Monitoring.HttpConfig
      |> Ash.Query.filter(
        contains(string_downcase(url), ^downcased) and
          org_id == ^scope.org_id and monitor.project_id == ^project_id
      )
      |> Ash.Query.select([:monitor_id])
      |> Ash.read!(actor: scope)
      |> Enum.map(& &1.monitor_id)

    tcp_ids =
      Alplus.Monitoring.TcpConfig
      |> Ash.Query.filter(
        contains(string_downcase(hostname), ^downcased) and
          org_id == ^scope.org_id and monitor.project_id == ^project_id
      )
      |> Ash.Query.select([:monitor_id])
      |> Ash.read!(actor: scope)
      |> Enum.map(& &1.monitor_id)

    dns_ids =
      Alplus.Monitoring.DnsConfig
      |> Ash.Query.filter(
        contains(string_downcase(hostname), ^downcased) and
          org_id == ^scope.org_id and monitor.project_id == ^project_id
      )
      |> Ash.Query.select([:monitor_id])
      |> Ash.read!(actor: scope)
      |> Enum.map(& &1.monitor_id)

    Enum.uniq(http_ids ++ tcp_ids ++ dns_ids)
  end

  defp enrich_rows!([], _scope), do: []

  defp enrich_rows!(monitors, scope) do
    monitors
    |> Ash.load!(
      [:http_config, :heartbeat_config, :tcp_config, :dns_config, :latest_check, :open_incident],
      actor: scope
    )
    |> Enum.map(&row/1)
  end

  defp row(monitor) do
    config = config_for(monitor)
    latest_check = present(monitor.latest_check)

    %Row{
      monitor: monitor,
      config: config,
      latest_check: latest_check,
      open_incident: present(monitor.open_incident),
      target: target(monitor.type, config),
      interval_seconds: interval(config),
      state: state(monitor, latest_check, interval(config), 0)
    }
  end

  @doc "Classifies one monitor for fleet rows and incident surfaces."
  @spec state(
          Monitor.t(),
          MonitorCheck.t() | nil,
          pos_integer() | nil,
          non_neg_integer(),
          DateTime.t()
        ) ::
          Row.state()
  def state(monitor, latest_check, interval_seconds, check_count, now \\ DateTime.utc_now()) do
    current_state(monitor, latest_check, interval_seconds, check_count, now)
  end

  # Batches the whole page's activity into a small fixed number of reads
  # instead of ~5 per row, by filtering `monitor_id in ^ids` (or, for the
  # count/evidence aggregates, `id in ^ids` via the `checks` relationship)
  # for the page's shared window.
  #
  # check_count and evidence_start are exact grouped SQL aggregates (COUNT,
  # MIN), not an in-memory fold over a fetched row set: Monitor.checks (added
  # alongside this) lets `Ash.Query.aggregate/4` run a `:count` and a `:min`
  # per monitor, each scoped to the window via its own `query:` base -
  # bounded to one row of output per monitor regardless of how many checks
  # exist in the window.
  #
  # The `checks` samples (for the sparkline) cannot use the same aggregate
  # path: Ash explicitly rejects a `:limit` on an aggregate's base query
  # ("Cannot set limit on aggregate query"), so the sampled chart read stays
  # bounded. Uptime buckets use a parameterized PostgreSQL aggregate that
  # groups each monitor's base interval into at most 1,440 display buckets.
  # The tracer receives counts and state signals, never an unbounded raw read.
  defp activities!(rows, window, scope),
    do: activities!(rows, window, scope, DateTime.utc_now())

  defp activities!([], _window, _scope, _now), do: %{}

  defp activities!(rows, window, scope, now) do
    ids = Enum.map(rows, & &1.monitor.id)
    [first_row | _] = rows
    org_id = first_row.monitor.org_id
    project_id = first_row.monitor.project_id

    {window_start, window_end, display_interval, _bucket_count} =
      UptimeTracer.timeline_bounds(window, now)

    checks_window_query =
      Ash.Query.filter(
        MonitorCheck,
        org_id == ^org_id and project_id == ^project_id and
          checked_at >= ^window_start and checked_at < ^window_end
      )

    monitor_aggregates =
      Monitor
      |> Ash.Query.filter(id in ^ids and org_id == ^org_id and project_id == ^project_id)
      |> Ash.Query.aggregate(:window_check_count, :count, :checks, query: checks_window_query)
      |> Ash.Query.aggregate(:window_evidence_start, :min, :checks,
        field: :checked_at,
        query: checks_window_query
      )
      |> Ash.read!(actor: scope)
      |> Map.new(&{&1.id, &1})

    sample_ids = sample_check_ids!(org_id, project_id, ids, window_start, window_end, scope)

    checks_by_monitor =
      if sample_ids == [] do
        %{}
      else
        MonitorCheck
        |> Ash.Query.filter(
          org_id == ^org_id and project_id == ^project_id and monitor_id in ^ids and
            id in ^sample_ids
        )
        |> Ash.Query.sort(checked_at: :desc)
        |> Ash.read!(actor: scope)
        |> Enum.group_by(& &1.monitor_id)
        |> Map.new(fn {monitor_id, checks} -> {monitor_id, Enum.take(checks, @sample_limit)} end)
      end

    monitor_intervals =
      rows
      |> Enum.map(fn row ->
        {row.monitor.id, row.interval_seconds, display_interval}
      end)
      |> Enum.reject(fn {_monitor_id, base_interval, _display_interval} ->
        is_nil(base_interval)
      end)

    intervals_by_monitor =
      Map.new(monitor_intervals, fn {monitor_id, base_interval, display_interval} ->
        {monitor_id,
         %{base_interval_seconds: base_interval, display_interval_seconds: display_interval}}
      end)

    uptime_buckets_by_monitor =
      UptimeTracer.aggregate_checks!(
        org_id,
        project_id,
        monitor_intervals,
        window_start,
        window_end,
        scope
      )

    incidents_by_monitor =
      Incident
      |> Ash.Query.filter(
        org_id == ^org_id and project_id == ^project_id and monitor_id in ^ids and
          started_at < ^window_end and
          (is_nil(resolved_at) or resolved_at > ^window_start)
      )
      |> Ash.Query.sort(started_at: :asc)
      |> Ash.read!(actor: scope)
      |> Enum.group_by(& &1.monitor_id)

    pauses_by_monitor =
      PauseInterval
      |> Ash.Query.filter(
        org_id == ^org_id and project_id == ^project_id and monitor_id in ^ids and
          paused_at < ^window_end and
          (is_nil(resumed_at) or resumed_at > ^window_start)
      )
      |> Ash.Query.sort(paused_at: :asc)
      |> Ash.read!(actor: scope)
      |> Enum.group_by(& &1.monitor_id)

    rollups_by_monitor =
      DailyRollup
      |> Ash.Query.filter(
        org_id == ^org_id and project_id == ^project_id and monitor_id in ^ids and
          day >= ^DateTime.to_date(window_start) and
          day <= ^DateTime.to_date(window_end)
      )
      |> Ash.Query.sort(day: :asc)
      |> Ash.read!(actor: scope)
      |> Enum.group_by(& &1.monitor_id)

    Map.new(rows, fn row ->
      id = row.monitor.id

      checks = Map.get(checks_by_monitor, id, [])
      uptime_evidence = Map.get(uptime_buckets_by_monitor, id, [])
      interval_metadata = Map.get(intervals_by_monitor, id, %{})
      incidents = Map.get(incidents_by_monitor, id, [])
      pauses = Map.get(pauses_by_monitor, id, [])
      rollups = Map.get(rollups_by_monitor, id, [])
      # A monitor deleted after the page read its row has no aggregate row.
      aggregates =
        case monitor_aggregates do
          %{^id => %{aggregates: aggregates}} -> aggregates
          _ -> %{window_check_count: 0, window_evidence_start: nil}
        end

      check_count = aggregates.window_check_count
      evidence_start = aggregates.window_evidence_start

      uptime =
        if is_nil(evidence_start) do
          nil
        else
          Uptime.calculate(
            max_datetime(evidence_start, window_start),
            window_end,
            incidents,
            Enum.map(pauses, &%{started_at: &1.paused_at, resolved_at: &1.resumed_at})
          )
        end

      # A missing ping is the failure only for a heartbeat: for every other
      # kind a bucket with no checks is no data, never downtime.
      uptime_trace =
        UptimeTracer.trace(
          [],
          window_start,
          window_end,
          Map.get(interval_metadata, :display_interval_seconds),
          incidents: incidents,
          pauses: pauses,
          bucket_evidence: uptime_evidence,
          base_interval_seconds: Map.get(interval_metadata, :base_interval_seconds),
          scope: %{org_id: org_id, project_id: project_id, monitor_id: id},
          now: now,
          missing_is_failure: row.monitor.type == "heartbeat"
        )

      state =
        current_state(
          row.monitor,
          row.latest_check,
          row.interval_seconds,
          check_count,
          window_end
        )

      row = %{row | state: state}

      {id,
       %Activity{
         row: row,
         checks: checks,
         check_count: check_count,
         incidents: incidents,
         incident_count: length(incidents),
         pauses: pauses,
         rollups: rollups,
         evidence_start: evidence_start,
         window_start: window_start,
         window_end: window_end,
         uptime: uptime,
         uptime_trace: uptime_trace,
         state: state
       }}
    end)
  end

  defp config_for(%Monitor{type: type} = monitor) when type in ["http", "keyword"],
    do: present(monitor.http_config)

  defp config_for(%Monitor{type: "heartbeat"} = monitor), do: present(monitor.heartbeat_config)
  defp config_for(%Monitor{type: "tcp"} = monitor), do: present(monitor.tcp_config)
  defp config_for(%Monitor{type: "dns"} = monitor), do: present(monitor.dns_config)

  # Ash does not expose a per-group limit for a relationship aggregate. This
  # bounded window-function read gives every visible monitor up to the same
  # sample cap, then Ash re-reads those ids with the project actor policy.
  defp sample_check_ids!(org_id, project_id, monitor_ids, window_start, window_end, scope) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id
        FROM (
          SELECT checks.id,
                 row_number() OVER (
                   PARTITION BY checks.monitor_id
                   ORDER BY checks.checked_at DESC, checks.id DESC
                 ) AS sample_rank
          FROM monitor_checks AS checks
          WHERE checks.org_id = $1
            AND checks.project_id = $2
            AND checks.monitor_id = ANY($3::text[])
            AND checks.checked_at >= $4::timestamp
            AND checks.checked_at < $5::timestamp
            AND EXISTS (
              SELECT 1
              FROM monitors
              WHERE monitors.id = checks.monitor_id
                AND monitors.org_id = $1
                AND monitors.project_id = $2
            )
            AND EXISTS (
              SELECT 1
              FROM memberships
              WHERE memberships.org_id = checks.org_id
                AND memberships.user_id = $6::text
            )
        ) AS ranked
        WHERE sample_rank <= $7
        """,
        [
          org_id,
          project_id,
          monitor_ids,
          window_start,
          window_end,
          scope.user_id,
          @sample_limit
        ]
      )

    Enum.map(rows, &hd/1)
  end

  defp target(type, nil) when type in ["http", "keyword", "tcp", "dns"], do: nil

  defp target(type, config) when type in ["http", "keyword"],
    do: MonitorDisplay.sanitize_url(config.url)

  defp target("tcp", config), do: "#{config.hostname}:#{config.port}"
  defp target("dns", config), do: "#{config.hostname} (#{config.record_type})"
  defp target("heartbeat", _config), do: "PostDeploy heartbeat endpoint"

  defp interval(nil), do: nil
  defp interval(%{interval_seconds: interval}), do: interval

  defp present(%Ash.NotLoaded{}), do: nil
  defp present(value), do: value

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp current_state(%{status: "paused"}, _latest_check, _interval, _check_count, _now),
    do: :paused

  defp current_state(
         %{status: "active", last_known_status: "down"},
         _latest_check,
         _interval,
         _check_count,
         _now
       ),
       do: :down

  defp current_state(
         %{status: "active", last_known_status: "degraded"},
         _latest_check,
         _interval,
         _check_count,
         _now
       ),
       do: :degraded

  defp current_state(
         %{status: "active", last_known_status: "unknown"} = monitor,
         latest_check,
         _interval,
         _check_count,
         _now
       ) do
    if evidence?(monitor, latest_check), do: :missing, else: :waiting
  end

  defp current_state(
         %{status: "active"} = monitor,
         latest_check,
         interval,
         _check_count,
         now
       ) do
    cond do
      not evidence?(monitor, latest_check) -> :waiting
      late?(monitor, latest_check, interval, now) -> :late
      true -> :up
    end
  end

  defp current_state(_monitor, _latest_check, _interval, _check_count, _now), do: :missing

  defp evidence?(monitor, latest_check),
    do: not is_nil(latest_check) or not is_nil(Map.get(monitor, :last_check_at))

  defp monitor_evidence_at(monitor) do
    monitor.last_check_at ||
      case present(monitor.latest_check) do
        %{checked_at: checked_at} -> checked_at
        _ -> nil
      end
  end

  defp late?(monitor, latest_check, interval, now) do
    checked_at =
      case latest_check do
        nil -> monitor.last_check_at
        value -> Map.get(value, :checked_at) || monitor.last_check_at
      end

    if is_integer(interval) and interval > 0 do
      checked_at =
        case checked_at do
          %NaiveDateTime{} = value -> DateTime.from_naive!(value, "Etc/UTC")
          value -> value
        end

      match?(%DateTime{}, checked_at) and
        DateTime.diff(now, checked_at, :second) > max(interval * 2, 300)
    else
      false
    end
  end
end
