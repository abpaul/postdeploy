---
name: PostDeploy
description: One system, two expressions - an airy public surface and a calm, compact MCP-first dashboard.
---

# PostDeploy Design System — DESIGN.md

Text reference for agents building PostDeploy surfaces. Canonical visual spec: `PostDeploy v3.dc.html`. When this file and the visual spec disagree, the visual spec wins.

## Visual aim

Premium, airy, simple, usable. Every surface, public or authenticated, should feel like one calm product: generous space, one idea per screen, numbers you can read from across the room, and nothing on the page that a person did not come for. A reader with ADHD must be able to open any screen and know in one glance what is happening and what to do next.

Three tests for any screen (settled 2026-08-29):

1. **The title is the answer.** The screen's `<h1>` states what is true right now ("2 monitors are down", "No open issues", "Your agent is connected"). No intro sentence under it.
2. **One list, one chart, or one card.** A screen holds the one thing it is for. Summary bands, stat tiles, secondary panels, explanatory paragraphs, footers, and hidden data tables are cut before they are added. If in doubt, remove it.
3. **Short words, no caveats.** Coverage, comparison and collection facts are one short line each, present only when true. Everything else lives on the detail screen or in the agent.

## One system, two expressions

- **Public** (marketing, pricing, auth, public status pages, public changelogs, widgets): airy, light, friendly, product-led. Billow-level breathing room.
- **Dashboard** (the authenticated app): the same air, in a working tool. The one chart a screen is built around sits in the marketing product frame (18px radius, soft `shadow-frame`, mono context row, centred metric cells, a rail beside the chart). Everything else is a hairline panel.
- **MCP-first throughout**: PostDeploy has no chatbot, no AI sidebar, no "Ask PostDeploy". The user brings their own agent (Claude Code, Codex, any MCP client) which configures PostDeploy through MCP OAuth. The dashboard's job is human inspection and review of what the agent did. Show MCP provenance ("created by claude-code via MCP") wherever it applies. Destructive MCP actions require dashboard confirmation. Plan/billing changes are human-only, never MCP.

## Color tokens

Brand and status are separated on purpose and never swap jobs.

| Token | Hex | Use |
|---|---|---|
| `brand` (Pantone 2297 C) | `#C0DF16` | Identity, logo accent, selected state, active nav, primary button fill (always with ink text), limited chart emphasis. Never means "healthy". Never body text on white. |
| `brand-tint` | `#E7F3A3` | Selection highlight, headline underline wash |
| `brand-wash` | `#F4FADC` | Subtle brand backgrounds, hover wash |
| `brand-deep` | `#8FA80E` / `#5E6C0B` | Text-safe brand (5.8:1) — the wordmark dot, brand-colored text |
| `ink` | `#171B12` | Primary text, dark buttons, code panel background |
| `text-secondary` | `#000000` | Body copy, descriptions. Pure black since 2026-09-15, because `#4C5445` read as grey. 21:1 white |
| `text-tertiary` | `#5F6856` | Metadata, captions, mono labels. 5.8:1 white, 5.2:1 on the well. Never below 12px |
| `operational` (Pantone 354 C) | `#00B140` | Up, available, success, passing, uptime history. Text-safe pair: `#00753B` |
| `degraded` | `#E8960C` | Late, degraded, warning. Text-safe pair: `#8A5106`; wash `#FCF0DD` |
| `failure` | `#D92D20` | Down, error, open incident. Text-safe pair: `#B42318`; wash `#FDECEA` |
| `info` | `#2E62E8` | Informational; also the focus ring. Text pair `#1D4FC4` |
| `neutral-dot` | `#8A9691` / `#C9D0BD` | Paused, resolved, no-data |
| Surfaces | `#FFFFFF` page, `#FBFBF9` raised/sunken alt, `#F1F2EC` wells/pills | |
| Borders | `#E9ECE4` public, `#ECEEE8` dashboard, `#F0F2EC`/`#F5F6F1` internal hairlines, `#E1E4D9` inputs | |

State is always **dot + word**, never color alone.

## Typography

**Public:** Lastik (display; until licensed, Bricolage Grotesque stands in) for hero + major headings only — 600 weight, tight leading (1.04–1.1), letter-spacing −0.02 to −0.025em, sizes 38–62px. Open Runde for everything else: body 15–17px/1.6, weights 400–700, buttons and nav 600–700 at 13–15px.

**Dashboard:** Open Runde for all UI (settled 2026-08-29: Geist read as architectural at working sizes, and one family across both arms is what "share typography" meant all along) — headings 600 at 17–19px, working text 400–500 at 13–14px, stat values 600 at 20–24px with −0.02em, always under the screen's 28px h1, labels 500–600 at 12.5px. Geist Mono ONLY for machine output: IDs, versions, endpoints, timestamps, counts, stack traces — never decoration. Floor: nothing below 12px.

## Voice and punctuation

Friendly, plain, matter-of-fact. Sentences over fragments. **No em-dashes. No `·` middle-dot separators** — use commas or full sentences ("1 incident, 4 minutes" not "1 incident · 4m"). Honest phrasing: state correlation, not causation ("Impact compares the 2 hours after a deploy with the 2 hours before it. Correlation is stated, causation is yours to judge."). Headlines state a benefit in the user's words ("Everything is up. One thing needs you.").

**Marketing and comparison pages sell (settled 2026-09-15).** Write to win the switch. No concessions to competitors, no "what they do well", no "where we stop", no disclaimers about sources, no "try both before you decide". Lead with what PostDeploy gives and what the competitor charges. Aggression never licenses a false or unsourced claim: every number comes from the plan registry or a cited competitor source, and a gap PostDeploy has is left unsaid, never denied. Docs pages keep their limits sections, because a reader there is configuring, not buying.

## Shape, depth, spacing

- Radius: public 16–28px cards, pill (999px) buttons and chips; dashboard 8–14px cards, 8px controls and buttons.
- Borders: 1px hairlines carry all separation. No decorative shadows; shadow only under product frames (`0 12–24px 36–70px rgba(23,27,18,.05–.08)`), which includes the hero chart frame on a dashboard screen.
- Public spacing: 96–120px between major sections, one idea per viewport, copy max ~52–56ch, product visuals 75–100% of a 1200px container.
- Dashboard spacing: 24px content padding, 14–18px card padding, full-width layouts that use the page.
- Focus: 2px `#2E62E8` ring with 2px offset, on everything interactive.
- Icons (dashboard): Lucide, 16px, 1.8px stroke. Icons label, never decorate.

