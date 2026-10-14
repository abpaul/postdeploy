/**
 * @postdeploy/sdk Observe client: `init`, `captureException`, `captureMessage`,
 * `flush`, `close`. Platform-neutral -- `./browser`, `./node`, and
 * `./cloudflare` re-export this verbatim except for how each schedules (or
 * deliberately doesn't schedule) the idle-flush timer, since Workers
 * isolates, long-lived Node processes, and browser tabs have very different
 * lifetimes.
 *
 * State is a single module-level singleton, matching `heartbeat.ts`'s
 * platform-neutral design and the SDK spec's "a module-scope `init()` call
 * is correct and recommended" guidance -- one client per process/isolate,
 * calling `init` again reinitializes it rather than creating a second one.
 */

import { generateEventId } from "../id";
import { SDK_NAME, SDK_VERSION } from "../version";
import { __resetDedupForTests, resolveDedupId } from "./dedup";
import {
  BATCH_FLUSH_MS,
  BATCH_MAX_BYTES,
  BATCH_MAX_ITEMS,
  MAX_CONTEXT_CHARS,
  MAX_ENVELOPE_BYTES,
  MAX_EXCEPTION_VALUE_CHARS,
  MAX_FINGERPRINT_CHARS,
  MAX_FINGERPRINT_ENTRIES,
  MAX_MESSAGE_CHARS,
  MAX_STACK_TRACE_CHARS,
  MAX_TAGS_CHARS,
  SERVER_MAX_BREADCRUMBS,
  capContext,
  capFingerprint,
  capFrames,
  capText,
  type ErrorLevel,
  type WireBreadcrumb,
  type WireErrorItem,
  type WireException,
  type WireStackFrame,
} from "./envelope";
import { stripQueryString } from "./breadcrumbs";
import { mergeScope, type ScopeOverrides, type ScopeSnapshot } from "./scope";
import { parseStack } from "./stack";
import { delay, postJsonWithRetries } from "./transport";

/**
 * Registered once by a platform adapter that has an ambient scope to offer
 * (browser: a module-global singleton; Node: the active
 * `AsyncLocalStorage` context). Cloudflare registers none -- every capture
 * there must pass `user`/`tags`/`contexts`/`breadcrumbs` explicitly (see
 * `./scope.ts`'s file comment for why). Module-level and independent of
 * `state` so it survives `init()` being called again.
 */
type ScopeProvider = () => ScopeSnapshot;
let scopeProvider: ScopeProvider | null = null;

/** Adapter-internal wiring, not part of the public platform surface -- called once from each adapter module, never by application code. */
export function setScopeProvider(provider: ScopeProvider | null): void {
  scopeProvider = provider;
}

const DEFAULT_BASE_URL = "https://ingest.postdeploy.dev";
const DEFAULT_FLUSH_TIMEOUT_MS = 2_000;

const SENSITIVE_KEY_PARTS = [
  "password",
  "passwd",
  "secret",
  "token",
  "api_key",
  "apikey",
  "authorization",
  "cookie",
] as const;
const FILTERED = "[FILTERED]";

