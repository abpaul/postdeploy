/**
 * `POST /e/errors` transport: retry/backoff and 429 handling. Deliberately
 * NOT shared with `heartbeat.ts`'s near-identical retry loop -- the two
 * differ in POST body/headers and heartbeat is a shipped, load-bearing
 * function this change must not touch (see this package's top-level
 * README/AGENTS.md "never-throw guarantee"); duplicating ~30 lines is
 * cheaper than the regression risk of extracting a shared helper underneath
 * it.
 */

const MAX_ATTEMPTS = 3;
const BACKOFF_BASE_MS = 500;
const BACKOFF_JITTER = 0.5;
const MAX_RETRY_AFTER_MS = 30_000;
const REQUEST_TIMEOUT_MS = 10_000;
/** 401/403 (bad/scopeless key) and 404 (unrecognized route) can't be fixed by retrying; 400 means the envelope itself is malformed. */
const PERMANENT_STATUSES: Record<number, true> = { 400: true, 401: true, 403: true, 404: true };

// Deliberate exception to the repo's "prefer Promise.withResolvers" rule, and
// it must stay one: `withResolvers` needs Node 22, Chrome 119, Safari 17.4 or
// Firefox 121. This package declares `engines.node >= 18` and runs inside
// third-party browsers, so on a supported runtime it throws a TypeError on
// every retry — breaking the never-throw guarantee in the host's app. CI pins
// Node 20 and fails if anyone changes this back.
export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function backoffMs(attempt: number): number {
  const exponential = BACKOFF_BASE_MS * 2 ** (attempt - 1);
  const jitterFactor = 1 - BACKOFF_JITTER + Math.random() * (2 * BACKOFF_JITTER);
  return exponential * jitterFactor;
}

function retryAfterMs(response: Response): number | null {
  const retryAfter = response.headers.get("Retry-After");
  if (retryAfter === null || retryAfter.trim() === "") return null;
  const seconds = Number(retryAfter);
  if (!Number.isFinite(seconds) || seconds < 0) return null;
  return Math.min(seconds * 1000, MAX_RETRY_AFTER_MS);
}

function timeoutSignal(): AbortSignal | undefined {
  // AbortSignal.timeout is available in Node >= 18, workerd, and every
  // evergreen browser this package targets; the guard only protects an
  // unusually old runtime from a thrown ReferenceError, not a supported one.
  if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
    return AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  }
  return undefined;
}

/** How one POST attempt sequence ended, so the caller can decide whether/how to log it. */
export type SendOutcome = { outcome: "sent" } | { outcome: "dropped_permanent" } | { outcome: "exhausted"; lastError: unknown };

/**
 * Posts `body` to `url` with up to 3 total attempts, jittered exponential
 * backoff (base 500ms) between them, and a 429 `Retry-After` honored
 * instead of hot-looping (capped at 30s so a misbehaving server can't stall
 * a flush indefinitely). Never throws or rejects: a network error is
 * treated the same as a retryable non-ok response.
 */
export async function postJsonWithRetries(url: string, body: string, headers: Record<string, string>, fetchImpl: typeof fetch): Promise<SendOutcome> {
  let lastError: unknown;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      const response = await fetchImpl(url, { method: "POST", headers, body, signal: timeoutSignal() });
      if (response.ok) return { outcome: "sent" };

      lastError = new Error(`request failed with status ${response.status}`);
      if (PERMANENT_STATUSES[response.status]) return { outcome: "dropped_permanent" };

      if (attempt < MAX_ATTEMPTS) {
        await delay(response.status === 429 ? (retryAfterMs(response) ?? backoffMs(attempt)) : backoffMs(attempt));
      }
      continue;
    } catch (err) {
      lastError = err;
    }
    if (attempt < MAX_ATTEMPTS) await delay(backoffMs(attempt));
  }

  return { outcome: "exhausted", lastError };
}