## Logo

Pebble/organic blob mark in `#C0DF16` with an `#8FA80E` satellite dot, followed by the lowercase wordmark `postdeploy` + a `#8FA80E` terminal dot, set in Open Runde 700. Word and dot are one unit; the mark sits 9px before it. On dark, the mark stays brand-lime, wordmark goes `#F4FADC`.

## Signature patterns

- **Interactive product frames**: real product components enlarged for marketing (hero overview with metric tabs, time ranges, clickable deploy markers). Never fake dashboards; marketing versions may be larger and simpler, never invented.
- **Deploy markers** (`▲ v2.4.1` ink pill) annotate every time-series chart; deploys, incidents, and changelog posts cross-link everywhere.
- **Uptime ticks**: rounded bars/squares in `operational` green, failures in `failure` red, one per check/day.
- **Charts**: answer a concrete operational question in seconds or don't exist. Bar axes start at zero. Direct series labels over legends. Values readable without hover and without color alone.
- **Buttons**: public primary = brand lime pill with ink text; dashboard primary = ink fill, white text, 8px radius; secondary = 1px `#E1E4D9` border; destructive = `#B42318` text with `#F3D2CE` border.
- **Pills/badges**: status washes with text-safe pairs (New = brand-wash/brand-deep, errors = red wash, late = amber wash, connected/positive = green wash).

## Public expression, generic rules (apply to ALL public surfaces)

Applies to the homepage, pricing, help/docs, public status pages, public changelogs/blog, auth, and embeddable widgets. Container: `max-width:1200px` for marketing, status pages, and changelog shells; `max-width:720–840px` for help articles and long-form reading bodies; 40px side padding (16–20px under 480px); white `#FFFFFF` page background.

Universal rules:
- Type: Lastik/Bricolage 600 for the page's one or two big headings only; Open Runde for everything else. Reading body: Open Runde 400 16px/1.65 `#171B12`; secondary `#5A6352`.
- One idea per screenful. Prefer taller pages over denser sections.
- Cards: white, 1px `#E9ECE4`, 14–18px radius. Shadow ONLY under interactive product frames.
- Links: ink text with 2px `#C0DF16` underline, hover `#F4FADC` wash.
- Machine values (dates, versions, uptime %) in Geist Mono 12–12.5px `#6E7864`, even on public pages.
- Status is always dot + word. Pills use the status washes with text-safe pairs.
- Never: card grids of features, testimonials walls, logo carousels, sticky promo bars.

### Marketing page recipe (homepage, product pages, pricing)

### Public navbar
Height ~64px (20px vertical padding), no border or a bottom hairline `#F0F2EC`. Left: logo lockup (pebble mark 22px + `postdeploy` wordmark, Open Runde 700, 16.5px, with the `#8FA80E` dot). Center: 5 links max, Open Runde 600 14px `#5A6352`, 30px gap. Right: "Log in" text link + one brand-lime pill CTA (`#C0DF16` fill, ink text, Open Runde 700 14px, padding 11px 20px, radius 999px). No mega-menus, no dropdowns.

### Hero
Centered column, 88–110px top padding. Order, top to bottom, 22–26px gaps:
1. Status pill: hairline `#E9ECE4` border, 999px radius, 8px 15px padding, containing a 7px `operational` dot + Open Runde 600 12.5px text (e.g. "postdeploy.dev, all systems operational").
2. Headline: Lastik/Bricolage 600, 52–62px, line-height 1.05, −0.025em, max-width ~780px, often two lines. May carry one `#E7F3A3` highlight wash (`background:linear-gradient(transparent 62%, #E7F3A3 62%)`) on the key phrase.
3. Standfirst: Open Runde 500, 16–17px/27px, `#5A6352`, max-width 520px.
4. CTA row: one lime pill primary (14px 28px padding) + one text secondary with a 2px `#C0DF16` underline.
5. Reassurance line: Open Runde 500 12.5px `#6E7864` ("14 days free, no credit card").
6. A large interactive product frame (below).

**Homepage hero is a setup transcript (settled 2026-10-12).** The homepage alone replaces the centred column above with two columns at `lg` (`5fr/6fr`, 48px gap, `max-w-content`, 16px top padding (24px from `sm`)). Left, left-aligned: the headline (Bricolage 600, `clamp(30px, 1.6vw + 20px, 44px)`, max 600px, one `interactive-tint` wash on the closing sentence), the standfirst, the lime pill CTA with the underlined text link, and the trial and price line. Right: a `bg-surface-inverse` terminal built from `border-inverse`, `surface-inverse-control`, `text-inverse-code`, `text-inverse-muted` and `status-live-inverse` tokens, mono 12px/20px, then a 3-step strip, then one hairline "plain endpoints" panel. A full-width sunken founder letter strip (portrait, letter, signature, profile links) sits under both columns, so the whole hero fits a 1280x800 fold. On mobile, the founder letter sits between the hero copy and the transcript. The status pill appears only with live data from 640px up; it is absent for preview data. The terminal lists only action ids that exist in the MCP registry (`monitor.create`, `measure.create_source`, `status.ensure_workspace`); never invent an id for effect. The product frame follows below the hero in its own section, not inside the fold.

### Interior masthead (settled 2026-09-15)
The centred display hero above belongs to the homepage alone. Pricing, product hubs, comparisons, and other marketing pages open with `leadspace/1`, a compact masthead. Order: breadcrumb trail, then the `<h1>` in `heading-01` (28 to 40px) on the reading edge, then the standfirst (15px on mobile, 17px from `sm`, max 64ch). Product and comparison pages use one primary action near the title. Their content follows one reading column. Comparison pages put the evidence table and source links in that flow; product pages put technical details and limits there. No eyebrow above the title: the breadcrumb already names the section. Section titles on these pages use `heading-02`, so the page keeps three clear steps (40, 21, 17px). The first content row starts inside the first half of a 900px desktop viewport.

### Docs and Guides
Both collections use `resource_shell/1`. The sidebar holds a search field, a Docs and Guides segmented switch, and the current collection's categories; only the current category expands. On mobile, a native disclosure opens the same navigation. Search uses one GET results page for both collections. Index pages open with one sunken "Start here" panel, then group links by topic as ruled rows.

