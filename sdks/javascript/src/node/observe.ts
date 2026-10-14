/**
 * Node-specific `init`/`close`: same as the core client, plus automatic
 * global error capture (docs/sdk/02-dx-improvements.md section 2) and
 * request-scoped scope/breadcrumbs (`./scope.ts`).
 *
 * `uncaughtException` -- the two rules that are not negotiable:
 *
 * 1. Never keeps the process alive. Node suppresses its OWN default
 *    "print stack trace and exit 1" behavior the instant ANY listener is
 *    attached to `uncaughtException` -- re-throwing from inside our listener
 *    does not restore that default (Node treats a throw from within
 *    exception-handling as a distinct, harder crash path, not a clean
 *    replay). So this handler explicitly calls `process.exit(1)` itself,
 *    after a best-effort flush bounded to ~2s, to reproduce the same
 *    outcome the process would have had with no SDK installed at all.
 * 2. Never swallows: the flush is bounded so a slow/unreachable ingest
 *    endpoint cannot turn a crash into a hang, and the process always exits
 *    non-zero.
 *
 * `unhandledRejection` is deliberately NOT treated the same way. Node's own
 * default for it is configurable (`--unhandled-rejections`) and varies by
 * Node version; forcing `process.exit` here on every unhandled rejection
 * would be an SDK-caused behavior change for an app that has that flag set
 * to `warn`/`none` on purpose -- exactly the "changes program behaviour"
 * bug the spec calls out. So this handler captures and flushes
 * best-effort, but does not exit, matching the conservative default other
 * production error-tracking SDKs ship for this specific hook.
 *
 * `processImpl` (an injectable `{ on, exit }`) exists purely for tests: a
 * real test attaching real listeners to the real `process` and calling the
 * real `process.exit` would either crash the test runner or leak listeners
 * across test files.
 */
import { configureScope } from "./scope";
import { captureException, close as coreClose, flush, init as coreInit, type ObserveInitOptions } from "../core/observe";

const UNCAUGHT_FLUSH_TIMEOUT_MS = 2_000;

export interface NodeProcessLike {
  on(event: "uncaughtException", listener: (err: unknown) => void): void;
  on(event: "unhandledRejection", listener: (reason: unknown) => void): void;
  off(event: string, listener: (...args: unknown[]) => void): void;
  exit(code: number): never;
}

export interface NodeObserveInitOptions extends ObserveInitOptions {
  /** Injectable process-like object, primarily for tests. Defaults to the real global `process`. */
  processImpl?: NodeProcessLike;
}

let registeredProcess: NodeProcessLike | null = null;
let uncaughtExceptionListener: ((err: unknown) => void) | null = null;
let unhandledRejectionListener: ((reason: unknown) => void) | null = null;

function getGlobalProcess(): NodeProcessLike | undefined {
  return (globalThis as { process?: NodeProcessLike }).process;
}

function registerGlobalHandlers(processImpl: NodeProcessLike, debug: boolean): void {
  if (registeredProcess !== null) return;
  registeredProcess = processImpl;

  uncaughtExceptionListener = (err: unknown) => {
    captureException(err, { mechanism: "uncaughtException" });
    void flush(UNCAUGHT_FLUSH_TIMEOUT_MS).finally(() => {
      if (debug) console.warn("[@postdeploy/sdk] node: uncaughtException captured; exiting", err);
      processImpl.exit(1);
    });
  };
  unhandledRejectionListener = (reason: unknown) => {
    captureException(reason, { mechanism: "unhandledRejection" });
    void flush(UNCAUGHT_FLUSH_TIMEOUT_MS);
  };

  processImpl.on("uncaughtException", uncaughtExceptionListener);
  processImpl.on("unhandledRejection", unhandledRejectionListener);
}

function unregisterGlobalHandlers(): void {
  if (registeredProcess === null) return;
  if (uncaughtExceptionListener !== null) registeredProcess.off("uncaughtException", uncaughtExceptionListener as (...args: unknown[]) => void);
  if (unhandledRejectionListener !== null) registeredProcess.off("unhandledRejection", unhandledRejectionListener as (...args: unknown[]) => void);
  registeredProcess = null;
  uncaughtExceptionListener = null;
  unhandledRejectionListener = null;
}

/** Initializes the Observe client, wires the AsyncLocalStorage-backed scope, and (unless `captureUnhandled: false`) attaches the process-level handlers described above. */
export function init(options: NodeObserveInitOptions): void {
  coreInit(options);
  configureScope({ maxBreadcrumbs: options.maxBreadcrumbs, debug: options.debug });
  if (options.captureUnhandled === false) {
    unregisterGlobalHandlers();
    return;
  }
  const processImpl = options.processImpl ?? getGlobalProcess();
  if (processImpl === undefined) return;
  registerGlobalHandlers(processImpl, options.debug ?? false);
}

/** Detaches the process-level handlers, then flushes and closes the core client. Never throws. */
export async function close(timeoutMs?: number): Promise<boolean> {
  unregisterGlobalHandlers();
  return coreClose(timeoutMs);
}
