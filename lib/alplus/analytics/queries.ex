defmodule Alplus.Analytics.Queries do
  @moduledoc """
  Every product-analytics read (ADR 0007).

  Direct SQL, documented in `docs/DIRECT-ECTO-ESCAPE-HATCHES.md`. Ash reads
  cannot express `GROUP BY`, `count(DISTINCT ...)`, `date_trunc`, or the
  chained self-joins a funnel needs without loading every matching event row
  into the VM. Every statement here repeats the org and project predicate, so
  a caller cannot reach another tenant even if a policy were missing.

  ## What the numbers mean

    * **Event count** is the number of matching event rows.
    * **Unique users** is `count(DISTINCT distinct_id)`. A distinct ID is
      whatever the customer's application sent; PostDeploy never merges two
      of them and never claims one is a person.
    * **Funnel conversion** starts at each person's FIRST step-one event in
      the range. Each later step must occur strictly after the previous
      step's matched event and within the funnel's window, measured from the
      step-one event. Repeating a step does not count twice.
    * **Retention** is exact-day (or exact-week): a person counts at offset
      N only if they did the return event during that exact day or week, not
      at any time up to it. The denominator at offset N excludes cohort
      members whose offset-N period has not finished.

  ## Untrusted input

  Property names and values arrive from customer events. Every one of them
  is a bound parameter here, never interpolated. The only interpolated parts
  of any statement are step counts and placeholder numbers this module
  computes itself.
  """

  alias Alplus.Analytics.{Event, Limits}
  alias Alplus.Repo
  alias Alplus.Scope

  @windows ~w(24h 7d 30d 90d)
  @intervals ~w(hour day week month)

  # Warning: `date_trunc/2` on a `timestamptz` truncates in the session's
  # TimeZone setting, not in UTC. Every bucket here casts to UTC first, so a
  # server whose GUC is not UTC still draws the same days retention counts.

  @doc "The date ranges the product offers."
  @spec windows() :: [String.t()]
  def windows, do: @windows

  @doc """
  Returns `{from, to}` in UTC for a named window.

  Warning: `to` runs past `now` by the clock skew ingest accepts, and it has
  to. An event may carry a client timestamp up to
  `Limits.timestamp_max_skew_seconds/0` ahead of this server, and the
  database's own `now()` can sit milliseconds ahead of the VM's. An upper
  bound of exactly `now` made every such event invisible in every window
  while still counting against the customer's quota.
  """
  @spec range(String.t(), DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def range(window, now \\ DateTime.utc_now())
  def range("24h", now), do: {DateTime.add(now, -24, :hour), horizon(now)}
  def range("7d", now), do: {DateTime.add(now, -7, :day), horizon(now)}
  def range("30d", now), do: {DateTime.add(now, -30, :day), horizon(now)}
  def range("90d", now), do: {DateTime.add(now, -90, :day), horizon(now)}
  def range(_window, now), do: range("30d", now)

  defp horizon(now), do: DateTime.add(now, Limits.timestamp_max_skew_seconds(), :second)

  @doc """
  Returns the equal-length period immediately before `window`, for a
  period-over-period comparison.
  """
  @spec previous_range(String.t(), DateTime.t()) :: {DateTime.t(), DateTime.t()}
  def previous_range(window, now \\ DateTime.utc_now()) do
    {from, _to} = range(window, now)
    seconds = DateTime.diff(now, from, :second)
    {DateTime.add(from, -seconds, :second), from}
  end

  @doc "The chart bucket a window is drawn at."
  @spec interval_for(String.t()) :: String.t()
  def interval_for("24h"), do: "hour"
  def interval_for("90d"), do: "week"
  def interval_for(_window), do: "day"

  @doc "Normalizes a caller-supplied window to one the product offers."
  @spec valid_window(term()) :: String.t()
  def valid_window(window) when window in @windows, do: window
  def valid_window(_window), do: "30d"

  # ---- Totals ---------------------------------------------------------

  @doc """
  Returns the total event count and unique-user count for a range.

  `opts` accepts `:event_name` and `:filters`.
  """
  @spec totals(Scope.t(), {DateTime.t(), DateTime.t()}, keyword()) ::
          %{events: non_neg_integer(), users: non_neg_integer()}
  # The interpolated `where` is built by `predicate/4` from literals and
  # computed placeholder numbers. Property names and values are bound
  # parameters.
  # sobelow_skip ["SQL.Query"]
  def totals(%Scope{} = scope, {from, to}, opts \\ []) do
    {where, params} = predicate(scope, from, to, opts)

    %{rows: [[events, users]]} =
      Repo.query!(
        """
        SELECT count(*)::bigint, count(DISTINCT distinct_id)::bigint
        FROM product_events
        WHERE #{where}
        """,
        params
      )

    %{events: events, users: users}
  end

  # ---- Event explorer -------------------------------------------------

  @doc """
  Returns one row per event name in the range: count, unique users, and when
  it was last seen. Ordered by event count, highest first.
  """
  @spec list_events(Scope.t(), {DateTime.t(), DateTime.t()}, keyword()) :: [map()]
  # `where` and the placeholder numbers are computed here; the search term,
  # the limit, and every filter are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def list_events(%Scope{} = scope, {from, to}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    search = Keyword.get(opts, :search)
    {where, params} = predicate(scope, from, to, opts)

    # `_` and `%` are ILIKE wildcards and `_` is a legal event-name character,
    # so a search for `meal_logged` matched `mealXlogged` until this escaped
    # them.
    {where, params} =
      if is_binary(search) and search != "" do
        {where <> " AND event_name ILIKE $#{length(params) + 1} ESCAPE '\\'",
         params ++ ["%#{escape_like(search)}%"]}
      else
        {where, params}
      end

    %{rows: rows} =
      Repo.query!(
        """
        SELECT event_name, count(*)::bigint, count(DISTINCT distinct_id)::bigint,
               max(occurred_at), min(occurred_at)
        FROM product_events
        WHERE #{where}
        GROUP BY event_name
        ORDER BY count(*) DESC, event_name ASC
        LIMIT $#{length(params) + 1}
        """,
        params ++ [limit]
      )

    Enum.map(rows, fn [name, events, users, last_seen, first_seen] ->
      %{
        event_name: name,
        events: events,
        users: users,
        last_seen: utc(last_seen),
        first_seen: utc(first_seen)
      }
    end)
  end

  @doc """
  Returns the event-count trend for the named events, bucketed by `interval`.

  One statement covers every event, so drawing twenty sparklines costs one
  query. Buckets with no events are absent; the caller draws a measured zero
  only inside the range it asked for.
  """
  @spec trend_by_event(
          Scope.t(),
          {DateTime.t(), DateTime.t()},
          [String.t()],
          String.t(),
          keyword()
        ) ::
          %{String.t() => [%{at: DateTime.t(), events: non_neg_integer()}]}
  # `interval` passes through `valid_interval/1`, a closed whitelist. The
  # event names are a bound array parameter.
  # sobelow_skip ["SQL.Query"]
  def trend_by_event(%Scope{} = scope, {from, to}, event_names, interval, opts \\ []) do
    interval = valid_interval(interval)
    params = [scope.org_id, scope.project_id, from, to, event_names]

    {source_sql, params} =
      maybe_equals("", params, "source_id", Keyword.get(opts, :source_id))

    %{rows: rows} =
      Repo.query!(
        """
        SELECT event_name,
               date_trunc('#{interval}', occurred_at AT TIME ZONE 'UTC') AS bucket,
               count(*)::bigint
        FROM product_events
        WHERE org_id = $1 AND project_id = $2 AND occurred_at >= $3 AND occurred_at < $4
          AND event_name = ANY($5)#{source_sql}
        GROUP BY event_name, bucket
        ORDER BY bucket ASC
        """,
        params
      )

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {name, name_rows} ->
      {name,
       Enum.map(name_rows, fn [_name, bucket, count] -> %{at: utc(bucket), events: count} end)}
    end)
  end

  @doc """
  Returns the event and unique-user counts per time bucket.

  `opts` accepts `:event_name`, `:filters`, and `:interval`.
  """
  @spec time_series(Scope.t(), {DateTime.t(), DateTime.t()}, keyword()) :: [map()]
  # `interval` passes through `valid_interval/1`, a closed whitelist; `where`
  # comes from `predicate/4`.
  # sobelow_skip ["SQL.Query"]
  def time_series(%Scope{} = scope, {from, to}, opts \\ []) do
    interval = opts |> Keyword.get(:interval, "day") |> valid_interval()
    {where, params} = predicate(scope, from, to, opts)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT date_trunc('#{interval}', occurred_at AT TIME ZONE 'UTC') AS bucket,
               count(*)::bigint, count(DISTINCT distinct_id)::bigint
        FROM product_events
        WHERE #{where}
        GROUP BY bucket
        ORDER BY bucket ASC
        """,
        params
      )

    Enum.map(rows, fn [bucket, events, users] ->
      %{at: utc(bucket), events: events, users: users}
    end)
  end

  # ---- Properties -----------------------------------------------------

  @doc """
  Returns the property names seen on an event, most recent first.

  Read from the ingest-maintained registry, so it costs one indexed lookup
  rather than a scan over events.
  """
  @spec property_keys(Scope.t(), String.t() | nil) :: [String.t()]
  # The interpolated fragment is one of two literals chosen here. The event
  # name is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def property_keys(%Scope{} = scope, event_name \\ nil) do
    {where, params} =
      if is_binary(event_name) do
        {" AND event_name = $3", [scope.org_id, scope.project_id, event_name]}
      else
        {"", [scope.org_id, scope.project_id]}
      end

    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT property_key
        FROM product_event_property_keys
        WHERE org_id = $1 AND project_id = $2#{where}
        ORDER BY property_key ASC
        LIMIT 200
        """,
        params
      )

    Enum.map(rows, &hd/1)
  end

  @doc """
  Returns the most common values of one property, with the long tail
  collected into `(other)`.

  The cap is what protects the product from an accidental high-cardinality
  property: a `request_id` produces one `(other)` row carrying almost every
  event, which reads as the mistake it is.
  """
  @spec breakdown(Scope.t(), {DateTime.t(), DateTime.t()}, String.t(), keyword()) :: [map()]
  # Only placeholder numbers are interpolated. The property NAME is a bound
  # parameter, so `properties ->> $n` reads a customer-supplied key without
  # it ever reaching the statement text.
  # sobelow_skip ["SQL.Query"]
  def breakdown(%Scope{} = scope, {from, to}, property, opts \\ []) do
    limit = Keyword.get(opts, :limit, Limits.breakdown_max_values())
    {where, params} = predicate(scope, from, to, opts)
    property_index = length(params) + 1

    %{rows: rows} =
      Repo.query!(
        """
        SELECT properties ->> $#{property_index} AS value,
               count(*)::bigint, count(DISTINCT distinct_id)::bigint,
               sum(count(*)) OVER ()::bigint AS total_events
        FROM product_events
        WHERE #{where}
        GROUP BY value
        ORDER BY count(*) DESC, value ASC NULLS LAST
        LIMIT $#{property_index + 1}
        """,
        params ++ [property, limit + 1]
      )

    total_events =
      case rows do
        [[_value, _events, _users, total] | _rest] -> total
        [] -> 0
      end

    rows
    |> Enum.map(fn [value, events, users, _total] ->
      %{value: value || "(not set)", events: events, users: users}
    end)
    |> collapse_tail(limit, total_events)
  end

  # Past the cap, everything else becomes one `(other)` row whose count comes
  # from the whole grouped total, not from the rows this page happened to
  # fetch. A truncated list that silently under-reported the total would make
  # a high-cardinality property look smaller than it is.
  defp collapse_tail(rows, limit, _total) when length(rows) <= limit, do: rows

  defp collapse_tail(rows, limit, total) do
    head = Enum.take(rows, limit)

    head ++
      [
        %{
          value: "(other)",
          events: total - Enum.sum(Enum.map(head, & &1.events)),
          users: nil
        }
      ]
  end

  # ---- Funnels --------------------------------------------------------

  @doc """
  Runs an ordered funnel over `steps`.

  `opts` accepts `:window_hours` (the conversion window, measured from each
  person's step-one event), `:filters`, and `:breakdown`.

  Returns one entry per breakdown value, or a single entry keyed `nil` when
  no breakdown was asked for. Each entry carries the per-step user counts in
  step order.
  """
  @spec funnel(Scope.t(), {DateTime.t(), DateTime.t()}, [String.t()], keyword()) :: [map()]
  def funnel(scope, range, steps, opts \\ [])

  def funnel(_scope, _range, steps, _opts) when length(steps) < 2, do: []

  # `funnel_sql/7` interpolates only step indexes, placeholder numbers, and
  # the CTE names it generates. Step names, the source, filters, the
  # breakdown property, and the window are all bound parameters.
  # sobelow_skip ["SQL.Query"]
  def funnel(%Scope{} = scope, {from, to}, steps, opts) do
    window_hours = Keyword.get(opts, :window_hours, 168)
    filters = Keyword.get(opts, :filters, %{})
    breakdown = Keyword.get(opts, :breakdown)

    base_params = [scope.org_id, scope.project_id, from, to]

    {source_sql, base_params} =
      maybe_equals("", base_params, "source_id", Keyword.get(opts, :source_id))

    {filter_sql, filter_params} = filter_clause(filters, length(base_params) + 1)
    base_params = base_params ++ filter_params

    step_start = length(base_params) + 1
    params = base_params ++ steps ++ [window_hours]
    window_index = step_start + length(steps)

    {bucket_select, params, breakdown?} =
      if is_binary(breakdown) do
        {"properties ->> $#{window_index + 1}", params ++ [breakdown], true}
      else
        {"NULL::text", params, false}
      end

    # Restrict the base scan to the event names this funnel names. Without it
    # the CTE materializes every event in the range, and a project with a
    # dozen event names pays for all of them on every funnel read.
    names_index = length(params) + 1
    params = params ++ [Enum.uniq(steps)]

    sql =
      funnel_sql(
        steps,
        source_sql <> filter_sql,
        step_start,
        window_index,
        bucket_select,
        breakdown?,
        names_index
      )

    %{rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn [bucket | counts] ->
      %{
        breakdown_value: bucket,
        steps:
          steps
          |> Enum.zip(counts)
          |> Enum.map(fn {name, users} -> %{event_name: name, users: users} end)
      }
    end)
  end

  # The step CTEs are generated, but every value in them is a bound
  # parameter. Only the step index and the placeholder numbers, both computed
  # here, reach the statement text.
  defp funnel_sql(
         steps,
         filter_sql,
         step_start,
         window_index,
         bucket_select,
         breakdown?,
         names_index
       ) do
    step_count = length(steps)

    first_step = """
    s1 AS (
      SELECT DISTINCT ON (b.distinct_id) b.distinct_id, b.occurred_at AS t, b.bucket
      FROM base b
      WHERE b.event_name = $#{step_start}
      ORDER BY b.distinct_id, b.occurred_at ASC
    )
    """

    later_steps =
      2..step_count//1
      |> Enum.map(fn index ->
        # Join the step-one CTE rather than reading it from a correlated
        # subquery. A correlated read re-scans s1 once per candidate row,
        # which made a four-step funnel over a few thousand events run for
        # tens of seconds; the join is one hash join.
        anchor_join =
          if index == 2,
            do: "",
            else: "\n          JOIN s1 anchor ON anchor.distinct_id = b.distinct_id"

        anchor = if index == 2, do: "prev", else: "anchor"

        """
        s#{index} AS (
          SELECT b.distinct_id, min(b.occurred_at) AS t
          FROM base b
          JOIN s#{index - 1} prev ON prev.distinct_id = b.distinct_id#{anchor_join}
          WHERE b.event_name = $#{step_start + index - 1}
            AND b.occurred_at > prev.t
            AND b.occurred_at <= #{anchor}.t + make_interval(hours => $#{window_index}::int)
          GROUP BY b.distinct_id
        )
        """
      end)

    joins =
      2..step_count//1
      |> Enum.map_join("\n", fn index ->
        "LEFT JOIN s#{index} ON s#{index}.distinct_id = s1.distinct_id"
      end)

    counts =
      1..step_count//1
      |> Enum.map_join(",\n       ", fn index ->
        "count(s#{index}.distinct_id)::bigint AS step_#{index}"
      end)

    breakdown_column = if breakdown?, do: "s1.bucket", else: "NULL::text"

    """
    WITH base AS MATERIALIZED (
      SELECT distinct_id, event_name, occurred_at, #{bucket_select} AS bucket
      FROM product_events
      WHERE org_id = $1 AND project_id = $2 AND occurred_at >= $3 AND occurred_at < $4
        AND event_name = ANY($#{names_index})#{filter_sql}
    ),
    #{Enum.join([first_step | later_steps], ",\n")}
    SELECT #{breakdown_column} AS bucket,
           #{counts}
    FROM s1
    #{joins}
    GROUP BY 1
    ORDER BY step_1 DESC, 1 ASC NULLS LAST
    LIMIT #{Limits.breakdown_max_values()}
    """
  end

  @doc """
  Adds the conversion percentages a funnel result is read through.

  `overall` is against step one. `step` is against the step before it, which
  is the number that says where people stop.
  """
  @spec with_conversions(map()) :: map()
  def with_conversions(%{steps: steps} = entry) do
    first = steps |> List.first() |> Map.get(:users, 0)

    annotated =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        previous = if index == 0, do: step.users, else: Enum.at(steps, index - 1).users

        step
        |> Map.put(:overall_rate, rate(step.users, first))
        |> Map.put(:step_rate, rate(step.users, previous))
        |> Map.put(:lost, max(previous - step.users, 0))
      end)

    largest_drop =
      annotated
      |> Enum.drop(1)
      |> Enum.max_by(& &1.lost, fn -> nil end)

    entry
    |> Map.put(:steps, annotated)
    |> Map.put(:entered, first)
    |> Map.put(:converted, annotated |> List.last() |> Map.get(:users, 0))
    |> Map.put(:overall_rate, rate(annotated |> List.last() |> Map.get(:users, 0), first))
    |> Map.put(:largest_drop_event, largest_drop && largest_drop.event_name)
  end

  defp rate(_part, 0), do: nil
  defp rate(_part, nil), do: nil
  defp rate(part, whole), do: part * 100 / whole

  # ---- Activation -----------------------------------------------------

  @doc """
  Returns the activation rate: of the people who did the starting event in
  the range, how many went on to do the activation event inside the window.

  Activation is a two-step funnel, so it uses the same definition and the
  same code. Returns `nil` when the project has not defined one.
  """
  @spec activation(Scope.t(), {DateTime.t(), DateTime.t()}, map() | nil, keyword()) ::
          map() | nil
  def activation(scope, range, settings, opts \\ [])

  def activation(_scope, _range, nil, _opts), do: nil

  def activation(
        %Scope{} = scope,
        range,
        %{
          activation_start_event: start_event,
          activation_event: activation_event,
          activation_window_hours: window_hours
        },
        opts
      )
      when is_binary(start_event) and is_binary(activation_event) do
    case funnel(
           scope,
           range,
           [start_event, activation_event],
           Keyword.put(opts, :window_hours, window_hours)
         ) do
      [entry] ->
        converted = with_conversions(entry)

        %{
          start_event: start_event,
          activation_event: activation_event,
          window_hours: window_hours,
          started: converted.entered,
          activated: converted.converted,
          rate: converted.overall_rate
        }

      _none ->
        %{
          start_event: start_event,
          activation_event: activation_event,
          window_hours: window_hours,
          started: 0,
          activated: 0,
          rate: nil
        }
    end
  end

  def activation(_scope, _range, _settings, _opts), do: nil

  # ---- Retention ------------------------------------------------------

  @doc """
  Exact-period retention.

  The day-0 cohort is everyone whose FIRST starting event in the range falls
  in that period. A cohort member counts at offset N only if they did the
  return event during that exact period.

  The denominator at offset N leaves out anyone whose offset-N period has not
  FINISHED, not merely started. Somebody whose first event was yesterday has
  not finished day 1 today, so counting them would report a person who still
  has hours left as a person who did not return.
  """
  @spec retention(Scope.t(), {DateTime.t(), DateTime.t()}, String.t(), String.t(), keyword()) ::
          %{granularity: String.t(), periods: [map()]}
  # The interpolated fragments are the source predicate `maybe_equals/4`
  # builds from a computed placeholder number, once for each side of the
  # join. The source id itself is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def retention(%Scope{} = scope, {from, to}, start_event, return_event, opts \\ []) do
    granularity = Keyword.get(opts, :granularity, "daily")
    today = Keyword.get(opts, :today, Date.utc_today())
    {period_days, offsets} = retention_shape(granularity)

    params = [
      scope.org_id,
      scope.project_id,
      start_event,
      from,
      to,
      period_days,
      return_event,
      today,
      offsets
    ]

    # One bound source, referenced from both the cohort and the returns, so a
    # per-app cohort only ever counts that app's own returns.
    {source_sql, params} = maybe_equals("", params, "source_id", Keyword.get(opts, :source_id))
    returns_source_sql = String.replace(source_sql, " AND source_id", " AND e.source_id")

    %{rows: rows} =
      Repo.query!(
        """
        WITH cohort AS (
          SELECT distinct_id, (min(occurred_at) AT TIME ZONE 'UTC')::date AS day0
          FROM product_events
          WHERE org_id = $1 AND project_id = $2 AND event_name = $3
            AND occurred_at >= $4 AND occurred_at < $5#{source_sql}
          GROUP BY distinct_id
        ),
        returns AS (
          SELECT c.distinct_id, c.day0,
                 (((e.occurred_at AT TIME ZONE 'UTC')::date - c.day0) / $6::int) AS period
          FROM product_events e
          JOIN cohort c ON c.distinct_id = e.distinct_id
          WHERE e.org_id = $1 AND e.project_id = $2 AND e.event_name = $7
            AND e.occurred_at >= $4
            AND (e.occurred_at AT TIME ZONE 'UTC')::date >= c.day0#{returns_source_sql}
        )
        SELECT o.period,
               (SELECT count(*) FROM cohort
                 WHERE cohort.day0 <= $8::date - ((o.period + 1) * $6::int))::bigint,
               (SELECT count(DISTINCT r.distinct_id) FROM returns r
                 WHERE r.period = o.period
                   AND r.day0 <= $8::date - ((o.period + 1) * $6::int))::bigint
        FROM unnest($9::int[]) AS o(period)
        ORDER BY o.period ASC
        """,
        params
      )

    periods =
      Enum.map(rows, fn [period, cohort_size, retained] ->
        %{
          period: period,
          cohort: cohort_size,
          retained: retained,
          rate: rate(retained, cohort_size)
        }
      end)

    %{granularity: granularity, periods: periods}
  end

  defp retention_shape("weekly"), do: {7, [0, 1, 2, 3, 4, 6, 8]}
  defp retention_shape(_daily), do: {1, [0, 1, 3, 7, 14, 30]}

  # ---- Live events ----------------------------------------------------

  @doc """
  Returns the most recent events, for verifying instrumentation.

  Bounded to a short recent window and a small row count on purpose: this is
  a debugging view, not the analytics store's query interface.
  """
  @spec live_events(Scope.t(), keyword()) :: [map()]
  # `name_sql` is one of two literals chosen here; the event name is bound.
  # sobelow_skip ["SQL.Query"]
  def live_events(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, Limits.live_events_limit())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -Limits.live_events_window_minutes(), :minute)

    # Filter by name in SQL, never after the limit. Filtering afterwards made
    # a busy project's per-event panel read "nothing in the last hour" while
    # its events kept arriving.
    params = [scope.org_id, scope.project_id, since, limit]
    {name_sql, params} = maybe_equals("", params, "event_name", Keyword.get(opts, :event_name))

    {source_sql, params} =
      maybe_equals(name_sql, params, "source_id", Keyword.get(opts, :source_id))

    %{rows: rows} =
      Repo.query!(
        """
        SELECT event_name, distinct_id, occurred_at, received_at, properties
        FROM product_events
        WHERE org_id = $1 AND project_id = $2 AND received_at >= $3#{source_sql}
        ORDER BY received_at DESC
        LIMIT $4
        """,
        params
      )

    Enum.map(rows, fn [name, distinct_id, occurred_at, received_at, properties] ->
      %{
        event_name: name,
        distinct_id: distinct_id,
        occurred_at: utc(occurred_at),
        received_at: utc(received_at),
        properties: properties
      }
    end)
  end

  @doc "Returns the most recent event in the project, or `nil`."
  @spec latest_event(Scope.t()) :: map() | nil
  def latest_event(%Scope{} = scope) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT event_name, received_at
        FROM product_events
        WHERE org_id = $1 AND project_id = $2
        ORDER BY received_at DESC
        LIMIT 1
        """,
        [scope.org_id, scope.project_id]
      )

    case rows do
      [[name, received_at]] -> %{event_name: name, received_at: utc(received_at)}
      [] -> nil
    end
  end

  # ---- Export ---------------------------------------------------------

  @doc """
  Streams the raw events in a range, oldest first, in bounded pages.

  The export exists so a customer is never locked in and can debug their own
  instrumentation. It is not an ETL interface.
  """
  @spec stream_events(Scope.t(), {DateTime.t(), DateTime.t()}, pos_integer(), keyword()) ::
          Enumerable.t()
  def stream_events(scope, range, page_size \\ 1_000, opts \\ [])

  def stream_events(%Scope{} = scope, {from, to}, page_size, opts)
      when is_integer(page_size) and page_size > 0 and page_size <= 10_000 do
    source_id = Keyword.get(opts, :source_id)

    Stream.resource(
      fn -> {from, nil} end,
      fn
        :halt ->
          {:halt, :halt}

        {cursor_at, cursor_id} ->
          rows = export_page(scope, cursor_at, cursor_id, to, page_size, source_id)

          case rows do
            [] ->
              {:halt, :halt}

            rows ->
              [last_at, last_id] = rows |> List.last() |> then(&[&1.occurred_at, &1.id])
              next = if length(rows) < page_size, do: :halt, else: {last_at, last_id}
              {rows, next}
          end
      end,
      fn _state -> :ok end
    )
  end

  # `where` is one of two literals chosen here. `page_size` is guarded to a
  # bounded integer by `stream_events/3`'s own clause; no caller takes it from
  # a request.
  # sobelow_skip ["SQL.Query"]
  defp export_page(scope, cursor_at, cursor_id, to, page_size, source_id) do
    params = [scope.org_id, scope.project_id, cursor_at, to]
    {source_sql, params} = maybe_equals("", params, "source_id", source_id)

    {where, params} =
      if cursor_id do
        index = length(params) + 1

        {source_sql <> " AND (occurred_at, id) > ($#{index}, $#{index + 1})",
         params ++ [cursor_at, cursor_id]}
      else
        {source_sql, params}
      end

    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, event_name, distinct_id, occurred_at, properties
        FROM product_events
        WHERE org_id = $1 AND project_id = $2 AND occurred_at >= $3 AND occurred_at < $4
          #{where}
        ORDER BY occurred_at ASC, id ASC
        LIMIT #{page_size}
        """,
        params
      )

    Enum.map(rows, fn [id, name, distinct_id, occurred_at, properties] ->
      %{
        id: id,
        event_name: name,
        distinct_id: distinct_id,
        occurred_at: utc(occurred_at),
        properties: properties
      }
    end)
  end

  # ---- Deletion -------------------------------------------------------

  @doc """
  Deletes every analytics event and property-key registry row for one
  project. Returns how many events were removed.

  Destructive and irreversible. The caller is responsible for confirming it.
  """
  @spec delete_project_data(Scope.t()) :: non_neg_integer()
  def delete_project_data(%Scope{org_id: org_id, project_id: project_id})
      when is_binary(org_id) and is_binary(project_id) do
    %{num_rows: deleted} =
      Repo.query!(
        "DELETE FROM product_events WHERE org_id = $1 AND project_id = $2",
        [org_id, project_id]
      )

    Repo.query!(
      "DELETE FROM product_event_property_keys WHERE org_id = $1 AND project_id = $2",
      [org_id, project_id]
    )

    deleted
  end

  # ---- Shared ---------------------------------------------------------

  # Every read starts here, so the org and project predicate cannot be
  # forgotten on a new query.
  defp predicate(%Scope{} = scope, from, to, opts) do
    params = [scope.org_id, scope.project_id, from, to]
    where = "org_id = $1 AND project_id = $2 AND occurred_at >= $3 AND occurred_at < $4"

    {where, params} = maybe_equals(where, params, "event_name", Keyword.get(opts, :event_name))
    {where, params} = maybe_equals(where, params, "source_id", Keyword.get(opts, :source_id))

    {filter_sql, filter_params} =
      opts |> Keyword.get(:filters, %{}) |> filter_clause(length(params) + 1)

    {where <> filter_sql, params ++ filter_params}
  end

  # The placeholder number is computed from what is already bound, never
  # written by hand. Adding a predicate here used to mean renumbering every
  # one after it.
  defp maybe_equals(where, params, column, value) when is_binary(value) do
    {where <> " AND #{column} = $#{length(params) + 1}", params ++ [value]}
  end

  defp maybe_equals(where, params, _column, _value), do: {where, params}

  # A property filter compares one JSON value to one text value. Both the
  # name and the value are bound parameters, so a property called
  # `'; DROP TABLE` is matched literally and matches nothing.
  defp filter_clause(filters, _next_index) when filters == %{}, do: {"", []}

  defp filter_clause(filters, next_index) when is_map(filters) do
    {clauses, params, _index} =
      Enum.reduce(filters, {[], [], next_index}, fn {key, value}, {clauses, params, index} ->
        clause = " AND properties ->> $#{index} = $#{index + 1}"
        {[clause | clauses], params ++ [key, to_text(value)], index + 2}
      end)

    {clauses |> Enum.reverse() |> Enum.join(""), params}
  end

  defp filter_clause(_filters, _next_index), do: {"", []}

  defp to_text(value) when is_binary(value), do: value
  defp to_text(true), do: "true"
  defp to_text(false), do: "false"
  defp to_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_text(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp to_text(value), do: to_string(value)

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp valid_interval(interval) when interval in @intervals, do: interval
  defp valid_interval(_interval), do: "day"

  # Warning: a raw `Repo.query!` returns a `NaiveDateTime` for a timestamptz
  # column. Coerce at the boundary so callers can do date arithmetic.
  defp utc(nil), do: nil
  defp utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp utc(%DateTime{} = value), do: value

  @doc "The identifier events with no `distinct_id` are counted under."
  @spec anonymous_distinct_id() :: String.t()
  def anonymous_distinct_id, do: Event.anonymous_distinct_id()
end
