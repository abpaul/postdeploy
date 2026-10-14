defmodule AlplusWeb.MarketingComponents do
  @moduledoc """
  Server-rendered building blocks for the public marketing site
  (ARCHITECTURE.md §9, BUILD.md Phase 4).

  Styled to the PostDeploy v3 "Billow" public expression
  (`designSystem/PostDeploy v3.dc.html` §§01, 03, 06, 11): white page,
  16-24px radius, pill controls, Bricolage Grotesque display over Open
  Runde body. Every class here is a semantic token utility from
  `assets/css/alp/theme.css` — the `[data-public-shell]` scope in
  `tokens.css` remaps those tokens to the public arm automatically, so
  nothing in this module hardcodes a public-only value.

  Ported from `workers/www/site/components/*.astro`, minus the waitlist
  form: `/register` creates the account and signs the reader in, so every
  call-to-action below links there and no copy implies a queue.
  """

  use Phoenix.Component
  use AlplusWeb, :verified_routes

  import AlplusWeb.CoreComponents,
    only: [
      button: 1,
      chip: 1,
      code_panel: 1,
      icon: 1,
      logo: 1
    ]

  alias Alplus.Billing.Package

  alias AlplusWeb.Marketing.PackagePresenter

  # Homepage nav from designSystem/PostDeploy v3.dc.html §03.
  @header_links [
    {"Product", "/#product"},
    {"MCP", "/#mcp"},
    {"Pricing", "/pricing"},
    {"Changelog", "/changelog"},
    {"Blog", "/blog"},
    {"Help", "/docs"}
  ]

  @doc "The header nav links, `{label, path}`, in display order. Shared by the topbar and the 404 page."
  def header_links, do: @header_links

  # The footer's four grouped columns (SITE-ARCHITECTURE.md §4): Product,
  # Compare, Developers, Company. Five links maximum per column. Later
  # tickets append entries as their pages ship; keep each list a plain,
  # readable literal so that stays easy.
  @footer_columns [
    {"Product",
     [
       {"Monitoring", "/monitoring"},
       {"Error tracking", "/error-tracking"},
       {"Analytics", "/analytics"},
       {"Pricing", "/pricing"},
       {"#{Package.trial_days()}-day uptime monitoring trial", "/free-uptime-monitoring"}
     ]},
    {"Compare",
     [
       {"All comparisons", "/alternatives"},
       {"UptimeRobot alternative", "/alternatives/uptimerobot"},
       {"Better Stack alternative", "/alternatives/better-stack"},
       {"Cronitor alternative", "/alternatives/cronitor"},
       {"Healthchecks.io alternative", "/alternatives/healthchecks-io"}
     ]},
    {"Developers",
     [
       {"Docs", "/docs"},
       {"Guides", "/guides"},
       {"Changelog", "/changelog"},
       {"LLMs.txt", "/llms.txt"}
     ]},
    {"Company",
     [
       {"About", "/about"},
       {"Privacy", "/privacy"},
       {"Terms", "/terms"},
       {"@hasieratik on X", "https://x.com/hasieratik"}
     ]}
  ]

  @doc "The footer's four columns, `{column_title, [{label, href}]}`, in display order."
  def footer_columns, do: @footer_columns

  @doc """
  Where the start CTA sends this visitor: the register form when nobody is
  signed in, the console when somebody is. `load_from_session` in the
  `:browser` pipeline assigns `current_user` (nil when absent) on every
  public route, so a signed-in operator never follows a marketing CTA into a
  register form that would only bounce them straight back out.
  """
  def start_path(nil), do: ~p"/register"
  def start_path(_user), do: ~p"/dashboard"
  defp topbar_cta_label(nil), do: "Start free trial"
  defp topbar_cta_label(_user), do: "Open dashboard"

  # Navigation stays one line at desktop and exposes the selected destination
  # with both stronger ink and the brand rule used elsewhere in the public arm.
  defp nav_link_class(current_path, path) do
    [
      "inline-flex min-h-target-min items-center border-b-2 border-transparent text-[14px] font-semibold text-text-secondary hover:text-text-primary",
      active_nav_link?(current_path, path) &&
        "border-interactive-primary text-text-primary"
    ]
  end

  defp active_nav_link?(current_path, path) when is_binary(current_path) do
    current_path == path or
      (path in ["/docs", "/guides", "/changelog"] and
         String.starts_with?(current_path, path <> "/"))
  end

  defp active_nav_link?(_current_path, _path), do: false

  attr :current_path, :string, default: nil
  attr :current_user, :map, required: true

  def topbar(assigns) do
    assigns = assign(assigns, :header_links, header_links())

    ~H"""
    <header
      id="marketing-header"
      data-marketing-menu
      class="sticky top-0 z-40 border-b border-border-subtle bg-surface-page"
    >
      <div class="mx-auto flex h-[84px] max-w-content items-center justify-between gap-4 px-6 sm:px-11">
        <.logo id="landing-brand" href={~p"/"} class="min-h-target-min text-[17px]" />
        <nav
          id="marketing-nav"
          class="hidden min-w-0 items-center gap-[30px] lg:flex"
          aria-label="Primary"
        >
          <a
            :for={{label, path} <- @header_links}
            href={path}
            aria-current={active_nav_link?(@current_path, path) && "page"}
            class={nav_link_class(@current_path, path)}
          >
            {label}
          </a>
        </nav>
        <div class="flex items-center gap-[18px]">
          <a
            :if={is_nil(@current_user)}
            href={~p"/sign-in"}
            class="hidden min-h-target-min items-center text-[14px] font-semibold text-text-secondary hover:text-text-primary sm:inline-flex"
          >
            Log in
          </a>
          <div class="hidden sm:block">
            <.link href={start_path(@current_user)} class={cta_class()}>
              {topbar_cta_label(@current_user)}
            </.link>
          </div>
          <button
            id="marketing-mobile-menu-toggle"
            type="button"
            aria-label="Toggle navigation menu"
            aria-expanded="false"
            aria-controls="marketing-mobile-sheet"
            data-marketing-menu-button
            class="inline-flex min-h-target-min min-w-target-min cursor-pointer items-center justify-center text-text-primary lg:hidden"
          >
            <.icon name="hero-bars-3" class="size-5" />
            <span class="sr-only">Toggle menu</span>
          </button>
        </div>
      </div>
      <div
        id="marketing-mobile-sheet"
        hidden
        data-marketing-menu-panel
        role="dialog"
        aria-modal="true"
        aria-label="Navigation"
        class="fixed inset-0 z-50 bg-surface-page lg:hidden"
      >
        <div class="flex h-full flex-col">
          <div class="flex h-[84px] shrink-0 items-center justify-between border-b border-border-subtle px-6">
            <.logo href={~p"/"} class="min-h-target-min" />
            <button
              type="button"
              aria-label="Close navigation menu"
              class="inline-flex min-h-target-min min-w-target-min items-center justify-center text-text-primary"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <nav aria-label="Mobile primary" class="flex-1 overflow-y-auto px-2 py-2">
            <a
              :for={{label, path} <- @header_links}
              href={path}
              aria-current={active_nav_link?(@current_path, path) && "page"}
              class={[
                "flex min-h-[48px] items-center rounded-control-sm px-4 text-label text-text-secondary hover:bg-hover hover:text-text-primary",
                active_nav_link?(@current_path, path) &&
                  "bg-interactive-wash font-semibold text-text-primary"
              ]}
            >
              {label}
            </a>
            <a
              :if={is_nil(@current_user)}
              href={~p"/sign-in"}
              class="flex min-h-[48px] items-center rounded-control-sm px-3 text-label text-text-secondary hover:bg-hover hover:text-text-primary"
            >
              Log in
            </a>
          </nav>
          <div class="shrink-0 p-4">
            <.link href={start_path(@current_user)} class={cta_class("w-full")}>
              {topbar_cta_label(@current_user)}
            </.link>
          </div>
        </div>
      </div>
      <noscript>
        <nav
          id="marketing-mobile-noscript"
          aria-label="Mobile primary without JavaScript"
          class="mx-auto grid max-w-content gap-1 border-t border-border-subtle px-6 pb-4 lg:hidden"
        >
          <a
            :for={{label, path} <- @header_links}
            href={path}
            class={nav_link_class(@current_path, path)}
          >
            {label}
          </a>
          <.link href={start_path(@current_user)} class={cta_class("mt-1 w-full")}>
            {topbar_cta_label(@current_user)}
          </.link>
        </nav>
      </noscript>
    </header>
    """
  end

  # outside `[data-public-shell]` (which the page template puts on `<main>`),
  # so this never branches on a `[data-public-shell] &` descendant selector
  # the way `CoreComponents.button/1`'s "primary" variant does. `body:has(
  # [data-public-shell])` in tokens.css resolves `--color-action-primary`
  # per expression on the shared `<body>` regardless of nesting depth, so
  # the same three classes read chartreuse-on-ink here and ink-on-white
  # inside the console shell.
  defp cta_class(extra \\ nil) do
    [
      "inline-flex min-h-target-min h-auto w-fit items-center justify-center",
      "rounded-dot bg-action-primary px-5 py-[11px] text-[14px] font-bold text-action-primary-ink",
      "transition-colors duration-productive ease-productive hover:bg-action-primary-hover",
      extra
    ]
  end

  def site_footer(assigns) do
    ~H"""
    <footer
      id="marketing-footer"
      class="border-t border-border-public bg-surface-sunken text-text-secondary"
    >
      <div class="mx-auto max-w-content px-6 py-12 sm:px-11 lg:py-16">
        <div class="grid gap-10 sm:grid-cols-2 lg:grid-cols-[minmax(0,2fr)_repeat(3,minmax(0,1fr))] lg:gap-12">
          <div class="max-w-xs">
            <.logo id="landing-footer-brand" href={~p"/"} class="min-h-target-min text-[17px]" />
            <p class="mt-4 text-body text-text-secondary">
              Know what happens to your software after deploy.
            </p>
          </div>
          <nav aria-label="Product footer links">
            <h2 class="text-label font-semibold text-text-primary">Product</h2>
            <ul class="mt-3 space-y-1">
              <li :for={
                {label, path} <- [
                  {"Monitoring", ~p"/monitoring"},
                  {"Error tracking", ~p"/error-tracking"},
                  {"Analytics", ~p"/analytics"},
                  {"Pricing", ~p"/pricing"}
                ]
              }>
                <a
                  href={path}
                  class="inline-flex min-h-target-min items-center text-body hover:text-text-primary hover:underline"
                >{label}</a>
              </li>
            </ul>
          </nav>
          <nav aria-label="Resources footer links">
            <h2 class="text-label font-semibold text-text-primary">Resources</h2>
            <ul class="mt-3 space-y-1">
              <li :for={
                {label, path} <- [
                  {"Docs", ~p"/docs"},
                  {"Guides", ~p"/guides"},
                  {"Website health check", ~p"/tools/website-health-check"},
                  {"Changelog", ~p"/changelog"},
                  {"Blog", ~p"/blog"},
                  {"Alternatives", ~p"/alternatives"}
                ]
              }>
                <a
                  href={path}
                  class="inline-flex min-h-target-min items-center text-body hover:text-text-primary hover:underline"
                >{label}</a>
              </li>
            </ul>
          </nav>
          <nav aria-label="Company footer links">
            <h2 class="text-label font-semibold text-text-primary">Company</h2>
            <ul class="mt-3 space-y-1">
              <li :for={
                {label, path} <- [
                  {"About", ~p"/about"},
                  {"Privacy", ~p"/privacy"},
                  {"Terms", ~p"/terms"}
                ]
              }>
                <a
                  href={path}
                  class="inline-flex min-h-target-min items-center text-body hover:text-text-primary hover:underline"
                >{label}</a>
              </li>
            </ul>
          </nav>
        </div>
        <section
          id="built-with"
          class="mt-12 border-t border-border-default pt-6 text-center"
          aria-labelledby="built-with-heading"
        >
          <h2 id="built-with-heading" class="text-label font-semibold text-text-primary">
            Built with
          </h2>
          <div class="mt-4 flex flex-wrap items-center justify-center gap-x-8 gap-y-4">
            <a
              href="https://elixir-lang.org"
              aria-label="Elixir"
              class="inline-flex min-h-target-min items-center"
            >
              <img
                src={~p"/images/vendors/elixir.png"}
                alt="Elixir"
                width="1000"
                height="420"
                loading="lazy"
                class="h-8 w-auto max-w-28 object-contain"
              />
            </a>
            <a
              href="https://ash-hq.org"
              aria-label="Ash"
              class="inline-flex min-h-target-min items-center"
            >
              <img
                src={~p"/images/vendors/ash-black.png"}
                alt="Ash"
                width="409"
                height="192"
                loading="lazy"
                class="h-8 w-auto max-w-28 object-contain"
              />
            </a>
            <a
              href="https://www.cloudflare.com"
              aria-label="Cloudflare"
              class="inline-flex min-h-target-min items-center"
            >
              <img
                src={~p"/images/vendors/cloudflare.png"}
                alt="Cloudflare"
                width="400"
                height="135"
                loading="lazy"
                class="h-8 w-auto max-w-28 object-contain"
              />
            </a>
            <a
              href="https://www.ovhcloud.com"
              aria-label="OVHcloud"
              class="inline-flex min-h-target-min items-center"
            >
              <img
                src={~p"/images/vendors/ovhcloud.svg"}
                alt="OVHcloud"
                width="298"
                height="47"
                loading="lazy"
                class="h-8 w-auto max-w-28 object-contain"
              />
            </a>
          </div>
        </section>
        <div class="mt-12 flex flex-col gap-2 border-t border-border-default pt-6 text-caption sm:flex-row sm:justify-between">
          <span>PostDeploy</span>
          <span>Built in the open by
          <a
            href="https://badarau.net"
            class="font-semibold text-text-primary underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash"
          >Paul Bădărău</a></span>
        </div>
      </div>
    </footer>
    """
  end

  attr :docs, :list, required: true
  attr :guide_groups, :list, required: true
  attr :current_path, :string, required: true
  attr :query, :string, default: ""
  slot :inner_block, required: true

  def resource_shell(assigns) do
    ~H"""
    <div class="mx-auto max-w-content px-6 sm:px-11">
      <div class="border-b border-border-default py-4 lg:hidden">
        <details id="resource-mobile-navigation" class="group">
          <summary class="flex min-h-target-min cursor-pointer list-none items-center justify-between gap-3 font-semibold text-text-primary">
            Browse {if guides_path?(@current_path), do: "Guides", else: "Docs"}
            <.icon name="hero-chevron-down" class="size-4 transition-transform group-open:rotate-180" />
          </summary>
          <.resource_navigation
            id="resource-mobile-nav"
            docs={@docs}
            guide_groups={@guide_groups}
            current_path={@current_path}
            query={@query}
          />
        </details>
      </div>
      <div class="grid lg:grid-cols-[15rem_minmax(0,1fr)] lg:gap-12 xl:gap-16">
        <aside
          class="hidden min-w-0 border-r border-border-default pr-6 lg:block"
          aria-label="Resource navigation"
        >
          <div class="sticky top-[104px] max-h-[calc(100vh-116px)] overflow-y-auto py-10">
            <.resource_navigation
              id="resource-desktop-nav"
              docs={@docs}
              guide_groups={@guide_groups}
              current_path={@current_path}
              query={@query}
            />
          </div>
        </aside>
        <div class="min-w-0 py-8 lg:py-10">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :docs, :list, required: true
  attr :guide_groups, :list, required: true
  attr :current_path, :string, required: true
  attr :query, :string, required: true

  defp resource_navigation(assigns) do
    assigns = assign(assigns, :guides?, guides_path?(assigns.current_path))

    ~H"""
    <nav id={@id} aria-label="Docs and Guides" class="pt-4 pb-6 text-body lg:pt-0 lg:pb-0">
      <form id={"#{@id}-search"} action={~p"/docs/search"} method="get" role="search">
        <label for={"#{@id}-query"} class="sr-only">Search Docs and Guides</label>
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-text-tertiary"
          />
          <input
            id={"#{@id}-query"}
            type="search"
            name="q"
            value={@query}
            placeholder="Search"
            class="h-target-min w-full rounded-input border border-border-control bg-surface-page pr-3 pl-9 text-body text-text-primary placeholder:text-text-tertiary"
          />
        </div>
      </form>

      <div class="mt-5 grid grid-cols-2 gap-1 rounded-control bg-surface-sunken p-1">
        <a
          href={~p"/docs"}
          aria-current={@current_path == "/docs" && "page"}
          class={resource_switch_class(!@guides?)}
        >Docs</a>
        <a
          href={~p"/guides"}
          aria-current={@current_path == "/guides" && "page"}
          class={resource_switch_class(@guides?)}
        >Guides</a>
      </div>

      <ul :if={!@guides?} class="mt-5 space-y-0.5">
        <li :for={category <- @docs}>
          <a
            href={category.root.path}
            aria-current={@current_path == category.root.path && "page"}
            class={resource_nav_class(@current_path == category.root.path)}
          >{category.title}</a>
          <ul
            :if={
              category.topics != [] &&
                (category.root.path == @current_path ||
                   Enum.any?(category.topics, &(&1.path == @current_path)))
            }
            class="my-1 ml-3 space-y-0.5 border-l border-border-default pl-2"
          >
            <li :for={page <- category.topics}>
              <a
                href={page.path}
                aria-current={@current_path == page.path && "page"}
                class={resource_nav_class(@current_path == page.path)}
              >{page.nav_label}</a>
            </li>
          </ul>
        </li>
      </ul>

      <ul :if={@guides?} class="mt-5 space-y-0.5">
        <li :for={group <- @guide_groups}>
          <a
            href={"/guides#guides-#{group.key}"}
            class={resource_nav_class(false)}
          >{group.title}</a>
          <ul
            :if={Enum.any?(group.guides, &(&1.path == @current_path))}
            class="my-1 ml-3 space-y-0.5 border-l border-border-default pl-2"
          >
            <li :for={guide <- group.guides}>
              <a
                href={guide.path}
                aria-current={@current_path == guide.path && "page"}
                class={resource_nav_class(@current_path == guide.path)}
              >{guide.nav_label}</a>
            </li>
          </ul>
        </li>
      </ul>
    </nav>
    """
  end

  defp guides_path?(path), do: String.starts_with?(path, "/guides")

  defp resource_switch_class(active?) do
    [
      "flex min-h-target-min items-center justify-center rounded-control-sm text-body font-semibold transition-colors duration-productive",
      if(active?,
        do: "bg-surface-page text-text-primary",
        else: "text-text-secondary hover:text-text-primary"
      )
    ]
  end

  defp resource_nav_class(active?) do
    [
      "flex min-h-target-min items-center rounded-control-sm px-3 py-1.5 text-body leading-snug transition-colors duration-productive hover:bg-interactive-wash hover:text-text-primary",
      if(active?,
        do: "bg-interactive-wash font-semibold text-text-primary",
        else: "text-text-secondary"
      )
    ]
  end

  @doc """
  Renders the masthead shared by Docs, Guides, and product articles: the
  breadcrumb trail, the page's one `<h1>`, a standfirst, an optional meta
  line, and an optional action row under the words.
  """
  attr :id, :string, required: true
  attr :breadcrumbs, :list, required: true
  attr :breadcrumbs_id, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :meta
  slot :actions

  def resource_masthead(assigns) do
    ~H"""
    <header id={@id} class="border-b border-border-default pb-8">
      <.breadcrumb_trail id={@breadcrumbs_id || "#{@id}-breadcrumbs"} trail={@breadcrumbs} />
      <h1 class="mt-5 max-w-[24ch] text-heading-01 text-balance text-text-primary">{@title}</h1>
      <p class="mt-4 max-w-[65ch] text-body text-pretty text-text-secondary sm:text-body-long">
        {@description}
      </p>
      <p :if={@meta != []} class="mt-4 text-caption text-text-tertiary">{render_slot(@meta)}</p>
      <div :if={@actions != []} class="mt-6 flex flex-wrap items-center gap-x-5 gap-y-3">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders an article's section jump links as one quiet panel under the
  masthead. Each item is a `{label, anchor}` pair.
  """
  attr :items, :list, required: true

  def page_contents(assigns) do
    ~H"""
    <nav aria-label="On this page" class="mt-8 rounded-frame bg-surface-sunken px-5 py-4 sm:px-6">
      <h2 class="text-label font-semibold text-text-primary">On this page</h2>
      <ol class="mt-1 grid gap-x-8 sm:grid-cols-2">
        <li :for={{label, anchor} <- @items}>
          <a
            href={"#" <> anchor}
            class="flex min-h-target-min items-center text-body text-text-secondary underline decoration-transparent decoration-2 underline-offset-4 transition-colors duration-productive hover:text-text-primary hover:decoration-interactive-primary"
          >{label}</a>
        </li>
      </ol>
    </nav>
    """
  end

  @doc "Renders one titled section that follows an article body."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def article_section(assigns) do
    ~H"""
    <section id={@id} class="scroll-mt-28 pt-14" {@rest}>
      <h2 class="text-heading-02 text-text-primary">{@title}</h2>
      <div class="mt-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "Renders an article's author, publish date, and review date as one line."
  attr :guide, :map, required: true

  def article_byline(assigns) do
    ~H"""
    <span :if={@guide.author_name}>By {@guide.author_name}</span><span :if={@guide.published_on}>, published
    <time datetime={Date.to_iso8601(@guide.published_on)}>{@guide.published_on}</time></span><span :if={
      @guide.last_verified_on
    }>, last verified
    <time datetime={Date.to_iso8601(@guide.last_verified_on)}>{@guide.last_verified_on}</time></span>
    """
  end

  @doc "Renders cited sources as ruled rows with the date each was checked."
  attr :sources, :list, required: true

  def source_list(assigns) do
    ~H"""
    <ul class="divide-y divide-border-default border-y border-border-default">
      <li
        :for={source <- @sources}
        class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 py-2"
      >
        <a
          href={source["url"]}
          class="inline-flex min-h-target-min items-center text-body text-text-primary underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash"
        >{source["label"]}</a>
        <span class="text-caption text-text-tertiary">Checked
        <time datetime={source["retrieved"]}>{source["retrieved"]}</time></span>
      </li>
    </ul>
    """
  end

  @doc """
  Renders related pages as a compact two-column link list. Each link is a
  map with `:id`, `:label`, and `:path`.
  """
  attr :links, :list, required: true

  def related_links(assigns) do
    ~H"""
    <ul class="grid border-t border-border-default sm:grid-cols-2 sm:gap-x-8">
      <li :for={link <- @links} class="border-b border-border-default">
        <a
          id={link.id}
          href={link.path}
          class="group flex min-h-target-min items-center justify-between gap-3 py-2.5 text-body font-semibold text-text-primary transition-colors duration-productive hover:text-interactive-strong"
        >
          <span>{link.label}</span>
          <.icon
            name="hero-arrow-right"
            class="size-4 shrink-0 text-text-tertiary transition-transform duration-productive group-hover:translate-x-0.5"
          />
        </a>
      </li>
    </ul>
    """
  end

  @doc """
  Renders the shared interior masthead: the breadcrumb trail, the page's one
  `<h1>`, a standfirst, and the page's actions, in the first third of the
  viewport.

  Interior pages are read, not launched. The display size and centred column
  belong to the homepage hero alone; here the title takes the `heading-01`
  role, sits on the reading edge, and the content starts inside the first
  screen. Actions sit under the words. The optional
  evidence slot carries one comparison fact beside the title instead.
  """
  attr :id, :string, default: "leadspace"
  attr :title, :string, required: true
  attr :description, :string, required: true

  attr :breadcrumbs, :list,
    default: [],
    doc: "`{label, path}` trail ending with the current page"

  attr :breadcrumbs_id, :string, default: nil
  attr :class, :any, default: nil

  attr :evidence_class, :any,
    default: "rounded-frame border border-border-public bg-surface-raised p-5 lg:p-6",
    doc: "classes for the evidence aside; pass a flush value when it holds its own frame"

  attr :rest, :global
  slot :actions
  slot :evidence

  def leadspace(assigns) do
    ~H"""
    <section id={@id} class={["border-b border-border-public", @class]} {@rest}>
      <div class="mx-auto max-w-content px-6 pt-5 pb-10 sm:px-11 md:pb-14">
        <.breadcrumb_trail
          :if={@breadcrumbs != []}
          id={@breadcrumbs_id || "#{@id}-breadcrumbs"}
          trail={@breadcrumbs}
        />
        <div class={[
          "mt-5 grid gap-6 md:mt-8 lg:gap-x-16",
          @evidence != [] && "lg:grid-cols-12 lg:items-start"
        ]}>
          <div class={@evidence != [] && "lg:col-span-7"}>
            <h1 class="max-w-[28ch] text-heading-01 text-balance text-text-primary">{@title}</h1>
            <p class="mt-4 max-w-[64ch] text-body text-pretty text-text-secondary sm:text-body-long">
              {@description}
            </p>
            <div :if={@actions != []} class="mt-6 flex flex-wrap items-center gap-x-5 gap-y-3">
              {render_slot(@actions)}
            </div>
          </div>
          <aside
            :if={@evidence != []}
            class={["lg:col-span-5", @evidence_class]}
            aria-label="Page evidence"
          >
            {render_slot(@evidence)}
          </aside>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a visible breadcrumb trail. The last entry is the current page and
  is never a link, so the trail matches the page's BreadcrumbList schema.
  """
  attr :id, :string, required: true
  attr :trail, :list, required: true

  def breadcrumb_trail(assigns) do
    assigns = assign(assigns, :last, length(assigns.trail) - 1)

    ~H"""
    <nav id={@id} class="text-caption text-text-tertiary" aria-label="Breadcrumb">
      <ol class="flex flex-wrap items-center gap-x-2">
        <li :for={{{label, path}, index} <- Enum.with_index(@trail)} class="flex items-center">
          <span :if={index == @last} aria-current="page">{label}</span>
          <a
            :if={index < @last}
            href={path}
            class="inline-flex min-h-target-min items-center text-text-secondary underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash"
          >
            {label}
          </a>
          <span :if={index < @last} class="ml-2" aria-hidden="true">/</span>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  Splits `text` on backticks and wraps the odd segments in `<code>`, and turns
  `[label](/path)` into a link. Only site-relative paths become links, so
  content cannot inject an external or script URL. Never `raw/1`.
  """
  attr :text, :string, required: true

  def rich_text(assigns) do
    parts =
      assigns.text
      |> String.split("`")
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {part, i} when rem(i, 2) == 1 -> [{:code, part}]
        {part, _i} -> text_and_links(part)
      end)

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span phx-no-format><%= for {kind, part} <- @parts do %><code :if={kind == :code} class="rounded-control-sm bg-surface-sunken px-1 py-0.5 font-mono text-data">{part}</code><a :if={kind == :link} href={elem(part, 1)} class="font-semibold text-text-primary underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash">{elem(part, 0)}</a><%= if kind == :text do %>{part}<% end %><% end %></span>
    """
  end

  @link_pattern ~r{\[([^\]]+)\]\((/(?!/)[a-z0-9/#_-]*)\)}

  defp text_and_links(text) do
    @link_pattern
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn segment ->
      case Regex.run(@link_pattern, segment) do
        [^segment, label, path] -> {:link, {label, path}}
        _ -> {:text, segment}
      end
    end)
  end

  @doc """
  Renders a Help Center article body in one reading column.

  Each section map takes a `"heading"` and any of, in this order: `"body"`
  paragraphs, a `"callout"` (`"tone"` is `"tip"` or `"caution"`, with a
  `"lead"` word and a `"body"`), numbered `"steps"` (each a `"text"` with an
  optional `"code"`, `"filename"` and `"language"`), a `"code"` block, a
  `"list"`, `"rows"` of `"term"` and `"detail"`, and `"after"` paragraphs.
  Every section heading carries an anchor for the page's contents rail.
  """
  attr :sections, :list, required: true

  def doc_sections(assigns) do
    ~H"""
    <div class="max-w-[46rem]">
      <section
        :for={{section, section_index} <- Enum.with_index(@sections)}
        id={doc_anchor(section["heading"], section_index)}
        class="scroll-mt-28 pt-14 first:pt-10"
      >
        <h2 class="text-heading-02 text-text-primary">{section["heading"] || "Details"}</h2>
        <div class="mt-4 space-y-5">
          <p :for={p <- section["body"] || []} class="text-body-long text-pretty text-text-secondary">
            <.rich_text text={p} />
          </p>
          <.doc_callout :if={section["callout"]} callout={section["callout"]} />
          <ol :if={section["steps"]} class="space-y-6">
            <li
              :for={{step, index} <- Enum.with_index(section["steps"], 1)}
              class="grid grid-cols-[1.5rem_minmax(0,1fr)] gap-x-3"
            >
              <span
                class="mt-[3px] flex size-6 items-center justify-center rounded-dot bg-surface-sunken font-mono text-data font-semibold text-text-primary"
                aria-hidden="true"
              >
                {index}
              </span>
              <div class="min-w-0 space-y-3">
                <p class="text-body-long text-pretty text-text-secondary">
                  <span class="sr-only">Step {index}.</span> <.rich_text text={step["text"]} />
                </p>
                <.code_panel
                  :if={step["code"]}
                  id={"doc-code-#{doc_anchor(section["heading"], section_index)}-#{index}"}
                  code={step["code"]}
                  filename={step["filename"] || "Terminal"}
                  language={step["language"] || "shell"}
                  wrap={step["language"] == "text"}
                  liveview_copy={false}
                />
              </div>
            </li>
          </ol>
          <.code_panel
            :if={section["code"]}
            id={"doc-code-#{doc_anchor(section["heading"], section_index)}"}
            code={section["code"]}
            filename={section["filename"] || "Terminal"}
            language={section["language"] || "shell"}
            wrap={section["language"] == "text"}
            liveview_copy={false}
          />
          <ul
            :if={section["list"]}
            class="divide-y divide-border-default border-y border-border-default"
          >
            <li :for={item <- section["list"]} class="py-3 text-body-long text-text-secondary">
              <.rich_text text={item} />
            </li>
          </ul>
          <dl
            :if={section["rows"]}
            class="divide-y divide-border-default border-y border-border-default"
          >
            <div :for={row <- section["rows"]} class="py-4">
              <dt class="text-heading-03 text-text-primary"><.rich_text text={row["term"]} /></dt>
              <dd class="mt-1 text-body-long text-text-secondary">
                <.rich_text text={row["detail"]} />
              </dd>
            </div>
          </dl>
          <p :for={p <- section["after"] || []} class="text-body-long text-pretty text-text-secondary">
            <.rich_text text={p} />
          </p>
        </div>
      </section>
    </div>
    """
  end

  @doc "The in-page anchor for a docs section heading."
  def doc_anchor(heading, index \\ 0)

  def doc_anchor(heading, index) when is_binary(heading) do
    case heading
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/u, "-")
         |> String.trim("-") do
      "" -> "section-#{index + 1}"
      anchor -> anchor
    end
  end

  def doc_anchor(_heading, index), do: "section-#{index + 1}"

  attr :callout, :map, required: true

  defp doc_callout(assigns) do
    ~H"""
    <div class={[
      "rounded-frame px-[18px] py-[14px] text-body-long text-text-primary",
      if(@callout["tone"] == "caution", do: "bg-status-late-bg", else: "bg-interactive-wash")
    ]}>
      <p>
        <strong class="font-semibold">{@callout["lead"]}:</strong>
        <.rich_text text={@callout["body"]} />
      </p>
    </div>
    """
  end

  @doc """
  Renders public page sections. The compact variant rules each section into
  a heading and content grid; the prose variant spaces sections in one
  reading column.
  """
  attr :sections, :list, required: true
  attr :variant, :string, default: "compact", values: ["compact", "prose"]

  # A page whose other sections are `text-heading-01` (the comparison
  # pages) would otherwise render these as subordinate to their neighbours.
  attr :heading_size, :string,
    default: "text-heading-02",
    values: ["text-heading-01", "text-heading-02"]

  def body_sections(assigns) do
    ~H"""
    <div class={@variant != "prose" && "divide-y divide-border-default"}>
      <section
        :for={{section, idx} <- Enum.with_index(@sections)}
        class={[
          if(@variant == "prose",
            do: "max-w-[46rem] pt-14 first:pt-0",
            else: "grid gap-5 py-10 first:pt-0 last:pb-0 md:grid-cols-12 md:items-center md:gap-10"
          ),
          idx == 0 && "pt-0"
        ]}
      >
        <h2
          :if={section["heading"]}
          class={[
            "text-text-primary",
            @variant == "prose" && "mb-4",
            @variant != "prose" && "max-w-[20ch] md:col-span-5",
            @heading_size
          ]}
        >
          {section["heading"]}
        </h2>
        <div class={[
          "min-w-0 space-y-5",
          @variant != "prose" && "max-w-prose md:col-span-7"
        ]}>
          <p :for={p <- section["body"] || []} class="text-body-long text-pretty text-text-secondary">
            <.rich_text text={p} />
          </p>
          <ul
            :if={section["list"]}
            class="divide-y divide-border-default border-y border-border-default"
          >
            <li :for={item <- section["list"]} class="py-3 text-body-long text-text-secondary">
              <.rich_text text={item} />
            </li>
          </ul>
          <.code_panel
            :if={section["code"]}
            id={"marketing-code-#{section_id(section["heading"])}"}
            code={section["code"]}
            filename={section["filename"] || "Example"}
            language={section["language"] || "shell"}
            copy={Map.get(section, "copy", false)}
            liveview_copy={false}
          />
          <.founder_letter :if={section["founder_letter"]} />
          <.setup_transcript
            :if={section["transcript"]}
            id={"marketing-transcript-#{section_id(section["heading"])}"}
            transcript={section["transcript"]}
          />
        </div>
      </section>
    </div>
    """
  end

  @doc """
  The founder's letter: portrait, the reason PostDeploy exists, the
  founder's own products that run on it, and profile links. The homepage
  places it in the hero (`wide`, a three-column strip on large screens);
  the About page places it in a reading column.
  """
  attr :wide, :boolean, default: false
  attr :class, :any, default: nil

  def founder_letter(assigns) do
    ~H"""
    <section
      id="founder-letter"
      aria-labelledby="founder-letter-title"
      class={[
        "grid min-w-0 grid-cols-[auto_1fr] items-center gap-x-4 gap-y-1.5 rounded-frame border border-border-public bg-surface-sunken px-4 py-2.5 text-left sm:items-start sm:gap-x-6 sm:gap-y-3 sm:px-7 sm:py-4",
        @wide && "lg:grid-cols-[auto_1fr_auto]",
        @class
      ]}
    >
      <img
        src={~p"/images/paul-badarau.webp"}
        alt=""
        width="360"
        height="360"
        loading="lazy"
        class={[
          "row-span-2 size-11 rounded-full object-cover sm:row-span-3 sm:size-14",
          @wide && "lg:row-span-2"
        ]}
      />
      <h2
        id="founder-letter-title"
        class="col-start-2 row-start-1 self-end text-[18px] leading-[1.2] font-semibold tracking-[-0.02em] text-text-primary sm:self-auto"
      >
        Why I built PostDeploy
      </h2>
      <p class="col-span-2 max-w-[56rem] text-[14px] leading-[20px] font-medium text-text-secondary sm:col-span-1 sm:col-start-2 sm:text-[14.5px] sm:leading-[22px]">
        Hi, I'm Paul. Every project I shipped needed three more tools: uptime checks in one
        place, errors in another, visitor numbers somewhere else, each with its own login and
        bill. I built PostDeploy to keep them in one project. I run
        <a
          href="https://crabgate.com"
          class="font-semibold text-text-primary underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash"
        >CrabGate</a>
        and
        <a
          href="https://keysend.app"
          class="font-semibold text-text-primary underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash"
        >KeySend.app</a>
        on it, because I want a useful answer after a deploy and a bill I can predict.
      </p>
      <div class={[
        "contents min-w-0 sm:col-start-2 sm:block",
        @wide && "lg:col-start-3 lg:row-span-2 lg:row-start-1 lg:self-center"
      ]}>
        <p class="col-start-2 row-start-2 self-start text-[14px] font-semibold text-text-primary">
          <a
            href="https://badarau.net"
            class="underline decoration-interactive-primary decoration-2 underline-offset-4 hover:bg-interactive-wash"
          >Paul Bădărău</a>
          <span class="ml-1 font-normal text-text-tertiary">Founder</span>
        </p>
        <nav
          aria-label="Paul's profiles"
          class="col-span-2 flex gap-4 text-[13px] text-text-tertiary sm:mt-1"
        >
          <a
            href="https://www.linkedin.com/in/paulbpa/"
            class="inline-flex min-h-target-min items-center underline hover:text-text-primary sm:min-h-0"
          >LinkedIn</a>
          <a
            href="https://github.com/abpaul"
            class="inline-flex min-h-target-min items-center underline hover:text-text-primary sm:min-h-0"
          >GitHub</a>
          <a
            href="https://badarau.net"
            class="inline-flex min-h-target-min items-center underline hover:text-text-primary sm:min-h-0"
          >Website</a>
        </nav>
      </div>
    </section>
    """
  end

  @doc """
  Renders an example agent session: what the visitor tells their coding
  agent, the registry actions it runs, and the line that closes the session.
  The transcript is a section map's `"transcript"` entry, with `"project"`,
  `"prompt"`, `"actions"` (pairs of action name and target) and `"result"`.
  The frame is the page's only dark surface besides code panels, and its
  context bar always says it is an example.
  """
  attr :id, :string, required: true
  attr :transcript, :map, required: true

  def setup_transcript(assigns) do
    ~H"""
    <figure
      id={@id}
      class="m-0 min-w-0 overflow-hidden rounded-frame bg-surface-inverse text-text-inverse-code"
    >
      <figcaption class="flex min-w-0 items-center justify-between gap-3 border-b border-border-inverse px-5 py-3 text-data text-text-inverse-muted">
        <span class="min-w-0 truncate">project: {@transcript["project"]}</span>
        <span class="shrink-0">example session</span>
      </figcaption>
      <div class="space-y-4 px-5 py-4 text-data">
        <p><span class="mr-3 text-text-inverse-muted">you</span>{@transcript["prompt"]}</p>
        <ul class="space-y-3">
          <li
            :for={[action, target] <- @transcript["actions"] || []}
            class="flex items-baseline gap-2"
          >
            <.icon
              name="hero-check"
              class="size-3.5 shrink-0 translate-y-0.5 text-status-live-inverse"
            />
            <span class="min-w-0">
              <span class="block">{action}</span>
              <span class="block break-words text-text-inverse-muted">{target}</span>
            </span>
          </li>
        </ul>
        <p :if={@transcript["result"]} class="text-text-inverse-muted">{@transcript["result"]}</p>
      </div>
    </figure>
    """
  end

  defp section_id(heading) when is_binary(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "section"
      value -> value
    end
  end

  defp section_id(_heading), do: "section"

  @doc "Renders `%{\"q\" => ..., \"a\" => ...}` FAQ maps as a definition-style list."
  attr :faqs, :list, required: true

  def faq_list(assigns) do
    ~H"""
    <div class="divide-y divide-border-default border-y border-border-default">
      <div :for={f <- @faqs} class="py-5">
        <h3 class="max-w-prose text-heading-03 text-text-primary">{f["q"]}</h3>
        <p class="mt-2 max-w-prose text-body-long text-text-secondary">
          <.rich_text text={f["a"]} />
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The offer: the allowances a buyer weighs on the reading edge, and the
  priced panel beside them. The panel is the page's one frame and its one
  primary action; the trial reads from `PackagePresenter.trial_step/0` and
  stays a lifecycle line under that action, never a second thing to buy.
  """
  attr :current_user, :map, required: true

  def package_offer(assigns) do
    assigns =
      assigns
      |> assign(:trial, PackagePresenter.trial_step())
      |> assign(:package, PackagePresenter.offer())

    ~H"""
    <div id="package-offer" class="grid gap-8 lg:grid-cols-12 lg:items-start lg:gap-x-16">
      <div class="lg:col-span-7">
        <h2 class="text-heading-02 text-text-primary">What you can run</h2>
        <ul
          id="package-highlights"
          class="mt-5 grid border-t border-border-default sm:grid-cols-2 sm:gap-x-10"
        >
          <li
            :for={h <- @package.highlights}
            class="border-b border-border-default py-3 text-body text-text-primary"
          >
            {h}
          </li>
        </ul>
        <p id="package-eligibility" class="mt-5 text-caption text-text-secondary">
          {@package.eligibility}
        </p>
      </div>
      <div class="order-first w-full max-w-measure rounded-frame bg-surface-inverse p-6 lg:order-none lg:col-span-5 lg:max-w-none lg:p-7">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-heading-03 text-text-inverse">{@package.name}</h2>
          <.chip variant="new">{@trial.days} days free, no card</.chip>
        </div>
        <p
          id="package-price"
          class="mt-4 flex flex-wrap items-baseline gap-x-2 text-metric text-text-inverse"
        >
          {@package.price}
          <span class="text-caption font-normal text-text-inverse-muted">{@package.period}</span>
        </p>
        <p
          :for={note <- @package.billing_notes}
          class="mt-2 text-caption text-text-inverse-muted first:mt-3"
        >
          {note}
        </p>
        <.button href={start_path(@current_user)} variant="primary" class="mt-6 w-full">
          {PackagePresenter.cta_label()}
        </.button>
        <p class="mt-3 border-t border-border-inverse pt-3 text-body text-text-inverse-muted">
          {@trial.detail}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Every capability the package includes, as ruled rows rather than a card
  grid. Ordered by `PackagePresenter.features/0`.
  """
  def package_features(assigns) do
    assigns = assign(assigns, :features, PackagePresenter.features())

    ~H"""
    <ul id="package-features" class="grid gap-x-10 border-t border-border-default lg:grid-cols-2">
      <li
        :for={feature <- @features}
        id={"package-feature-#{feature.id}"}
        class="border-b border-border-default py-4"
      >
        <span class="block text-heading-03 text-text-primary">{feature.name}</span>
        <span class="mt-1 block text-body text-text-secondary">{feature.description}</span>
      </li>
    </ul>
    """
  end

  @doc """
  What a buyer must know before they subscribe: how limits behave and what
  the package does not include.
  """
  def package_terms(assigns) do
    assigns =
      assigns
      |> assign(:constraints, PackagePresenter.constraints())
      |> assign(:not_included, PackagePresenter.not_included())

    ~H"""
    <div class="grid gap-8 lg:grid-cols-2 lg:gap-10">
      <div>
        <h3 class="text-label font-semibold text-text-secondary">How limits work</h3>
        <ul
          id="package-constraints"
          class="mt-3 divide-y divide-border-default border-t border-border-default text-body text-text-secondary"
        >
          <li
            :for={constraint <- @constraints}
            id={"package-constraint-#{constraint.id}"}
            class="py-3"
          >
            {constraint.text}
          </li>
        </ul>
      </div>
      <div>
        <h3 class="text-label font-semibold text-text-secondary">Not included, at any price</h3>
        <ul
          id="package-not-included"
          class="mt-3 divide-y divide-border-default border-t border-border-default text-body text-text-secondary"
        >
          <li :for={item <- @not_included} class="py-3">{item}</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :heading, :string, default: "Know what happens after your next deploy."
  attr :label, :string, default: nil
  attr :body, :string, required: true
  attr :current_user, :map, required: true

  @doc """
  The shared final call to action: the landing page's quiet, repeating
  close (`designSystem/PostDeploy v3.dc.html` §01 "Scroll is the
  navigation" — CTAs repeat quietly instead of shouting once). No
  atmospheric field: the only elevation left on the public arm is the
  product frame.
  """
  def final_cta(assigns) do
    assigns = assign(assigns, :label, assigns.label || PackagePresenter.cta_label())

    ~H"""
    <section id="final-cta" class="border-t border-border-public">
      <div class="mx-auto flex max-w-content flex-col items-center gap-5 px-4 py-24 text-center sm:px-6">
        <h2 class="max-w-[14ch] text-heading-01 text-text-primary">
          {@heading}
        </h2>
        <p class="max-w-measure text-body-long text-text-secondary">{@body}</p>
        <.button href={start_path(@current_user)} variant="primary">
          {@label}
        </.button>
      </div>
    </section>
    """
  end

  @doc "Every limit the package includes, from `PackagePresenter.included_groups/0`."
  def included_list(assigns) do
    assigns = assign(assigns, :groups, PackagePresenter.included_groups())

    ~H"""
    <div
      id="package-included"
      class="divide-y divide-border-default overflow-clip rounded-frame border border-border-public bg-surface-raised"
    >
      <section :for={group <- @groups} class="p-4 md:px-6">
        <h3 class="text-label font-semibold text-text-secondary">{group.title}</h3>
        <dl class="mt-3 divide-y divide-border-default">
          <div
            :for={row <- group.rows}
            class={[
              "grid items-baseline gap-x-4 py-3 first:pt-0 last:pb-0",
              if(row[:face] == :prose,
                do: "sm:grid-cols-[minmax(0,1fr)_auto]",
                else: "grid-cols-[minmax(0,1fr)_auto]"
              )
            ]}
          >
            <dt class="text-body text-text-primary">
              {row.label}
              <span :if={row.note} class="mt-1 block text-caption text-text-tertiary">
                {row.note}
              </span>
            </dt>
            <dd class={[
              if(row[:face] == :prose,
                do: "mt-1 text-body text-text-secondary sm:mt-0 sm:text-right",
                else: "whitespace-nowrap text-right text-data tabular-nums text-text-secondary"
              )
            ]}>
              {row.value}
            </dd>
          </div>
        </dl>
      </section>
    </div>
    """
  end

  @doc """
  Renders a competitor comparison as a table on wide screens and feature-led
  value pairs on small screens. The same row values feed both views.
  """
  attr :competitor, :string, required: true
  attr :rows, :list, required: true

  def comparison_matrix(assigns) do
    ~H"""
    <div
      id="comparison-matrix"
      class="overflow-hidden rounded-structural border border-border-public bg-surface-raised"
    >
      <div class="hidden overflow-x-auto md:block">
        <table class="w-full border-collapse text-left text-body">
          <caption class="sr-only">
            {@competitor} and PostDeploy comparison
          </caption>
          <thead>
            <tr class="border-b border-border-default">
              <th scope="col" class="px-4 py-4 text-label text-text-primary md:px-6">Feature</th>
              <th
                scope="col"
                class="border-l border-border-default px-4 py-4 text-heading-02 text-text-primary md:px-6"
              >
                {@competitor}
              </th>
              <th
                scope="col"
                class="border-l border-border-default px-4 py-4 text-heading-02 text-text-primary md:px-6"
              >
                PostDeploy
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class="border-b border-border-default last:border-b-0">
              <th scope="row" class="px-4 py-3 text-text-primary md:px-6">{row["label"]}</th>
              <td class="border-l border-border-default px-4 py-3 text-text-secondary md:px-6">
                {row["them"]}
              </td>
              <td class="border-l border-border-default px-4 py-3 text-text-secondary md:px-6">
                {row["us"]}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="divide-y divide-border-default md:hidden">
        <dl>
          <div :for={row <- @rows} class="p-4">
            <dt class="text-heading-02 text-text-primary">{row["label"]}</dt>
            <dd class="mt-3">
              <dl class="grid gap-2">
                <div class="rounded-input bg-surface-page px-3 py-3">
                  <dt class="text-label font-semibold text-text-secondary">{@competitor}</dt>
                  <dd class="mt-1 text-body text-text-primary">{row["them"]}</dd>
                </div>
                <div class="rounded-input bg-surface-sunken px-3 py-3">
                  <dt class="text-label font-semibold text-text-secondary">PostDeploy</dt>
                  <dd class="mt-1 text-body text-text-primary">{row["us"]}</dd>
                </div>
              </dl>
            </dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end
end
