/**
 * Browser scope + breadcrumb storage (docs/sdk/02-dx-improvements.md
 * sections 3-4): a single module-global instance, which is CORRECT here
 * unlike Node/Cloudflare -- a browser tab has exactly one user and no
 * concurrent-request multiplexing, so there is no "request A's `setUser`
 * leaks into request B" failure mode to guard against. Registered with the
 * core client via `setScopeProvider` so every `captureException`/
 * `captureMessage` call picks it up automatically.
 */
import {
  createRingBuffer,
  createScopeState,
  DEFAULT_MAX_BREADCRUMBS,
  pushBreadcrumb,
  setScopeProvider,
  snapshotBreadcrumbs,
  type BreadcrumbInput,
  type RingBuffer,
  type ScopeSnapshot,
  type ScopeState,
  type WireUser,
} from "../core/observe";

const scope: ScopeState = createScopeState();
let ring: RingBuffer = createRingBuffer(DEFAULT_MAX_BREADCRUMBS);

function provideScope(): ScopeSnapshot {
  return { user: scope.user, tags: scope.tags, contexts: scope.contexts, breadcrumbs: snapshotBreadcrumbs(ring) };
}

/** Called once from `./observe.ts`'s `init` -- resets the ring buffer capacity and registers this module as the core client's ambient scope source. */
export function configureScope(maxBreadcrumbs: number): void {
  ring = createRingBuffer(maxBreadcrumbs);
  setScopeProvider(provideScope);
}

/** Attaches user identity to every subsequent event until changed or cleared. Pass `null` to clear. */
export function setUser(user: WireUser | null): void {
  scope.user = user;
}

/** Sets a single indexed key/value pair, merged into every subsequent event's `tags`. */
export function setTag(key: string, value: string): void {
  scope.tags[key] = value;
}

/** Attaches a named structured object (not indexed/filterable), merged into every subsequent event's `contexts`. */
export function setContext(name: string, data: Record<string, unknown>): void {
  scope.contexts[name] = data;
}

/** Appends a breadcrumb to the ring buffer; attached to the next captured event. See `../core/observe/breadcrumbs.ts` for the privacy scrubbing applied. */
export function addBreadcrumb(breadcrumb: BreadcrumbInput): void {
  pushBreadcrumb(ring, breadcrumb);
}

/** Test-only: not re-exported from `./index.ts`. */
export function __resetScopeForTests(): void {
  scope.user = null;
  scope.tags = {};
  scope.contexts = {};
  ring = createRingBuffer(DEFAULT_MAX_BREADCRUMBS);
}
