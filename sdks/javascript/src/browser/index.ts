/**
 * `@postdeploy/sdk` (unqualified package root) -- browser/neutral entry point.
 * v0.3.0 adds automatic global error capture (`window.onerror`/
 * `onunhandledrejection`, default on), breadcrumbs (manual `addBreadcrumb`
 * plus automatic navigation/click/console/fetch instrumentation), and scope
 * (`setUser`/`setTag`/`setContext`) -- see `./observe.ts`, `./scope.ts`,
 * `./global-handlers.ts`, `./auto-breadcrumbs.ts`, and this package's README.
 * There is no IIFE/UMD build yet.
 */
export { heartbeat } from "../core/heartbeat";
export type { HeartbeatOptions } from "../core/heartbeat";

export { init, close } from "./observe";
export { addBreadcrumb, setContext, setTag, setUser } from "./scope";
export { captureException, captureMessage, flush } from "../core/observe";
export type { ObserveInitOptions, CaptureExceptionOptions, CaptureMessageOptions, ErrorLevel, WireUser } from "../core/observe";
export type { BreadcrumbInput } from "../core/observe";

export { sendMeasureHit } from "../core/measure";
export type { MeasureHitOptions } from "../core/measure";
