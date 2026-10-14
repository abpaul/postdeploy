/**
 * Exception dedup (docs/sdk/02-dx-improvements.md section 2, "Deduplicate"):
 * a rejected promise that is also caught later, or an error that reaches
 * both a global handler and a manual `captureException`, must produce ONE
 * event. Keyed on error object identity (a `WeakMap`, so it never leaks
 * memory -- an entry disappears with the error object itself) within a
 * short window; non-object thrown values (a string, a plain object without
 * identity worth keying on... same object still works via WeakMap, only
 * PRIMITIVES need the fallback) use a small bounded map instead, since a
 * `WeakMap` cannot key on a primitive.
 *
 * Module-level, not part of `ObserveState`: dedup must survive across
 * `init()` re-calls (re-initializing the client mid-process must not reopen
 * a window for an error that was already reported a moment ago), and it is
 * intentionally the one piece of state in this package that is NOT
 * per-client, since "the same error was already reported" is a property of
 * the error, not of which client instance happens to be active.
 */
const DEDUP_WINDOW_MS = 2_000;
/** Bounds the primitive-keyed fallback map so a flood of distinct thrown strings can't grow it unboundedly. */
const VALUE_CACHE_MAX = 50;

interface DedupEntry {
  id: string;
  expiresAt: number;
}

const byIdentity = new WeakMap<WeakKey, DedupEntry>();
const byValue = new Map<string, DedupEntry>();

function isWeakKeyable(value: unknown): value is WeakKey {
  return (typeof value === "object" && value !== null) || typeof value === "function";
}

function stringifyPrimitive(value: unknown): string {
  try {
    return `${typeof value}:${JSON.stringify(value)}`;
  } catch {
    return `${typeof value}:${String(value)}`;
  }
}

function pruneExpired(now: number): void {
  for (const [key, entry] of byValue) {
    if (entry.expiresAt <= now) byValue.delete(key);
  }
}

/**
 * Returns the id to use for this capture: a fresh one for a new error, or
 * the PREVIOUS capture's id if `error` was already captured within the
 * dedup window (so a caller showing "reference id `err_...`" for either
 * call shows the same id the dashboard will actually contain).
 */
export function resolveDedupId(error: unknown, freshId: string): { id: string; isDuplicate: boolean } {
  const now = Date.now();

  if (isWeakKeyable(error)) {
    const existing = byIdentity.get(error);
    if (existing !== undefined && existing.expiresAt > now) return { id: existing.id, isDuplicate: true };
    byIdentity.set(error, { id: freshId, expiresAt: now + DEDUP_WINDOW_MS });
    return { id: freshId, isDuplicate: false };
  }

  pruneExpired(now);
  const key = stringifyPrimitive(error);
  const existing = byValue.get(key);
  if (existing !== undefined && existing.expiresAt > now) return { id: existing.id, isDuplicate: true };
  if (byValue.size >= VALUE_CACHE_MAX) {
    const oldestKey = byValue.keys().next().value;
    if (oldestKey !== undefined) byValue.delete(oldestKey);
  }
  byValue.set(key, { id: freshId, expiresAt: now + DEDUP_WINDOW_MS });
  return { id: freshId, isDuplicate: false };
}

/** Test-only: clears both dedup tables between test cases. */
export function __resetDedupForTests(): void {
  byValue.clear();
}
