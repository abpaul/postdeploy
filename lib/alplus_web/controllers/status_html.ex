defmodule AlplusWeb.StatusHTML do
  use AlplusWeb, :html

  import AlplusWeb.Status.Display

  embed_templates "status_html/*"

  @doc false
  def feed_xml(snapshot) do
    page = snapshot.public_page || snapshot.page

    items =
      snapshot
      |> feed_entries()
      |> Enum.sort_by(
        fn {at, _title, _body, _guid} -> DateTime.to_unix(at, :microsecond) end,
        :desc
      )
      |> Enum.map_join("", fn {at, title, body, guid} ->
        "<item><title>#{xml_escape(title)}</title>" <>
          "<description>#{xml_escape(body)}</description>" <>
          "<pubDate>#{DateTime.to_iso8601(at)}</pubDate>" <>
          "<guid isPermaLink=\"false\">#{xml_escape(guid)}</guid></item>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>#{xml_escape(page.title)}</title><link>/status/#{xml_escape(page.public_slug)}</link><description>#{xml_escape(page.title)}</description><lastBuildDate>#{DateTime.to_iso8601(snapshot.generated_at)}</lastBuildDate>#{items}</channel></rss>
    """
  end

  defp feed_entries(snapshot) do
    incidents =
      Enum.map(snapshot.incidents, fn incident ->
        {incident.published_at, "Incident: #{incident.title}", incident.body,
         "incident:#{incident.id}"}
      end)

    announcements =
      Enum.map(
        Map.get(snapshot, :announcement_history, Map.get(snapshot, :announcements, [])),
        fn announcement ->
          {announcement.published_at, "Announcement: #{announcement.title}", announcement.body,
           "announcement:#{announcement.id}"}
        end
      )

    maintenances =
      Enum.map(
        Map.get(snapshot, :maintenance_history, Map.get(snapshot, :maintenances, [])),
        fn maintenance ->
          body =
            maintenance.description || "#{maintenance_status_label(maintenance.status)} window"

          {maintenance.starts_at, "Maintenance: #{maintenance.title}", body,
           "maintenance:#{maintenance.id}"}
        end
      )

    incidents ++ announcements ++ maintenances
  end

  def public_changelog_path(%{public_page: %{public_slug: slug}}) when is_binary(slug),
    do: "/status/#{slug}/changelog"

  def public_changelog_path(_snapshot), do: nil

  def status_label(:operational), do: "All systems operational"
  def status_label(:degraded), do: "Degraded"
  def status_label(:partial_outage), do: "Partial outage"
  def status_label(:major_outage), do: "Major outage"
  def status_label(:maintenance), do: "Maintenance"
  def status_label(:up), do: "Operational"
  def status_label(:down), do: "Outage"
  def status_label(:partial), do: "Partial evidence"
  def status_label(:unknown), do: "No observations yet"

  @doc """
  The current state as one word for a dot-plus-word pill. The pill states the
  word; the heading beside it states the full sentence.
  """
  def status_word(:operational), do: "Operational"
  def status_word(:up), do: "Operational"
  def status_word(:degraded), do: "Degraded"
  def status_word(:partial_outage), do: "Partial outage"
  def status_word(:major_outage), do: "Major outage"
  def status_word(:down), do: "Outage"
  def status_word(:maintenance), do: "Maintenance"
  def status_word(:partial), do: "Partial evidence"
  def status_word(_unknown), do: "No data yet"

  def page_status_label(:operational), do: "All systems operational"
  def page_status_label(:degraded), do: "Some services are degraded"
  def page_status_label(:partial_outage), do: "Some services are unavailable"
  def page_status_label(:major_outage), do: "We are experiencing a major outage"
  def page_status_label(:maintenance), do: "Maintenance in progress"
  def page_status_label(status), do: status_label(status)

  @doc """
  The page's one answer, derived from open incidents and service state
  together. Open incidents win: a visitor who came because something broke
  reads how many things are broken before anything else. "All services are
  operational" is claimed only when every published service is measured and
  up; otherwise the unmeasured services are named as such.
  """
  def status_headline(snapshot) do
    open = open_incidents(snapshot)
    services = snapshot.services

    cond do
      length(open) == 1 ->
        "1 incident is open"

      open != [] ->
        "#{length(open)} incidents are open"

      services == [] ->
        "No services are published yet"

      snapshot.status == :operational and Enum.all?(services, &(&1.observed_days > 0)) ->
        "All services are operational"

      snapshot.status == :operational ->
        "Operational, but #{unmeasured_phrase(services)}"

      snapshot.status == :unknown ->
        String.capitalize(unmeasured_phrase(services))

      true ->
        page_status_label(snapshot.status)
    end
  end

  defp unmeasured_phrase(services) do
    case Enum.filter(services, &(&1.observed_days == 0)) do
      [] -> "some services are not measured yet"
      [one] -> "#{one.name} has no checks yet"
      many -> "#{length(many)} services have no checks yet"
    end
  end

  @doc "One short line under the headline: what to read next on this page."
  def status_lead(snapshot) do
    case open_incidents(snapshot) do
      [] -> "Each service below shows its state and its uptime over the last 90 days."
      [_one] -> "The incident and its latest update are below."
      _many -> "Each incident and its latest update are below."
    end
  end

  def state_class(:operational), do: "success"
  def state_class(:up), do: "success"
  def state_class(:degraded), do: "warning"
  def state_class(:partial_outage), do: "error"
  def state_class(:major_outage), do: "error"
  def state_class(:down), do: "error"
  def state_class(:maintenance), do: "info"
  def state_class(:unknown), do: "neutral"

  @doc "Health icon so status never reads by colour alone."
  def state_icon(state) when state in [:operational, :up], do: "hero-check-circle"
  def state_icon(:degraded), do: "hero-exclamation-triangle"
  def state_icon(state) when state in [:partial_outage, :major_outage, :down], do: "hero-x-circle"
  def state_icon(:maintenance), do: "hero-wrench-screwdriver"
  def state_icon(_unknown), do: "hero-question-mark-circle"

  @doc "The overall banner surface: the loudest element on the page."
  def banner_class(status) when status in [:operational],
    do: "border-status-live-border bg-status-live-bg text-status-live-ink"

  def banner_class(:degraded),
    do: "border-status-late-border bg-status-late-bg text-status-late-ink"

  def banner_class(status) when status in [:partial_outage, :major_outage],
    do: "border-status-error-border bg-status-error-bg text-status-error-ink"

  def banner_class(:maintenance),
    do: "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink"

  def banner_class(_unknown),
    do: "border-status-neutral-border bg-status-neutral-bg text-status-neutral-ink"

  @doc """
  The state dot inside the banner, in the same tone as the banner wash.

  It mirrors `banner_class/1` arm for arm so the dot never disagrees with the
  surface it sits on.
  """
  def banner_dot_class(:operational), do: "bg-status-live"
  def banner_dot_class(:degraded), do: "bg-status-late"

  def banner_dot_class(status) when status in [:partial_outage, :major_outage],
    do: "bg-status-error"

  def banner_dot_class(_neutral), do: "bg-status-neutral"

  def banner_icon(:operational), do: "hero-check-circle"
  def banner_icon(:degraded), do: "hero-exclamation-triangle"
  def banner_icon(:maintenance), do: "hero-wrench-screwdriver"
  def banner_icon(:unknown), do: "hero-question-mark-circle"
  def banner_icon(_outage), do: "hero-exclamation-circle"

  @doc """
  Solid fill for one day square in the 90-day uptime history, and for the dot
  beside a state word. Operational green, degraded amber, failure red,
  maintenance blue, and no evidence grey.
  """
  def bar_class(state) when state in [:operational, :up], do: "bg-status-live"
  def bar_class(:degraded), do: "bg-status-late"

  def bar_class(state) when state in [:partial_outage, :major_outage, :down],
    do: "bg-status-error"

  def bar_class(:maintenance), do: "bg-status-info"
  def bar_class(:partial), do: "bg-status-late"
  def bar_class(:unknown), do: "bg-status-neutral"

  @doc "Literal text classes so Tailwind sees every candidate."
  def state_text_class(state) when state in [:operational, :up], do: "text-status-live-ink"
  def state_text_class(:degraded), do: "text-status-late-ink"

  def state_text_class(state) when state in [:partial_outage, :major_outage, :down],
    do: "text-status-error-ink"

  def state_text_class(:maintenance), do: "text-status-neutral-ink"
  def state_text_class(:partial), do: "text-status-late-ink"
  def state_text_class(_unknown), do: "text-text-tertiary"

  @doc """
  One-sentence uptime evidence that does not depend on the graphic, and never
  hides its denominator: the percentage is stated over the days that were
  observed, and the days with no checks are counted separately from downtime.
  """
  def uptime_summary(service) do
    observed = Map.get(service, :observed_days, 0)
    no_data = Map.get(service, :no_data_days, 0)
    window = Map.get(service, :window_days, 90)

    case service.uptime_percent do
      nil when observed == 0 ->
        "No checks in the last #{window} days."

      nil ->
        "Not enough data for a percentage: checks on #{day_count(observed)} of the last #{window}."

      percent ->
        down_days = Enum.count(service.history, &(&1.downtime > 0))

        "#{format_percent(percent)}% uptime across #{day_count(observed)} observed. #{no_data_phrase(no_data)} #{downtime_phrase(down_days)}."
    end
  end

  @doc "The uptime value cell: the percentage, or the reason there is none."
  def uptime_value(service) do
    case service.uptime_percent do
      nil -> "Not enough data"
      percent -> "#{format_percent(percent)}%"
    end
  end

  @doc "The coverage clause under a service: which of the 90 days were observed."
  def coverage_words(service) do
    observed = Map.get(service, :observed_days, 0)
    window = Map.get(service, :window_days, 90)

    case observed do
      0 -> "No complete #{window}-day record, no checks yet"
      ^window -> "Observed on every one of the last #{window} days"
      _ -> "Observed on #{observed} of the last #{window} days"
    end
  end

  defp day_count(1), do: "1 day"
  defp day_count(days), do: "#{days} days"

  defp no_data_phrase(0), do: "Every day had checks."
  defp no_data_phrase(1), do: "1 day had no checks."
  defp no_data_phrase(days), do: "#{days} days had no checks."

  defp downtime_phrase(0), do: "No downtime was recorded"
  defp downtime_phrase(1), do: "Downtime on 1 day"
  defp downtime_phrase(days), do: "Downtime on #{days} days"

  defp format_percent(percent) do
    if percent == trunc(percent), do: trunc(percent), else: percent
  end

  @doc """
  Inline style for one embed status chip: dot + word, pill-shaped. The embed
  route's CSP blocks app.css (`default-src 'none'; style-src 'unsafe-inline'`),
  so the embed inlines v3 token values as hex, like the mail template. When a
  token moves in tokens.css, move it here too. The error tone is fixed and
  never remapped by the embed's dark-mode block, by design.
  """
  def embed_chip_style(tone) do
    "display:inline-flex;align-items:center;gap:.4rem;border-radius:999px;min-height:1.75rem;" <>
      "padding:.3rem .7rem;font-weight:600;font-size:.8125rem;white-space:nowrap;" <>
      embed_tone_style(tone)
  end

  defp embed_tone_style("success"),
    do:
      "color:var(--pd-chip-live-ink);background:var(--pd-chip-live-bg);border:1px solid var(--pd-chip-live-border)"

  defp embed_tone_style("warning"),
    do:
      "color:var(--pd-chip-late-ink);background:var(--pd-chip-late-bg);border:1px solid var(--pd-chip-late-border)"

  defp embed_tone_style("error"),
    do: "color:#B42318;background:#FDECEA;border:1px solid #F3D2CE"

  defp embed_tone_style("info"),
    do:
      "color:var(--pd-chip-info-ink);background:var(--pd-chip-info-bg);border:1px solid var(--pd-chip-info-border)"

  defp embed_tone_style(_neutral),
    do:
      "color:var(--pd-chip-neutral-ink);background:var(--pd-chip-neutral-bg);border:1px solid var(--pd-chip-neutral-border)"

  @doc "Solid dot fill for one embed state chip or uptime tick, hex-inlined for the CSP-locked embed."
  def embed_dot_color("success"), do: "#00B140"
  def embed_dot_color("warning"), do: "#E8960C"
  def embed_dot_color("error"), do: "#D92D20"
  def embed_dot_color("info"), do: "#2E62E8"
  def embed_dot_color(_neutral), do: "#A9B0A0"

  @doc "The last 14 recorded days for the embed's compact uptime tick strip."
  def embed_ticks(history) when is_list(history), do: Enum.take(history, -14)
  def embed_ticks(_history), do: []

  @doc "One line of coverage for the embed: what the 14-day strip rests on."
  def embed_coverage(component) do
    ticks = embed_ticks(Map.get(component, :history, []))
    observed = Enum.count(ticks, &Map.get(&1, :evidence?, false))

    case {length(ticks), observed} do
      {0, _} -> nil
      {days, 0} -> "No checks in the last #{days} days"
      {days, some} when some == days -> "Checks on every one of the last #{days} days"
      {days, some} -> "Checks on #{some} of the last #{days} days"
    end
  end

  @doc "The embed's impact line for one open incident."
  def embed_impact(%{affected_services: []}), do: "Impact assessment in progress"

  def embed_impact(%{affected_services: services}),
    do: "Affected: " <> Enum.map_join(services, ", ", &(&1.name || "Service"))

  @doc """
  One tick's fill for the embed's compact uptime strip. Uses the `--pd-tick-*`
  variables so healthy/degraded ticks can shift for dark mode; the failing
  fill is a literal hex, never a variable, so it stays red in both themes.
  """
  def embed_tick_color(state) when state in [:operational, :up], do: "var(--pd-tick-live)"
  def embed_tick_color(:degraded), do: "var(--pd-tick-late)"
  def embed_tick_color(:partial), do: "var(--pd-tick-late)"

  def embed_tick_color(state) when state in [:partial_outage, :major_outage, :down],
    do: "#D92D20"

  def embed_tick_color(_maintenance_or_unknown), do: "var(--pd-tick-neutral)"

  @doc "One day's state as plain text for the keyboard-readable daily list."
  def day_detail(%{state: :partial} = day), do: "Partial evidence, #{daily_evidence_detail(day)}"

  def day_detail(%{state: :unknown} = day), do: "No data, #{daily_evidence_detail(day)}"

  def day_detail(day) do
    [
      status_label(day.state),
      uptime_detail(day),
      downtime_detail(day),
      daily_evidence_detail(day)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp downtime_detail(%{downtime: downtime}) when downtime > 0,
    do: "#{downtime_label(downtime)} down"

  defp downtime_detail(_day), do: nil

  defp uptime_detail(%{uptime: uptime}) when is_number(uptime),
    do: "#{Float.round(uptime * 100, 2)}% uptime"

  defp uptime_detail(_day), do: nil

  # Public: the same words the daily table prints, for the embed's summary.
  def daily_evidence_detail(day) do
    monitored =
      duration_label(Map.get(day, :monitored_microseconds, Map.get(day, :monitored, 0)))

    checks = Map.get(day, :check_count, 0)
    incidents = Map.get(day, :incident_count, 0)
    pauses = Map.get(day, :pause_count, 0)
    coverage = if checks > 0, do: "#{checks} checks", else: "no checks"
    partial = if Map.get(day, :partial?, false), do: ", partial today", else: ""
    "monitored #{monitored}, #{incidents} incidents, #{pauses} pauses, #{coverage}#{partial}"
  end

  defp duration_label(microseconds) when is_integer(microseconds) do
    downtime_label(microseconds)
  end

  defp duration_label(_), do: "not available"

  defp downtime_label(microseconds) do
    minutes = div(microseconds, 60_000_000)

    cond do
      minutes >= 60 -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
      minutes >= 1 -> "#{minutes}m"
      true -> "under a minute"
    end
  end

  def open_incidents(snapshot), do: Enum.filter(snapshot.incidents, &(&1.status == "open"))

  def active_maintenances(snapshot),
    do: Enum.filter(snapshot.maintenances, &(&1.status == "active"))

  def upcoming_maintenances(snapshot),
    do: Enum.filter(snapshot.maintenances, &(&1.status == "scheduled"))

  def update_kind_label("recovery"), do: "Recovered"
  def update_kind_label("report"), do: "Reported"
  def update_kind_label(_note), do: "Update"

  def update_kind_class("recovery"),
    do: "border-status-live-border bg-status-live-bg text-status-live-ink"

  def update_kind_class(_note),
    do: "border-border-default bg-surface-sunken text-text-secondary"

  @doc """
  The incident report and its published updates as one chronological
  timeline: the report first, then every update, oldest to newest.
  """
  def incident_timeline(incident) do
    report = %{body: incident.body, kind: "report", inserted_at: incident.published_at}
    [report | incident.updates]
  end

  def update_headline(%{kind: "report"}), do: "Reported"
  def update_headline(_update), do: "Latest update"

  def earlier_updates_label(1), do: "Show 1 earlier update"
  def earlier_updates_label(count), do: "Show #{count} earlier updates"

  @doc "Incident logs use absolute UTC times, never elapsed phrasing."
  def absolute_utc(at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  def machine_time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def machine_time(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)

  attr :at, :any, required: true
  attr :class, :string, default: "text-data tabular-nums text-text-tertiary"

  def status_time(assigns) do
    ~H"""
    <time
      datetime={machine_time(@at)}
      data-status-time={machine_time(@at)}
      class={@class}
    >
      {absolute_utc(@at)}
    </time>
    """
  end

  def history_months(history) do
    history
    |> Enum.group_by(fn day -> {day.day.year, day.day.month} end)
    |> Enum.sort_by(fn {{year, month}, _days} -> {year, month} end, :desc)
    |> Enum.map(fn {{year, month}, days} ->
      {Calendar.strftime(Date.new!(year, month, 1), "%B %Y"), Enum.sort_by(days, & &1.day)}
    end)
  end

  def incident_history_months(snapshot) do
    snapshot.incidents
    |> Enum.reject(&(&1.status == "open"))
    |> Enum.group_by(fn incident ->
      at = incident.published_at || incident.closed_at || DateTime.utc_now()
      {at.year, at.month}
    end)
    |> Enum.sort_by(fn {{year, month}, _incidents} -> {year, month} end, :desc)
    |> Enum.map(fn {{year, month}, incidents} ->
      entries = Enum.sort_by(incidents, & &1.published_at, {:desc, DateTime})
      {Calendar.strftime(Date.new!(year, month, 1), "%B %Y"), entries}
    end)
  end

  attr :maintenances, :list, required: true

  def maintenance_list(assigns) do
    ~H"""
    <div class="divide-y divide-border-subtle">
      <article :for={maintenance <- @maintenances} class="px-6 py-5">
        <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1.5">
          <h3 class="min-w-0 break-words font-public text-label font-semibold text-text-primary">
            {maintenance.title}
          </h3>
          <.status_badge
            tone={maintenance_status_tone(maintenance.status)}
            label={maintenance_status_label(maintenance.status)}
            size={:public}
          />
        </div>
        <p
          :if={maintenance.description}
          class="mt-2 max-w-measure whitespace-pre-line break-words text-body text-text-secondary"
        >
          {maintenance.description}
        </p>
        <p class="mt-2.5 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 font-mono text-data tabular-nums text-text-tertiary">
          <.status_time at={maintenance.starts_at} class="font-mono tabular-nums" />
          <span>until</span>
          <.status_time at={maintenance.ends_at} class="font-mono tabular-nums" />
        </p>
      </article>
    </div>
    """
  end

  @doc """
  One active incident: title, a single stage badge, affected services,
  the newest update expanded, the next-update target, and the earlier
  entries (down to the original report) behind one disclosure.
  """
  attr :incident, :map, required: true

  def incident_article(assigns) do
    [latest | earlier] = Enum.reverse(incident_timeline(assigns.incident))

    assigns =
      assigns
      |> assign(:latest, latest)
      |> assign(:earlier, earlier)

    ~H"""
    <article
      id={"status-incident-#{@incident.id}"}
      class="min-w-0 rounded-frame border border-border-public bg-surface-raised px-6 py-6"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2">
        <h3 class="min-w-0 break-words font-public text-heading-03 font-semibold text-text-primary">
          {@incident.title}
        </h3>
        <.status_badge
          tone={stage_tone(@incident.stage)}
          label={incident_stage_label(@incident.stage)}
          size={:public}
        />
      </div>
      <%!-- Impact is stated as a fact or as an assessment in progress. A bare
            "Being confirmed" read as internal triage (audit 2026-08-30). --%>
      <p class="mt-3 flex min-w-0 flex-wrap items-center gap-2">
        <span
          :if={@incident.affected_services != []}
          class="text-label font-semibold text-text-tertiary"
        >
          Affected
        </span>
        <span
          :for={service <- @incident.affected_services}
          class="min-w-0 break-words rounded-dot border border-border-public bg-surface-sunken px-3 py-1 text-label font-semibold text-text-secondary"
        >
          {service.name || "Service"}
        </span>
        <span
          :if={@incident.affected_services == []}
          class="text-label font-medium text-text-secondary"
        >
          Impact assessment in progress
        </span>
      </p>
      <div class="mt-5">
        <p class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
          <span class="text-label font-semibold text-text-primary">{update_headline(@latest)}</span>
          <.status_time at={@latest.inserted_at} class="font-mono text-data text-text-tertiary" />
        </p>
        <p class="mt-1.5 max-w-measure whitespace-pre-line break-words text-body text-text-secondary">
          {@latest.body}
        </p>
      </div>
      <p class="mt-4 text-label font-medium text-text-tertiary">
        <span :if={@incident.next_update_at}>
          Next update by
          <.status_time at={@incident.next_update_at} class="font-mono text-data text-text-tertiary" />
        </span>
        <span :if={is_nil(@incident.next_update_at)}>
          We will update this page when we confirm the impact.
        </span>
      </p>
      <details :if={@earlier != []} class="mt-5 border-t border-border-subtle pt-4">
        <summary class="inline-flex min-h-target-min cursor-pointer items-center rounded-dot text-label font-semibold text-text-secondary hover:text-text-primary">
          {earlier_updates_label(length(@earlier))}
        </summary>
        <ol class="mt-4 space-y-5 border-l border-border-public pl-4">
          <li :for={update <- @earlier}>
            <p class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
              <span class={[
                "rounded-dot border px-2.5 py-0.5 text-chip font-semibold",
                update_kind_class(update.kind)
              ]}>
                {update_kind_label(update.kind)}
              </span>
              <.status_time at={update.inserted_at} class="font-mono text-data text-text-tertiary" />
            </p>
            <p class="mt-1.5 max-w-measure whitespace-pre-line break-words text-body text-text-secondary">
              {update.body}
            </p>
          </li>
        </ol>
      </details>
    </article>
    """
  end

  @doc """
  One service's status row: name, the 90-day square strip, and the uptime
  percent. The strip is decoration for a reader that cannot see it, so it is
  hidden from assistive technology and followed by the same 90 days as a
  table with a caption, units, and the window. The visible daily record adds
  downtime, checks, incidents, and pauses for each day.
  """
  attr :id, :string, required: true
  attr :service, :map, required: true

  def service_row(assigns) do
    ~H"""
    <article id={@id} class="min-w-0 px-6 py-6" aria-labelledby={"#{@id}-name"}>
      <div class="grid min-w-0 grid-cols-1 gap-x-4 gap-y-2.5 sm:grid-cols-[minmax(0,124px)_minmax(0,1fr)_minmax(64px,max-content)] sm:items-center lg:grid-cols-[minmax(0,220px)_minmax(0,1fr)_minmax(64px,max-content)]">
        <h3
          id={"#{@id}-name"}
          title={@service.name}
          class="flex min-w-0 items-center gap-2 font-public text-label font-semibold text-text-primary"
        >
          <span
            class={["size-[7px] shrink-0 rounded-dot", bar_class(@service.status)]}
            aria-hidden="true"
          />
          <span class="min-w-0 truncate">{@service.name}</span>
          <span class="sr-only">, {status_word(@service.status)}</span>
        </h3>
        <div class="flex h-4 min-w-0 items-stretch gap-[1.5px] overflow-hidden" aria-hidden="true">
          <span
            :for={day <- @service.history}
            class={["min-w-0 flex-1 rounded-tick", bar_class(day.state)]}
          />
        </div>
        <p class="font-mono text-data tabular-nums text-text-secondary sm:text-right">
          {uptime_value(@service)}
        </p>
      </div>

      <div
        class="mt-2.5 flex min-w-0 justify-between gap-3 font-mono text-data font-medium text-text-tertiary"
        aria-hidden="true"
      >
        <span>90 days ago</span>
        <span>today</span>
      </div>

      <%!-- The one accessible summary of the strip: state, uptime, and the
            days it rests on. The 90 daily rows live only inside the
            disclosure below, so a visitor is never walked through 180 rows to
            reach the next service (audit 2026-08-30). --%>
      <p
        id={"#{@id}-summary"}
        class="mt-2.5 max-w-measure text-pretty text-label font-medium text-text-secondary"
      >
        {uptime_summary(@service)}
      </p>
      <p
        :if={@service.description}
        class="mt-2 max-w-measure text-pretty text-body text-text-secondary"
      >
        {@service.description}
      </p>

      <details :if={@service.history != []} class="mt-3">
        <summary class="inline-flex min-h-target-min cursor-pointer items-center rounded-dot text-label font-semibold text-text-secondary hover:text-text-primary">
          View daily uptime
        </summary>
        <p class="mt-2 max-w-measure text-label font-medium text-text-secondary">
          One row per day, oldest first. States: <span class="inline-flex items-center gap-1 text-status-live-ink"><.icon name="hero-check-circle" class="size-3" />Healthy</span>, <span class="inline-flex items-center gap-1 text-status-late-ink"><.icon name="hero-exclamation-triangle" class="size-3" />Degraded</span>, <span class="inline-flex items-center gap-1 text-status-error-ink"><.icon name="hero-x-circle" class="size-3" />Incident</span>, <span class="inline-flex items-center gap-1 text-status-info-ink"><.icon name="hero-pause-circle" class="size-3" />Maintenance</span>, <span class="inline-flex items-center gap-1 text-status-late-ink"><.icon name="hero-question-mark-circle" class="size-3" />Partial evidence</span>.
        </p>
        <div class="mt-4 overflow-x-auto">
          <table class="w-full text-left text-label tabular-nums">
            <caption class="sr-only">
              Daily uptime for {@service.name}, in percent, last 90 days, oldest first.
            </caption>
            <thead>
              <tr class="border-b border-border-public text-text-tertiary">
                <th scope="col" class="py-1.5 pr-3 font-semibold">Day</th>
                <th scope="col" class="py-1.5 pr-3 font-semibold">State</th>
                <th scope="col" class="py-1.5 pr-3 font-semibold">Uptime (%)</th>
                <th scope="col" class="py-1.5 font-semibold">Evidence</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @service.history} class="border-b border-border-subtle">
                <th
                  scope="row"
                  class="py-1.5 pr-3 font-mono text-data font-medium text-text-secondary"
                >
                  {Date.to_iso8601(day.day)}
                </th>
                <td class={["py-1.5 pr-3 font-medium", state_text_class(day.state)]}>
                  {day_state_word(day)}
                </td>
                <td class="py-1.5 pr-3 font-mono text-data text-text-secondary">
                  {day_uptime_cell(day)}
                </td>
                <td class="py-1.5 text-text-secondary">{daily_evidence_detail(day)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
      <.service_reliability service={@service} />
    </article>
    """
  end

  defp day_state_word(%{state: :partial}), do: "Partial evidence"
  defp day_state_word(%{state: :unknown}), do: "No data"
  defp day_state_word(%{state: state}), do: status_label(state)

  defp day_uptime_cell(%{uptime: uptime}) when is_number(uptime),
    do: Float.round(uptime * 100, 2)

  defp day_uptime_cell(_day), do: "No data"

  attr :service, :map, required: true

  def service_reliability(assigns) do
    ~H"""
    <section
      :if={@service.reliability}
      class="mt-4 border-t border-border-default pt-4"
      aria-label="Reliability objective"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h4 class="text-label font-medium text-text-primary">Reliability objective</h4>
        <span class="text-data tabular-nums text-text-secondary">
          Target {status_slo_percent(@service.reliability.target)}
        </span>
      </div>
      <p
        :if={@service.reliability.budget.evidence_state != :ready}
        class="mt-2 text-data text-text-secondary"
      >
        Not enough evidence to report attainment or burn rate yet.
      </p>
      <dl
        :if={@service.reliability.budget.evidence_state == :ready}
        class="mt-2 grid gap-x-5 gap-y-1 text-label tabular-nums sm:grid-cols-2 lg:grid-cols-5"
      >
        <div>
          <dt class="text-text-tertiary">Attainment</dt><dd class="font-semibold text-text-primary">
            {status_slo_percent(@service.reliability.budget.attainment)}
          </dd>
        </div>
        <div>
          <dt class="text-text-tertiary">Allowed downtime</dt><dd class="font-semibold text-text-primary">
            {status_duration(@service.reliability.budget.allowed_downtime_microseconds)}
          </dd>
        </div>
        <div>
          <dt class="text-text-tertiary">Spent</dt><dd class="font-semibold text-text-primary">
            {status_duration(@service.reliability.budget.spent_downtime_microseconds)}
          </dd>
        </div>
        <div>
          <dt class="text-text-tertiary">Budget left</dt><dd class="font-semibold text-text-primary">
            {status_duration(@service.reliability.budget.remaining_downtime_microseconds)}
          </dd>
        </div>
        <div>
          <dt class="text-text-tertiary">
            Burn, last {@service.reliability.budget.burn_window_days} days
          </dt><dd class={budget_value_class(@service.reliability.budget)}>
            {status_burn(@service.reliability.budget.burn_rate)}
          </dd>
        </div>
      </dl>
      <p class="mt-2 text-label text-text-tertiary">
        Budget month ends {Calendar.strftime(@service.reliability.budget.month_end, "%d %b %Y")}. Alert threshold: {status_burn(
          @service.reliability.budget.alert_threshold
        )} burn.
      </p>
    </section>
    """
  end

  defp status_slo_percent(nil), do: "Not enough evidence"

  defp status_slo_percent(value) when is_number(value) do
    value = Float.round(value * 100, 4)
    if value == trunc(value), do: "#{trunc(value)}%", else: "#{value}%"
  end

  defp status_duration(0), do: "0 seconds"

  defp status_duration(microseconds) when is_integer(microseconds) do
    seconds = div(microseconds, 1_000_000)

    cond do
      seconds >= 86_400 -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      seconds >= 60 -> "#{div(seconds, 60)}m"
      true -> "under a minute"
    end
  end

  defp status_duration(_value), do: "Not available"

  defp status_burn(nil), do: "Not available"
  defp status_burn(value) when is_number(value), do: "#{Float.round(value, 2)}x"

  defp budget_value_class(%{state: state}) when state in [:alert, :exhausted],
    do: "font-semibold text-status-error-ink"

  defp budget_value_class(_budget), do: "font-semibold text-text-primary"

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