Articles (Docs, Guides, and product articles such as `/monitoring`) share one pattern in a 46rem reading column: `resource_masthead/1` (breadcrumb, `h1`, standfirst, one meta line, the action row under the words), the `page_contents/1` sunken jump-link panel, body sections separated by space rather than rules, then `article_section/1` blocks for questions, limits, sources, and `related_links/1`. Hairlines appear only inside lists. A trial action appears in the topbar and after the article.

### Product frame (the only thing allowed to float)
White card, 1px `#E9ECE4` border, 18px radius, shadow `0 20px 60px rgba(23,27,18,.08)`, max-width 920px. Top bar: 13px 20px padding, bottom hairline, Geist Mono 12px `#6E7864` context ("org / project, environment") left, controls right. Inside it, dashboard vocabulary applies (Geist, real chart patterns, deploy markers). Range switchers are segmented pills: `#F5F6F1` track (999px, 3px padding), active segment white with `0 1px 5px rgba(23,27,18,.12)` shadow, Open Runde 600 12px.

### Section rhythm
96–120px vertical padding between sections. Each section: centered eyebrow (Geist Mono 600 12.5px `#6E7864`, uppercase, e.g. "MONITOR"), headline (Lastik 600 38–44px/1.1), standfirst (Open Runde 500 15px/25px `#5A6352`, max-width 480–560px), then ONE artifact: a product frame, a two-column frame pair (grid 5fr/7fr or 7fr/5fr, 18px gap, max-width 920px), or a diagram. Alternate white and `#FBFBF9` section backgrounds (with top hairline) for gentle banding. Never two ideas in one section; never a card grid of features.

**Homepage section headings (settled 2026-10-12).** On the homepage the Monitor, Measure, Observe, Status and MCP sections carry no eyebrow. Each heading is Bricolage 600, 26px (32px from `sm`), left-aligned at max 640px, over a standfirst at max 560px, inside a shared hero-derived content column that follows the hero gutters. The two-frame pairs below share that same width. The centred eyebrow and the 38 to 44px heading above apply to other marketing pages. The final CTA keeps the centred 44px headline.

**Interior pages after the homepage (settled 2026-10-12).** `leadspace/1` puts its actions under the words, never at the far edge. Its `evidence` slot holds the page's one decision aid beside the title. A product page (`/monitoring`, `/error-tracking`, `/analytics`) puts `setup_transcript/1` there: the example agent session, with only real registry actions and a context bar that says "example session". A comparison page puts the "Switch if" list there, and its evidence table runs the full container width. Code panels, not a second transcript, show the line that changes on a comparison. Pricing orders the offer, the agent setup, the features, the allowances, the terms, then the FAQ. `/about` places `founder_letter/1` (the homepage block) under the masthead.  Product pages and comparisons keep their one primary action near the title and carry no closing CTA.

### Closing CTA + footer
CTA: centered, 100px padding, Lastik 600 44px two-line headline, one lime pill, one reassurance line. The sitewide footer uses a quiet sunken surface with a brand description, grouped Product, Resources, and Company links, and a separate author credit. Keep links readable and at least 44px tall on touch screens.

### Auth pages
Inherit the public expression: centered, generous, Lastik heading, Open Runde labels, inputs 1px `#E1E4D9` border 8–10px radius (`rounded-input`, 10px in the public arm; public *buttons* are pills, public inputs are not), one lime pill submit. Not a tiny form in a big rounded card; the form sits directly on the page with breathing room. Error states inline under the field (Open Runde 500 13px `#B42318`), never toasts. OAuth buttons: hairline border, provider name, 44px tall.

### Pricing recipe (single package, settled 2026-09-18)
There is one package, so there is no card row and no comparison of offers. `/pricing` opens with the plain interior masthead (`leadspace/1`, no evidence column): breadcrumb, `heading-01` value proposition, standfirst. Directly under it, inside its own hairline-bounded band, sits the offer (`package_offer/1`) as a 7/5 grid at `lg`: on the reading edge, "What you can run" in `heading-02` over the headline allowances as ruled rows, two columns from `sm`, closing on the eligibility line in `text-caption`; beside it the priced panel, the page's one frame and its one primary action. **The panel is the page's ink peak (settled 2026-09-18):** `bg-surface-inverse`, `rounded-frame`, `p-6` (`lg:p-7`), no border, because ink declares its own elevation. Inside it, package name in `heading-03` `text-text-inverse` beside the brand-wash trial chip, price in `text-metric` (mono 40px) `text-text-inverse` with the interval as a sans caption, the billing terms as `text-caption` `text-text-inverse-muted` lines, the lime pill CTA at full width, then the trial sentence over a `border-border-inverse` rule. It is the only ink surface on the page and the only dark object in the scroll until the footer, which is what makes the price unmistakable; everything around it stays white and quiet. Below `lg` the panel takes `order-first` and caps at `max-w-measure`, so price and CTA stay inside the first viewport on a phone, the pill never stretches across a tablet, and the allowances still precede the closing CTA. Below, in order: the included capabilities as a two-column ruled row list, never a card grid (`package_features/1`); every enforced allowance in one `rounded-frame` panel, grouped, label left and value right, mono for measurements and the sans body for a value that is a sentence (`included_list/1`, `face: :prose`), with notes in `text-caption` so an annotation never outweighs its label; the terms sheet, how limits behave beside what is not included, both as ruled rows, full width and always above the closing CTA (`package_terms/1`); then body sections, FAQ, and the shared `final_cta/1`. Every split on this page, the section's 5/7 heading grid and each inner two-column list alike, engages at `lg` (1056px) and at no breakpoint below it: from 768 down the page is one column at full reading measure, and the terms sheet keeps the full width at every size. FAQ: hairline-separated rows, question in `text-heading-03`, answer in `text-body-long` `text-text-secondary`; no accordions unless more than 8 items. Never a plan ladder, a "most popular" badge, a billing-interval toggle, or a second priced offer. The price figure itself appears in exactly three reviewed places, all reading through `PackagePresenter`: the masthead standfirst, the panel, and the cost FAQ answer. Never restate it in a section intro, and never write a package number into a template.