function scrubSensitive<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((entry) => scrubSensitive(entry)) as T;
  }
  if (value === null || typeof value !== "object") return value;

  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      SENSITIVE_KEY_PARTS.some((part) => key.toLowerCase().includes(part))
        ? FILTERED
        : scrubSensitive(entry),
    ]),
  ) as T;
}
export interface ObserveInitOptions {
  /** Project API key, e.g. `"alp_p_..."`. Must carry the `ingest` scope. Required. */
  key: string;
  /** Logical deploy environment. Defaults to `"production"`. */
  environment?: string;
  /** Release identifier (git SHA, semver tag) attached to every captured event. */
  release?: string;
  /** Override the ingest origin. Defaults to `https://ingest.postdeploy.dev`. Mainly for testing against a local/self-hosted ingest endpoint. */
  baseUrl?: string;
  /** Injectable `fetch` implementation, primarily for tests. Defaults to the platform global `fetch`. */
  fetchImpl?: typeof fetch;
  /** Enables `console.warn` diagnostics for dropped events and transport failures. Default `false`. */
  debug?: boolean;
  /**
   * Idle-queue flush interval in ms: once the oldest queued event has waited
   * this long, the queue is flushed even if it hasn't hit the item/byte
   * threshold. Set to `0` to disable the background timer entirely -- what
   * the `/cloudflare` adapter's `init` always does, since a Workers isolate
   * can be evicted between requests and a `setTimeout` that outlives the
   * request it was scheduled in is not a reliable flush mechanism there.
   * Default `5000`.
   */
  autoFlushIntervalMs?: number;
  /**
   * Automatic global error capture (docs/sdk/02-dx-improvements.md section
   * 2): `window.onerror`/`onunhandledrejection` in the browser,
   * `process.on("uncaughtException"/"unhandledRejection")` in Node. Default
   * `true` on both. Cloudflare has no process-global hooks to attach, so its
   * `init` ignores this option entirely -- use `wrapHandler`/`wrapScheduled`
   * from `@postdeploy/sdk/cloudflare` instead.
   */
  captureUnhandled?: boolean;
  /**
   * Post-error log window in ms (issue #47): an exception item lingers this
   * long before it joins the send queue, and console/log breadcrumbs
   * recorded during the window are appended to it, marked
   * `data.after_error`. `0` disables the window (items queue immediately,
   * exactly the pre-#47 behavior). Clamped to `BATCH_FLUSH_MS` so a
   * pending item can never outwait the idle flush it will join.
   * `flush()`/`close()`/the pagehide keepalive seal pending items
   * immediately -- the window delays sending, never loses events.
   * Default `2000`.
   */
  postErrorLogWindowMs?: number;
  /**
   * Breadcrumb ring buffer capacity (docs/sdk/02-dx-improvements.md section
   * 3). Default 30. Only meaningful on adapters that carry an ambient
   * breadcrumb trail (browser, Node); Cloudflare has none to size.
   */
  maxBreadcrumbs?: number;
}

/**
 * Scope overrides accepted by both `captureException` and `captureMessage`,
 * on top of whichever ambient scope the platform adapter provides (none, on
 * Cloudflare -- see `./scope.ts`). `mechanism` defaults to `"generic"` for a
 * direct call; the browser/Node/Cloudflare auto-capture paths pass their own
 * value (`"onerror"`, `"uncaughtException"`, `"instrumentation"`, etc, per
 * docs/sdk/02-dx-improvements.md section 2) through this same option rather
 * than a separate code path, which is also what makes dedup (section 2,
 * "Deduplicate") work for free: an auto-captured error and a manually
 * captured one for the same object both flow through `captureException`.
 */
export interface CaptureScopeOptions extends ScopeOverrides {
  mechanism?: string;
  /**
   * Overrides the server's default fingerprint-based grouping for this one
   * event (issue #17). At most 16 entries of at most 256 characters each
   * (server-enforced; capped client-side too, mirroring the Elixir/Ruby
   * SDKs' own `fingerprint` option).
   */
  fingerprint?: string[];
}

export interface CaptureExceptionOptions extends CaptureScopeOptions {
  /** Arbitrary structured data local to this one capture, merged into the event's `contexts.extra`. */
  context?: Record<string, unknown>;
  /**
   * Overrides the normal `parseStack(error.stack)` capture with an
   * already-built wire frame array (mirrors the Elixir SDK's
   * `Envelope.build_frame(%{} = wire_frame, _)` passthrough). Real capture
   * callers never pass this; it exists so the golden-envelope contract
   * test (issue #18) can call the real `captureException` with the
   * golden's literal, cross-language-reproducible frames instead of a
   * real `Error.stack` tied to this file's own call site.
   */
  frames?: WireStackFrame[];
}

export type CaptureMessageOptions = CaptureScopeOptions;

interface PendingItem {
  item: WireErrorItem;
  appended: number;
  timer: ReturnType<typeof setTimeout>;
}

interface ObserveState {
  key: string;
  environment: string;
  release: string | undefined;
  baseUrl: string;
  fetchImpl: typeof fetch;
  debug: boolean;
  autoFlushIntervalMs: number;
  postErrorLogWindowMs: number;
  queue: WireErrorItem[];
  queuedBytes: number;
  pending: PendingItem[];
  inFlight: Promise<void> | null;
  timer: ReturnType<typeof setTimeout> | null;
  closed: boolean;
}

let state: ObserveState | null = null;

function debugWarn(message: string, ...rest: unknown[]): void {
  // packages/sdk is deliberately exempt from the repo's no-console rule:
  // this IS the documented debug-diagnostics channel for a published
  // package that cannot depend on the app's own logger.
  console.warn(`[@postdeploy/sdk] ${message}`, ...rest);
}

