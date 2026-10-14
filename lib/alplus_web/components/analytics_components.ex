defmodule AlplusWeb.AnalyticsComponents do
  @moduledoc """
  The shared pieces every product-analytics screen draws (ADR 0007).

  Warning: every event name, distinct ID, property name, and property value
  rendered here came from a customer's own application and is untrusted.
  HEEx escapes every interpolated value, so they are rendered as text and
  never as markup. Do not introduce `raw/1` anywhere in this module.
  """

  use AlplusWeb, :html

  import AlplusWeb.ConsoleComponents
  import AlplusWeb.DataDisplayComponents

  alias AlplusWeb.Marketing.PackagePresenter

  @doc "Formats a count with thousands separators."
  def count(nil), do: "0"
  def count(value) when is_integer(value), do: PackagePresenter.thousands(value)
  def count(value), do: to_string(value)

  @doc """
  Formats a rate as a percentage with one decimal.

  A rate with no denominator reads as an em dash replacement in words, never
  as `0%`: nobody entered, so there is no rate to report.
  """
  def percent(nil), do: "No data"

  def percent(value) when is_number(value),
    do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}%"

  @doc "Formats a difference between two rates in percentage points."
  def points(nil), do: "No data"

  def points(value) when is_number(value) do
    sign = if value >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(value * 1.0, decimals: 1)} percentage points"
  end

  @doc "A short UTC timestamp for a table cell."
  def at(nil), do: "Never"
  def at(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  @doc "A clock time, for the live feed."
  def clock(%DateTime{} = value), do: Calendar.strftime(value, "%H:%M:%S")

  @doc """
  The one-line reminder that unique users are supplied identifiers.

  It appears anywhere a user count does, because the number means something
  different from what a reader assumes on first sight.
  """
  def users_help, do: "Counted from the distinct IDs your application sends."

  attr :id, :string, default: "analytics-app-select"
  attr :sources, :list, required: true
  attr :source_id, :string, default: nil

  @doc """
  The App picker.

  One project holds one write key per application, and they share one event
  pool so a person who signs up on the web and acts in the app is one person
  in a funnel. This control narrows a screen to one of them.

  It draws nothing for a project with a single app, where the choice would
  be a control with one answer.
  """
  def app_select(assigns) do
    assigns = assign(assigns, :labels, source_labels(assigns.sources))

    ~H"""
    <form :if={length(@sources) > 1} id={@id} phx-change="pick_app" class="flex items-center gap-2">
      <label for={"#{@id}-field"} class="text-label text-text-secondary">App</label>
      <select
        id={"#{@id}-field"}
        name="source"
        class="h-control-sm rounded-control border border-border-control bg-surface-raised px-2 text-ui text-text-primary"
      >
        <option value="" selected={is_nil(@source_id)}>All apps</option>
        <option :for={source <- @sources} value={source.id} selected={source.id == @source_id}>
          {Map.fetch!(@labels, source.id)}
        </option>
      </select>
    </form>
    """
  end

  @doc "The label one app carries in the picker and in a screen's title."
  def source_label(sources, source_id) do
    Map.get(source_labels(sources), source_id)
  end

  # Two apps may share a name across environments, so the environment only
  # appears when it is what tells them apart.
  defp source_labels(sources) do
    duplicated =
      sources
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Map.new()

    Map.new(sources, fn source ->
      label =
        if Map.has_key?(duplicated, source.name),
          do: "#{source.name} (#{source.environment})",
          else: source.name

      {source.id, label}
    end)
  end

  attr :id, :string, required: true
  attr :series, :list, required: true
  attr :window, :string, required: true
  attr :metric, :atom, default: :events, values: [:events, :users]
  attr :title, :string, default: "Event activity"

  @doc "The event-activity chart. Buckets with no events are measured zeros."
  def activity_chart(assigns) do
    assigns = assign(assigns, :bars, bars(assigns.series, assigns.metric))

    ~H"""
    <div :if={@bars == []} class="rounded-control border border-dashed border-border-control p-4">
      <p class="text-body text-text-secondary">No events in this range yet.</p>
    </div>

    <div :if={@bars != []} class="min-w-0 overflow-hidden">
      <.data_display
        id={@id}
        title={@title}
        kind={:bucket_bar}
        variant={:full}
        data={@bars}
        unit={unit_word(@metric)}
        plot_height={:tall}
        table_columns={["When", String.capitalize(unit_word(@metric))]}
        summary={"#{String.capitalize(unit_word(@metric))} per #{bucket_word(@window)}, #{window_words(@window)} (UTC)."}
        description={"#{String.capitalize(unit_word(@metric))} per bucket, starting at zero."}
      />
    </div>
    """
  end

  defp bars(series, metric) do
    max_value = series |> Enum.map(&Map.fetch!(&1, metric)) |> Enum.max(fn -> 1 end) |> max(1)

    Enum.map(series, fn point ->
      value = Map.fetch!(point, metric)
      label = at(point.at)

      %{
        id: DateTime.to_iso8601(point.at),
        label: axis_label(point.at),
        value: value,
        height: value / max_value * 100,
        tone: if(value > 0, do: "brand", else: "neutral"),
        tooltip: "#{label}, #{count(value)} #{unit_word(metric)}",
        aria_label: "#{label}, #{count(value)} #{unit_word(metric)}",
        table_cells: [label, count(value)]
      }
    end)
  end

  defp axis_label(%DateTime{} = at), do: Calendar.strftime(at, "%m-%d %H:%M")

  defp unit_word(:events), do: "events"
  defp unit_word(:users), do: "users"

  defp bucket_word("24h"), do: "hour"
  defp bucket_word("90d"), do: "week"
  defp bucket_word(_window), do: "day"

  @doc "The human phrase for a window key."
  def window_words("24h"), do: "last 24 hours"
  def window_words("7d"), do: "last 7 days"
  def window_words("30d"), do: "last 30 days"
  def window_words("90d"), do: "last 90 days"
  def window_words(window), do: window

  attr :id, :string, required: true
  attr :points, :list, required: true, doc: "one %{at, events} per bucket, oldest first"
  attr :label, :string, required: true

  @doc """
  The per-event trend cell in the explorer: a compact tick strip.

  It carries no axis and no numbers. The count beside it is the number; this
  says whether it is arriving steadily, in one burst, or stopped.
  """
  def sparkline(assigns) do
    assigns = assign(assigns, :ticks, ticks(assigns.points))

    ~H"""
    <span :if={@ticks == []} class="text-caption text-text-tertiary">No events</span>

    <.data_display
      :if={@ticks != []}
      id={@id}
      title={"#{@label} trend"}
      heading={:assistive}
      kind={:ticks}
      variant={:compact}
      data={@ticks}
      unit="events"
      summary={"#{@label} over the range, oldest first."}
    />
    """
  end

  # The compact display caps its own tick count, so hand it the most recent
  # buckets rather than letting it drop the newest ones.
  @sparkline_buckets 14

  defp ticks(points) do
    points = Enum.take(points, -@sparkline_buckets)
    max_value = points |> Enum.map(& &1.events) |> Enum.max(fn -> 1 end) |> max(1)

    Enum.map(points, fn point ->
      %{
        id: DateTime.to_iso8601(point.at),
        label: at(point.at),
        value: point.events,
        height: point.events / max_value * 100,
        tone: if(point.events > 0, do: "brand", else: "neutral"),
        tooltip: "#{at(point.at)}, #{count(point.events)} events",
        aria_label: "#{at(point.at)}, #{count(point.events)} events"
      }
    end)
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :class, :any, default: nil

  @doc """
  One funnel: a bar per step with its user count and both conversion rates.

  The largest drop is marked, and marked only. It is the number the reader
  came for; whether it is bad depends on the product, and this component
  does not know.
  """
  def funnel_steps(assigns) do
    ~H"""
    <div id={@id} class={["min-w-0", @class]}>
      <ol class="grid gap-2">
        <li
          :for={{step, index} <- Enum.with_index(@entry.steps)}
          class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1"
        >
          <div class="min-w-0">
            <p class="truncate font-mono text-data text-text-primary">{step.event_name}</p>
            <div
              aria-hidden="true"
              class="mt-1 h-2 rounded-dot bg-chart-p50"
              style={"width: #{bar_width(step.overall_rate)}%"}
            >
            </div>
          </div>
          <div class="text-right">
            <p class="text-data-strong text-text-primary">{count(step.users)}</p>
            <p class="text-caption text-text-secondary">{percent(step.overall_rate)}</p>
          </div>
          <p
            :if={index > 0}
            class={[
              "col-span-2 text-caption",
              step.event_name == @entry.largest_drop_event && "text-status-late-ink",
              step.event_name != @entry.largest_drop_event && "text-text-tertiary"
            ]}
          >
            {step_line(step, @entry)}
          </p>
        </li>
      </ol>
    </div>
    """
  end

  defp bar_width(nil), do: 0
  defp bar_width(rate), do: max(rate, 0.5)

  defp step_line(step, entry) do
    base = "#{percent(step.step_rate)} of the previous step, #{count(step.lost)} did not continue"

    if step.event_name == entry.largest_drop_event,
      do: base <> ". Largest drop in this funnel.",
      else: base
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :property, :string, required: true
  attr :total, :integer, default: nil

  @doc "A property breakdown table: value, events, users, share."
  def breakdown_table(assigns) do
    assigns =
      assign_new(assigns, :computed_total, fn ->
        assigns.total || Enum.sum(Enum.map(assigns.rows, & &1.events))
      end)

    ~H"""
    <table :if={@rows != []} id={@id} class="w-full min-w-0 table-fixed">
      <caption class="sr-only">Breakdown of {@property}</caption>
      <thead>
        <tr class="border-b border-border-default text-left text-caption text-text-tertiary">
          <th scope="col" class="px-5 py-2 font-normal">{@property}</th>
          <th scope="col" class="w-24 px-5 py-2 text-right font-normal">Events</th>
          <th scope="col" class="w-24 px-5 py-2 text-right font-normal">Users</th>
          <th scope="col" class="w-20 px-5 py-2 text-right font-normal">Share</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-border-subtle">
        <tr :for={row <- @rows}>
          <td class="truncate px-5 py-2.5 font-mono text-data text-text-primary">{row.value}</td>
          <td class="px-5 py-2.5 text-right text-data text-text-primary">{count(row.events)}</td>
          <td class="px-5 py-2.5 text-right text-data text-text-secondary">
            {if row.users, do: count(row.users), else: "Not counted"}
          </td>
          <td class="px-5 py-2.5 text-right text-data text-text-secondary">
            {percent(share(row.events, @computed_total))}
          </td>
        </tr>
      </tbody>
    </table>

    <.empty_state
      :if={@rows == []}
      id={"#{@id}-empty"}
      title="No values in this range"
      description={"No event in this range carried a #{@property} property."}
    />
    """
  end

  defp share(_events, 0), do: nil
  defp share(_events, nil), do: nil
  defp share(events, total), do: events * 100 / total

  attr :id, :string, required: true
  attr :properties, :map, required: true

  @doc """
  One event's properties, as text.

  Every name and value is interpolated, so HEEx escapes it. A property whose
  value is `<script>` renders those characters and runs nothing.
  """
  def property_list(assigns) do
    ~H"""
    <dl :if={map_size(@properties) > 0} id={@id} class="flex flex-wrap gap-x-3 gap-y-1">
      <div :for={{key, value} <- Enum.sort(@properties)} class="flex min-w-0 gap-1">
        <dt class="font-mono text-caption text-text-tertiary">{key}</dt>
        <dd class="truncate font-mono text-caption text-text-secondary">{display(value)}</dd>
      </div>
    </dl>
    """
  end

  defp display(value) when is_binary(value), do: value
  defp display(true), do: "true"
  defp display(false), do: "false"
  defp display(value) when is_number(value), do: to_string(value)
  defp display(value), do: inspect(value)
end