### Public status page recipe
Marketing-width container (max 1200px). Top: org logo small, then a full-width state banner: `#EAF9F0` wash card (red/amber wash when not operational), 18px radius, 18–22px padding, 9px dot + Open Runde 700 14.5–16px text-safe color ("All systems operational"), timestamp right in Geist Mono 11–12px. Below: one row per component: name Open Runde 600 13px left, 90-day tick strip center (one 14px-tall, 2px-radius square per day, 1.5px gap, `operational` green / `failure` red / `#E9ECE4` no-data), uptime % right in Geist Mono 11.5px `#5A6352`. Caption under strips: Open Runde 500 11.5px `#6E7864` ("90 days, one square per day, incidents link to their post-mortem"). Active incident: failure-wash card above components with title, plain-language updates in reverse order, each with timestamp and status pill. Resolved incidents: hairline-separated list below, no card grid.

### Public changelog / blog recipe
Index: marketing-width container (max 1200px), page title Lastik 600 38px, then filter chips (hairline pills, active = `#F1F2EC` fill) + "RSS, JSON" right. Entries as hairline-separated rows: date Geist Mono 12px `#6E7864` in a fixed left column (110px), area tag pill, title Open Runde 600 14.5–16px, one-sentence summary 400 13.5px `#5A6352`. Rows link whole. Group by year with a sticky mono year label once long.
Entry page: marketing-width shell with a readable body measure. Meta line first (date, area pill, version pill in mono), then H1 Lastik 600 34–40px, standfirst Open Runde 500 17px `#5A6352`, then body: Open Runde 400 16px/1.65, H2s Open Runde 700 22px with 40px top margin, images inside product-frame cards with captions (Geist Mono 12px `#6E7864`), code in dark panels (below). Footer nav: previous/next links + back to index. Every H2 gets an anchor.

### Help / docs recipe
See "Docs and Guides" above. Callouts: wash cards (brand-wash for tips, amber for caution) with 14px radius, 14px 18px padding, bold lead word instead of icons. Step lists: numbered, number in a 22px `#F1F2EC` circle, Geist 600 12px.

### Code panels (public and dashboard)
Background ink `#171B12`, 10–12px radius, header row (filename/language left, "copy" right, Geist Mono 11.5px `#A9B49B`, bottom border `#2A342F`), body Geist Mono 12.5px/20px `#E8ECDF`, 14–18px padding, horizontal scroll inside the panel. Comments `#A9B49B`; success lines `#C0DF16`. The only dark surfaces anywhere.

### Embeddable widget recipe
Restrained enough for someone else's site: white (or ink, in dark variant) card, 1px border, 12px radius, system-safe fallback fonts allowed. Variants: status badge (dot + "All systems operational", one line, 999px pill); uptime widget (badge + 30/90-day tick strip + %); status summary (badge + component rows); changelog widget (latest entry title, date, one-liner); combined. Compact ≤ 320px wide, expanded ≤ 480px. One quiet "PostDeploy" attribution in Geist Mono 10.5px. No shadows, no animation except the live pulse.

## Dashboard page recipe (follow exactly)

Shell: full-width, `#FFFFFF` main on the right of a 216px sidebar, Open Runde everywhere, Geist Mono for machine values only.

The distilled screen (settled 2026-08-29, every console screen follows it):

- `<h1>` = the answer. No `:intro`.
- Then exactly one of: a hero chart frame, a row list in one `data_panel`, or a `first_run_card` when there is nothing yet.
- A "Needs attention" list may sit above the one thing, only when something needs a person.
- Filters and search appear only when the list is long enough to need them (more than six rows, or a filter already in the URL).
- No stat bands, no summary cards, no resting-row table previews, no "view data table" folds, no footer prose, no checklists, no second panel restating a prerequisite.

### Sidebar
216px wide, `#FBFBF9` background, right hairline `#ECEEE8`, 12px 10px padding. Top: org switcher row (20px logo tile, Geist 600 13px name, `⌄`). Items: 6px 10px padding, 8px radius, Geist 400 13px `#454D3E`, 16px Lucide icon (1.8px stroke) + label, 9px gap. Active item: `#EFF2E6` fill, `inset 2px 0 0 #C0DF16` left bar, ink text, icon stroke ink. Group labels: Geist Mono 600 10.5px uppercase `#6E7864`, 12px above group (MONITOR, OBSERVE, MEASURE, PUBLIC). Counts/badges right-aligned (e.g. red `#FDECEA`/`#B42318` incident count). Bottom, pinned: MCP, Settings, then user row above a top hairline. Search row shows `⌘K` in Geist Mono 10.5px.

### Page header
Breadcrumb row, 14px 24px padding, bottom hairline: project name Geist 500 13px `#6E7864`, `/` in `#D7DCCE`, current page Geist 600 13.5px ink. Right side: environment pill (hairline border, 6px dot, "production"), time-range control, or the page's single primary action (ink fill button). Below it, optionally, one plain-language summary line: Geist 600 19px ("Everything is up. One thing needs you.") + "updated 12s ago" in Geist Mono 12px.

### Content layout
Page gutter 16px below `sm`, 24px from `sm`, 32px from `lg`. The content column caps at 1440px and centres; below that the page is full-bleed. The context bar aligns to the same measure, so the breadcrumb, the time range and the first card share one left and one right edge.

Compose from cards: white, 1px `#ECEEE8` border, 12–14px radius, NO shadow inside the shell (shadow only on the marketing-side frames). Card gutter is 20px. Card anatomy: header row (20px side padding, bottom hairline, panel title left in `heading-03`, Geist Mono 12.5px metadata right), body, optional footer strip (top hairline, explanatory sentence in `caption`).

Two spacing intervals, and the contrast between them is what makes a page read as groups: **16px between sibling cards inside one group, 24px between the page's major sections.** `console_page/1` sets the 24px; a group sets its own 16px. Nothing else.

Use the full page width. A hero chart frame takes `2fr/1fr`, chart beside its rail; a list takes the full width. Never a wall of metric cards, and never a metric row above a list: the numbers that matter are the centred cells at the top of the chart frame, or the trailing value on each row.

### Tables
Header row: `#FBFBF9` band, Geist 600 12px uppercase `#6E7864`, 12px 24px padding. Rows: 13–14px 24px padding, top hairline `#F5F6F1`, Geist 400 13–13.5px; machine values (dates, versions, durations, counts) in Geist Mono 12.5px `#5A6352`; leading status dot 8px + word. Impact/status chips: 999px pills in status washes with text-safe colors, 500 12px.

