# Reading the visual spec

`PostDeploy v3.dc.html` is the authoring source and the visual authority. Read
it line by line; it is 1149 readable lines. `PostDeploy v3.html` is the rendered
twin, 391 lines of ~1.4MB. Open the rendered one only to resolve a template
placeholder (`sc-for`, `{{...}}`), and read it in slices.

## The specimen frame is not part of the product

Screens in this document are drawn inside a bordered, rounded, shadowed frame
with an outer `max-width`, sitting on a pale page. **That frame is this
document's device for presenting a screen specimen. It is not the screen.**

Two separate agents shipped it as product chrome before this was written:

- The auth screens came back as a centred card floating in the viewport. The
  real screens are full-bleed: a full-width top bar, the body filling the
  remaining height, and only the form column constrained.
- The dashboard is likewise full-bleed: a 216px sidebar and a `#FFFFFF` main
  region using the entire page width, with no outer border, radius or shadow.

Read every specimen through that lens. Ask what the screen is, not what the
picture of the screen is.

## Section map

`02 TOKENS`, `04 DASHBOARD`, `05 MCP SCREEN`, `07 CHART LIBRARY`,
`09 COMPONENT LIBRARY`, `11 RESPONSIVE + ACCESSIBILITY`, `12 DASHBOARD SCREENS`
(Observe, Measure, Incidents, Deployments, Status, Changelog, Integrations,
Settings, Billing), `13 COVERAGE`. Sections `01`, `03`, `06`, `08`, `10` are
public-surface; read them to learn which idioms are deliberately public-only and
must not leak into the console.

## Values are read here, never copied

The spec states raw hex and px. The application's default Tailwind palette is
wiped, so pasting a hex into a template renders nothing. Translate through the
token layer: see `assets/css/alp/AGENTS.md`.

`12 DASHBOARD SCREENS` includes a Deployments screen that **does not exist** in
the product. The spec is a design target, not an inventory. Do not add a route
because a specimen exists.