/**
 * Best-effort, diagnostic-only -- never validated server-side (ingest.md
 * §2.2's `header.sdk` is free-form). Reads `process` through `globalThis`
 * rather than the bare identifier: this package's tsconfig carries no
 * `@types/node` (it must type-check standalone as a published, dependency-free
 * package), so `process` is not an ambient global here even under Node.
 */
function detectPlatform(): string {
  if (typeof navigator !== "undefined" && navigator.userAgent === "Cloudflare-Workers") return "cloudflare";
  if (typeof window !== "undefined" && typeof window.document !== "undefined") return "browser";
  const nodeProcess = (globalThis as { process?: { versions?: { node?: string } } }).process;
  if (nodeProcess?.versions?.node !== undefined) return "node";
  return "unknown";
}

function clearTimer(s: ObserveState): void {
  if (s.timer !== null) {
    clearTimeout(s.timer);
    s.timer = null;
  }
}

function maybeUnref(timer: ReturnType<typeof setTimeout>): void {
  // Real in Node (lets a short script exit without an explicit close()/flush()
  // call keeping the process alive); a no-op everywhere else, since browsers
  // and workerd don't expose `unref` on their timer handles.
  const withUnref = timer as unknown as { unref?: () => void };
  if (typeof withUnref.unref === "function") withUnref.unref();
}

function scheduleTimer(s: ObserveState): void {
  const timer = setTimeout(() => {
    s.timer = null;
    void triggerFlush(s);
  }, s.autoFlushIntervalMs);
  maybeUnref(timer);
  s.timer = timer;
}

function estimateBytes(item: WireErrorItem): number {
  return new TextEncoder().encode(JSON.stringify(item)).byteLength;
}

const DEFAULT_POST_ERROR_LOG_WINDOW_MS = 2_000;
/**
 * At most this many after-error breadcrumbs join a pending item. A crash
 * that triggers a log storm gets a bounded tail, and the before-error
 * trail is never evicted to make room.
 */
const MAX_AFTER_ERROR_BREADCRUMBS = 20;

/**
 * Holds an exception item open for the post-error log window (issue #47),
 * or queues it immediately when the window is disabled.
 */
function enqueueOrHold(s: ObserveState, item: WireErrorItem): void {
  if (s.postErrorLogWindowMs === 0) {
    enqueue(s, item);
    return;
  }

  const pendingItem: PendingItem = {
    item,
    appended: 0,
    timer: setTimeout(() => sealPending(s, pendingItem), s.postErrorLogWindowMs),
  };
  maybeUnref(pendingItem.timer);
  s.pending.push(pendingItem);
}

function sealPending(s: ObserveState, pendingItem: PendingItem): void {
  const index = s.pending.indexOf(pendingItem);
  if (index === -1) return;
  s.pending.splice(index, 1);
  clearTimeout(pendingItem.timer);
  enqueue(s, pendingItem.item);
}

function sealAllPending(s: ObserveState): void {
  while (s.pending.length > 0) sealPending(s, s.pending[0]!);
}

/**
 * Called by adapters when a log-line breadcrumb (browser `console.*`) is
 * recorded: appends it to every pending exception item, marked
 * `data.after_error`, within the per-item and server breadcrumb bounds.
 * A no-op with no pending items or before `init`.
 */
export function notifyLogBreadcrumb(crumb: WireBreadcrumb): void {
  if (state === null || state.pending.length === 0) return;
  for (const pendingItem of state.pending) {
    if (pendingItem.appended >= MAX_AFTER_ERROR_BREADCRUMBS) continue;
    const breadcrumbs = pendingItem.item.breadcrumbs ?? [];
    if (breadcrumbs.length >= SERVER_MAX_BREADCRUMBS) continue;
    breadcrumbs.push({ ...crumb, data: { ...(crumb.data ?? {}), after_error: true } });
    pendingItem.item.breadcrumbs = breadcrumbs;
    pendingItem.appended += 1;
  }
}

function enqueue(s: ObserveState, item: WireErrorItem): void {
  const wasEmpty = s.queue.length === 0;
  s.queue.push(item);
  s.queuedBytes += estimateBytes(item);

  if (s.queue.length >= BATCH_MAX_ITEMS || s.queuedBytes >= BATCH_MAX_BYTES) {
    clearTimer(s);
    void triggerFlush(s);
    return;
  }
  if (wasEmpty && s.timer === null && s.autoFlushIntervalMs > 0) {
    scheduleTimer(s);
  }
}