### Cards, in detail
Four card types, nothing else:
1. **Panel** (default): header row + body (+ footer strip). Use for charts, lists, forms.
2. **Stat tile**: 12px radius, 12–16px padding, label (Geist 500 12.5px `#6E7864`) over value (Geist 600 24px, −0.02em, ink or status text-safe color) over one mono context clause (Geist Mono 12px). Max 4 in a rail.
3. **Alert card**: status-wash background (`#FDECEA`/`#FCF0DD`/`#FCF6E8`), matching 1px border (`#F3D2CE`/`#F0E2C0`), dot + bold title in the text-safe color, plain-language body, actions right. Used for open incidents, drafts awaiting review, danger zones.
4. **Row list**: panel whose body is hairline-separated rows (13px 24px padding), leading 8px status dot, primary text 13–13.5px, trailing mono metadata `#6E7864`.
Never nest cards more than one level. Never put a shadow on a card inside the dashboard shell.

### Charts in the dashboard
Bars: 2–3px gap, 3px top radius, brand `#C0DF16` (or muted `#B7C46E`) for normal, `degraded`/`failure` only when semantically true. Deploy marker: 1px ink vertical line (opacity .22) + ink pill `▲ vX.Y.Z` (Geist Mono 10–11px, `#F4FADC` text). Axis captions: Geist Mono 10.5–12px `#6E7864`, left = range start, right = "now"/"today", center = one insight sentence ("threshold 400ms, never crossed"). Every value the chart makes visible must also exist as text somewhere on the card.

Full chart vocabulary (pick by the question, not by looks):
- **Uptime ticks**: is it up? Equal-width bars, 2px gap, 3px radius, green/red/amber by check result; heights may vary ±40% for texture only.
- **90-day grid**: how reliable lately? One square per day (status-page spec above).
- **Bars over time** (response, traffic, events): what's the trend? Bars brand lime, post-deploy regression bars amber, error spikes red on an `#E4E7DE` quiet baseline; deploy marker line + pill.
- **Wave/area** (traffic feel): smooth quadratic path, stroke `#8FA80E` 1.6px, fill `rgba(192,223,22,.22)`. Marketing and overview only, never for precise reading.
- **Sparkline**: inline 60–120px wave or bars, no axes, always next to its number.
- **Ranked horizontal bars** (top pages, referrers): label left (mono for paths), 9px track `#F0F2EC` with brand fill proportional, count right in mono. Sorted descending, max 6 rows, "view all" after.
- **Percentile lines** (p50/p95/p99): distinct dash patterns + direct end labels, never a color-only legend.
- **Stacked composition** (2xx/4xx/5xx): status colors only, max 4 series, direct labels.
- **Step line** (sparse counts): horizontal steps, dots at events.
- **Timeline** (incidents/deploys): horizontal axis with square event markers, mono timestamps, one label per marker.
Rules for all: axes start at zero for bars; time axes read left→old, right→now; empty state = dashed border + sentence, never an empty grid; loading = `#F1F2EC` skeleton bars at plausible heights; tooltips repeat x, y, and context in Geist 12.5px on an ink card (white text, 8px radius).

### Dashboard typography scale (exact)

**The rail and the content region are sized apart (settled 2026-08-28, do not reopen).** The 216px rail is chrome, read at a glance, and keeps every value below. The content region is the product, read for minutes at a time on a 1440px canvas, and the values the visual spec draws are specimen-frame sizes: at real width they produced a page that looked like a 600px settings form dropped into a dashboard. `[data-console-content]` on the shell's `<main>` and its context bar carries the larger scale; the rail sits outside it and is unchanged. Both columns of the table below are real, and no component chooses between them: the scope does.

| Role | Rail (base) | Content region |
|---|---|---|
| Page `<h1>` | 20px | **28px** (22px below `md`) |
| Summary band headline | 17px | **20px** |
| Panel title (`heading-03`) | 14px | **16px** |
| Stat value | 24px | **28px** (hero stat 34px) |
| Working text and rows | 13px | **14px** |
| Reading body (intro, panel prose) | 14px | **15px** |
| Labels, tile labels | 12px | **13px** |
| Small sans (`caption`) | 12.5px | **13px** |
| Mono metadata | 12px | **12.5px** |

- Table headers: Geist 600 uppercase at the `label` size
- Absolute floor 12px, with one exception: chart annotations drawn inside the plot (axis captions, threshold sentences, deploy-marker pills) may go to 10–11px, as the visual spec draws them. Nothing else goes below 12px.
- **Chips and tooltips sit at the floor, not at the drawn size (settled, do not reopen).** The visual spec draws chips at 11–11.5px and the tooltip at 11px. Both carry meaning a reader must act on, and neither is drawn inside a plot, so the exception above does not reach them. Chips render at 12px (`text-chip`) and tooltips at the 12.5px this file already gives overlay copy (`text-tooltip`). The difference from the drawing is under 1.5px and changes no layout; sub-12px body text changes who can read it.
- Weights: 400/500/600 only, no 700 in the dashboard.

