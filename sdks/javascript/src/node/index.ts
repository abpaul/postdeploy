/**
 * `@postdeploy/sdk/node` -- Node.js >= 18 entry point. v0.3.0 adds automatic
 * `uncaughtException`/`unhandledRejection` capture (default on -- see
 * `./observe.ts`) and request-scoped scope/breadcrumbs via
 * `AsyncLocalStorage` (`setUser`/`setTag`/`setContext`/`addBreadcrumb`,
 * active only inside `withScope(fn)` -- see `./observe.ts`'s file comment
 * for why there is no ambient module-global scope here).
 *
 * `sendMeasureHit` is NOT exported from this entry point (docs/sdk/
 * 02-dx-improvements.md section 5): `POST /m`'s only auth is a browser's own
 * `Origin` header, which a Node `fetch` call never carries, so calling it
 * from here always silently records nothing. Use the `/m.js` browser tracker
 * instead (see README).
 */
export { heartbeat } from "../core/heartbeat";
export type { HeartbeatOptions } from "../core/heartbeat";

export { init, close } from "./observe";
export { addBreadcrumb, setContext, setTag, setUser, withScope } from "./scope";
export { captureException, captureMessage, flush } from "../core/observe";
export type { ObserveInitOptions, CaptureExceptionOptions, CaptureMessageOptions, ErrorLevel, WireUser } from "../core/observe";
export type { BreadcrumbInput } from "../core/observe";
