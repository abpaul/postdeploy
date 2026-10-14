# Issue #122 accessibility evidence matrix

**Recorded:** 2026-08-25
**Scope:** shared redesign primitives, representative marketing/auth/console/public routes
**Evidence owner:** implementation pass; root browser pass remains required

This matrix separates repository evidence from browser evidence. The code and
component tests below are the evidence recorded in this pass. No browser,
Lighthouse, axe, contrast-ratio, or screen-reader run was performed here.
Rows marked **PENDING ROOT** must stay pending until the root pass records the
actual browser result.

## Evidence status

| Evidence type | Current result | What it proves |
| --- | --- | --- |
| Render and LiveView tests | Code assertions added or updated in the referenced tests | Markup contracts, state labels, focus targets, exact tables, and route behavior |
| Static implementation review | Recorded below by surface | Token use, semantic landmarks, and interaction hooks exist in source |
| Browser contrast and keyboard pass | **PENDING ROOT** | Actual computed contrast, focus order, touch behavior, and assistive-technology output |

## Representative route matrix

| Surface | Route and viewport | Workflow to run | Repository evidence | Browser result |
| --- | --- | --- | --- | --- |
| Marketing home | `/`, 1440×900 and 390×844 | Activate the skip link, move through the header/menu, switch the Measure preview tab, focus a trend point, open exact values, and toggle the theme. | `page_controller_test.exs`, `marketing_components_test.exs`, `measure_activity_components_test.exs`, `layouts/root.html.heex`, `assets/js/app.js` | **PENDING ROOT**: verify focus order, menu dismissal, point touch behavior, and light/dark contrast. |
| Marketing intent pages | `/pricing`, `/monitoring`, `/error-tracking`, `/analytics`, 1440×900 and 390×844 | Use the skip link, inspect the primary CTA, open the mobile menu, and check the page heading and footer links. | `page_controller_test.exs`, marketing templates, `layouts/root.html.heex` | **PENDING ROOT**: verify mobile containment, visible focus, and contrast. |
| Authentication | `/sign-in`, `/register`, `/reset`, 320×800 and 390×844 | Skip to the form, complete keyboard-only invalid submission, confirm focus moves to the first invalid field, and inspect Turnstile error announcement and description. | `sign_in_live_test.exs`, `register_live_test.exs`, `layouts.ex`, `register_live.ex`, `assets/js/app.js` (`FocusInvalid`) | **PENDING ROOT**: verify the `main` landmark, heading/logo names, 320px layout, focus transfer, and live errors. |
| Projects index | `/dashboard/orgs/{org}/projects`, 1440×900 and 390×844 | Open the org switcher with keyboard, inspect a project with no Measure source, open archive confirmation, cancel, then confirm removal. | `projects_live_test.exs`, `project_signals_test.exs`, `projects_live.ex`, `console_components.ex` | **PENDING ROOT**: verify menu Escape/click-away, `No analytics yet`, confirmation focus return, and narrow-table reading order. |
| Measure index/detail | `/dashboard/orgs/{org}/projects/{project}/measure` and `/measure/{source}`, 1440×900 and 390×844 | Focus and tap trend samples, read the tooltip, open exact values, copy a snippet, and test copy fallback after clipboard rejection. | `measure_activity_components_test.exs`, `measure_detail_live_test.exs`, `core_components_test.exs`, `measure_activity_components.ex`, `core_components.ex` | **PENDING ROOT**: verify touch tooltip visibility, exact table access, long identifiers, focus return, and clipboard fallback. |
| Monitor and Observe | `/dashboard/orgs/{org}/projects/{project}/monitor` and `/observe`, 1440×900 and 390×844 | Traverse tabs, filters, data displays, row actions, and a destructive confirmation with keyboard and touch. | `monitor_activity_components_test.exs`, `observe_activity_components_test.exs`, `data_display_components_test.exs`, `assets/js/app.js` | **PENDING ROOT**: verify point interaction, table alternatives, responsive rows, and focus order. |
| Public share/status | `/share/{token}`, `/status/{slug}`, and `/status/{slug}/embed`, 1440×900 and 390×844 | Read the status heading, open tabs/details, inspect uptime data, and use any refresh/time controls with keyboard and touch. | `measure_share_controller_test.exs`, `status_controller_test.exs`, `status_html_test.exs`, public templates | **PENDING ROOT**: verify contrast, exact data-display touch behavior, reduced-motion behavior, and focus. |

## Focused workflow assertions

These are the implementation contracts that the root browser pass must verify
visually and interactively:

1. **Exact values:** shared displays and Measure trend charts derive the table
   rows from the same records as the visual. Point buttons reference those rows
   with `aria-controls`.
2. **Touch points:** delegated handlers in `assets/js/app.js` and the static
   root script show one `role="tooltip"` on click, pointer, or focus, and hide
   it when the user leaves the display.
3. **No source:** Projects uses `data-state="empty"` and the visible text
   `No analytics yet`; a real zero remains a numeric value.
4. **Destructive actions:** `.DestructiveConfirmFocus` focuses the input or
   submit control when opened, the trigger after cancellation, and a supplied
   fallback or main landmark after the original row is removed.
5. **Authentication:** `auth_live` owns one `main#auth-main` with
   `tabindex="-1"`; the root wrapper stays a `div`, so the custom auth shell
   does not create nested `main` landmarks.
6. **Clipboard:** the copy hook tries `navigator.clipboard.writeText`, then
   uses a temporary textarea and `document.execCommand("copy")` if the promise
   rejects or the API is unavailable. The failure label appears only after
   both paths fail.

## Root pass recording format

For each **PENDING ROOT** row, record the browser, date, viewport, and result.
Record failures with the exact route, element, expected behavior, and a short
reproduction step. Change the row only after the run; do not infer a browser
result from a component test.
