/**
 * Client-side event id generation for Observe. The ingest wire protocol
 * treats `items[].id` as the idempotency key for `POST /e/errors` and
 * requires it to be generated client-side, `err_`-prefixed, before the
 * event ever leaves the process -- `captureException`/`captureMessage`
 * return it synchronously so a caller can correlate it (for example,
 * showing "reference id err_..." on a user-facing error page).
 *
 * This is a local UUIDv7 implementation, not an import of
 * `packages/core`'s id helpers: this package ships to third-party
 * production apps with zero runtime dependencies and cannot import
 * worker-internal code, so the handful of lines a UUIDv7 needs are
 * duplicated here rather than shared.
 */

const HEX_CHARS = "0123456789abcdef";

function randomBytes16(): Uint8Array {
  const bytes = new Uint8Array(16);
  const cryptoRef: Crypto | undefined = globalThis.crypto;
  if (cryptoRef && typeof cryptoRef.getRandomValues === "function") {
    cryptoRef.getRandomValues(bytes);
    return bytes;
  }
  // Fallback for environments without a global Web Crypto object (older
  // Node < 19 without --experimental-global-webcrypto). Not
  // cryptographically strong, but this id is a correlation/idempotency key,
  // never a security token, matching the same trade-off `heartbeat.ts`
  // already makes for its ping ids.
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Math.floor(Math.random() * 256);
  }
  return bytes;
}

function toHex(byte: number): string {
  return HEX_CHARS[(byte >> 4) & 0x0f]! + HEX_CHARS[byte & 0x0f]!;
}

/**
 * Builds a time-ordered UUIDv7 (RFC 9562): a 48-bit millisecond Unix
 * timestamp, a version nibble (0111), 74 bits of randomness, and the
 * variant bits (10). Time-ordering is the reason UUIDv7 was specified for
 * this id over a plain random UUIDv4 (docs section 4.1) -- event ids sort
 * chronologically, which is useful for the console's issue timeline even
 * before the server does anything with them.
 */
function uuidv7(): string {
  const bytes = randomBytes16();
  const ts = BigInt(Date.now());

  bytes[0] = Number((ts >> 40n) & 0xffn);
  bytes[1] = Number((ts >> 32n) & 0xffn);
  bytes[2] = Number((ts >> 24n) & 0xffn);
  bytes[3] = Number((ts >> 16n) & 0xffn);
  bytes[4] = Number((ts >> 8n) & 0xffn);
  bytes[5] = Number(ts & 0xffn);
  bytes[6] = 0x70 | (bytes[6]! & 0x0f); // version 7
  bytes[8] = 0x80 | (bytes[8]! & 0x3f); // variant 10

  const hex = Array.from(bytes, toHex).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Generates the `err_`-prefixed, client-generated UUIDv7 every Observe event carries. */
export function generateEventId(): string {
  return `err_${uuidv7()}`;
}
