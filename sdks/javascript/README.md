# @postdeploy/sdk

Official instrumentation SDK for [PostDeploy](https://postdeploy.dev), the
Cloudflare-native dev toolkit built around three pillars — **Monitor**
(uptime and heartbeat checks), **Observe** (error tracking), and **Measure**
(product analytics) — on one platform, one dashboard, and one bill. This
package ships `heartbeat()` (Monitor); `init`/`captureException`/
`captureMessage`/`flush`/`close`, automatic global error capture,
breadcrumbs, and scope (`setUser`/`setTag`/`setContext`) for Observe; and
`sendMeasureHit()` (Measure, browser-only as of 0.3.0 — see below). See
[Roadmap](#roadmap) below for what's not here yet.

Setup guide: [JavaScript error tracking](https://postdeploy.dev/docs/observe/javascript).
Heartbeat reference: [heartbeat protocol](https://postdeploy.dev/docs/monitoring/heartbeats).

## Install

```sh
npm install @postdeploy/sdk
```

Zero runtime dependencies. Requires Node.js >= 18 for the `/node` entry
point; the `/cloudflare` and neutral (`.`) entry points work anywhere
`fetch` and `URL` are global (workerd, browsers, modern runtimes). Do not
import `./core`. That entry is adapter-internal.

## Monitor: `heartbeat()`

`heartbeat(token, options?)` sends a ping to a **Heartbeat monitor** you've
created at [postdeploy.dev/dashboard](https://postdeploy.dev/dashboard). Heartbeat
monitors watch scheduled jobs — cron tasks, nightly batches, queue
workers — that are supposed to run on a schedule; PostDeploy alerts you when a
ping doesn't show up on time or reports failure. Every ping ultimately hits:

```
GET|POST https://ingest.postdeploy.dev/h/{token}
```

so the SDK is just a small, resilient, typed wrapper around a single HTTP
request — nothing you couldn't do with `curl`, which is the point: your job
doesn't need a network SDK at all if a shell one-liner already works.

### Quickstart

Create a Heartbeat monitor in the console first and copy its token (looks
like `hb_...`). Every example below pings that monitor.

#### Cloudflare Workers (Cron Triggers)

Use `ctx.waitUntil()` so the ping doesn't block (or get cancelled when) the
scheduled handler returns:

```ts
import { heartbeat } from "@postdeploy/sdk/cloudflare";

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(heartbeat("hb_your_token", { state: "start" }));
    await runScheduledTask();
    ctx.waitUntil(heartbeat("hb_your_token", { state: "finish" }));
  },
};
```

#### Node.js (cron job or standalone script)

```ts
import { heartbeat } from "@postdeploy/sdk/node";

try {
  await runNightlyJob();
  await heartbeat("hb_your_token", { state: "finish" });
} catch (err) {
  await heartbeat("hb_your_token", {
    state: "fail",
    message: err instanceof Error ? err.message : String(err),
  });
}
```

Or skip the try/catch and use the process exit-code shortcut, which is
handy at the tail of a script:

```ts
process.on("exit", (code) => {
  void heartbeat("hb_your_token", { exitCode: code });
});
```

#### Plain shell / crontab (no SDK required)

Heartbeat monitors are just a URL, so anything that can run `curl` in a
crontab works without installing this package. The exit-code path form
(`/h/{token}/{exitCode}`) maps `0` to a finish ping and any other value
(`1`-`255`) to a fail ping — the same semantics as the SDK's `exitCode`
option:

```sh
# crontab -e
0 2 * * * /usr/local/bin/nightly-backup.sh; curl -fsS "https://ingest.postdeploy.dev/h/hb_your_token/$?" > /dev/null
```

### `heartbeat()` options reference

```ts
import { heartbeat } from "@postdeploy/sdk/node"; // or /cloudflare, or "@postdeploy/sdk"

await heartbeat(token, options?);
```

| Option | Type | Default | Semantics |
| --- | --- | --- | --- |
| `state` | `"start" \| "finish" \| "fail"` | _(none — a plain ping)_ | `start` records the beginning of a run so the console can track its duration. `finish` closes it out as a success. `fail` **opens an incident immediately** on the monitor. Mutually exclusive with `exitCode`. |
| `exitCode` | `number` | _(none)_ | Shortcut for `state`: `0` maps to `finish`, any value `1`-`255` maps to `fail`. Mutually exclusive with `state`. |
| `message` | `string` | _(none)_ | Diagnostic text attached to `fail` pings, shown on the incident in the console. Silently truncated to 2048 characters. |
| `pingId` | `string` | a fresh generated id | Idempotency key, reused across retries of one call and deduplicated by the monitor for 24 hours. |
| `baseUrl` | `string` | `https://ingest.postdeploy.dev` | Override the ingest origin. |
| `fetchImpl` | `typeof fetch` | the platform's global `fetch` | Inject a custom `fetch` implementation — primarily for unit tests. |
| `debug` | `boolean` | `false` | Log a `console.warn` when retries are exhausted or an internal error occurs. Tokens are always redacted. |

`heartbeat()` **never throws or rejects**, regardless of network failure or
an internal SDK bug. It makes at most two attempts. It retries transport
failures, `408`, `429`, and `5xx` responses only. Each attempt is bounded to
five seconds. A delta-seconds `Retry-After` is capped at two seconds; other
retries use jittered backoff around 500ms.

## Observe: error tracking

```ts
import { init, captureException, captureMessage, flush, close } from "@postdeploy/sdk/node"; // or "." or "/cloudflare"

init({ key: "alp_p_your_ingest_key", environment: "production", release: "1.4.2" });
// That's it -- uncaught exceptions and unhandled rejections are captured
// automatically from here on (browser and Node; see below for Cloudflare).

try {
  riskyOperation();
} catch (err) {
  captureException(err, { context: { feature: "checkout" } });
}

captureMessage("payment webhook received an unexpected status", "warning");

// Before a short-lived script exits:
await flush(2000);
```

`init(options)` configures one module-scope client. Repeated calls update the
active client without discarding pending, queued, or in-flight events.
Calling `init` after `close` starts a new active client. `key` must be a
project API key with the `ingest` scope. `captureUnhandled` (default `true` on
browser/Node) controls automatic capture — see below.

`captureException(error, options?)` accepts any thrown value — an `Error`,
a string, or anything else JavaScript allows you to `throw`. A non-`Error`
value is normalized into a synthetic error with the original value
preserved under `contexts.extra.non_error_value`. `options.context` is
merged into `contexts.extra`; `options.user`/`.tags`/`.contexts`/
`.breadcrumbs` are per-capture scope overrides (see
[Scope](#scope-setuser-settag-setcontext) below), and `options.mechanism`
overrides the default `"generic"` (the automatic capture paths set their
own). Returns the client-generated `err_`-prefixed event id synchronously,
so you can surface it to a user ("reference id `err_...`") even before the
event is sent. The same error object captured twice within ~2 seconds (for
example by both the automatic handler and a manual call) is deduplicated to
one event and returns the same id both times.

`captureMessage(message, level?, options?)` records a non-exception event;
`level` defaults to `"info"` and must be one of `"fatal" | "error" |
"warning" | "info"`. `options` accepts the same scope overrides as
`captureException`.

`flush(timeoutMs?)` (default 2000ms) forces an immediate send and resolves
`true` if it drained in time. `close(timeoutMs?)` detaches automatic capture,
breadcrumb instrumentation, and the browser `pagehide` callback. It flushes
the closing client and rejects further captures until the next `init`.

Every capture/transport path is wrapped so **the SDK never throws into your
application** — a malformed capture, a network failure, or an internal bug
is caught, optionally logged via `debug: true`, and swallowed. Automatic
capture never changes your program's own behavior either: the browser still
logs an uncaught error to the console exactly as it would with no SDK
installed, and a wrapped Cloudflare handler still re-throws so the Worker's
own error response still happens.

### Automatic global error capture

Installing the SDK captures errors by default — opt out with
`captureUnhandled: false`, not opt in.

- **Browser** (`.`): `window.addEventListener("error"
  /"unhandledrejection")`, attached on `init`, detached on `close()`.
- **Node** (`/node`): `process.on("uncaughtException"/"unhandledRejection")`.
  `uncaughtException` captures, flushes (bounded to ~2s so a slow ingest
  endpoint can't hang shutdown), and then calls `process.exit(1)` itself —
  Node suppresses its own default crash-and-exit behavior the instant any
  listener is attached, so this is the only way to reproduce it, not an
  SDK choice to be more aggressive than Node's default. `unhandledRejection`
  captures and flushes but deliberately does **not** exit the process, since
  Node's own default there is configurable (`--unhandled-rejections`) and
  forcing an exit would change the behavior of an app that set it to
  `warn`/`none` on purpose.
- **Cloudflare** (`/cloudflare`): no process-global hooks exist in workerd,
  so there is no `captureUnhandled` flag to flip here. Wrap your handler(s)
  instead:

  ```ts
  import { init, wrapHandler, wrapScheduled } from "@postdeploy/sdk/cloudflare";

  export default {
    fetch: wrapHandler(async (request, env, ctx) => {
      init({ key: env.POSTDEPLOY_API_KEY, environment: "production" });
      // application code; a thrown error is captured, flushed via
      // ctx.waitUntil, and re-thrown -- the Worker's own error response
      // still happens exactly as it would with no SDK installed.
      return handleRequest(request);
    }),
    scheduled: wrapScheduled(async (controller, env, ctx) => {
      init({ key: env.POSTDEPLOY_API_KEY, environment: "production" });
      await runScheduledTask();
    }),
  };
  ```

Every captured event — automatic or manual — carries `mechanism`:
`"onerror"`, `"onunhandledrejection"`, `"uncaughtException"`,
`"unhandledRejection"`, `"instrumentation"` (Cloudflare's wrappers), or
`"generic"` (a direct `captureException`/`captureMessage` call).

### Breadcrumbs

```ts
import { addBreadcrumb } from "@postdeploy/sdk"; // or "/node"

addBreadcrumb({ category: "checkout", message: "clicked pay", level: "info" });
```

A ring buffer (default 30 entries, `maxBreadcrumbs` on `init`) attached to
every subsequent captured event, giving a trail of what led up to it. Never
records input values or request/response bodies, and strips query strings
from URLs by default — and `data` on any breadcrumb (manual or automatic) is
scrubbed of `password`/`secret`/`token`/`api_key`-shaped keys the same way
`context`/`setContext` payloads are.

- **Browser** (`.`): automatic, on by default — navigation
  (`pushState`/`replaceState`/`popstate`), delegated clicks (a CSS selector
  only, e.g. `button#submit.btn-primary`, **never** element text), patched
  `console.log`/`.warn`/`.error`, and patched `fetch` (method, URL with the
  query string stripped, status, duration). Every patch is reversible on
  `close()`, composes with a `fetch` your own code already patched (wraps
  whatever `fetch` currently is, not a reference saved at import time), and
  a breadcrumb-recording failure never affects the underlying call.
- **Node** (`/node`): manual `addBreadcrumb` only, scoped the same way
  `setUser`/etc are — see [Scope](#scope-setuser-settag-setcontext). No
  automatic `fetch` breadcrumbs yet (a global `fetch` patch writing
  anywhere other than a request-scoped buffer would reintroduce the same
  cross-request attribution bug scope avoids).
- **Cloudflare** (`/cloudflare`): no ambient breadcrumb buffer at all — pass
  `breadcrumbs: [...]` directly in `captureException`/`captureMessage`'s
  options for a one-off capture.

### Scope: `setUser`/`setTag`/`setContext`

```ts
import { setUser, setTag, setContext } from "@postdeploy/sdk"; // or "/node"

setUser({ id: "user_123", email: "jane@example.com" }); // or null to clear
setTag("plan", "agency");
setContext("cart", { items: 3 });
```

Merged into every subsequent captured event until changed or cleared.
**How this is scoped differs sharply by platform, and the difference is
deliberate** — a naive module-global `setUser` is safe in a browser tab (one
user, no concurrent requests) and a real bug on a server (request A's
`setUser` would still be set during request B the instant they overlap):

- **Browser** (`.`): a single module-global scope. Correct here.
- **Node** (`/node`): backed by `AsyncLocalStorage`, active **only** inside
  `withScope(fn)`:

  ```ts
  import { withScope, setUser, captureException } from "@postdeploy/sdk/node";

  async function handleRequest(req: Request) {
    return withScope(async () => {
      setUser({ id: req.userId });
      try {
        return await process(req);
      } catch (err) {
        captureException(err); // attributed to req.userId, not some other
        // concurrent request's user
        throw err;
      }
    });
  }
  ```

  Calling `setUser`/`setTag`/`setContext`/`addBreadcrumb` **outside** an
  active `withScope` is a no-op (logged in debug mode) — never a
  module-global write. A single-threaded script can wrap once around its
  whole body; a request-handling server should wrap per request.
- **Cloudflare** (`/cloudflare`): no ambient scope API at all — a Workers
  isolate can serve concurrent requests, and this package cannot assume the
  `nodejs_compat` flag `AsyncLocalStorage` needs there. Pass
  `user`/`tags`/`contexts` directly in `captureException`/
  `captureMessage`'s options instead; this is always safe regardless of
  isolate concurrency, and it works as an escape hatch on every platform,
  where an explicit per-capture value overrides the ambient one.

### Batching and per-platform flush behavior

Captured events are queued in memory and sent as a batch once any of these
is first true: 10 events queued, ~64 KB of estimated serialized size, or 5
seconds since the oldest queued event. Free-text fields (`message`,
exception `value`, stack traces, context objects) are capped at the same
boundary the server enforces, so an oversized payload is trimmed by the SDK
rather than discovered by a server rejection.

- **Browser** (`.`): the 5-second idle timer applies, plus one `pagehide`
  listener that best-effort flushes any remaining queue via
  `fetch(..., { keepalive: true })` when the page is closed or bfcache'd.
  `close` removes that exact callback, so a close/reinit cycle leaves one
  current handler. (This uses `fetch` keepalive rather than
  `navigator.sendBeacon`, because `sendBeacon` cannot carry the
  `Authorization` header this endpoint requires.)
- **Node** (`/node`): the 5-second idle timer applies, and is `unref()`'d so
  it never keeps a short-lived script running on its own — call `flush()` or
  `close()` before your script exits, or a queued batch waiting on the timer
  can be lost.
- **Cloudflare Workers** (`/cloudflare`): the idle timer is always disabled
  (a Workers isolate can be evicted between requests, so a background timer
  is not a reliable flush mechanism there). Call `ctx.waitUntil(flush())` at
  the end of every request that captured something:

  ```ts
  import { Hono } from "hono";
  import { init, captureException, flush } from "@postdeploy/sdk/cloudflare";

  const app = new Hono<{ Bindings: { POSTDEPLOY_API_KEY: string } }>();
  app.use("*", async (c, next) => {
    init({ key: c.env.POSTDEPLOY_API_KEY, environment: "production" });
    await next();
  });
  app.onError((err, c) => {
    captureException(err, { context: { path: c.req.path } });
    c.executionCtx.waitUntil(flush());
    return c.text("Internal Server Error", 500);
  });
  ```

  The 10-event/64KB thresholds still trigger an immediate flush regardless
  of platform.

### What Observe does not do yet

No `sampleRate`/`beforeSend`, no `tunnel` proxy option, no browser offline
queue, no `XMLHttpRequest` breadcrumbs, no automatic Node/Cloudflare `fetch`
breadcrumbs (manual `addBreadcrumb` covers Node; Cloudflare has no ambient
breadcrumb buffer at all — pass `breadcrumbs` explicitly per capture), no
framework helpers (Hono/Express/React), and no source map upload tooling.
See [Roadmap](#roadmap).

## Measure: `sendMeasureHit()`

Available from the browser entry point (`@postdeploy/sdk`) only as of 0.3.0 —
**not** from `/node` or `/cloudflare`. `POST /m`'s only auth is a real
browser's own `Origin` header, which neither a Node nor a Workers `fetch`
call ever carries, so calling this from either of those adapters always
silently recorded nothing; the exports were removed rather than left as a
working-looking trap (`docs/sdk/02-dx-improvements.md` section 5). Use the
first-party `/m.js` browser tracker for anything server-side.

```ts
import { sendMeasureHit } from "@postdeploy/sdk"; // browser only

await sendMeasureHit({
  site: "proj_your_project_id",
  url: "https://shop.example.com/checkout/complete",
  type: "custom_event",
  name: "signup_completed",
});
```

This is a low-level, programmatic wrapper around `POST /m` for use
somewhere a `<script>` tag isn't an option in a real browser page — an SPA
route change, a dynamically-injected form submit handler. It is **not** a
replacement for PostDeploy's first-party browser tracker script; a real website
should load that script instead.

`POST /m` has no API key: the only gate is the request's `Origin` header,
checked against your project's allowlisted domains. A real browser attaches
that header automatically on every POST and JavaScript cannot override it,
which is what makes it trustworthy as a control — and is exactly why this
function is browser-only as of 0.3.0 (see above). The response is always
`204 No Content` whether the hit was recorded or rejected, by design, so
there is nothing in the response to tell the difference if your domain
isn't on the project's allowlist.

This function deliberately does **not** accept an `origin` override to work
around that. Fabricating an Origin value to get a call past the allowlist
would defeat the one security control this endpoint has.

| Option | Type | Notes |
| --- | --- | --- |
| `site` | `string` | The project id (`proj_...`) — public, not secret. |
| `url` | `string` | Full page URL the hit is recorded for. |
| `referrer` | `string \| null` | Optional; omitted or `null` for a direct hit. |
| `type` | `"pageview" \| "custom_event"` | Defaults to `"pageview"`. |
| `name` | `string` | Required when `type` is `"custom_event"`. |
| `props` | `Record<string, unknown>` | Accepted for forward compatibility; the server discards it before rollup and never stores it. |
| `baseUrl` / `fetchImpl` / `debug` | — | Same as `heartbeat()`'s options above. |

There is no retry: unlike Observe, a hit carries no client-generated
idempotency id, so retrying risks double-counting a visit rather than
recovering a lost one. Never throws.

## Troubleshooting

- **Heartbeat returns 404** — the token is wrong, or the monitor has been
  deleted or paused in the console. Copy the token again from the
  monitor's detail page.
- **Pings/hits are fire-and-forget** — none of these functions return
  monitor state, issue status, or analytics numbers. Check the relevant
  page in the console.
- **Nothing shows up in the console** — confirm the process actually
  reaches the network (egress rules, offline dev environment, VPN) and
  that `baseUrl` wasn't overridden to point somewhere else. For Observe,
  confirm the key carries the `ingest` scope. For Measure, see the Origin
  caveat above — this is the single most common "it silently does
  nothing" cause.

## Roadmap

Not available in `@postdeploy/sdk@0.3.x` — no stub exports, no
reserved-but-throwing placeholders. If it isn't documented above, it
doesn't exist in this package yet:

- `beforeSend`, `sampleRate`, and the `tunnel` proxy option.
- Framework helpers: `@postdeploy/sdk/hono`, `/express`, `/react`.
- Automatic outbound-`fetch` breadcrumbs on Node/Cloudflare, and any ambient
  breadcrumb/scope API on Cloudflare at all (pass `breadcrumbs`/`user`/
  `tags`/`contexts` explicitly per capture there instead).
- `XMLHttpRequest` breadcrumbs (browser `fetch` breadcrumbs ship; XHR does
  not).
- A browser offline queue.
- Source map upload tooling (`postdeploy-cli sourcemaps upload`).
- An IIFE/UMD browser build for non-bundler `<script>` tag usage.
- **`./core`** is not a host import. Use `.`, `./node`, or `./cloudflare`.
- **Ruby / Rails** — `postdeploy` is the first-party gem. It is not this
  npm package. Hex and RubyGems first publish is separate from this 0.3.x
  line.

## Versioning

This package is `0.x`: minor versions (`0.2` -> `0.3`) may introduce
breaking changes as new modules land, though `heartbeat()`, `init`,
`captureException`, `captureMessage`, `flush`, and `close` documented here
are expected to stay stable going forward — 0.3.0's additions
(automatic capture, breadcrumbs, scope) are all additive on top of that
surface. `sendMeasureHit()` is no longer exported from `/node`/`/cloudflare`
as of 0.3.0 (see [Measure](#measure-sendmeasurehit) above) — a breaking
change made while the package was still unpublished, so it cost nothing.
Patch versions are always backwards compatible.

## Development

This package lives in the PostDeploy repository under `sdks/javascript`. The
contract tests read `sdks/contract` from the same checkout, so nothing needs
setting up:

```
cd sdks/javascript
npm ci
npm test
```

Release: bump `version` in `package.json` and `SDK_VERSION` in
`src/core/version.ts`, merge, then push the tag `js-v<version>`.

## License

MIT — see [LICENSE](./LICENSE).
