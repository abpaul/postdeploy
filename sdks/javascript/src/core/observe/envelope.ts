/**
 * `POST /e/errors` wire shape and write-boundary caps, mirrored BY HAND from
 * the accepted server shape in `packages/schemas/src/observe/error-envelope.ts`
 * (that file's own header names the ingest route and doc section that own
 * this contract). This package cannot import `packages/schemas` directly:
 * it ships to npm with zero runtime dependencies and `packages/schemas` is
 * an unpublished workspace package, so a real import would either break the
 * npm install or silently bundle a private package into a public one.
 *
 * Keeping these caps here (rather than only documenting them) matters
 * because the server enforces its own copy regardless of what a caller
 * sends -- a drift between this file and the schema it tracks means the SDK
 * trims a little more or less aggressively than necessary, not a wire
 * protocol break. If the server-side caps change, update this file to
 * match; nothing here is generated.
 */

/** Whole-envelope ceiling the server enforces (`POST /e/errors` 413 above this). */
export const MAX_ENVELOPE_BYTES = 1_048_576;
/** Per-item free-text caps the server applies at its own write boundary. */
export const MAX_MESSAGE_CHARS = 4_096;
export const MAX_EXCEPTION_VALUE_CHARS = 4_096;
export const MAX_STACK_TRACE_CHARS = 16_384;
export const MAX_CONTEXT_CHARS = 8_192;
export const MAX_TAGS_CHARS = 4_096;
/**
 * SDK-side ring buffer default (docs/sdk/02-dx-improvements.md section 3):
 * smaller than the server's own 100-breadcrumb ceiling
 * (`packages/schemas/src/observe/error-envelope.ts`'s `MAX_BREADCRUMBS`) on
 * purpose -- a trail this long is already more than enough to reconstruct
 * what led to a capture, and keeping it short bounds both memory and the
 * per-event payload size. `maxBreadcrumbs` on `init` overrides it.
 */
export const DEFAULT_MAX_BREADCRUMBS = 30;
/** Server ceiling (`error-envelope.ts`'s own `MAX_BREADCRUMBS`) -- a defensive cap applied when merging ambient + per-capture breadcrumbs, never expected to bind given the ring buffer default above. */
export const SERVER_MAX_BREADCRUMBS = 100;
export const MAX_BREADCRUMB_MESSAGE_CHARS = 2_048;
export const MAX_BREADCRUMB_CATEGORY_CHARS = 128;
/**
 * Mirrors the server's `errorItemSchema.fingerprint`
 * (`z.array(z.string().max(256)).min(1).max(16)`, issue #17) and the
 * Elixir/Ruby SDKs' own copies of the same caps -- kept here so this SDK
 * can accept a `fingerprint` override too (previously missing here; issue
 * #18 contract testing surfaced the gap against the other two SDKs).
 */
export const MAX_FINGERPRINT_ENTRIES = 16;
export const MAX_FINGERPRINT_CHARS = 256;

/**
 * SDK-side batching thresholds (not a server cap): the in-memory queue is
 * flushed as soon as any one of these is first true. Deliberately smaller
 * than the server's own ceilings above so a batch this SDK builds is never
 * the thing that trips a server-side size rejection.
 */
export const BATCH_MAX_ITEMS = 10;
export const BATCH_MAX_BYTES = 64 * 1024;
export const BATCH_FLUSH_MS = 5_000;

/**
 * The four levels the server's `errorLevelSchema` actually accepts. The SDK
 * spec's public draft additionally lists `"debug"` for `captureMessage`;
 * this package does not expose that value because the ingest route treats
 * an unrecognized level as a malformed item and drops it silently (a
 * capture the caller would reasonably expect to show up, quietly
 * discarded) -- narrowing the type here is safer than reproducing that
 * doc/server mismatch in a public type signature. See the SDK spec's change
 * log for the tracking note.
 */
export type ErrorLevel = "fatal" | "error" | "warning" | "info";

export interface WireStackFrame {
  file?: string;
  function?: string;
  lineno?: number;
  colno?: number;
  in_app?: boolean;
}

/** Mirrors the server's `breadcrumbSchema` (`packages/schemas/src/observe/error-envelope.ts`). */
export interface WireBreadcrumb {
  category?: string;
  message?: string;
  level?: string;
  ts?: string;
  data?: unknown;
}

/** Mirrors the server's `errorItemSchema.user` (`.strict()`, `id`/`email` only). */
export interface WireUser {
  id?: string;
  email?: string;
}

/**
 * One exception in the wire item. `cause` nests the next link of the
 * `Error#cause` chain; the server accepts at most 4 nested causes
 * (`Alplus.Observe.ErrorEnvelope`'s depth 5 counting the top level).
 */
export interface WireException {
  type: string;
  value?: string;
  stacktrace?: { frames: WireStackFrame[] };
  cause?: WireException;
}

export interface WireErrorItem {
  id: string;
  type: "exception" | "message";
  timestamp: string;
  level: ErrorLevel;
  release?: string;
  environment?: string;
  message?: string;
  exception?: WireException;
  contexts?: Record<string, unknown>;
  mechanism?: string;
  breadcrumbs?: WireBreadcrumb[];
  tags?: Record<string, string>;
  user?: WireUser;
  fingerprint?: string[];
}

/**
 * Truncates to at most `maxLength` UTF-16 code units, stripping a trailing
 * lone high surrogate left by the cut so a later UTF-8 re-encode doesn't
 * produce U+FFFD or get rejected by a strict encoder. Passes `undefined`
 * through unchanged.
 */
export function capText(value: string | undefined, maxLength: number): string | undefined {
  if (value === undefined) return undefined;
  const capped = value.slice(0, maxLength);
  const finalCodeUnit = capped.charCodeAt(capped.length - 1);
  return finalCodeUnit >= 0xd800 && finalCodeUnit <= 0xdbff ? capped.slice(0, -1) : capped;
}

/**
 * Caps a JSON-ish context object by its serialized size. A value whose
 * serialization exceeds `maxChars` is REPLACED by a small truncation
 * marker rather than cut mid-string, matching the server's own
 * `capJson` -- a partial JSON string is unparseable, which is worse than a
 * shorter one.
 */
export function capContext(value: Record<string, unknown>, maxChars: number): Record<string, unknown> {
  const serialized = JSON.stringify(value);
  if (serialized === undefined || serialized.length <= maxChars) return value;
  return { _truncated: true, _original_chars: serialized.length };
}

/** Drops trailing frames until the serialized array fits `maxChars`, mirroring the server's `capFramesToBudget`. */
export function capFrames(frames: readonly WireStackFrame[], maxChars: number): WireStackFrame[] {
  const kept = [...frames];
  while (kept.length > 0 && JSON.stringify(kept).length > maxChars) kept.pop();
  return kept;
}

/**
 * Caps a custom fingerprint override to the server's own bounds: at most
 * `maxEntries` entries, each at most `maxChars` characters -- mirrors
 * `sdks/ruby/lib/postdeploy/envelope.rb`'s `cap_fingerprint`. Returns
 * `undefined` for an empty/undefined input so the caller can omit the wire
 * key.
 */
export function capFingerprint(
  fingerprint: readonly string[] | undefined,
  maxEntries: number,
  maxChars: number,
): string[] | undefined {
  if (fingerprint === undefined || fingerprint.length === 0) return undefined;
  return fingerprint.slice(0, maxEntries).map((part) => capText(part, maxChars)!);
}