function buildEnvelope(s: ObserveState, items: WireErrorItem[]): Record<string, unknown> {
  return {
    header: { key: s.key, sdk: { name: SDK_NAME, version: SDK_VERSION, platform: detectPlatform() }, sent_at: new Date().toISOString() },
    items: items.map((item) => scrubSensitive(item)),
  };
}

async function sendBatch(s: ObserveState, items: WireErrorItem[]): Promise<void> {
  const body = JSON.stringify(buildEnvelope(s, items));
  if (new TextEncoder().encode(body).byteLength > MAX_ENVELOPE_BYTES) {
    // Should be unreachable given this SDK's own 64 KB batching ceiling
    // (envelope.ts's BATCH_MAX_BYTES), but guard rather than send a request
    // the server would 413 anyway.
    if (s.debug) debugWarn(`observe: dropping oversized envelope (${items.length} events, over ${MAX_ENVELOPE_BYTES} bytes)`);
    return;
  }

  const outcome = await postJsonWithRetries(`${s.baseUrl}/e/errors`, body, { "Content-Type": "application/json", Authorization: `Bearer ${s.key}` }, s.fetchImpl);
  if (s.debug && outcome.outcome === "exhausted") {
    debugWarn(`observe: dropped ${items.length} event(s) after exhausting retries`, outcome.lastError);
  }
}

/**
 * Sends `items`, then -- while still the one and only in-flight send --
 * checks the queue again: if a capture landed while this send was in
 * flight, it sends THAT batch too before letting `s.inFlight` go `null`.
 * This is what makes `flush()`/`close()` truthful: whichever caller is
 * awaiting `s.inFlight` (the original `triggerFlush` caller, or a later one
 * that joined the same in-flight promise) only sees it resolve once the
 * queue is actually empty, not just once the first POST lands.
 */
async function drainLoop(s: ObserveState, initialItems: WireErrorItem[]): Promise<void> {
  let items = initialItems;
  for (;;) {
    try {
      await sendBatch(s, items);
    } catch (err) {
      // Belt-and-suspenders: sendBatch/postJsonWithRetries should never
      // reject, but this guarantees flush()/close() never throw either way.
      if (s.debug) debugWarn("observe: internal error while flushing", err);
    }
    if (s.queue.length === 0) break;
    items = s.queue.splice(0, s.queue.length);
    s.queuedBytes = 0;
  }
  s.inFlight = null;
}

/** Drains whatever is currently queued and sends it, then keeps draining (single POST at a time) until the queue is empty. Single-flight per client: a call while one is already in flight joins it rather than starting a second concurrent send. */
function triggerFlush(s: ObserveState): Promise<void> {
  if (s.inFlight !== null) return s.inFlight;

  const items = s.queue.splice(0, s.queue.length);
  s.queuedBytes = 0;
  if (items.length === 0) return Promise.resolve();

  const promise = drainLoop(s, items);
  s.inFlight = promise;
  return promise;
}

/**
 * Initializes the Observe client. Repeated initialization may update transport
 * settings in place. Changing the key while work is pending is rejected so an
 * event can never move to another project; flush or close first.
 * Initialization after `close()` starts a new active state.
 */
export function init(options: ObserveInitOptions): void {
  const autoFlushIntervalMs = options.autoFlushIntervalMs ?? BATCH_FLUSH_MS;
  const postErrorLogWindowMs = Math.max(0, Math.min(options.postErrorLogWindowMs ?? DEFAULT_POST_ERROR_LOG_WINDOW_MS, BATCH_FLUSH_MS));

  if (state !== null && !state.closed) {
    if (
      options.key !== state.key &&
      (state.pending.length > 0 || state.queue.length > 0 || state.inFlight !== null)
    ) {
      throw new Error("Cannot change the Observe key while events are pending; flush or close first.");
    }

    if (options.debug === true) debugWarn("init() called again; updating the active client without discarding work.");
    clearTimer(state);
    state.key = options.key;
    state.environment = options.environment ?? "production";
    state.release = options.release;
    state.baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    state.fetchImpl = options.fetchImpl ?? globalThis.fetch;
    state.debug = options.debug ?? false;
    state.autoFlushIntervalMs = autoFlushIntervalMs;
    state.postErrorLogWindowMs = postErrorLogWindowMs;
    if (state.queue.length > 0 && state.inFlight === null && autoFlushIntervalMs > 0) scheduleTimer(state);
    return;
  }

  state = {
    key: options.key,
    environment: options.environment ?? "production",
    release: options.release,
    baseUrl: (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, ""),
    fetchImpl: options.fetchImpl ?? globalThis.fetch,
    debug: options.debug ?? false,
    autoFlushIntervalMs,
    postErrorLogWindowMs,
    queue: [],
    queuedBytes: 0,
    pending: [],
    inFlight: null,
    timer: null,
    closed: false,
  };
}

