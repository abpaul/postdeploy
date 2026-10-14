defmodule AlplusWeb.Marketing.HomepageData do
  @moduledoc """
  The single public read model rendered by the marketing homepage.

  Vendor selection is delegated to `Changelog.Public.resolve_vendor/0`. Every
  subsequent read is pinned to that resolved actor and project. The returned
  map contains presentation-safe projections only; callers never receive
  tenant identifiers, credentials, payloads, or raw errors.

  The homepage is server rendered, so the hero range, the hero metric, the
  selected monitor and the Measure range arrive as query parameters. Every
  parameter is normalised against an allow-list before any read runs, and
  only the normalised range values reach a cache key. Metric and monitor
  selection are pure projections over already cached data.
  """

  alias Alplus.Changelog.Public, as: ChangelogPublic
  alias Alplus.Measure.PublicCache
  alias Alplus.Observe
  alias Alplus.Status.PublicPage
  alias AlplusWeb.Marketing.{HomepagePreview, PackagePresenter}

  @max_changelog_entries 3
  @max_monitor_index 19

  @ranges ["24h", "7d", "30d"]
  @traffic_ranges ["7d", "14d", "30d"]
  @metric_ids [:uptime, :response, :traffic, :errors]
  @metric_names %{
    "uptime" => :uptime,
    "response" => :response,
    "traffic" => :traffic,
    "errors" => :errors
  }

  @default_selection %{range: "24h", metric: :uptime, monitor: 0, traffic_range: "7d"}

  @type state :: :ready | :partial | :empty | :preview | :unavailable

  @doc "Loads the bounded, cacheable public homepage projection."
  @spec load(map()) :: map()
  def load(params \\ %{}) do
    selection = normalize(params)

    :marketing_homepage_v3
    |> PublicCache.fetch(&base_entry/0)
    |> compose(selection)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable(normalize(params))
  end

  @doc """
  Projects one vendor resolution. The development preview is reachable only
  from `{:error, :not_found}`: an unavailable data source must never be
  presented as example data.
  """
  @spec project_from_resolution({:ok, map()} | {:error, :not_found | :unavailable}, map()) ::
          map()
  def project_from_resolution(resolution, params \\ %{}) do
    resolution |> entry_from_resolution() |> compose(normalize(params))
  end

  @doc "Returns the allow-listed range values the hero switch may request."
  @spec ranges() :: [String.t()]
  def ranges, do: @ranges

  @doc "Returns the allow-listed range values the Measure switch may request."
  @spec traffic_ranges() :: [String.t()]
  def traffic_ranges, do: @traffic_ranges

  # ---------------------------------------------------------------------------
  # Parameter normalisation
  # ---------------------------------------------------------------------------

  defp normalize(params) when is_map(params) do
    %{
      range: allowed(params, "range", @ranges, @default_selection.range),
      metric: metric_param(params),
      monitor: monitor_param(params),
      traffic_range: allowed(params, "traffic", @traffic_ranges, @default_selection.traffic_range)
    }
  end

  defp normalize(_params), do: @default_selection

  defp allowed(params, key, allow_list, default) do
    value = Map.get(params, key)
    if is_binary(value) and value in allow_list, do: value, else: default
  end

  defp metric_param(params) do
    case Map.get(params, "metric") do
      value when is_binary(value) -> Map.get(@metric_names, value, @default_selection.metric)
      _other -> @default_selection.metric
    end
  end

  defp monitor_param(params) do
    with value when is_binary(value) <- Map.get(params, "monitor"),
         {index, ""} <- Integer.parse(value),
         true <- index >= 0 do
      min(index, @max_monitor_index)
    else
      _invalid -> @default_selection.monitor
    end
  end

  # ---------------------------------------------------------------------------
  # Cached base entry
  # ---------------------------------------------------------------------------

  defp base_entry do
    ChangelogPublic.resolve_vendor() |> entry_from_resolution()
  end

  defp entry_from_resolution({:ok, %{identity: identity, actor: actor} = resolved}),
    do: build(identity, actor, resolved)

  defp entry_from_resolution({:error, :not_found}), do: %{mode: no_vendor_mode(), context: nil}
  defp entry_from_resolution({:error, :unavailable}), do: %{mode: :unavailable, context: nil}

  defp no_vendor_mode do
    if Application.get_env(:alplus, :homepage_preview_when_unconfigured, false),
      do: :preview,
      else: :empty
  end

  defp build(identity, actor, resolved) do
    status_data = status(identity.public_slug)
    monitor_data = monitors(actor)
    observe_data = observe(actor)
    changelog_data = changelog(resolved)
    source_ids = measure_source_ids(actor)

    %{
      mode: :vendor,
      public: %{
        identity: %{name: identity.title, slug: identity.public_slug},
        monitor: monitor_data,
        observe: observe_data,
        status: status_data,
        changelog: changelog_data
      },
      context: %{
        actor: actor,
        monitor_ids: Map.get(monitor_data, :monitor_ids, []),
        source_ids: source_ids,
        rollup_days: Map.get(monitor_data, :history, [])
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Composition
  # ---------------------------------------------------------------------------

  defp compose(%{mode: :preview}, selection), do: HomepagePreview.data(selection)
  defp compose(%{mode: :empty}, selection), do: empty(selection)
  defp compose(%{mode: :unavailable}, selection), do: unavailable(selection)

  defp compose(%{mode: :vendor, public: public, context: context}, selection) do
    hero =
      PublicCache.fetch({:marketing_homepage_hero, selection.range}, fn ->
        hero_entry(context, selection.range)
      end)

    traffic =
      PublicCache.fetch({:marketing_homepage_traffic, selection.traffic_range}, fn ->
        traffic_entry(context, selection.traffic_range)
      end)

    measure_data = measure_section(traffic, selection.traffic_range)
    {monitor_data, monitor_index} = select_monitor(public.monitor, selection.monitor)

    sections = [
      monitor_data,
      measure_data,
      public.observe,
      public.status,
      public.changelog
    ]

    %{
      state: overall_state(sections),
      identity: public.identity,
      selection: %{selection | monitor: monitor_index},
      overview: overview(hero, selection.metric),
      metrics: metrics(monitor_data, measure_data, public.observe),
      monitor: monitor_data,
      measure: measure_data,
      observe: public.observe,
      status: public.status,
      changelog: public.changelog
    }
  end

  # ---------------------------------------------------------------------------
  # Hero reads, one bounded set per normalised range
  # ---------------------------------------------------------------------------

  defp hero_entry(context, range) do
    spec = bucket_spec(range)
    keys = bucket_keys(spec)
    since = window_start(spec)
    actor = context.actor

    %{
      spec: spec,
      keys: keys,
      checks: index_by_bucket(check_buckets(actor, context.monitor_ids, spec, since), spec),
      rollups: rollup_index(context.rollup_days, keys, spec),
      traffic: index_by_bucket(traffic_buckets(actor, context.source_ids, spec, since), spec),
      issues:
        index_by_bucket(
          Alplus.Observe.PublicEvidence.load_issue_buckets(actor, spec.unit, since),
          spec
        )
    }
  end

  defp check_buckets(actor, monitor_ids, spec, since) do
    Alplus.Monitoring.PublicEvidence.load_check_buckets(actor, monitor_ids, spec.unit, since)
  end

  defp traffic_buckets(actor, source_ids, %{unit: :hour} = _spec, since) do
    until = DateTime.add(DateTime.utc_now(), 3_600, :second)
    Alplus.Measure.PublicEvidence.load_hour_buckets(actor, source_ids, since, until)
  end

  defp traffic_buckets(actor, source_ids, %{count: count}, _since) do
    Alplus.Measure.PublicEvidence.load_day_buckets(actor, source_ids, count)
  end

  defp index_by_bucket(rows, spec) do
    Map.new(rows, fn row -> {bucket_key(row.at, spec.unit), row} end)
  end

  # Daily uptime for 7d and 30d comes from the ninety-day rollup set the base
  # entry already read, so a range switch costs no extra rollup query.
  defp rollup_index(_rollup_days, _keys, %{unit: :hour}), do: %{}

  defp rollup_index(rollup_days, keys, _spec) do
    wanted = MapSet.new(keys)

    rollup_days
    |> Enum.filter(&(is_number(&1.uptime) and MapSet.member?(wanted, &1.day)))
    |> Map.new(&{&1.day, &1.uptime})
  end

  defp traffic_entry(context, traffic_range) do
    days = bucket_spec(traffic_range).count

    case Alplus.Measure.PublicEvidence.load_for_sources(context.actor, context.source_ids, days) do
      {:ok, projection} -> projection
      _error -> %{pageviews: nil, visitors: nil, trend: [], top_pages: []}
    end
  end

  # ---------------------------------------------------------------------------
  # Bucket arithmetic
  # ---------------------------------------------------------------------------

  defp bucket_spec("24h"),
    do: %{unit: :hour, count: 24, axis: "-24h", window: "24 hours", noun: "hour"}

  defp bucket_spec("7d"), do: %{unit: :day, count: 7, axis: "-7d", window: "7 days", noun: "day"}

  defp bucket_spec("14d"),
    do: %{unit: :day, count: 14, axis: "-14d", window: "14 days", noun: "day"}

  defp bucket_spec("30d"),
    do: %{unit: :day, count: 30, axis: "-30d", window: "30 days", noun: "day"}

  defp bucket_keys(%{unit: :hour, count: count}) do
    top = current_hour()
    Enum.map((count - 1)..0//-1, &NaiveDateTime.add(top, -&1 * 3_600, :second))
  end

  defp bucket_keys(%{unit: :day, count: count}) do
    today = Date.utc_today()
    Enum.map((count - 1)..0//-1, &Date.add(today, -&1))
  end

  defp current_hour do
    now = DateTime.utc_now() |> DateTime.to_naive()
    %{now | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp window_start(%{unit: :hour} = spec) do
    spec |> bucket_keys() |> hd() |> DateTime.from_naive!("Etc/UTC")
  end

  defp window_start(%{unit: :day} = spec) do
    spec |> bucket_keys() |> hd() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp bucket_key(at, :hour) do
    naive = to_naive(at)
    %{naive | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp bucket_key(at, :day), do: at |> to_naive() |> NaiveDateTime.to_date()

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp to_naive(%NaiveDateTime{} = at), do: at
  defp to_naive(%Date{} = day), do: NaiveDateTime.new!(day, ~T[00:00:00])

  defp bucket_label(%Date{} = day), do: Date.to_iso8601(day)

  defp bucket_label(%NaiveDateTime{} = at),
    do: String.pad_leading("#{at.hour}", 2, "0") <> ":00"

  # ---------------------------------------------------------------------------
  # Overview projection
  # ---------------------------------------------------------------------------

  defp overview(hero, metric) do
    totals = totals(hero)
    chart = chart(hero, metric, totals)

    %{
      state: overview_state(totals),
      ranges: @ranges,
      tiles: tiles(metric, totals),
      chart: chart
    }
  end

  defp totals(hero) do
    checks = Map.values(hero.checks)
    total_checks = Enum.sum(Enum.map(checks, & &1.checks))
    failed_checks = Enum.sum(Enum.map(checks, & &1.failed))
    latency_total = Enum.sum(Enum.map(checks, &weighted_latency/1))

    traffic = Map.values(hero.traffic)
    rollup_days = Map.values(hero.rollups)

    %{
      spec: hero.spec,
      checks: total_checks,
      failed: failed_checks,
      latency_ms: if(total_checks > 0 and latency_total > 0, do: latency_total / total_checks),
      rollup_days: length(rollup_days),
      down_days: Enum.count(rollup_days, &(&1 < 100.0)),
      uptime: uptime_total(hero, total_checks, failed_checks, rollup_days),
      pageviews: Enum.sum(Enum.map(traffic, & &1.pageviews)),
      visitors: Enum.sum(Enum.map(traffic, & &1.visitors)),
      traffic_days: length(traffic),
      latency_buckets: Enum.count(checks, &(&1.checks > 0)),
      issues: hero.issues |> Map.values() |> Enum.map(& &1.issues) |> Enum.sum()
    }
  end

  defp weighted_latency(%{latency_ms: latency, checks: checks}) when is_number(latency),
    do: latency * checks

  defp weighted_latency(_bucket), do: 0

  defp uptime_total(%{spec: %{unit: :hour}}, total_checks, failed_checks, _rollup_days) do
    if total_checks > 0,
      do: Float.round((total_checks - failed_checks) / total_checks * 100, 2),
      else: nil
  end

  defp uptime_total(_hero, _total_checks, _failed_checks, []), do: nil

  defp uptime_total(_hero, _total_checks, _failed_checks, rollup_days),
    do: Float.round(Enum.sum(rollup_days) / length(rollup_days), 2)

  defp overview_state(totals) do
    if is_nil(totals.uptime) and totals.checks == 0 and totals.pageviews == 0 and
         totals.issues == 0,
       do: :empty,
       else: :ready
  end

  defp tiles(metric, totals) do
    Enum.map(@metric_ids, fn id ->
      %{
        id: id,
        label: tile_label(id),
        value: tile_value(id, totals),
        sub: tile_sub(id, totals),
        tone: if(id == :errors and totals.issues > 0, do: :error, else: :ink),
        selected?: id == metric
      }
    end)
  end

  defp tile_label(:uptime), do: "Uptime"
  defp tile_label(:response), do: "Response"
  defp tile_label(:traffic), do: "Traffic"
  defp tile_label(:errors), do: "Errors"

  defp tile_value(:uptime, %{uptime: uptime}) when is_number(uptime), do: "#{uptime}%"
  defp tile_value(:uptime, _totals), do: nil

  defp tile_value(:response, %{latency_ms: latency}) when is_number(latency),
    do: "#{round(latency)}ms"

  defp tile_value(:response, _totals), do: nil
  defp tile_value(:traffic, %{pageviews: 0}), do: nil
  defp tile_value(:traffic, %{pageviews: pageviews}), do: PackagePresenter.thousands(pageviews)
  defp tile_value(:errors, %{issues: issues}), do: PackagePresenter.thousands(issues)

  defp tile_sub(:uptime, %{spec: %{unit: :hour}, checks: 0}), do: "No checks recorded"

  defp tile_sub(:uptime, %{spec: %{unit: :hour}, checks: checks}),
    do: "#{PackagePresenter.thousands(checks)} #{plural(checks, "check")}"

  defp tile_sub(:uptime, %{rollup_days: 0}), do: "No uptime history"

  defp tile_sub(:uptime, %{rollup_days: days}),
    do: "#{days} #{plural(days, "day")} measured"

  defp tile_sub(:response, %{latency_ms: nil}), do: "No latency recorded"
  defp tile_sub(:response, _totals), do: "Average per check"
  defp tile_sub(:traffic, %{pageviews: 0}), do: "No traffic recorded"

  defp tile_sub(:traffic, %{visitors: visitors}),
    do: "#{PackagePresenter.thousands(visitors)} #{plural(visitors, "visitor")}"

  defp tile_sub(:errors, %{issues: 0}), do: "No issues active"
  defp tile_sub(:errors, _totals), do: "Active in this window"

  defp chart(hero, metric, totals) do
    points = points(hero, metric)
    values = points |> Enum.map(& &1.value) |> Enum.filter(&is_number/1)

    %{
      kind: chart_kind(metric),
      unit: chart_unit(metric),
      points: points,
      peak: peak(metric, values),
      caption: caption(metric, totals),
      axis_start: totals.spec.axis,
      axis_end: "now",
      table_caption: table_caption(metric, totals.spec),
      column_label: column_label(metric),
      state: chart_state(metric, totals)
    }
  end

  defp chart_kind(:uptime), do: :ticks
  defp chart_kind(:traffic), do: :wave
  defp chart_kind(_metric), do: :bars

  defp chart_unit(:uptime), do: "percent"
  defp chart_unit(:response), do: "ms"
  defp chart_unit(:traffic), do: "pageviews"
  defp chart_unit(:errors), do: "issues"

  defp column_label(:uptime), do: "Uptime, percent"
  defp column_label(:response), do: "Average response, milliseconds"
  defp column_label(:traffic), do: "Traffic, pageviews"
  defp column_label(:errors), do: "Issues active, count"

  defp table_caption(metric, spec) do
    "#{column_label(metric)} for each #{spec.noun} in the last #{spec.window}."
  end

  defp peak(:uptime, _values), do: 100
  defp peak(_metric, []), do: 0
  defp peak(_metric, values), do: Enum.max(values)

  defp points(hero, :uptime), do: Enum.map(hero.keys, &uptime_point(hero, &1))
  defp points(hero, :response), do: Enum.map(hero.keys, &response_point(hero, &1))
  defp points(hero, :traffic), do: Enum.map(hero.keys, &traffic_point(hero, &1))
  defp points(hero, :errors), do: Enum.map(hero.keys, &errors_point(hero, &1))

  defp uptime_point(%{spec: %{unit: :hour}} = hero, key) do
    case Map.get(hero.checks, key) do
      %{checks: checks, failed: failed} when checks > 0 ->
        %{
          label: bucket_label(key),
          value: Float.round((checks - failed) / checks * 100, 2),
          state: check_state(checks, failed)
        }

      _missing ->
        %{label: bucket_label(key), value: nil, state: :none}
    end
  end

  defp uptime_point(hero, key) do
    case Map.get(hero.rollups, key) do
      uptime when is_number(uptime) ->
        %{label: bucket_label(key), value: uptime, state: uptime_state(uptime)}

      _missing ->
        %{label: bucket_label(key), value: nil, state: :none}
    end
  end

  defp check_state(checks, checks), do: :down
  defp check_state(_checks, 0), do: :up
  defp check_state(_checks, _failed), do: :degraded

  defp uptime_state(uptime) when uptime >= 100.0, do: :up
  defp uptime_state(uptime) when uptime <= 0.0, do: :down
  defp uptime_state(_uptime), do: :degraded

  defp response_point(hero, key) do
    case Map.get(hero.checks, key) do
      %{latency_ms: latency, checks: checks} when is_number(latency) and checks > 0 ->
        %{label: bucket_label(key), value: round(latency), state: :up}

      _missing ->
        %{label: bucket_label(key), value: nil, state: :none}
    end
  end

  defp traffic_point(hero, key) do
    pageviews = hero.traffic |> Map.get(key, %{pageviews: 0}) |> Map.get(:pageviews, 0)

    %{
      label: bucket_label(key),
      value: pageviews,
      state: if(pageviews > 0, do: :up, else: :none)
    }
  end

  defp errors_point(hero, key) do
    issues = hero.issues |> Map.get(key, %{issues: 0}) |> Map.get(:issues, 0)

    %{
      label: bucket_label(key),
      value: issues,
      state: if(issues > 0, do: :degraded, else: :none)
    }
  end

  defp chart_state(:uptime, %{spec: %{unit: :hour}, checks: 0}), do: :empty
  defp chart_state(:uptime, %{spec: %{unit: :day}, rollup_days: 0}), do: :empty
  defp chart_state(:response, %{latency_ms: nil}), do: :empty
  defp chart_state(:traffic, %{pageviews: 0}), do: :empty
  defp chart_state(:errors, %{issues: 0}), do: :empty
  defp chart_state(_metric, _totals), do: :ready

  # Captions are derived from the rows that were read. None is written ahead
  # of the data, and none claims a percentile the check history cannot show.
  defp caption(:uptime, %{spec: %{unit: :hour}, checks: 0}),
    do: "No checks recorded in this window"

  defp caption(:uptime, %{spec: %{unit: :hour}, checks: checks, failed: 0}),
    do: "#{PackagePresenter.thousands(checks)} checks, every one passed"

  defp caption(:uptime, %{spec: %{unit: :hour}, failed: failed}),
    do: "#{PackagePresenter.thousands(failed)} failed #{plural(failed, "check")} in this window"

  defp caption(:uptime, %{rollup_days: 0}), do: "No uptime history in this window"

  defp caption(:uptime, %{rollup_days: days, spec: %{count: count}}) when days < count,
    do: "#{days} #{plural(days, "day")} of history available"

  defp caption(:uptime, %{down_days: 0}), do: "Every day reported full uptime"

  defp caption(:uptime, %{down_days: down_days}),
    do: "#{down_days} #{plural(down_days, "day")} recorded downtime"

  defp caption(:response, %{latency_ms: nil}), do: "No latency recorded in this window"

  defp caption(:response, %{spec: %{unit: :hour}}), do: "Average check latency per hour"

  defp caption(:response, %{latency_buckets: buckets, spec: %{count: count}})
       when buckets < count,
       do:
         "Average check latency per day, #{buckets} #{plural(buckets, "day")} of history available"

  defp caption(:response, _totals), do: "Average check latency per day"

  defp caption(:traffic, %{pageviews: 0}), do: "No traffic recorded in this window"
  defp caption(:traffic, %{spec: %{unit: :hour}}), do: "Pageviews per hour"

  defp caption(:traffic, %{traffic_days: days, spec: %{count: count}}) when days < count,
    do: "Pageviews per day, #{days} #{plural(days, "day")} of history available"

  defp caption(:traffic, _totals), do: "Pageviews per day"

  defp caption(:errors, %{issues: 0}), do: "No issues were active in this window"

  defp caption(:errors, %{issues: 1}), do: "1 issue was active in this window"

  defp caption(:errors, %{issues: issues}),
    do: "#{PackagePresenter.thousands(issues)} issues were active in this window"

  defp plural(1, noun), do: noun
  defp plural(_count, noun), do: noun <> "s"

  # ---------------------------------------------------------------------------
  # Monitor section
  # ---------------------------------------------------------------------------

  defp monitors(actor) do
    case Alplus.Monitoring.PublicEvidence.load(actor) do
      {:ok, %{rows: rows, history: history} = evidence} when rows != [] ->
        monitor_projection(Enum.map(rows, &Map.put_new(&1, :type, "monitor")), history,
          uptime: evidence.uptime,
          response_time_ms: evidence.response_time_ms,
          uptime_label: "Weighted production uptime, last 90 days",
          monitor_ids: Map.get(evidence, :monitor_ids, [])
        )

      {:ok, _empty} ->
        monitor_projection([], [])

      _error ->
        %{
          state: :unavailable,
          rows: [],
          headline: %{total: nil, operational: nil, uptime: nil},
          response_time_ms: nil,
          history: [],
          selected: nil,
          monitor_ids: []
        }
    end
  end

  defp monitor_projection(rows, history, opts \\ []) do
    if rows == [] and opts == [] do
      %{
        state: :empty,
        rows: [],
        headline: %{total: 0, operational: 0},
        history: history,
        selected: nil,
        monitor_ids: []
      }
    else
      %{
        state: :ready,
        rows: rows,
        headline: %{
          total: length(rows),
          operational: Enum.count(rows, &(&1.state == :up)),
          uptime: Keyword.get(opts, :uptime)
        },
        response_time_ms: Keyword.get(opts, :response_time_ms),
        history: history,
        uptime_label: Keyword.get(opts, :uptime_label),
        selected: nil,
        monitor_ids: Keyword.get(opts, :monitor_ids, [])
      }
    end
  end

  # The monitor ids stay in the private cache context. They are stripped here
  # so no identifier can reach a template or a rendered page.
  defp select_monitor(monitor, index) do
    monitor = Map.delete(monitor, :monitor_ids)
    rows = Map.get(monitor, :rows, [])

    if rows == [] do
      {%{monitor | selected: nil}, 0}
    else
      selected_index = min(index, length(rows) - 1)

      marked =
        Enum.with_index(rows, fn row, row_index ->
          Map.put(row, :selected?, row_index == selected_index)
        end)

      {%{monitor | rows: marked, selected: Enum.at(marked, selected_index)}, selected_index}
    end
  end

  # ---------------------------------------------------------------------------
  # Measure section
  # ---------------------------------------------------------------------------

  defp measure_source_ids(actor) do
    case Alplus.Measure.PublicEvidence.source_ids(actor) do
      {:ok, ids} -> ids
      _error -> []
    end
  end

  defp measure_section(projection, traffic_range) do
    %{pageviews: pageviews, visitors: visitors, trend: trend, top_pages: top_pages} = projection

    %{
      state:
        if(is_number(pageviews) and is_number(visitors) and (pageviews > 0 or visitors > 0),
          do: :ready,
          else: :empty
        ),
      pageviews: pageviews,
      visitors: visitors,
      trend: trend,
      top_pages: Enum.map(top_pages, &normalize_page/1),
      ranges: @traffic_ranges,
      range: traffic_range
    }
  end

  # ---------------------------------------------------------------------------
  # Remaining sections
  # ---------------------------------------------------------------------------

  defp normalize_history_percent(value) when is_number(value) and value >= 0 and value <= 1,
    do: Float.round(value * 100, 2)

  defp normalize_history_percent(value) when is_number(value), do: Float.round(value, 2)
  defp normalize_history_percent(_), do: nil

  defp observe(actor) do
    case Observe.list_public_issues_for_vendor(actor: actor) do
      {:ok, issues} ->
        data = %{state: if(issues == [], do: :empty, else: :ready), open_issues: length(issues)}
        if length(issues) == 100, do: Map.put(data, :open_issues_lower_bound, true), else: data

      _ ->
        %{state: :unavailable, open_issues: nil}
    end
  end

  defp status(slug) do
    case PublicPage.load(slug) do
      {:ok, snapshot} ->
        components =
          Enum.map(Map.get(snapshot, :components, []), fn component ->
            %{
              name: component.name,
              state: component.status,
              uptime: normalize_history_percent(component.uptime_percent),
              history:
                component.history
                |> List.wrap()
                |> Enum.map(fn point ->
                  point
                  |> Map.take([:day, :uptime])
                  |> Map.update(:uptime, nil, &normalize_history_percent/1)
                  |> Map.put(:state, day_state(point))
                end)
            }
          end)

        %{
          state: if(components == [], do: :empty, else: :ready),
          status: snapshot.status,
          components: components
        }

      {:error, :not_found} ->
        %{state: :empty, status: nil, components: []}
    end
  end

  # A public square carries the day's own state, so a day with downtime cannot
  # render as a healthy day. The vocabulary matches the public status page.
  @day_states [:up, :degraded, :down, :maintenance, :unknown]

  defp day_state(%{state: state}) when state in @day_states, do: state
  defp day_state(%{state: :operational}), do: :up
  defp day_state(%{state: state}) when state in [:partial_outage, :major_outage], do: :down
  defp day_state(%{uptime: uptime}) when is_number(uptime) and uptime >= 1.0, do: :up
  defp day_state(%{uptime: uptime}) when is_number(uptime) and uptime > 0, do: :degraded
  defp day_state(%{uptime: +0.0}), do: :down
  defp day_state(_point), do: :unknown

  defp changelog(resolved) do
    case ChangelogPublic.load_resolved_vendor(resolved, limit: @max_changelog_entries) do
      {:ok, %{entries: entries}} ->
        %{
          state: if(entries == [], do: :empty, else: :ready),
          entries: Enum.map(entries, &public_entry/1)
        }

      {:error, :not_found} ->
        %{state: :empty, entries: []}
    end
  end

  defp metrics(monitor, measure, observe) do
    %{
      monitor: %{
        value: uptime_headline(monitor[:headline]),
        response_time_ms: Map.get(monitor, :response_time_ms),
        visitors: nil
      },
      measure: %{
        value: format_number(measure.pageviews),
        visitors: format_number(measure.visitors)
      },
      observe: %{open_issues: observe.open_issues},
      monitor_history:
        monitor.history
        |> Enum.map(&Map.get(&1, :uptime))
        |> Enum.map(&normalize_history_percent/1)
        |> Enum.filter(&is_number/1)
    }
  end

  defp uptime_headline(%{uptime: uptime}) when is_number(uptime),
    do: "#{Float.round(uptime, 2)}%"

  defp uptime_headline(_), do: "Unavailable"

  defp format_number(nil), do: nil
  defp format_number(value) when is_integer(value), do: PackagePresenter.thousands(value)
  defp format_number(value) when is_float(value), do: PackagePresenter.thousands(round(value))

  defp public_entry(entry) do
    Map.take(entry, [:title, :slug, :published_at, :excerpt, :area, :version])
  end

  defp pageviews_count(page) do
    case Map.get(page, :pageviews) do
      value when is_number(value) ->
        value

      _ ->
        case Map.get(page, :count) do
          value when is_number(value) -> value
          _ -> nil
        end
    end
  end

  defp normalize_page(page) do
    page
    |> Map.put(:path, Map.get(page, :path) || Map.get(page, :value))
    |> Map.put(:pageviews, pageviews_count(page))
  end

  defp overall_state(sections) do
    states = Enum.map(sections, & &1.state)

    cond do
      :unavailable in states -> :partial
      :ready in states -> :ready
      :empty in states -> :empty
      true -> :unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # Empty and unavailable projections
  # ---------------------------------------------------------------------------

  defp empty_overview(state, selection) do
    spec = bucket_spec(selection.range)
    keys = bucket_keys(spec)

    hero = %{spec: spec, keys: keys, checks: %{}, rollups: %{}, traffic: %{}, issues: %{}}
    projection = overview(hero, selection.metric)

    %{
      projection
      | state: state,
        chart: %{projection.chart | state: state}
    }
  end

  defp empty(selection), do: blank(:empty, selection)
  defp unavailable(selection), do: blank(:unavailable, selection)

  defp blank(state, selection) do
    %{
      state: state,
      identity: %{name: nil, slug: nil},
      selection: %{selection | monitor: 0},
      overview: empty_overview(state, selection),
      metrics: %{
        monitor: %{value: "Unavailable", response_time_ms: nil, visitors: nil},
        measure: %{value: nil, visitors: nil},
        observe: %{open_issues: nil},
        monitor_history: []
      },
      monitor: %{
        state: state,
        rows: [],
        headline: %{total: 0, operational: 0},
        history: [],
        selected: nil
      },
      measure: %{
        state: state,
        pageviews: nil,
        visitors: nil,
        trend: [],
        top_pages: [],
        ranges: @traffic_ranges,
        range: selection.traffic_range
      },
      observe: %{state: state, open_issues: nil},
      status: %{state: state, status: nil, components: []},
      changelog: %{state: state, entries: []}
    }
  end
end
