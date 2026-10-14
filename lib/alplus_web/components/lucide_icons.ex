defmodule AlplusWeb.LucideIcons do
  @moduledoc """
  The console's icon set: Lucide, drawn inline from vendored path data.

  The design source (`designSystem/PostDeploy v3.dc.html` §04) states the
  console iconography exactly: "Lucide (open source, ISC) at 16px, 1.8px
  stroke, square-cornered grid". Heroicons — the app's previous set — is a
  2px-stroke, rounder family, so a Heroicon beside a Lucide glyph reads as
  two icon systems on one screen.

  Vendored, not fetched: the glyphs below are the Lucide `24x24` outline
  paths, copied into this module. There is no CDN request, no runtime font,
  and no JavaScript icon package in the asset graph. The stroke geometry
  (`stroke-width="1.8"`, round caps and joins) is applied once, here, so no
  caller can draw a glyph at the wrong weight.

  Every glyph in this map appears in the design source's own sidebar or page
  header, plus the shell chrome those screens imply (a drawer toggle, a
  switcher chevron, a menu check). Add a glyph only when a screen needs it,
  and copy the path from Lucide rather than drawing one.

  Icons label, never decorate: `lucide/1` renders `aria-hidden` and expects
  adjacent text or an `aria-label` on the control that owns it.

  Lucide is ISC licensed (https://lucide.dev). The licence text ships with
  the vendored geometry in `priv/static/licenses/lucide-ISC.txt`.
  """

  use Phoenix.Component

  # Lucide 24x24 outline geometry, one entry per glyph name. Values are static
  # author-controlled markup, never user input, so `raw/1` below is safe.
  @glyphs %{
    # Sidebar: the flat IA of design source §04, top to bottom.
    "layout-dashboard" => """
    <rect width="7" height="9" x="3" y="3" rx="1"/>\
    <rect width="7" height="5" x="14" y="3" rx="1"/>\
    <rect width="7" height="9" x="14" y="12" rx="1"/>\
    <rect width="7" height="5" x="3" y="16" rx="1"/>\
    """,
    "search" => """
    <circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>\
    """,
    "triangle-alert" => """
    <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 20h16a2 2 0 0 0 1.73-2Z"/>\
    <path d="M12 9v4"/><path d="M12 17h.01"/>\
    """,
    "activity" => """
    <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>\
    """,
    "heart" => """
    <path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.29 1.51 4.04 3 5.5l7 7Z"/>\
    """,
    "circle-alert" => """
    <circle cx="12" cy="12" r="10"/><path d="M12 8v4"/><path d="M12 16h.01"/>\
    """,
    "git-commit-horizontal" => """
    <circle cx="12" cy="12" r="3"/><line x1="3" x2="9" y1="12" y2="12"/>\
    <line x1="15" x2="21" y1="12" y2="12"/>\
    """,
    "chart-column" => """
    <line x1="6" x2="6" y1="20" y2="16"/><line x1="12" x2="12" y1="20" y2="10"/>\
    <line x1="18" x2="18" y1="20" y2="4"/>\
    """,
    # Sidebar: the Analytics group (ADR 0007).
    "gauge" => """
    <path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>\
    """,
    "list" => """
    <path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/>\
    <path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/>\
    """,
    "filter" => """
    <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>\
    """,
    "repeat" => """
    <path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/>\
    <path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>\
    """,
    "file-text" => """
    <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/>\
    <path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M16 13H8"/><path d="M16 17H8"/>\
    """,
    "globe" => """
    <circle cx="12" cy="12" r="10"/>\
    <path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>\
    """,
    "megaphone" => """
    <path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>\
    """,
    "plug" => """
    <path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/>\
    <path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/>\
    """,
    "settings-2" => """
    <line x1="21" x2="14" y1="4" y2="4"/><line x1="10" x2="3" y1="4" y2="4"/>\
    <line x1="21" x2="12" y1="12" y2="12"/><line x1="8" x2="3" y1="12" y2="12"/>\
    <line x1="21" x2="16" y1="20" y2="20"/><line x1="12" x2="3" y1="20" y2="20"/>\
    <line x1="14" x2="14" y1="2" y2="6"/><line x1="8" x2="8" y1="10" y2="14"/>\
    <line x1="16" x2="16" y1="18" y2="22"/>\
    """,
    # Shell chrome the sidebar and page header need.
    "building-2" => """
    <path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"/>\
    <path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"/>\
    <path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"/>\
    <path d="M10 6h4"/><path d="M10 10h4"/><path d="M10 14h4"/><path d="M10 18h4"/>\
    """,
    "users" => """
    <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/>\
    <path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>\
    """,
    "credit-card" => """
    <rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/>\
    """,
    "chevrons-up-down" => """
    <path d="m7 15 5 5 5-5"/><path d="m7 9 5-5 5 5"/>\
    """,
    "chevron-down" => """
    <path d="m6 9 6 6 6-6"/>\
    """,
    "check" => """
    <path d="M20 6 9 17l-5-5"/>\
    """,
    "plus" => """
    <path d="M5 12h14"/><path d="M12 5v14"/>\
    """,
    "menu" => """
    <path d="M4 5h16"/><path d="M4 12h16"/><path d="M4 19h16"/>\
    """,
    "x" => """
    <path d="M18 6 6 18"/><path d="m6 6 12 12"/>\
    """,
    "ellipsis" => """
    <circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>\
    """,
    "arrow-right" => """
    <path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>\
    """
  }

  @names Map.keys(@glyphs)

  @doc "The names this module can draw, for tests and for a caller's guard."
  def names, do: @names

  @doc """
  Renders one Lucide glyph.

  `name` must be a key of the vendored set; an unknown name raises at render
  rather than silently drawing nothing.

      <.lucide name="activity" class="size-4" />
  """
  attr :name, :string, required: true, values: @names
  attr :class, :any, default: "size-4"
  attr :rest, :global

  # `@glyphs` is a compile-time map of our own SVG path data, and `name` is
  # validated against `@names` by the `attr` above; no caller input is rendered.
  # sobelow_skip ["XSS.Raw"]
  def lucide(assigns) do
    assigns = assign(assigns, :shapes, Phoenix.HTML.raw(Map.fetch!(@glyphs, assigns.name)))

    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
      focusable="false"
      data-lucide={@name}
      {@rest}
    >{@shapes}</svg>
    """
  end
end