function normalizeError(error: unknown): { type: string; value: string | undefined; frames: ReturnType<typeof parseStack>; nonErrorValue: unknown } {
  if (error instanceof Error) {
    return { type: error.name.length > 0 ? error.name : "Error", value: error.message, frames: parseStack(error.stack), nonErrorValue: undefined };
  }
  // Spec §3.2: a non-Error thrown value is normalized into a synthetic
  // error, with the original value preserved under `contexts.extra.non_error_value`.
  return { type: "Error", value: safeStringifyThrown(error), frames: [], nonErrorValue: error };
}

function safeStringifyThrown(value: unknown): string {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return String(value);
  }
}

/** Caps a tags object by serialized size; drops it (with a debug warning) rather than send a truncated `Record<string, string>` that would no longer parse as one. */
function capTags(tags: Record<string, string> | undefined, s: ObserveState): Record<string, string> | undefined {
  if (tags === undefined || Object.keys(tags).length === 0) return undefined;
  if (new TextEncoder().encode(JSON.stringify(tags)).byteLength <= MAX_TAGS_CHARS) return tags;
  if (s.debug) debugWarn("observe: dropping oversized tags object (over MAX_TAGS_CHARS)");
  return undefined;
}

/**
 * Resolves the scope fields (`contexts`, `tags`, `user`, `breadcrumbs`)
 * shared by both `captureException` and `captureMessage`: merges whichever
 * ambient scope the platform adapter provides (`scopeProvider`, none on
 * Cloudflare) with this capture's explicit overrides, folds `extraContext`
 * (the `context` option / a non-Error's preserved value) into
 * `contexts.extra`, and applies the same write-boundary caps the server
 * enforces so an oversized scope is trimmed here rather than discovered as
 * a 413.
 */
function resolveScopeFields(
  options: CaptureScopeOptions | undefined,
  extraContext: Record<string, unknown> | undefined,
  s: ObserveState,
): Pick<WireErrorItem, "contexts" | "tags" | "user" | "breadcrumbs"> {
  const ambient = scopeProvider !== null ? scopeProvider() : undefined;
  const merged = mergeScope(ambient, options);
  const namedContexts: Record<string, unknown> = { ...merged.contexts };
  if (extraContext !== undefined) namedContexts.extra = extraContext;
  if (namedContexts.request === undefined) {
    const request = defaultRequestContext();
    if (request !== undefined) namedContexts.request = request;
  }
  const contexts = Object.keys(namedContexts).length > 0 ? capContext(namedContexts, MAX_CONTEXT_CHARS) : undefined;
  const breadcrumbs = merged.breadcrumbs.length > 0 ? merged.breadcrumbs.slice(-SERVER_MAX_BREADCRUMBS) : undefined;
  return { contexts, tags: capTags(merged.tags, s), user: merged.user, breadcrumbs };
}

/**
 * Ambient request context for browser-like hosts: the page URL with its
 * query string stripped (a query string routinely carries tokens and PII
 * that key-based scrubbing cannot see inside a raw string) plus the user
 * agent. Non-browser hosts (Node, Cloudflare) return `undefined`; the host
 * attaches its own request context through the scope instead.
 */
function defaultRequestContext(): Record<string, string> | undefined {
  // Gated on a real page URL, not on `navigator`: Node ≥21 defines a global
  // `navigator.userAgent` too, and a server-side host must not grow a
  // meaningless request context (it broke the golden contract test).
  if (typeof window === "undefined" || typeof window.location?.href !== "string") return undefined;
  const context: Record<string, string> = { url: stripQueryString(window.location.href) };
  if (typeof navigator !== "undefined" && typeof navigator.userAgent === "string") {
    context.user_agent = navigator.userAgent;
  }
  return context;
}

