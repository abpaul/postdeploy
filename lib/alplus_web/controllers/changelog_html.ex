defmodule AlplusWeb.ChangelogHTML do
  @moduledoc "Helpers for the public Changelog templates and RSS feed."

  use AlplusWeb, :html

  import AlplusWeb.MarketingComponents

  embed_templates "changelog_html/*"

  attr :first_party?, :boolean, required: true
  attr :postdeploy_owned?, :boolean, required: true
  attr :available_areas, :list, required: true
  attr :filters, :map, required: true
  attr :query_path, :string, required: true
  attr :canonical_path, :string, required: true
  attr :public_page, :map, required: true
  attr :rss_path, :string, required: true
  attr :json_path, :string, required: true
  attr :entries, :list, required: true
  attr :changelog_path, :string, required: true
  attr :pagination, :map, required: true

  @doc """
  The shared changelog body: the filter band, the entry feed, the pager, and
  the footer. Both arms render the same bands. The marketing arm wraps them in
  the site chrome; the tenant arm wraps them in the project masthead.

  Every published update is one row of the same feed, newest first. There is
  no larger card for the newest one: a reader scanning for what changed reads
  a single consistent column, and the date carries the recency the card used
  to shout.

  The filters sit behind one "Filter updates" disclosure directly under the
  title, open when a filter is already applied so the state stays visible.
  Apply filters stays a quiet secondary, never the loudest action on the page.
  """
  def changelog_index_body(assigns) do
    assigns =
      assign(
        assigns,
        :filters_active?,
        not is_nil(assigns.filters.area) or not is_nil(assigns.filters.version) or
          not is_nil(assigns.filters.year)
      )

    ~H"""
    <section
      :if={(@available_areas != [] or @filters.version) || @filters.year}
      aria-label="Filter updates"
      class="px-5 pb-8 sm:px-11"
    >
      <details
        id="changelog-filter-disclosure"
        open={@filters_active?}
        class="mx-auto flex max-w-content flex-col gap-5"
      >
        <summary class="inline-flex min-h-target-min w-fit cursor-pointer items-center gap-2 rounded-dot text-label font-semibold text-text-secondary hover:text-text-primary">
          Filter updates
          <span :if={@filters_active?} class="text-text-tertiary">(a filter is applied)</span>
        </summary>
        <nav
          id="changelog-filters"
          aria-label="Filter updates by topic"
          class="mt-4 flex min-w-0 flex-wrap gap-2"
        >
          <a
            href={clear_filter_href(@query_path)}
            aria-current={is_nil(@filters.area) && "page"}
            class={filter_pill_class(is_nil(@filters.area))}
          >
            All
          </a>
          <a
            :for={area <- @available_areas}
            href={filter_href(@query_path, area)}
            aria-current={@filters.area == area && "page"}
            class={filter_pill_class(@filters.area == area)}
          >
            {area_label(area)}
          </a>
        </nav>

        <form
          id="changelog-filter-form"
          action={@canonical_path}
          method="get"
          class="mt-4 flex min-w-0 flex-wrap items-end gap-3"
          aria-label="Filter updates by version or year"
        >
          <div class="flex flex-col gap-1.5">
            <label for="changelog-filter-version" class="text-label font-semibold text-text-secondary">
              Version
            </label>
            <input
              id="changelog-filter-version"
              name="version"
              type="text"
              value={@filters.version || ""}
              maxlength="80"
              class="min-h-target-min w-36 rounded-dot border border-border-control bg-surface-raised px-4 text-label font-medium text-text-primary"
            />
            <span class="text-data text-text-tertiary">For example 2.4</span>
          </div>
          <div class="flex flex-col gap-1.5">
            <label for="changelog-filter-year" class="text-label font-semibold text-text-secondary">
              Year
            </label>
            <input
              id="changelog-filter-year"
              name="year"
              type="number"
              value={@filters.year || ""}
              min="1970"
              max="2200"
              inputmode="numeric"
              class="min-h-target-min w-28 rounded-dot border border-border-control bg-surface-raised px-4 text-label font-medium tabular-nums text-text-primary"
            />
            <span class="text-data text-text-tertiary">For example 2026</span>
          </div>
          <button
            type="submit"
            class="min-h-target-min rounded-dot border border-border-control bg-surface-raised px-5 text-label font-semibold text-text-primary hover:bg-surface-sunken"
          >
            Apply filters
          </button>
          <a href={clear_filter_href(@query_path)} class={public_quiet_link_class()}>Clear filters</a>
        </form>
      </details>
    </section>

    <section
      :if={@entries != []}
      id="changelog-entries"
      aria-label="Published updates"
      class="border-t border-border-subtle px-5 py-8 sm:px-11 sm:py-10"
    >
      <div class="mx-auto flex max-w-content flex-col gap-8">
        <div class="flex min-w-0 flex-col divide-y divide-border-subtle border-y border-border-subtle">
          <.changelog_row
            :for={entry <- @entries}
            entry={entry}
            changelog_path={@changelog_path}
          />
        </div>
      </div>
    </section>

    <section
      :if={@entries == [] and @filters_active?}
      id="changelog-filtered-empty"
      aria-label="Filtered updates"
      class="border-t border-border-subtle px-5 py-10 sm:px-11"
    >
      <div class="mx-auto flex max-w-content flex-wrap items-center gap-x-3 gap-y-2 text-body text-text-secondary">
        <p>No updates match these filters.</p>
        <a
          id="changelog-filtered-empty-clear"
          href={clear_filter_href(@query_path)}
          class={public_quiet_link_class()}
        >Clear filters</a>
      </div>
    </section>

    <%!-- Nothing published yet is a reading state, not a failure: one plain
          sentence, distinct from the error wash a temporarily unavailable
          changelog gets. --%>
    <section
      :if={@entries == [] and not @filters_active?}
      aria-label="Published updates"
      class="border-t border-border-subtle px-5 py-10 sm:px-11"
    >
      <p id="changelog-empty" class="mx-auto max-w-content text-body text-text-secondary">
        No updates are published yet. Published updates appear here, newest first.
      </p>
    </section>

    <nav
      :if={@pagination.has_next || @pagination.page > 1}
      id="changelog-pagination"
      aria-label="Changelog pages"
      class="border-t border-border-subtle px-5 py-8 sm:px-11"
    >
      <div class="mx-auto flex max-w-content items-center justify-between gap-4">
        <a
          :if={@pagination.page > 1}
          href={page_href(@query_path, @pagination.page - 1)}
          class={public_action_class()}
        >
          <.icon name="hero-arrow-left" class="size-4 shrink-0" /> Newer
        </a>
        <span class="font-mono text-data tabular-nums text-text-tertiary">
          Page {@pagination.page}
        </span>
        <a
          :if={@pagination.has_next}
          href={page_href(@query_path, @pagination.page + 1)}
          class={public_action_class()}
        >
          Older <.icon name="hero-arrow-right" class="size-4 shrink-0" />
        </a>
      </div>
    </nav>

    <section
      :if={@first_party?}
      id="changelog-postdeploy-action"
      class="border-t border-border-subtle px-5 py-10 sm:px-11"
      aria-labelledby="changelog-postdeploy-action-heading"
    >
      <div class="mx-auto flex max-w-content flex-wrap items-center justify-between gap-4">
        <div>
          <h2 id="changelog-postdeploy-action-heading" class="text-heading-03 text-text-primary">
            Put the next update to work.
          </h2>
          <p class="mt-1 text-body text-text-secondary">
            Monitor your own project from its next deploy.
          </p>
        </div>
        <a href={~p"/register"} class={public_action_class()}>Start monitoring your project</a>
      </div>
    </section>

    <.changelog_attribution
      first_party?={@first_party?}
      postdeploy_owned?={@postdeploy_owned?}
      class="max-w-content"
    />
    """
  end

  attr :entry, :map, required: true
  attr :changelog_path, :string, required: true

  @doc """
  One published update as a full-width feed row.

  The whole row is the link, so nothing inside it may be a second anchor. The
  date holds a fixed column from `sm` up so a reader scans dates down one
  edge; below that the row stacks date, classification, title, and the
  one-line summary in reading order.
  """
  def changelog_row(assigns) do
    ~H"""
    <a
      id={"changelog-entry-#{@entry.public_slug}"}
      href={"#{@changelog_path}/#{@entry.public_slug}"}
      data-permalink
      class="group grid min-h-target-min min-w-0 grid-cols-1 gap-x-5 gap-y-1.5 py-5 hover:bg-interactive-tint sm:grid-cols-[110px_minmax(0,1fr)]"
    >
      <span class="font-mono text-data tabular-nums text-text-tertiary">
        <.timestamp at={@entry.published_at} format={:date} class="tabular-nums" />
      </span>
      <span class="flex min-w-0 flex-col gap-1.5">
        <span
          :if={entry_new?(@entry) || @entry.area || @entry.version}
          class="flex min-w-0 flex-wrap items-center gap-2"
        >
          <.chip :if={entry_new?(@entry)} variant="new">New</.chip>
          <span
            :if={@entry.area}
            class="rounded-dot border border-border-public px-3 py-1 text-label font-semibold text-text-secondary"
          >
            {area_label(@entry.area)}
          </span>
          <.chip :if={@entry.version} variant="mono">{@entry.version}</.chip>
        </span>
        <h2 class="min-w-0 break-words font-public text-label font-semibold text-text-primary group-hover:text-interactive-strong">
          {@entry.title}
        </h2>
        <p
          :if={entry_summary(@entry)}
          class="line-clamp-2 min-w-0 break-words text-pretty text-body text-text-secondary [&_code]:font-mono"
        >
          <%= if is_binary(@entry.summary) and @entry.summary != @entry.title do %>
            {@entry.summary}
          <% else %>
            {raw(entry_summary(@entry))}
          <% end %>
        </p>
      </span>
    </a>
    """
  end

  attr :first_party?, :boolean, required: true
  attr :postdeploy_owned?, :boolean, required: true
  attr :class, :any, default: nil

  @doc """
  The one product line a changelog page closes with.

  PostDeploy's own marketing changelog says whose product it runs on. A
  customer's changelog carries the quiet attribution and nothing else. A
  changelog PostDeploy hosts under its own identity closes with neither,
  because its masthead already links PostDeploy home.
  """
  def changelog_attribution(assigns) do
    ~H"""
    <footer
      :if={@first_party? or not @postdeploy_owned?}
      class="border-t border-border-subtle px-5 py-9 sm:px-11"
    >
      <div class={[
        "mx-auto flex flex-wrap items-center gap-4 text-label font-medium text-text-tertiary",
        @class
      ]}>
        <span :if={@first_party?}>
          This changelog runs on <a
            href={~p"/"}
            class="inline-flex min-h-target-min items-center font-semibold text-text-secondary hover:text-text-primary hover:underline"
          >PostDeploy</a>. Yours can too.
        </span>
        <.public_attribution :if={!@first_party?} postdeploy_owned?={@postdeploy_owned?} />
      </div>
    </footer>
    """
  end

  @doc "Pill class for one public changelog area filter."
  def filter_pill_class(selected?) do
    base =
      "inline-flex min-h-target-min items-center rounded-dot border px-4 text-label font-semibold "

    base <>
      if selected? do
        "border-interactive-outline bg-interactive-wash text-interactive-strong"
      else
        "border-border-public text-text-secondary hover:bg-surface-sunken hover:text-text-primary"
      end
  end

  attr :first_party?, :boolean, required: true
  attr :postdeploy_owned?, :boolean, required: true
  attr :changelog, :map, required: true
  attr :entry, :map, required: true
  attr :changelog_path, :string, required: true
  attr :rss_path, :string, required: true
  attr :json_path, :string, required: true

  @doc """
  One published update as its own reading surface.

  The back link names the changelog the reader came from. It carries that
  changelog's own logo only when the changelog belongs to a customer: on a
  page PostDeploy owns, the masthead lockup is already the only mark.
  """
  def changelog_entry_body(assigns) do
    ~H"""
    <article id="changelog-entry-article" class="px-5 pb-14 pt-8 sm:px-11 sm:pt-12">
      <div class="mx-auto flex max-w-content flex-col">
        <a id="changelog-back-link" href={@changelog_path} class={public_quiet_link_class()}>
          <.icon name="hero-arrow-left" class="size-4 shrink-0" />
          <img
            :if={@changelog.logo_url && !@postdeploy_owned?}
            src={@changelog.logo_url}
            alt=""
            class="size-5 shrink-0 object-contain"
          />
          <span class="min-w-0 break-words">{@changelog.public_title}</span>
        </a>

        <%!-- Metadata classifies the update before its title is read: when it
              shipped, what it touches, which version carries it. --%>
        <p
          id="changelog-entry-meta"
          class="mt-6 flex min-w-0 flex-wrap items-center gap-x-4 gap-y-2 text-label text-text-tertiary"
        >
          <span class="font-mono text-data tabular-nums">
            <.timestamp at={@entry.published_at} format={:date} class="tabular-nums" />
          </span>
          <span
            :if={@entry.area}
            class="rounded-dot border border-border-public px-3 py-1 text-label font-semibold text-text-secondary"
          >
            {area_label(@entry.area)}
          </span>
          <span
            :if={@entry.version}
            class="rounded-dot border border-border-public bg-surface-sunken px-3 py-1 font-mono text-data text-text-secondary"
          >
            {@entry.version}
          </span>
        </p>

        <h1
          id="changelog-entry-title"
          class="mt-3 min-w-0 break-words text-heading-01 font-semibold tracking-[-0.02em] text-text-primary"
        >
          {@entry.title}
        </h1>

        <p
          :if={entry_standfirst(@entry)}
          class="mt-4 text-pretty text-body-long font-medium text-text-secondary"
        >
          {entry_standfirst(@entry)}
        </p>

        <figure
          :if={@entry.media_url}
          id="changelog-entry-media"
          class="mt-8 overflow-hidden rounded-frame border border-border-public bg-surface-console"
        >
          <img
            src={@entry.media_url}
            alt={@entry.media_alt}
            class="max-h-[32rem] w-full object-contain"
            loading="lazy"
          />
          <figcaption
            :if={@entry.media_caption}
            class="border-t border-border-subtle px-5 py-3.5 text-[13px] font-medium text-text-secondary"
          >
            {@entry.media_caption}
          </figcaption>
        </figure>

        <div
          id="changelog-entry-body"
          class={["mt-8 border-t border-border-subtle pt-8", body_classes()]}
        >
          {raw(entry_body(@entry))}
        </div>
      </div>
    </article>

    <nav
      id="changelog-entry-navigation"
      aria-label="Changelog entry navigation"
      class="border-t border-border-subtle px-5 py-10 sm:px-11"
    >
      <div class="mx-auto grid max-w-content gap-4 sm:grid-cols-2">
        <a
          :if={@entry.previous_entry}
          href={"#{@changelog_path}/#{@entry.previous_entry.public_slug}"}
          class="group min-w-0 rounded-frame border border-border-public bg-surface-raised px-5 py-4 hover:bg-interactive-tint"
        >
          <span class="block text-label font-semibold text-text-tertiary">Previous update</span>
          <span class="mt-1.5 block min-w-0 break-words text-label font-semibold text-text-primary group-hover:text-interactive-strong">
            {@entry.previous_entry.title}
          </span>
        </a>
        <a
          :if={@entry.next_entry}
          href={"#{@changelog_path}/#{@entry.next_entry.public_slug}"}
          class="group min-w-0 rounded-frame border border-border-public bg-surface-raised px-5 py-4 text-left hover:bg-interactive-tint sm:text-right"
        >
          <span class="block text-label font-semibold text-text-tertiary">Next update</span>
          <span class="mt-1.5 block min-w-0 break-words text-label font-semibold text-text-primary group-hover:text-interactive-strong">
            {@entry.next_entry.title}
          </span>
        </a>
      </div>
    </nav>

    <nav aria-label="Changelog links" class="border-t border-border-subtle px-5 py-8 sm:px-11">
      <div class="mx-auto flex max-w-content flex-wrap gap-3">
        <a href={@changelog_path} class={public_action_class()}>
          <.icon name="hero-arrow-left" class="size-4 shrink-0" /> Back to the changelog
        </a>
        <a href={@rss_path} class={public_action_class()}>Subscribe with RSS</a>
        <a href={@json_path} class={public_action_class()}>JSON feed</a>
      </div>
    </nav>

    <section
      :if={@first_party?}
      id="changelog-entry-postdeploy-action"
      class="border-t border-border-subtle px-5 py-10 sm:px-11"
      aria-labelledby="changelog-entry-postdeploy-action-heading"
    >
      <div class="mx-auto flex max-w-content flex-wrap items-center justify-between gap-4">
        <div>
          <h2
            id="changelog-entry-postdeploy-action-heading"
            class="text-heading-03 text-text-primary"
          >
            Put the next update to work.
          </h2>
          <p class="mt-1 text-body text-text-secondary">
            Monitor your own project from its next deploy.
          </p>
        </div>
        <a href={~p"/register"} class={public_action_class()}>Start monitoring your project</a>
      </div>
    </section>

    <.changelog_attribution
      first_party?={@first_party?}
      postdeploy_owned?={@postdeploy_owned?}
      class="max-w-content"
    />
    """
  end

  @doc """
  The first paragraph of an entry, for the one-line teaser in the list.

  Slices the leading `<p>` element out of the already-sanitized entry HTML, so
  the teaser carries the same trust as the body it came from. An entry that
  opens with a heading or a code block teases its first paragraph instead,
  which is the first prose the reader would have reached anyway. Anchors are
  unwrapped to their text: a link inside a list row competes with the row's own
  link to the entry. Returns nil for an entry with no paragraph at all.
  """
  def teaser(html) when is_binary(html) do
    case Regex.run(~r{<p>(.*?)</p>}s, html, capture: :all_but_first) do
      [inner] -> unwrap_anchors(inner)
      nil -> nil
    end
  end

  defp unwrap_anchors(html) do
    html
    |> String.replace(~r{</?a\b[^>]*>}s, "")
    |> String.trim()
  end

  @doc """
  Prose classes for the sanitized entry HTML on the entry page.

  The entry title is the `h1` there, so body headings start at `title2`. The
  list shows a teaser rather than the body, so it needs no prose scale.
  """
  def body_classes do
    "max-w-prose space-y-5 break-words text-body-long text-text-secondary " <>
      "[&_h2]:scroll-mt-6 [&_h2]:border-t [&_h2]:border-border-default " <>
      "[&_h2]:pt-5 [&_h2]:text-heading-02 [&_h2]:font-semibold [&_h2]:text-text-primary " <>
      "[&_h3]:scroll-mt-6 [&_h3]:pt-3 [&_h3]:text-heading-02 [&_h3]:font-semibold " <>
      "[&_h3]:text-text-primary [&_a]:text-interactive-strong [&_a]:underline " <>
      "[&_ol]:list-decimal [&_ol]:pl-6 [&_ul]:list-disc [&_ul]:pl-6 " <>
      "[&_blockquote]:border-l-2 [&_blockquote]:border-border-control [&_blockquote]:pl-4 [&_blockquote]:text-text-secondary " <>
      "[&_code]:rounded-control-sm [&_code]:bg-surface-sunken [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-data " <>
      "[&_pre]:overflow-x-auto [&_pre]:rounded-frame [&_pre]:bg-surface-inverse [&_pre]:p-4 [&_pre]:text-surface-page " <>
      "[&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_img]:rounded-frame [&_img]:max-w-full"
  end

  @doc """
  Customer-facing topic labels for the stored areas. The stored value stays in
  URLs and feeds; a visitor never has to know PostDeploy's product pillars to
  find an update about uptime or errors.
  """
  def area_label(nil), do: nil
  def area_label("monitor"), do: "Uptime and cron"
  def area_label("observe"), do: "Errors and sessions"
  def area_label("measure"), do: "Analytics"
  def area_label("platform"), do: "Product"
  def area_label(area), do: area |> to_string() |> String.capitalize()

  @doc "True when an entry published in the last 14 days should carry the New chip."
  def entry_new?(%{published_at: at}) when not is_nil(at) do
    DateTime.diff(DateTime.utc_now(), entry_utc(at), :day) <= 14
  end

  def entry_new?(_entry), do: false

  defp entry_utc(%DateTime{} = at), do: at
  defp entry_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  @doc """
  The entry body as rendered: without an opening paragraph that repeats the
  standfirst word for word, and with the correlation caveat stated as one
  plain sentence beside the comparison it qualifies.
  """
  def entry_body(%{html: html} = entry) when is_binary(html) do
    html
    |> drop_repeated_opener(entry_standfirst(entry))
    |> String.replace(
      ~r{Correlation is stated, causation is yours to judge\.?},
      "This comparison shows correlation, not proof that the deploy caused the change."
    )
  end

  def entry_body(_entry), do: ""

  defp drop_repeated_opener(html, nil), do: html

  defp drop_repeated_opener(html, standfirst) do
    case Regex.run(~r{\A\s*<p>(.*?)</p>}s, html, capture: :all_but_first) do
      [opener] ->
        if normalize_text(opener) == normalize_text(standfirst),
          do: Regex.replace(~r{\A\s*<p>.*?</p>}s, html, "", global: false),
          else: html

      nil ->
        html
    end
  end

  defp normalize_text(text) do
    text
    |> String.replace(~r{<[^>]*>}, "")
    |> String.replace(~r{\s+}, " ")
    |> String.trim()
    |> String.downcase()
  end

  @doc """
  The standfirst above an entry's body, or nil.

  An entry whose summary only repeats its title adds nothing above the body,
  so the entry page shows no standfirst at all in that case.
  """
  def entry_standfirst(%{summary: summary, title: title})
      when is_binary(summary) and summary != "" do
    if summary == title, do: nil, else: summary
  end

  def entry_standfirst(_entry), do: nil

  @doc "Returns the preferred customer-facing standfirst for an entry."
  def entry_summary(%{summary: summary, title: title} = entry)
      when is_binary(summary) and summary != "" do
    if summary == title, do: teaser(entry.html), else: summary
  end

  def entry_summary(entry), do: teaser(entry.html)

  @doc "Adds or replaces the page query without dropping active filters."
  def page_href(path, page) when is_binary(path) and is_integer(page) and page > 0 do
    uri = URI.parse(path)
    query = URI.decode_query(uri.query || "") |> Map.put("page", page)
    %{uri | query: URI.encode_query(query)} |> URI.to_string()
  end

  def filter_href(path, area) when is_binary(path) and is_binary(area) do
    set_filter_href(path, "area", area)
  end

  @doc "Adds one public filter and starts at its first page."
  def set_filter_href(path, key, value)
      when is_binary(path) and is_binary(key) and is_binary(value) do
    uri = URI.parse(path)
    query = URI.decode_query(uri.query || "") |> Map.put(key, value) |> Map.delete("page")
    %{uri | query: URI.encode_query(query)} |> URI.to_string()
  end

  def clear_filter_href(path) when is_binary(path) do
    uri = URI.parse(path)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["area", "version", "year", "page"])

    %{uri | query: if(query == %{}, do: nil, else: URI.encode_query(query))} |> URI.to_string()
  end

  @doc "Build a valid RSS 2.0 document from the public Changelog map."
  def rss_xml(public, mode \\ :legacy)

  def rss_xml(
        %{public_page: public_page, entries: entries},
        :canonical
      ) do
    rss_xml_body(public_page.title, "/status/#{public_page.public_slug}/changelog", entries)
  end

  def rss_xml(%{public_page: public_page, entries: entries}, :marketing) do
    rss_xml_body(public_page.title, "/changelog", entries, entry_path: "/changelog")
  end

  def rss_xml(%{changelog: changelog, entries: entries}, :legacy) do
    rss_xml_body(
      changelog.public_title,
      "/changelog/#{changelog.public_slug}",
      entries,
      legacy: true
    )
  end

  defp rss_xml_body(title, channel_path, entries, opts \\ []) do
    channel_url = absolute_url(channel_path)
    entry_path = Keyword.get(opts, :entry_path, channel_path)
    legacy? = Keyword.get(opts, :legacy, false)

    items =
      Enum.map_join(entries, "", fn entry ->
        path =
          if legacy?,
            do: "#{entry_path}/entries/#{entry.public_slug}",
            else: "#{entry_path}/#{entry.public_slug}"

        url = absolute_url(path)

        "<item>" <>
          "<title>#{xml_escape(entry.title)}</title>" <>
          "<link>#{xml_escape(url)}</link>" <>
          "<guid isPermaLink=\"true\">#{xml_escape(url)}</guid>" <>
          "<description>#{xml_escape(entry_summary(entry) || entry.html)}</description>" <>
          category_xml(entry) <>
          media_xml(entry) <>
          "<pubDate>#{rfc822_date(entry.published_at)}</pubDate>" <>
          "</item>"
      end)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" <>
      "<rss version=\"2.0\"><channel>" <>
      "<title>#{xml_escape(title)}</title>" <>
      "<link>#{xml_escape(channel_url)}</link>" <>
      "<description>#{xml_escape(title)}</description>" <>
      items <>
      "</channel></rss>"
  end

  defp category_xml(%{area: area}) when is_binary(area),
    do: "<category>#{xml_escape(area_label(area))}</category>"

  defp category_xml(_entry), do: ""

  defp media_xml(%{media_url: url, media_alt: alt})
       when is_binary(url) and is_binary(alt) do
    "<enclosure url=\"#{xml_escape(url)}\" type=\"image/*\" />"
  end

  defp media_xml(_entry), do: ""

  defp absolute_url(path), do: AlplusWeb.Endpoint.url() <> path

  defp rfc822_date(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

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
