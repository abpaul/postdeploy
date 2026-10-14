/**
 * @postdeploy/sdk core heartbeat transport (docs/sdk/01-sdk-spec.md section 3.5,
 * 5.5; heartbeat-v2 contract "SDK (@postdeploy/sdk v0.1.0)" section).
 *
 * v0.1.0 ships ONLY this module -- Observe/Measure land in later 0.x minors
 * (see packages/sdk/README.md's scope note). `./node`, `./cloudflare`, and
 * the neutral `.` entry all re-export this file verbatim; the transport
 * (`fetch`) is a Web-standard global on every target platform (Node >= 18,
 * workerd, browsers), so there is no platform branching to do here.
 */

const DEFAULT_BASE_URL = "https://ingest.postdeploy.dev";
const MAX_ATTEMPTS = 2;
const BACKOFF_BASE_MS = 500;
const BACKOFF_JITTER = 0.5;
const MAX_MESSAGE_LENGTH = 2048;
const MAX_RETRY_AFTER_MS = 2_000;
const ATTEMPT_TIMEOUT_MS = 5_000;
const PERMANENT_CLIENT_ERROR_STATUSES: Record<number, true> = { 400: true, 401: true, 403: true, 404: true };
const PING_ID_PATTERN = /^[A-Za-z0-9_.-]{1,128}$/;

export interface HeartbeatOptions {
  /** Explicit ping state. Mutually exclusive with `exitCode`. */
  state?: "start" | "finish" | "fail";
  /** Exit code shortcut: 0 -> finish, 1-255 -> fail. Mutually exclusive with `state`. */
  exitCode?: number;
  /** Diagnostic message attached to fail pings, truncated silently to 2048 chars. */
  message?: string;
  /** Idempotency id reused across retries. Invalid custom values fall back to a fresh client-generated id. */
  pingId?: string;
  /** Override ingest origin. Defaults to https://ingest.postdeploy.dev. */
  baseUrl?: string;
  /** Injectable fetch implementation, primarily for tests. Defaults to the global `fetch`. */
  fetchImpl?: typeof fetch;
  /** Log a console.warn on final retry exhaustion / internal error. Default false. */
  debug?: boolean;
}

function generatePingId(): string {
  const cryptoRef: Crypto | undefined = globalThis.crypto;
  if (cryptoRef && typeof cryptoRef.randomUUID === "function") {
    return cryptoRef.randomUUID();
  }
  // Fallback for environments without a global Web Crypto object (older
  // Node < 19 without --experimental-global-webcrypto). Not
  // cryptographically strong, but a ping id is only ever used as an
  // ingest-side dedup key, never a security token.
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function normalizeExitCode(exitCode: number): number {
  if (!Number.isFinite(exitCode)) return 1;
  return Math.min(255, Math.max(0, Math.trunc(exitCode)));
}

function truncateMessage(message: string): string {
  return message.length > MAX_MESSAGE_LENGTH ? message.slice(0, MAX_MESSAGE_LENGTH) : message;
}

/**
 * Builds the ping URL for a single heartbeat call. Exported for the SDK's
 * own URL-building tests; not part of the public subpath surface (only
 * `heartbeat` and `HeartbeatOptions` are re-exported by the platform
 * adapters).
 */
export function buildPingUrl(token: string, options: HeartbeatOptions & { pingId: string }): string {
  const baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
  const encodedToken = encodeURIComponent(token);

  let pathSuffix = "";
  const searchParams = new URLSearchParams();

  if (options.state !== undefined) {
    searchParams.set("state", options.state);
  } else if (options.exitCode !== undefined) {
    pathSuffix = `/${normalizeExitCode(options.exitCode)}`;
  }

  searchParams.set("ping_id", options.pingId);

  if (options.message !== undefined) {
    searchParams.set("msg", truncateMessage(options.message));
  }

  return `${baseUrl}/h/${encodedToken}${pathSuffix}?${searchParams.toString()}`;
}

// Same deliberate exception as `transport.ts`'s `delay`: `Promise.withResolvers`
// is Node 22+ and this package supports Node 18. Heartbeat is the load-bearing
// shipped function; a TypeError here breaks a customer's cron alerting.
function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function backoffMs(attempt: number): number {
  const exponential = BACKOFF_BASE_MS * 2 ** (attempt - 1);
  const jitterFactor = 1 - BACKOFF_JITTER + Math.random() * (2 * BACKOFF_JITTER);
  return exponential * jitterFactor;
}

function retryAfterMs(response: Response): number | null {
  const retryAfter = response.headers.get("Retry-After");
  if (retryAfter === null || retryAfter.length === 0 || /[^0-9]/.test(retryAfter)) return null;

  const seconds = Number(retryAfter);
  if (Number.isNaN(seconds)) return null;

  return Math.min(seconds * 1000, MAX_RETRY_AFTER_MS);
}
/**
 * Returns whether a response status represents a transient heartbeat failure.
 * Other client errors must not be retried because the request is unchanged.
 */
function retryableStatus(status: number): boolean {
  return status === 408 || status === 429 || (status >= 500 && status <= 599);
}

function diagnosticError(error: unknown, token: string): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.replaceAll(token, "[REDACTED]");
}