/** Walks `Error#cause` into the wire `cause` chain, bounded at the server's limit of 4 nested causes; a cycle terminates at the bound. */
function buildCause(error: unknown, depth: number): WireException | undefined {
  if (depth <= 0 || !(error instanceof Error)) return undefined;
  const normalized = normalizeError(error);
  const nested = buildCause(error.cause, depth - 1);
  return {
    type: normalized.type,
    value: capText(normalized.value, MAX_EXCEPTION_VALUE_CHARS),
    ...(normalized.frames.length > 0 ? { stacktrace: { frames: capFrames(normalized.frames, MAX_STACK_TRACE_CHARS) } } : {}),
    ...(nested !== undefined ? { cause: nested } : {}),
  };
}

const MAX_CAUSE_DEPTH = 4;

function buildExceptionItem(id: string, error: unknown, options: CaptureExceptionOptions | undefined, s: ObserveState): WireErrorItem {
  const normalized = normalizeError(error);
  const frames = options?.frames ?? normalized.frames;
  const scoped = resolveScopeFields(options, mergeContext(options?.context, normalized.nonErrorValue), s);
  const cause = error instanceof Error ? buildCause(error.cause, MAX_CAUSE_DEPTH) : undefined;
  return {
    id,
    type: "exception",
    timestamp: new Date().toISOString(),
    level: "error",
    release: s.release,
    environment: s.environment,
    exception: {
      type: normalized.type,
      value: capText(normalized.value, MAX_EXCEPTION_VALUE_CHARS),
      ...(frames.length > 0 ? { stacktrace: { frames: capFrames(frames, MAX_STACK_TRACE_CHARS) } } : {}),
      ...(cause !== undefined ? { cause } : {}),
    },
    ...(scoped.contexts !== undefined ? { contexts: scoped.contexts } : {}),
    ...(scoped.tags !== undefined ? { tags: scoped.tags } : {}),
    ...(scoped.user !== undefined ? { user: scoped.user } : {}),
    ...(scoped.breadcrumbs !== undefined ? { breadcrumbs: scoped.breadcrumbs } : {}),
    ...(resolveFingerprint(options) !== undefined ? { fingerprint: resolveFingerprint(options) } : {}),
    mechanism: options?.mechanism ?? "generic",
  };
}

function resolveFingerprint(options: CaptureScopeOptions | undefined): string[] | undefined {
  return capFingerprint(options?.fingerprint, MAX_FINGERPRINT_ENTRIES, MAX_FINGERPRINT_CHARS);
}

function mergeContext(userContext: Record<string, unknown> | undefined, nonErrorValue: unknown): Record<string, unknown> | undefined {
  if (userContext === undefined && nonErrorValue === undefined) return undefined;
  const extra: Record<string, unknown> = { ...userContext };
  if (nonErrorValue !== undefined) extra.non_error_value = nonErrorValue;
  return extra;
}

/**
 * Captures an exception for Observe. Accepts any thrown value; a non-`Error`
 * value is normalized into a synthetic error with the original preserved
 * under `contexts.extra.non_error_value`. Returns the client-generated
 * event id synchronously, even if `init` hasn't been called yet or the
 * client is closed -- the id is always safe to show a user, whether or not
 * the event was actually queued. Never throws.
 *
 * Deduplicates: the same error object (or, for a primitive throw, the same
 * value) captured again within a short window returns the FIRST call's id
 * and is not re-queued -- see `./dedup.ts`. This is what makes automatic
 * global capture safe to use alongside manual `captureException` calls for
 * the same error without double-reporting it.
 */
export function captureException(error: unknown, options?: CaptureExceptionOptions): string {
  const freshId = generateEventId();
  const { id, isDuplicate } = resolveDedupId(error, freshId);
  try {
    if (isDuplicate) {
      if (state?.debug === true) debugWarn("captureException(): duplicate error suppressed within the dedup window.", id);
      return id;
    }
    if (state === null) return id;
    if (state.closed) {
      if (state.debug) debugWarn("captureException() called after close(); event dropped.", id);
      return id;
    }
    enqueueOrHold(state, buildExceptionItem(id, error, options, state));
  } catch (err) {
    if (state?.debug === true) debugWarn("captureException() failed internally; event dropped.", err);
  }
  return id;
}

