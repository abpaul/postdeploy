/**
 * Browser automatic global error capture (docs/sdk/02-dx-improvements.md
 * section 2). Attached on `init` (when `captureUnhandled` is not explicitly
 * `false`), detached on `close` -- these are the two rules that are not
 * negotiable:
 *
 * 1. NEVER swallow: neither listener calls `event.preventDefault()`, so the
 *    browser's own default behavior (logging to the console) still happens
 *    exactly as it would with no SDK installed.
 * 2. Correctly attributed: `mechanism` is set per source
 *    (`"onerror"`/`"onunhandledrejection"`) so a dashboard reader can tell an
 *    unhandled crash from a handled, manually-logged one.
 */
import { captureException } from "../core/observe";

let errorListener: ((event: ErrorEvent) => void) | null = null;
let rejectionListener: ((event: PromiseRejectionEvent) => void) | null = null;

function getWindow(): (typeof globalThis & Window) | undefined {
  return typeof window === "undefined" ? undefined : (window as typeof globalThis & Window);
}

export function registerGlobalHandlers(): void {
  const win = getWindow();
  if (win === undefined || errorListener !== null) return;

  errorListener = (event: ErrorEvent) => {
    const error = event.error ?? new Error(event.message.length > 0 ? event.message : "Unknown error");
    captureException(error, { mechanism: "onerror" });
  };
  rejectionListener = (event: PromiseRejectionEvent) => {
    captureException(event.reason, { mechanism: "onunhandledrejection" });
  };

  win.addEventListener("error", errorListener);
  win.addEventListener("unhandledrejection", rejectionListener);
}

export function unregisterGlobalHandlers(): void {
  const win = getWindow();
  if (win === undefined) return;
  if (errorListener !== null) win.removeEventListener("error", errorListener);
  if (rejectionListener !== null) win.removeEventListener("unhandledrejection", rejectionListener);
  errorListener = null;
  rejectionListener = null;
}