### Forms and controls, in detail
- **Text inputs / selects**: 1px `#E1E4D9`, 8px radius, 9px 13px padding, Geist 400 13.5px, white background. Label above, Geist 500 12.5px `#5A6352`, 5px gap. Help text below, 400 12px `#6E7864`. Focus: 2px `#2E62E8` ring, border unchanged. Error: border `#D92D20`, message below in 500 12.5px `#B42318` stating what to do. Disabled: `#FBFBF9` fill, `#8A9691` text. Selects show `⌄` right in `#6E7864`. Machine-value inputs (domains, tokens) use Geist Mono 13px.
- **Checkboxes**: 15px, 4px radius, 1.5px `#C9D0BD` border; checked = ink fill, lime `✓`. Label 400 13px, 10px gap, whole row clickable.
- **Radios**: 15px circles, checked = ink ring + ink center dot. Use segmented pills instead when 2–4 short options.
- **Toggles**: 34×20px, 999px; on = `#00B140` fill, knob white 16px; off = `#E9ECE4`. Never for actions, only state.
- **Segmented control**: `#F1F2EC` track (999px, 2–3px padding), active segment white with `0 1px 5px rgba(23,27,18,.12)`, Geist 600 12–12.5px; inactive `#6E7864`.
- **Buttons**: primary = ink fill, white text; secondary = 1px `#E1E4D9` border, ink text; ghost = text-only `#454D3E`; destructive = `#B42318` text, `#F3D2CE` border (fill `#D92D20` white only in confirm dialogs). All Geist 500 13px, 8px radius, 7–8px 16px padding, 32–36px tall. One primary per view.
- **Dropdown menus**: white, 1px `#ECEEE8`, 10px radius, shadow `0 8px 24px rgba(23,27,18,.10)` (menus and dialogs are the only shadowed dashboard surfaces), items 8px 12px, 13px, destructive items `#B42318` separated by a hairline.
- **Dialogs**: max 440px, 14px radius, title Geist 600 15px, body 400 13.5px `#5A6352`, actions right (secondary then primary). Destructive confirms restate the consequence and name the object ("Delete monitor api-health"), require typed confirmation for org-level deletes.
- **Toasts**: bottom-right, ink card, white text 13px, status dot, auto-dismiss 5s, never for errors that need action (those get alert cards inline).
- **Tabs**: text row, 500 13px, active = ink + 2px `#C0DF16` underline; counts in mono after label.
- **Danger zones**: `#F3D2CE` bordered card with plain-language consequence text ("Removes every project, monitor and page. Asks twice.").
- **Form layout**: single column, 14px between fields, related fields grouped under a Geist 600 13.5px group title; submit row left-aligned at the end. Never two-column forms.

### Empty, loading, error states

Four different states hide behind the word "empty". Each has one shape, and they are not interchangeable.

**A screen with no evidence yet (first run).** One `first_run_card/1`, full width, and nothing else (settled 2026-08-29; the earlier "draw the shape of the product" recipe with placeholder tiles and resting-row previews is retired, it doubled every empty screen). The one exception is a hero chart: it keeps its frame, empty, with the sentence that says what is missing inside the plot.

**One card carries the action:** `first_run_card/1`. Never a dashed frame, never a centred icon hero, never centred text. Header row: title (`heading-02`) with an "Agent connection" label and a `status_badge/1` stating the *real* grant state on the right. Then one sentence saying what will appear here, the agent task in a sunken prompt box under a "Hand this to your agent" label (fill, no border, `font-mono` because the string is a payload for a machine), then one link in the UI face. The copy control is labelled **"Copy task"** on every screen in the product, and the link is one of "Open agent connection" or "Check connection". Two states only: `:not_connected` (warning tone, "Not connected") and `:awaiting_evidence` (success tone, "Connected, awaiting evidence").

The card is the screen. It fills the full content width.

**Say a prerequisite once.** The grant state belongs to the card that owns the action. A screen that prints "Not connected" in a banner, again in a panel header, and a third time inside a setup card has told the reader nothing three times, and has hidden the one next step among them.

**A slot inside a populated panel.** The dashed 1.5px `#C9D0BD` frame, plain sentence, at most one action, at the size the visual spec draws it (§07, a 56px slot inside a bordered card). This is `empty_state/1`, and `data_display/1`'s `:empty` state draws the same frame. A `:full` display that also states its `range` grows that frame to a real plot height and keeps its baseline, because there is an axis above it to hold up; every other case keeps the 56px slot. It is also the one documented exception to "a bordered container never contains another bordered container", because the dashed slot marks absent content rather than framing present content.

**A list filtered to zero matches.** Not a card and not a dashed frame. One sentence and a "Clear filters" link, inside the `data_panel` the rows would have filled. Nothing needing attention is a good outcome, not a missing prerequisite.

**A read that failed.** The red-wash error boundary: what happened, what to do, a retry. Never dressed as a first-run state, or the reader learns that "nothing here yet" and "we could not look" mean the same thing.

Loading: skeleton bars in `#F1F2EC`, no spinners for content. Errors: red wash card, what happened + what to do, never a bare code.

Resolved against the visual spec (2026-08-28): sections `05` and `12` draw **no** first-run treatment. Every dashboard specimen is populated, and the MCP screen (`05`) draws only a connected client. The single drawn empty state is the in-panel dashed slot at `PostDeploy v3.dc.html` line 635. The first-run card above is therefore this file's decision, not a contradiction of the spec, and the dashed frame stays at the size the spec draws it.

### MCP provenance (mandatory)
Anything an agent created/changed says so inline: "claude-code via MCP", drafts show a Draft amber pill + "Waiting for your review", the MCP page lists connection (client, org, scopes, last active, Reconnect/Revoke) and an audit table (ACTION in mono, resource, client, result with ✓/⚠). Destructive tool calls render "⚠ needs confirm".

## Accessibility

WCAG AA is the floor, not the target. Console text is mostly 12.5 to 14px, so AA-normal (4.5:1) is the honest bar, and the neutral ramp clears it on every surface a token can legally sit on, not only on white.

**Measure on the surface, not on white (settled 2026-08-28).** The old ramp read as AA-safe because it was measured on `#FFFFFF`. On the `#F1F2EC` well that chips and segmented tracks use, `text-tertiary` was 4.11:1, a real failure on 46 rendered elements. Check every neutral against `#FFFFFF`, `#FBFBF9`, `#F5F6F1`, `#F1F2EC`, and any status wash it sits on.

Current ramp: primary 17.5:1, secondary 7.9:1, tertiary 5.8:1 on white; 7.0:1 and 5.2:1 respectively on the well. Three levels, all comfortably readable.

`text-disabled` (3.3:1) is the one deliberate exception: a disabled control must still read as disabled, and WCAG exempts it. Never use it for a value that is merely absent; a placeholder metric takes `text-tertiary`.

**`opacity` inherits down the subtree.** A label nested inside a faded element renders faded too. The deploy marker drew its version label inside its own 20 percent guide line and reached about 1.3:1. Fade the mark, never the text: give the line its own element and give the label the ink pill.

Meaningful text never in faint grey. Status = dot + word. Reduced-motion support; nothing loops except live pulses. Hit targets ≥ 44px on mobile.

## Avoid

Gradient blobs, glassmorphism, card-grid walls, decorative charts, fake metrics, AI chat UI, emoji, monospace-as-decoration, tiny grey metadata, em-dashes, middle dots, truncated bar axes, color-only state, extra hues invented for variety. Also: intro sentences under a title, stat bands above a list, panels that explain another panel, "view data table" folds on a hero chart, checklists of steps the reader already did.

---