type PingOutcome =
  | { outcome: "sent" | "permanent" }
  | { outcome: "exhausted"; lastError: string };

/**
 * Runs the retry schedule. The same `url` (and therefore the same `pingId`)
 * is reused on every attempt so the ingest side dedupes retries of one
 * logical event rather than recording several.
 */

async function pingWithRetries(url: string, token: string, fetchImpl: typeof fetch): Promise<PingOutcome> {
  let lastError: unknown;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), ATTEMPT_TIMEOUT_MS);

    try {
      const response = await fetchImpl(url, { method: "POST", signal: controller.signal });
      if (response.ok) return { outcome: "sent" };

      lastError = new Error(`heartbeat ping responded with status ${response.status}`);
      if (PERMANENT_CLIENT_ERROR_STATUSES[response.status] || !retryableStatus(response.status)) {
        return { outcome: "permanent" };
      }

      if (attempt < MAX_ATTEMPTS) {
        await delay(response.status === 429 ? retryAfterMs(response) ?? backoffMs(attempt) : backoffMs(attempt));
      }
    } catch (err) {
      lastError = err;
      if (attempt < MAX_ATTEMPTS) await delay(backoffMs(attempt));
    } finally {
      clearTimeout(timeout);
    }
  }

  return { outcome: "exhausted", lastError: diagnosticError(lastError, token) };
}

/**
 * Never throws or rejects: internal errors, network failures, and retryable
 * 408, 429, and 5xx responses are retried up to two attempts total.
 * Retry-After delta-seconds are capped at two seconds. Other retries use
 * jittered backoff around 500ms, and every attempt is bounded to five seconds.
 */
export async function heartbeat(token: string, options: HeartbeatOptions = {}): Promise<void> {
  const debug = options.debug ?? false;
  try {
    const pingId = options.pingId !== undefined && PING_ID_PATTERN.test(options.pingId) ? options.pingId : generatePingId();
    const url = buildPingUrl(token, { ...options, pingId });
    const fetchImpl = options.fetchImpl ?? globalThis.fetch;

    if (typeof fetchImpl !== "function") {
      if (debug) {
        console.warn("[@postdeploy/sdk] heartbeat: no fetch implementation available (token [REDACTED])");
      }
      return;
    }

    const result = await pingWithRetries(url, token, fetchImpl);
    if (debug && result.outcome === "exhausted") {
      console.warn(`[@postdeploy/sdk] heartbeat: exhausted ${MAX_ATTEMPTS} attempts (token [REDACTED])`, result.lastError);
    }
  } catch {
    // Belt-and-suspenders: guarantees the "never throw into the host app"
    // contract (spec section 5.5) even against an unforeseen internal bug.
    if (debug) {
      console.warn("[@postdeploy/sdk] heartbeat: internal error (token [REDACTED])");
    }
  }
}