/**
 * Captures a non-exception message as an Observe event. Default level
 * `"info"`. Returns the client-generated event id synchronously. Never
 * throws.
 */
export function captureMessage(message: string, level: ErrorLevel = "info", options?: CaptureMessageOptions): string {
  const id = generateEventId();
  try {
    if (state === null) return id;
    if (state.closed) {
      if (state.debug) debugWarn("captureMessage() called after close(); event dropped.", id);
      return id;
    }
    const scoped = resolveScopeFields(options, undefined, state);
    enqueue(state, {
      id,
      type: "message",
      timestamp: new Date().toISOString(),
      level,
      release: state.release,
      environment: state.environment,
      message: capText(message, MAX_MESSAGE_CHARS),
      ...(scoped.contexts !== undefined ? { contexts: scoped.contexts } : {}),
      ...(scoped.tags !== undefined ? { tags: scoped.tags } : {}),
      ...(scoped.user !== undefined ? { user: scoped.user } : {}),
      ...(scoped.breadcrumbs !== undefined ? { breadcrumbs: scoped.breadcrumbs } : {}),
      ...(resolveFingerprint(options) !== undefined ? { fingerprint: resolveFingerprint(options) } : {}),
      mechanism: options?.mechanism ?? "generic",
    });
  } catch (err) {
    if (state?.debug === true) debugWarn("captureMessage() failed internally; event dropped.", err);
  }
  return id;
}

/**
 * Forces an immediate send of any queued events. Resolves `true` if the
 * queue drained within `timeoutMs` (default 2000ms), `false` on timeout --
 * queued events are not discarded on a `flush` timeout, only on `close`.
 * Never throws.
 */
export async function flush(timeoutMs: number = DEFAULT_FLUSH_TIMEOUT_MS): Promise<boolean> {
  if (state === null) return true;
  sealAllPending(state);
  clearTimer(state);
  const pending = triggerFlush(state);
  const timedOut = Symbol("observe-flush-timeout");
  const result = await Promise.race([pending.then(() => "done" as const), delay(timeoutMs).then(() => timedOut)]);
  return result !== timedOut;
}

/**
 * Stops this client instance from accepting new events, then drains its work.
 * Marking the captured instance closed before awaiting lets a concurrent
 * `init()` create a new owner without that new state being closed afterward.
 */
export async function close(timeoutMs: number = DEFAULT_FLUSH_TIMEOUT_MS): Promise<boolean> {
  if (state === null) return true;
  const closing = state;
  closing.closed = true;
  sealAllPending(closing);
  clearTimer(closing);
  const pending = triggerFlush(closing);
  const timedOut = Symbol("observe-close-timeout");
  const result = await Promise.race([pending.then(() => "done" as const), delay(timeoutMs).then(() => timedOut)]);
  clearTimer(closing);
  return result !== timedOut;
}

/**
 * Drains the queue and returns the exact request a normal `flush()` would
 * have sent, WITHOUT sending it or engaging the retry transport -- for a
 * platform adapter's own unload-time flush (e.g. the browser adapter's
 * `pagehide` handler, which needs a single best-effort attempt, not a
 * multi-second retry loop after the page is already gone). Not part of the
 * platform-neutral public surface (`init`/`capture*`/`flush`/`close`);
 * exported for adapter authors and advanced `/core` users only. Returns
 * `null` if there is nothing queued or the client was never initialized.
 */
export function buildKeepaliveFlushRequest(): { url: string; body: string; headers: Record<string, string> } | null {
  if (state === null) return null;
  sealAllPending(state);
  clearTimer(state);
  const items = state.queue.splice(0, state.queue.length);
  state.queuedBytes = 0;
  if (items.length === 0) return null;
  return {
    url: `${state.baseUrl}/e/errors`,
    body: JSON.stringify(buildEnvelope(state, items)),
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${state.key}` },
  };
}

/**
 * Test-only: resets the singleton client to its pre-`init` state. Not
 * re-exported from `./index.ts` or any adapter entrypoint, so it never
 * reaches a published bundle -- imported directly by this module's own
 * test file to isolate cases that assert on pre-`init` behavior.
 */
export function __resetForTests(): void {
  if (state !== null) {
    clearTimer(state);
    for (const pendingItem of state.pending) clearTimeout(pendingItem.timer);
    state.pending = [];
  }
  state = null;
  __resetDedupForTests();
}
