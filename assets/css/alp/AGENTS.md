# The token layer

`tokens.css` holds values, `theme.css` maps them to Tailwind utilities,
`dark.css` overrides for `data-theme=dark`.

## The default Tailwind palette is wiped

`bg-blue-500`, `text-sm`, `rounded-xl`, `shadow-md` and any raw hex **render
nothing**. An invented token name renders invisible rather than failing loudly,
so the mistake reaches a screenshot before anyone notices.

Adding a value the spec needs is a three-step move, and skipping the middle step
is the usual bug:

1. declare `--alp-*` in `tokens.css`
2. map it to a utility in `theme.css`
3. use the class in the template

Never inline `text-[30px]` or `rounded-[12px]` in HEEx. If you reach for an
arbitrary value, the token is missing. Add it.

Tailwind resolves `--color-*`, `--text-*`, `--radius-*` and `--spacing-*` at
`:root`, so a deeper `--alp-*` override alone cannot reach a utility. The public
scope re-declares that theme layer as well; keep both lists in step when a token
differs between the public and console arms.

## Scope, not branching

`[data-public-shell]` selects the public expression; `[data-webmcp-dashboard]`
and the `:root` default select the console. A component never branches on the
arm itself. This is why `rounded-control` is 8px in the console and a pill on
public, and why an auth input that wants 8–10px needs its own token rather than
an inline radius.

## Changing a token is a global act

Check every consumer before editing. Real example: `--alp-type-eyebrow-size` was
11px, and that role drives `table/1`'s column headers, so one token put every
table header on every screen below the 12px floor. Report the blast radius of
any token change.

## Coarse pointers

`tokens.css` rescales control heights under `pointer: coarse`. Verify the result
still clears the 44px touch floor; `--alp-control-sm` scaling to 40px put the
window segments and filter controls under it.