# Implementation appendix

The spec above states design intent in raw values. This appendix is how those values are expressed in this codebase. It is the only part of this file an engineer copies from.

**The default Tailwind palette is wiped in `theme.css`.** `bg-blue-500`, `text-sm`, `rounded-xl` and `shadow-md` render nothing. A raw hex or an invented token name renders invisible. Use the semantic classes below. If the spec needs a value with no token, add the token to `tokens.css`, map it in `theme.css`, then use the class. Never inline a hex in a template.

## Where things live

- **Visual authority:** `elixir/designSystem/PostDeploy v3.dc.html`. Every hex, size, radius and spacing decision originates there. This file describes it; that file settles it.
- **Token values:** `elixir/assets/css/alp/tokens.css`. Dark arm in `dark.css`.
- **Class mapping:** `elixir/assets/css/alp/theme.css`.
- **Fonts:** `elixir/assets/css/app.css`, four self-hosted families in `elixir/priv/static/fonts`.
- **Primitives:** `elixir/lib/alplus_web/components/{core,console,dashboard,marketing}_components.ex`.

## Scope attribute picks the arm

`[data-public-shell]` selects the public expression, `[data-webmcp-dashboard]` and the `:root` default select the console. A component never branches on the arm itself; the scope resolves it.

`[data-console-content]` sits on the shell's `<main>` and its context bar and selects the console **content scale** (`theme-console.css`): the same roles, sized for the product region rather than for the rail. Both halves of that block are required. Tailwind resolves `--text-*` at `:root`, so a deeper `--alp-type-*` override alone never reaches a utility; the theme layer is re-declared inside the scope for the same reason the public arm re-declares it in `tokens.css`. Adding a role means adding it in both places, or it silently keeps the rail's size everywhere.

## Class vocabulary

| Concept | Classes |
| --- | --- |
| Text | `text-text-primary`, `text-text-secondary`, `text-text-tertiary`, `text-text-disabled`, `text-text-inverse`, `text-text-inverse-muted` |
| Surface | `bg-surface-page`, `bg-surface-raised`, `bg-surface-sunken`, `bg-surface-inverse`, `bg-surface-inverse-raised` |
| Border | `border-border-subtle` (inner rule), `border-border-default` (panel edge), `border-border-control`, `border-border-public`, `border-border-strong` |
| Interaction | `bg-interactive-primary`, `bg-interactive-hover`, `bg-interactive-tint`, `bg-interactive-wash`, `text-interactive-ink`, `bg-interactive-ink-hover`, `text-interactive-strong`, `border-interactive-outline` |
| Status | `status-live`, `status-error`, `status-late`, `status-info`, `status-paused`, `status-neutral`, each with `-ink`, `-bg`, `-border` |
| Charts | `chart-p50`, `chart-p95`, `chart-p99`; `chart-{visits,pageviews,bounce-rate,avg-duration}` and their `-soft` fills |

`border-border-control` is `#7F8777` since 2026-08-30 (3.7:1 on white, 3.4:1 on the well). The visual spec drew the input boundary at `#E1E4D9` (1.29:1); WCAG 2.2 1.4.11 needs 3:1 for a control boundary, so the token wins over the specimen and every input, select and filter control uses it. Placeholders render in `text-tertiary` at full opacity for the same reason.

`interactive-strong` (`#69790D`) is the only brand value allowed as text or as a data mark on a light surface. `chart-p50` and `chart-p95` sit below 3:1 on white by design, so a dash pattern always carries the same distinction.

## Type roles

Families: `font-display` (Bricolage Grotesque, standing in for Lastik), `font-public` and `font-ui` (both Open Runde since 2026-08-29), `font-mono` (Geist Mono, machine values only).

