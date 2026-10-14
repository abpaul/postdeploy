/**
 * Browser-specific `init`: same as the core client, plus a `pagehide`
 * listener that best-effort flushes any queued events before the page is
 * torn down or bfcache'd.
 *
 * The SDK spec's transport section describes `navigator.sendBeacon` as the
 * primary unload-time transport, with `fetch(..., { keepalive: true })` as
 * the fallback. This adapter deliberately inverts that: `sendBeacon` cannot
 * carry an `Authorization` header (it has no header API at all), and
 * `POST /e/errors` authenticates exclusively via that header -- the
 * envelope's own redundant `header.key` field is validated only as a
 * cross-check against an Authorization header that already authenticated,
 * never accepted as a substitute for one. A beacon send to this route would
 * therefore always be rejected as unauthenticated. `fetch` with
 * `keepalive: true` supports custom headers and survives a page unload the
 * same way `sendBeacon` does, so it is used as the only unload-time
 * transport here, not merely the fallback.
 *
 * Also arms automatic global error capture and breadcrumb instrumentation
 * (docs/sdk/02-dx-improvements.md sections 2-3), both default-on and both
 * reversed by this module's own `close()` -- see `./global-handlers.ts` and
 * `./auto-breadcrumbs.ts`.
 */
import { registerAutoBreadcrumbs, unregisterAutoBreadcrumbs } from "./auto-breadcrumbs";
import { registerGlobalHandlers, unregisterGlobalHandlers } from "./global-handlers";
import { configureScope } from "./scope";
import { buildKeepaliveFlushRequest, close as coreClose, DEFAULT_MAX_BREADCRUMBS, init as coreInit, type ObserveInitOptions } from "../core/observe";

let pagehideListener: (() => void) | null = null;
let pagehideDebug = false;

function registerPagehideFlush(debug: boolean): void {
  pagehideDebug = debug;
  if (pagehideListener !== null) return;
  if (typeof window === "undefined" || typeof window.addEventListener !== "function") return;

  pagehideListener = () => {
    const request = buildKeepaliveFlushRequest();
    if (request === null) return;
    const fetchImpl = globalThis.fetch;
    if (typeof fetchImpl !== "function") return;
    fetchImpl(request.url, { method: "POST", headers: request.headers, body: request.body, keepalive: true }).catch((err: unknown) => {
      if (pagehideDebug) console.warn("[@postdeploy/sdk] observe: pagehide flush failed", err);
    });
  };
  window.addEventListener("pagehide", pagehideListener);
}

function unregisterPagehideFlush(): void {
  if (pagehideListener === null) return;
  if (typeof window !== "undefined" && typeof window.removeEventListener === "function") {
    window.removeEventListener("pagehide", pagehideListener);
  }
  pagehideListener = null;
  pagehideDebug = false;
}

/**
 * Initializes the Observe client, arms the `pagehide` unload flush described
 * above, registers the scope/breadcrumb ring buffer (section 4/3), and --
 * unless `captureUnhandled: false` is passed -- attaches automatic global
 * error capture (section 2). Breadcrumb auto-instrumentation is always on,
 * matching the spec's "no opt-in required" for it.
 */
export function init(options: ObserveInitOptions): void {
  coreInit(options);
  registerPagehideFlush(options.debug ?? false);
  configureScope(options.maxBreadcrumbs ?? DEFAULT_MAX_BREADCRUMBS);
  registerAutoBreadcrumbs();
  if (options.captureUnhandled !== false) {
    registerGlobalHandlers();
  } else {
    unregisterGlobalHandlers();
  }
}

/**
 * Detaches everything `init` attached, then flushes and closes the core
 * client. Never throws.
 */
export async function close(timeoutMs?: number): Promise<boolean> {
  unregisterPagehideFlush();
  unregisterGlobalHandlers();
  unregisterAutoBreadcrumbs();
  return coreClose(timeoutMs);
}

/** Test-only: not re-exported from `./index.ts`, so it never reaches a published bundle. */
export function __resetForTests(): void {
  unregisterPagehideFlush();
}
