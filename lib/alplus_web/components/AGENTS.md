# Choosing and building components

`DESIGN.md`'s implementation appendix lists the primitives and the class
vocabulary. This file records the mistakes that keep happening anyway. A UI
architecture review found every one of them in shipped code.

## Picking the right container

- **`data_panel/1` is the frame for every collection.** Its body is unpadded, so
  cells carry the gutter and the table's own `divide-y` becomes the panel's
  internal rules. Every collection is rows inside one panel, never a grid of cards.
- **`section_card/1` is wrong for a body of rows.** Its padded gutter fights an
  edge-to-edge table. Use it for block content: a form, a chart, prose.
- **`stat_card/1` never sits inside another bordered container.** Use
  `summary_card/1`'s `stats` or a divided grid.
- **A bordered container never contains another bordered container.** This is the
  binding layout rule and the most-violated one. Watch for a bordered
  `error_boundary` or a dashed empty frame dropped inside an already-bordered
  card, and for a mobile row list that adds `border-y` inside its panel. Render
  those states borderless, with a wash background only.

## Four states hide behind the word "empty"

- **`first_run_card/1`** is the *action* on a screen with no evidence yet: a
  left-aligned panel, an "Agent connection" label plus badge in its header row,
  the agent task in a sunken prompt box, and one link. The copy control says
  **"Copy task"** everywhere. Five screens each invented their own version of
  this before it existed; three of them centred a heading over a left-aligned
  mono block inside one frame.
- **The card is not the screen.** Around it, draw the shape the reader is about
  to get: `stat_card/1` with `placeholder` for the metric row, a
  `data_display/1` in `:empty` **with its `range`** for the plot, and a
  `data_display/1` table inside the `data_panel` the rows will fill. Every
  region must name a real product output. Then put the card in one arm of a
  `7/5` grid. A 720px card alone in a 1440px viewport is what this replaced.
- **State the prerequisite once.** It belongs to the card that owns the action.
  Changelog printed "Not connected" in a panel header, again in a second setup
  panel, and a third time inside the first-run card.
- **`empty_state/1`** is the small dashed slot **inside a populated panel**,
  at the size the visual spec draws it. It is the console's only dashed frame
  and the only exception to the bordered-container ban. It is not a page hero.
  `data_display/1`'s `:empty` draws the same frame, and grows it to a real plot
  height only when the display is `:full` and states a `range`, because then
  there is an axis above it to hold up.
- **A list filtered to zero** is a sentence and a "Clear filters" link inside
  the `data_panel` the rows would have filled. Nothing needing attention is a
  good outcome, not a missing prerequisite.
- **A failed read** is `error_boundary/1`. Never dress it as a first-run state.

## Prose is never mono

`text-data` sets `font-family: mono` at the role level, so it is a value style:
IDs, tokens, endpoints, timestamps, counts, and the first-run task string.
Reaching for it as "small text" is the mistake that put 308 mono sentences and
underlined mono links on screen. The small sans role is **`text-caption`**
(12.5px/18px). `text-meta`, `text-code` and `text-numeric` alias the same mono
size and have no call sites; keep it that way.

Two components used to force mono on prose anyway. `definition_list/1`'s value
takes `face={:prose}` for a sentence ("Not assigned yet"), and `stat_card/1`'s
hint switches to the sans caption when the tile is a `placeholder`, because a
tile with nothing to count has no machine value to print.

## Headings

Every console screen opens with `console_page/1`'s `:title` slot: one visible
`<h1>` in `text-heading-01`, left-aligned, with the intro sentence under it.

The shell also renders an `sr-only` `<h1>` from `page_title`. A page that draws
its own heading while still passing `page_title` produces **two competing
`<h1>`s**, which is what screen readers announce, so pass
`page_heading?={false}` alongside `:title`. Nothing inside a panel may outrank the panel's own title:
section titles use the card-title scale, not `text-heading-02`.

## One active nav row

`nav_link/1` sets `aria-current="page"` on every row whose atom matches
`active`. Two rows sharing an atom therefore both claim to be current, and the
rail stops telling the user where they are. Give every destination its own atom,
including pinned ones.

## One primary per view

`variant="primary"` is the page's single advancing action. Opening a record is
inspection, so per-card "Open ..." actions are `secondary`. A list of five cards
each with a primary button, plus a primary "Apply" on the filter bar, is six
primary-weight actions on one screen.

## One filter grammar

Sibling screens must filter the same way. Prefer the live `phx-change` form with
`h-control-sm` controls and no "Apply" button. A `method="get"` form that
full-page reloads beside a screen that patches in place is the drift users feel
first. Removing "Apply" must not remove keyboard operation.

## Component creation

Build a shared primitive only at two real call sites with one interface.
Role-distinct one-offs stay inline; a repeated utility string is a recipe to
document, not a component to build. Prefer composition over boolean-prop soup.
Cross-cutting goes in `CoreComponents`, console-only in `ConsoleComponents`, app
chrome in `DashboardComponents`, public site in `MarketingComponents`.

## Doc examples are copied

A docstring example that shows `"GET · 60s · 2 regions"` teaches the middot the
voice rule bans, and the next component copies it. Write examples to the same
standard as shipped copy.