Roles: `text-type-display`, `text-heading-01`, `text-heading-02`, `text-heading-03`, `text-body-long`, `text-body`, `text-label`, `text-caption`, `text-data`, `text-metric`, `text-metric-compact` (a panel's one headline number, 24px, −0.02em), `text-stat` (a rail reading or tile, 20px), `text-chip`, `text-tooltip`, `text-eyebrow`.

**`text-heading-03` is the panel title**, one step above the rows a panel holds and one step below the `heading-02` a summary band uses for its answer sentence. `data_panel/1` and `section_card/1` both draw their title with it. It exists because both were borrowing `text-ui`, a body role, so a panel header rendered at the same size as its own rows and no amount of weight recovered the step. Each role carries size, leading and weight for the current arm. Do not add a competing `font-*` or `leading-*` utility. Only `text-data` and `text-metric` are mono; a label is not a machine value.

**`text-caption` is the console's small sans role** (Geist Sans 12.5px/18px, weight 400, `text-text-secondary` or `text-text-tertiary`; 15px/22px in the public arm, which sets nothing below 15px). Use it for a short secondary sentence, a panel footer strip, a tile label, or any small prose. It exists because `text-data` carries `font-family: mono` at the role level, so reaching for `text-data` as "small text" silently set every short sentence in Geist Mono: 308 uses against 191 of `text-body` before the sweep of 2026-08-28.

**`text-data` styles a value. Never a sentence, and never a link.** Mono appears only on identifiers, tokens, endpoints, versions, timestamps, counts, stack traces, and the agent task string inside the first-run prompt box. `text-meta`, `text-code` and `text-numeric` alias the same mono size and carry the same rule; all three have zero call sites and should stay that way. A count in a table cell takes `tabular-nums` in the UI face, which the table recipe already says.

## Spacing, shape, controls

- Spacing: `sp-01` to `sp-09` on the 4px rhythm (4, 8, 12, 16, 24, 32, 48, 64, 96). Aliases `gap-section`, `gap-stack`, `gap-inline`, `p-page`. Widths `max-w-page-full` (1440px, the console content cap), `max-w-content`, `max-w-prose`, `max-w-measure`.
- Shape: `rounded-structural`, `rounded-frame`, `rounded-control`, `rounded-control-sm`, `rounded-input`, `rounded-overlay`, `rounded-tick`, `rounded-dot`. Inputs and selects use `rounded-input` (8px console, 10px public) because `rounded-control` is a pill in the public arm.
- Elevation: `shadow-frame`, `shadow-overlay`, `shadow-modal`, `shadow-toast`. Nothing else floats.
- Control height: `h-control-sm`, `h-control-md` (default), `h-control-lg`. Coarse pointers scale up automatically, and every size including `h-control-sm` reaches 44px there, so a control never needs its own `min-h-target-min` to clear the touch floor.
- Motion: `duration-productive` (110ms) for feedback, `duration-expressive` (240ms) for a deliberate reveal. Reduced motion collapses both globally.
- Disabled is a fill plus muted ink (`bg-status-paused-bg`, `text-text-disabled`) with `cursor-not-allowed`, never opacity.

**Binding layout rule: a bordered container never contains another bordered container.**

## Primitives

`CoreComponents` (auto-imported): `logo/1` (the only way to draw the logo), `button/1`, `input/1`, `header/1`, `table/1`, `list/1`, `chip/1`, `tooltip/1`, `skeleton/1`, `flash/1`, `icon/1`, `timestamp/1`, `modal/1`, `ruler/1`, `tabs/1`, `pagination/1`, `alert/1`, `article_layout/1`, `code_panel/1`, `metric_row/1`, `index_row/1`.

`ConsoleComponents` (every `/dashboard/` page): `console_page/1`, `status_badge/1`, `status_dot/1`, `stat_card/1`, `section_card/1`, `data_panel/1`, `summary_card/1`, `first_run_card/1`, `empty_state/1`, `permission_notice/1`, `checklist_item/1`, `project_select/1`, `environment_select/1`, `window_select/1`, `definition_list/1`.

Two primitives carry an explicit "no evidence yet" mode, and a first-run screen composes both (see "Empty, loading, error states"): `stat_card/1`'s `placeholder` and `data_display/1`'s `:empty` with a `range`. `definition_list/1`'s row takes `face={:prose}` when the value is a sentence rather than a machine value, because the row's default face is mono.

`DashboardComponents.dashboard_shell/1` is the app chrome for every `/dashboard/` route. `MarketingComponents` holds the public-site blocks.

## The dashboard page scaffold

`console_page/1` is the only way a `/dashboard/` screen is laid out. It fixes four things so geometry cannot drift between features:

- **Outer gutter**: the shell's `<main>` padding, 16px below `sm`, 24px from `sm`, 32px from `lg`, capped at 1440px and centred. A page never adds its own.
- **Vertical rhythm**: `gap-6` (24px) between the page's major sections. A group of sibling cards inside one section closes to `gap-4` (16px), and the contrast between the two is what makes the page read as groups rather than as one flat stack. No page-level `space-y-*`.
- **Width**: `:full` by default, because a console screen uses the page (design source §12). **A screen with no data is not an exception** (settled 2026-08-28): it draws the shape of the product it is about to become and puts the setup card in one arm of that composition, rather than shrinking to a 720px card in the corner of a 1440px viewport. `:reading` caps a screen that is a sequence to follow rather than a dashboard to scan; today that is Account. MCP left it, because its sequence and its live connection state are two jobs that read better side by side than stacked in one column.
- **Opening**: the `:title` slot draws the screen's one visible `<h1>` in `text-heading-01`, left-aligned. Every console screen opens the same way. A screen passing `:title` must also pass `page_heading?={false}` to `dashboard_shell/1`, or the shell adds a second, `sr-only` `<h1>` and a screen reader announces two. Exactly one `<h1>` per screen, and no skipped heading levels: nothing inside a panel outranks the panel's own title.
- **Intro**: the `:intro` slot is the screen's one plain-language sentence, directly under the title, always `text-body-long text-text-secondary max-w-prose`. A screen that opens with a `summary_card` headline needs none, because the headline is that sentence.
- **Everything else is a panel.** No loose paragraph, copy row or sentence sits on the page background. An explanatory sentence belongs to the panel it explains, in `data_panel/1`'s `:footer` strip.
- **One tab row per screen.** A screen never stacks two. When a second axis needs choosing, it becomes a segmented control in the relevant panel's header, which is what the Changelog Entries and Activity switch is.

Panel gutter is `p-5` (20px) everywhere: `section_card/1`, `summary_card/1`, `first_run_card/1`, `data_panel/1`'s padded body and header, and any in-panel block. A table cell or a row carries the same 20px side gutter, so a panel's rows line up with its own title. Selected state has one shape, an ink label over a 2px underline, and the arm picks the brand value: console surfaces use `interactive-primary` chartreuse (`tabs/1`, matching the visual spec §09), public surfaces use text-safe `interactive-strong` (the Changelog sub-nav, the Status workspace sections). The sidebar's active row is the one exception, and it is chrome, not content.

## No eyebrow

`summary_card/1` has no eyebrow, and no console surface uses small-caps above a heading. The headline states the answer in the user's words and carries its own weight. Uppercase in the dashboard is for table column headers only.

Notes that bite: `data_panel/1` has an unpadded body and is the frame for every table and row list; `section_card/1`'s gutter makes it wrong for a body of rows. `stat_card/1` never sits inside another bordered container. `empty_state/1` is the small dashed in-panel placeholder, never a page hero; a screen with no evidence at all uses `first_run_card/1`, and a list filtered to zero gets a sentence inside its panel. `timestamp/1` renders every time value; never print a raw `inserted_at`.

## The table recipe

Every collection is rows inside one `data_panel`, never a grid of cards. The panel body is unpadded, so cells carry the gutter and the table's `divide-y` becomes the panel's internal rules.

- Counts and metrics get `tabular-nums`; identifiers and tokens get `font-mono`, truncated, full value in `title`.
- A row navigates from its name cell. No stretched-overlay hack, no clickable `<tr>`.
- Action cells are right-aligned and quiet. A destructive action never carries the weight of the row's own name.
- A destructive confirm needs the full row: a second `<tr>` with a `colspan`, inside the same streamed subtree.
- Responsive: drop non-essential columns with `hidden sm:table-cell`. Horizontal scroll is the fallback, not the plan. Every console screen works at 390px.

## When to create a component

Create one when it establishes a shared primitive: two or more real call sites, one interface, and hiding the markup gives callers leverage. Do not create one because markup appears twice. Role-distinct one-offs stay inline. A repeated utility string is a recipe to document here, not a component to build.

Prefer composition over boolean-prop soup. Cross-cutting primitive goes in `CoreComponents`; console-only in `ConsoleComponents`; app chrome in `DashboardComponents`; public site in `MarketingComponents`. Snake_case names, one term for one thing, no synonym for a concept that already has a token.
