/**
 * `@postdeploy/sdk/cloudflare` -- Cloudflare Workers (workerd) entry point.
 * v0.3.0 adds `wrapHandler`/`wrapScheduled` (docs/sdk/02-dx-improvements.md
 * section 2, `./wrap.ts`) for automatic error capture -- workerd has no
 * process-global hooks to attach ambiently, so this is an explicit wrapper
 * instead of a default-on `init` option.
 *
 * There is deliberately NO ambient `setUser`/`setTag`/`setContext`/
 * `addBreadcrumb` exported here (section 4): a Workers isolate can serve
 * many CONCURRENT requests, and neither a module-global (Node's original
 * footgun) nor an unconditional `AsyncLocalStorage` (which would require
 * assuming `nodejs_compat`, a compatibility flag this package cannot depend
 * on) is safe here. Pass `user`/`tags`/`contexts`/`breadcrumbs` explicitly
 * per capture instead -- `captureException`/`captureMessage`'s options
 * accept all four directly, which is the one mechanism that is always safe
 * regardless of isolate concurrency.
 *
 * `sendMeasureHit` is NOT exported from this entry point (docs/sdk/
 * 02-dx-improvements.md section 5): `POST /m`'s only auth is a browser's own
 * `Origin` header, which a Workers-originated `fetch` never carries, so
 * calling it from here always silently records nothing. Use the `/m.js`
 * browser tracker instead (see README).
 */
import { init as coreInit, type ObserveInitOptions } from "../core/observe";

export { heartbeat } from "../core/heartbeat";
export type { HeartbeatOptions } from "../core/heartbeat";

export { captureException, captureMessage, flush, close } from "../core/observe";
export type { ObserveInitOptions, CaptureExceptionOptions, CaptureMessageOptions, ErrorLevel, WireUser } from "../core/observe";
export type { BreadcrumbInput } from "../core/observe";

export { wrapHandler, wrapScheduled } from "./wrap";
export type { MinimalExecutionContext, MinimalScheduledController } from "./wrap";

/**
 * Same as the core client's `init`, except the background idle-flush timer
 * is always disabled (`autoFlushIntervalMs: 0`), overriding any value the
 * caller passes. A Workers isolate can be evicted between requests at any
 * time, so a `setTimeout` scheduled during one request is not guaranteed to
 * ever fire -- call `ctx.waitUntil(flush())` at the end of every request
 * that captured something instead of relying on a background timer.
 * `captureUnhandled` is accepted for type compatibility with the other
 * adapters' `init` but has no effect here -- see this module's file comment.
 */
export function init(options: ObserveInitOptions): void {
  coreInit({ ...options, autoFlushIntervalMs: 0 });
}
