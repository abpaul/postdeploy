/**
 * Breadcrumb ring buffer (docs/sdk/02-dx-improvements.md section 3):
 * platform-neutral, pure data structure with no ambient storage of its own
 * -- each adapter owns WHERE its buffer lives (a module-global singleton in
 * the browser, an AsyncLocalStorage-scoped store in Node), never this file.
 * That split is what keeps this module usable from every platform without
 * itself becoming "the naive module-global scope" the DX spec's section 4
 * forbids on a server.
 *
 * Privacy (AGENTS.md, "no raw personal data without a bound"): every
 * breadcrumb pushed through here has its `data` scrubbed for
 * password/secret/token/api-key-shaped keys, matching the SDK spec's
 * section 9 denylist, and `stripQueryString` is exported so URL-bearing
 * breadcrumbs (fetch, navigation) can be redacted BEFORE they ever enter the
 * buffer, not just before transport.
 */
import { capText, MAX_BREADCRUMB_CATEGORY_CHARS, MAX_BREADCRUMB_MESSAGE_CHARS, type WireBreadcrumb } from "./envelope";

export type BreadcrumbLevel = "debug" | "info" | "warning" | "error";

export interface BreadcrumbInput {
  category?: string;
  message?: string;
  level?: BreadcrumbLevel;
  data?: Record<string, unknown>;
}

export interface RingBuffer {
  items: WireBreadcrumb[];
  max: number;
}

/** Same denylist as the SDK spec's section 9 header/context scrubbing, applied here to breadcrumb `data` too. */
const SENSITIVE_KEY_PATTERN = /pass(word)?|secret|token|api[_-]?key/i;

export function createRingBuffer(max: number): RingBuffer {
  return { items: [], max: Math.max(0, Math.trunc(max)) };
}

function scrubData(data: Record<string, unknown> | undefined): Record<string, unknown> | undefined {
  if (data === undefined) return undefined;
  const scrubbed: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    scrubbed[key] = SENSITIVE_KEY_PATTERN.test(key) ? "[Redacted]" : value;
  }
  return scrubbed;
}

/** Strips everything from `?` onward. Query strings routinely carry tokens, emails, or search terms -- never kept by default. */
export function stripQueryString(url: string): string {
  const qIndex = url.indexOf("?");
  return qIndex === -1 ? url : url.slice(0, qIndex);
}

/** Appends a breadcrumb, evicting the oldest once `buffer.max` is exceeded. A `max` of 0 (e.g. `maxBreadcrumbs: 0`) makes this a permanent no-op. */
export function pushBreadcrumb(buffer: RingBuffer, input: BreadcrumbInput): void {
  if (buffer.max === 0) return;
  const crumb: WireBreadcrumb = {
    ...(input.category !== undefined ? { category: capText(input.category, MAX_BREADCRUMB_CATEGORY_CHARS) } : {}),
    ...(input.message !== undefined ? { message: capText(input.message, MAX_BREADCRUMB_MESSAGE_CHARS) } : {}),
    ...(input.level !== undefined ? { level: input.level } : {}),
    ts: new Date().toISOString(),
    ...(input.data !== undefined ? { data: scrubData(input.data) } : {}),
  };
  buffer.items.push(crumb);
  if (buffer.items.length > buffer.max) buffer.items.shift();
}

/** Read-only copy of the current buffer contents, oldest first, or `undefined` when empty (so callers can `...` it into a wire item without an empty-array field). */
export function snapshotBreadcrumbs(buffer: RingBuffer): WireBreadcrumb[] | undefined {
  return buffer.items.length > 0 ? [...buffer.items] : undefined;
}

export function clearBreadcrumbs(buffer: RingBuffer): void {
  buffer.items = [];
}
