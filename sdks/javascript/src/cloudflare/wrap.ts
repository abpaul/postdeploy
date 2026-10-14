/**
 * Cloudflare automatic error capture (docs/sdk/02-dx-improvements.md
 * section 2): workerd has no `window.onerror`/`process.on` equivalent, so
 * capture here is an explicit wrapper around the fetch/scheduled handler
 * instead of an ambient hook. Both wrappers follow the same three rules:
 *
 * 1. Catch, capture with `mechanism: "instrumentation"`.
 * 2. `ctx.waitUntil(flush())` so the batch is guaranteed to be sent even
 *    though the response (or the scheduled invocation) has already
 *    returned/completed by the time the flush finishes.
 * 3. Re-throw. Never swallow: the Worker's own error behavior (a workerd
 *    default error response, or whatever `export default`'s caller does
 *    with a thrown scheduled error) must proceed exactly as it would with
 *    no SDK installed.
 *
 * Minimal structural types instead of a `@cloudflare/workers-types`
 * devDependency: this package's zero-runtime-dependency rule (AGENTS.md,
 * "No new production dependency without explicit founder approval") extends
 * to keeping its dev footprint small, and a real `ExecutionContext` already
 * satisfies `MinimalExecutionContext` structurally, so no real functionality
 * is lost.
 */
import { captureException, flush } from "../core/observe";

export interface MinimalExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
}

export interface MinimalScheduledController {
  cron?: string;
  scheduledTime?: number;
}

type FetchHandler<Env> = (request: Request, env: Env, ctx: MinimalExecutionContext) => Response | Promise<Response>;
type ScheduledHandler<Env> = (controller: MinimalScheduledController, env: Env, ctx: MinimalExecutionContext) => void | Promise<void>;

/** Wraps a `fetch` handler so any thrown error is captured, flushed, and re-thrown -- see this file's header comment. */
export function wrapHandler<Env = unknown>(handler: FetchHandler<Env>): FetchHandler<Env> {
  return async (request, env, ctx) => {
    try {
      return await handler(request, env, ctx);
    } catch (err) {
      captureException(err, { mechanism: "instrumentation" });
      ctx.waitUntil(flush());
      throw err;
    }
  };
}

/** Wraps a `scheduled` (cron trigger) handler with the same capture/flush/re-throw behavior as `wrapHandler`. */
export function wrapScheduled<Env = unknown>(handler: ScheduledHandler<Env>): ScheduledHandler<Env> {
  return async (controller, env, ctx) => {
    try {
      await handler(controller, env, ctx);
    } catch (err) {
      captureException(err, { mechanism: "instrumentation" });
      ctx.waitUntil(flush());
      throw err;
    }
  };
}
