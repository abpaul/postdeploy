# frozen_string_literal: true

require "securerandom"

module PostDeploy
  # Client-side event id generation for Observe. `POST /e/errors` treats
  # `items[].id` as the idempotency key and requires it to be generated
  # client-side, `err_`-prefixed, before the event leaves the process.
  #
  # This mirrors packages/sdk/src/core/id.ts (TypeScript SDK) byte-for-byte
  # in shape: a time-ordered UUIDv7 (RFC 9562) — 48-bit millisecond Unix
  # timestamp, version nibble (0111), 74 bits of randomness, variant bits (10).
  module Id
    module_function

    def uuidv7
      bytes = SecureRandom.random_bytes(16).bytes
      ts = (Time.now.to_f * 1000).to_i

      bytes[0] = (ts >> 40) & 0xff
      bytes[1] = (ts >> 32) & 0xff
      bytes[2] = (ts >> 24) & 0xff
      bytes[3] = (ts >> 16) & 0xff
      bytes[4] = (ts >> 8) & 0xff
      bytes[5] = ts & 0xff
      bytes[6] = 0x70 | (bytes[6] & 0x0f) # version 7
      bytes[8] = 0x80 | (bytes[8] & 0x3f) # variant 10

      hex = bytes.map { |b| format("%02x", b) }.join
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    # Generates the `err_`-prefixed, client-generated UUIDv7 every Observe
    # event carries — the same prefix/shape the JS and Elixir SDKs emit.
    def generate_event_id
      "err_#{uuidv7}"
    end

    # Generates a `ses_`-prefixed UUIDv7 session id for the
    # `POST /e/sessions` wire protocol (issue #12). Opaque and used only
    # for in-window ingest dedup — never persisted past that, never a PII
    # carrier.
    def generate_session_id
      "ses_#{uuidv7}"
    end
  end
end
