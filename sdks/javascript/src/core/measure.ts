/**
 * Measure's programmatic hit API: `POST /m`. This is a wire shape mirrored
 * BY HAND from `packages/schemas/src/measure.ts` for the same reason
 * `observe/envelope.ts` mirrors its own: this package ships to npm with
 * zero runtime dependencies and cannot import an unpublished workspace
 * package.
 *
 * This function exists for programmatic/server-side use -- somewhere a
 * `<script>` tag is not an option (an SSR data layer, a Cloudflare Worker,
 * a batch job re-emitting historical events). It intentionally does NOT
 * duplicate the first-party browser tracker script: a real website should
 * load that script instead, since it is smaller, requires no build step,
 * and (critically, see below) runs in a real browser where the request
 * carries a Origin header no script can forge.
 *
 * ## Read this before using it from Node or a Workers cron/queue handler
 *
 * `POST /m` has no API key or bearer auth: the only gate is the request's
 * `Origin` header, checked against a per-project allowlist of registered
 * domains. A real browser attaches that header itself on every POST,
 * same-origin included, and JavaScript running in a browser cannot override
 * it -- which is exactly what makes it trustworthy as a security control.
 *
 * `fetch` in Node.js and in a Cloudflare Worker has no such page context, so
 * a request built by this function in those environments carries no Origin
 * header at all. The server treats a missing Origin as an automatic reject.
 * That rejection is silent and indistinguishable from success: `POST /m`
 * always answers `204 No Content` with no body, whether the hit was
 * recorded, rejected for its Origin, or sent to an unknown project id, by
 * design (so the endpoint can never be used to enumerate valid project ids
 * or registered domains by an attacker probing it with `curl`). Calling
 * `sendMeasureHit` from a plain Node script or a Workers handler that isn't
 * relaying a real inbound browser request will therefore appear to
 * "succeed" -- the promise resolves, nothing throws -- while recording
 * nothing, forever, with no error to notice.
 *
 * This function deliberately does NOT accept an `origin`/header override to
 * paper over that. Fabricating an Origin value to get a server-side call
 * past the allowlist would defeat the one security control this endpoint
 * has; that is not a trade-off this SDK makes on a caller's behalf. If you
 * have a genuine reason to relay a hit from an edge Worker that already
 * terminated a real browser request, forward the request's own `Origin`
 * header value through your own `fetch` call instead of through this
 * helper.
 */

const DEFAULT_BASE_URL = "https://ingest.postdeploy.dev";
const REQUEST_TIMEOUT_MS = 5_000;

export interface MeasureHitOptions {
  /** The project id (`proj_...`), Measure's "site id". Public, not secret -- the same value a `m.js` snippet would carry. */
  site: string;
  /** Full current-page URL. The server extracts path/hostname/UTM from it; the raw string is never stored. */
  url: string;
  /** Document referrer, or an explicit override. Omit or pass `null` for a direct hit. */
  referrer?: string | null;
  /** `"pageview"` (default) or `"custom_event"`. */
  type?: "pageview" | "custom_event";
  /** Required when `type` is `"custom_event"`. */
  name?: string;
  /** Accepted for forward compatibility; the server DISCARDS this before rollup and never stores or queries it. Sending it is never an error, just a no-op. */
  props?: Record<string, unknown>;
  /** Override the ingest origin. Defaults to `https://ingest.postdeploy.dev`. Mainly for testing against a local/self-hosted ingest endpoint. */
  baseUrl?: string;
  /** Injectable `fetch` implementation, primarily for tests. Defaults to the platform global `fetch`. */
  fetchImpl?: typeof fetch;
  /** Enables `console.warn` diagnostics. Default `false`. */
  debug?: boolean;
}

function timeoutSignal(): AbortSignal | undefined {
  if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
    return AbortSignal.timeout(REQUEST_TIMEOUT_MS);
  }
  return undefined;
}

function buildBody(options: MeasureHitOptions): string {
  return JSON.stringify({
    site: options.site,
    url: options.url,
    referrer: options.referrer ?? null,
    type: options.type ?? "pageview",
    ...(options.name !== undefined ? { name: options.name } : {}),
    ...(options.props !== undefined ? { props: options.props } : {}),
  });
}

/**
 * Sends one Measure hit. Fire-and-forget, matching the wire protocol's own
 * semantics: there is no retry (unlike Observe, a hit carries no
 * client-generated idempotency id for the server to dedupe a retry
 * against, so retrying risks double-counting a visit rather than
 * recovering a lost one) and the resolved promise carries no information
 * about whether the hit was actually recorded -- see this module's
 * top-of-file comment for why that can never be observed from here. Never
 * throws.
 */
export async function sendMeasureHit(options: MeasureHitOptions): Promise<void> {
  try {
    const fetchImpl = options.fetchImpl ?? globalThis.fetch;
    if (typeof fetchImpl !== "function") {
      if (options.debug === true) console.warn("[@postdeploy/sdk] measure: no fetch implementation available");
      return;
    }
    if (options.type === "custom_event" && (options.name === undefined || options.name.length === 0)) {
      if (options.debug === true) console.warn('[@postdeploy/sdk] measure: type "custom_event" requires a non-empty name; hit not sent');
      return;
    }

    const baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    await fetchImpl(`${baseUrl}/m`, {
      method: "POST",
      headers: { "Content-Type": "text/plain;charset=UTF-8" },
      body: buildBody(options),
      mode: "no-cors",
      credentials: "omit",
      signal: timeoutSignal(),
    });
  } catch (err) {
    if (options.debug === true) console.warn("[@postdeploy/sdk] measure: hit failed", err);
  }
}
