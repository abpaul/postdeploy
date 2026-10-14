/**
 * Node scope + breadcrumbs (docs/sdk/02-dx-improvements.md section 4): "A
 * scope is per-isolate, and on a server that is a footgun... Do not ship a
 * naive module-global scope on the server." A long-lived Node process
 * (an HTTP server) can be handling many requests concurrently on one event
 * loop; a bare module-global `setUser` would attribute request B's errors to
 * request A's user the instant they overlap.
 *
 * This adapter closes that gap with `AsyncLocalStorage`: `withScope(fn)`
 * runs `fn` inside a FRESH scope, and `setUser`/`setTag`/`setContext`/
 * `addBreadcrumb` mutate whichever scope is active for the current async
 * call chain -- correct even across `await` and across a monkey-patched
 * `fetch` invoked from inside `fn`, since `AsyncLocalStorage` follows the
 * continuation, not the isolate.
 *
 * Deliberately, calling `setUser`/etc OUTSIDE an active `withScope` is a
 * no-op (logged in debug mode): falling back to some default global store
 * would reintroduce exactly the cross-request leakage this module exists to
 * prevent. Wrap a request handler in `withScope` to use these at all; a
 * single-threaded script can wrap once around its whole body.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import {
  createRingBuffer,
  createScopeState,
  pushBreadcrumb,
  setScopeProvider,
  snapshotBreadcrumbs,
  type BreadcrumbInput,
  type RingBuffer,
  type ScopeSnapshot,
  type ScopeState,
  type WireUser,
} from "../core/observe";

interface Store {
  scope: ScopeState;
  ring: RingBuffer;
}

const als = new AsyncLocalStorage<Store>();
let maxBreadcrumbs = 30;
let debug = false;

function debugWarn(message: string): void {
  if (debug) console.warn(`[@postdeploy/sdk] node: ${message}`);
}

function provideScope(): ScopeSnapshot {
  const store = als.getStore();
  if (store === undefined) return {};
  return { user: store.scope.user, tags: store.scope.tags, contexts: store.scope.contexts, breadcrumbs: snapshotBreadcrumbs(store.ring) };
}

/** Called once from `./observe.ts`'s `init`. */
export function configureScope(options: { maxBreadcrumbs?: number; debug?: boolean }): void {
  maxBreadcrumbs = options.maxBreadcrumbs ?? 30;
  debug = options.debug ?? false;
  setScopeProvider(provideScope);
}

/**
 * Runs `fn` inside a fresh, isolated scope: `setUser`/`setTag`/`setContext`/
 * `addBreadcrumb` calls made anywhere in `fn`'s async call chain (including
 * after an `await`) apply only to captures made within that same chain.
 * Nesting is supported -- a nested `withScope` gets its own fresh scope,
 * independent of any outer one.
 */
export function withScope<T>(fn: () => T): T {
  return als.run({ scope: createScopeState(), ring: createRingBuffer(maxBreadcrumbs) }, fn);
}

function currentStore(action: string): Store | undefined {
  const store = als.getStore();
  if (store === undefined) debugWarn(`${action}() called outside withScope(); ignored (see this module's file comment).`);
  return store;
}

export function setUser(user: WireUser | null): void {
  const store = currentStore("setUser");
  if (store !== undefined) store.scope.user = user;
}

export function setTag(key: string, value: string): void {
  const store = currentStore("setTag");
  if (store !== undefined) store.scope.tags[key] = value;
}

export function setContext(name: string, data: Record<string, unknown>): void {
  const store = currentStore("setContext");
  if (store !== undefined) store.scope.contexts[name] = data;
}

export function addBreadcrumb(breadcrumb: BreadcrumbInput): void {
  const store = currentStore("addBreadcrumb");
  if (store !== undefined) pushBreadcrumb(store.ring, breadcrumb);
}

/** Test-only: not re-exported from `./index.ts`. */
export function __resetScopeForTests(): void {
  maxBreadcrumbs = 30;
  debug = false;
}
