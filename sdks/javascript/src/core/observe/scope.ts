/**
 * Scope types + the merge rule shared by every platform adapter
 * (docs/sdk/02-dx-improvements.md section 4). This file holds NO state of
 * its own -- deliberately, since a module-level `ScopeState` singleton here
 * would be exactly the "naive module-global scope on the server" the spec
 * forbids (setUser during request A would still be set during request B).
 * Each adapter owns its own storage: the browser keeps one module-global
 * instance (correct there -- one tab, one user), Node scopes one per
 * `AsyncLocalStorage` context via `withScope`, and Cloudflare has no ambient
 * scope at all -- callers pass `user`/`tags`/`contexts` explicitly per
 * capture instead (`core/observe/client.ts`'s `CaptureExceptionOptions`).
 */
import type { WireBreadcrumb, WireUser } from "./envelope";

export interface ScopeState {
  user: WireUser | null;
  tags: Record<string, string>;
  contexts: Record<string, Record<string, unknown>>;
}

export function createScopeState(): ScopeState {
  return { user: null, tags: {}, contexts: {} };
}

/** What an adapter's scope provider hands the core client at capture time -- the ambient half of the merge in `client.ts`'s `resolveScope`. */
export interface ScopeSnapshot {
  user?: WireUser | null;
  tags?: Record<string, string>;
  contexts?: Record<string, Record<string, unknown>>;
  breadcrumbs?: WireBreadcrumb[];
}

/** Per-capture overrides a caller can pass directly -- the ONLY scope mechanism Cloudflare exposes, and an escape hatch on every platform. */
export interface ScopeOverrides {
  user?: WireUser | null;
  tags?: Record<string, string>;
  contexts?: Record<string, Record<string, unknown>>;
  breadcrumbs?: WireBreadcrumb[];
}

/**
 * Merges an ambient scope snapshot (may be absent -- Cloudflare has none)
 * with per-capture overrides. Overrides win field-by-field: an explicit
 * `user: null` clears the ambient user for this one capture rather than
 * falling back to it, `tags`/`contexts` shallow-merge with the override's
 * keys taking precedence on collision, and breadcrumbs concatenate
 * (ambient trail first, then any one-off breadcrumbs passed for this call).
 */
export function mergeScope(ambient: ScopeSnapshot | undefined, overrides: ScopeOverrides | undefined): {
  user: WireUser | undefined;
  tags: Record<string, string> | undefined;
  contexts: Record<string, Record<string, unknown>>;
  breadcrumbs: WireBreadcrumb[];
} {
  const resolvedUser = overrides?.user !== undefined ? overrides.user : ambient?.user;
  const tags = { ...ambient?.tags, ...overrides?.tags };
  const contexts = { ...ambient?.contexts, ...overrides?.contexts };
  const breadcrumbs = [...(ambient?.breadcrumbs ?? []), ...(overrides?.breadcrumbs ?? [])];
  return {
    user: resolvedUser === null ? undefined : resolvedUser,
    tags: Object.keys(tags).length > 0 ? tags : undefined,
    contexts,
    breadcrumbs,
  };
}
