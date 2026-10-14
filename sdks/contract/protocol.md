# Current ingest wire protocol

Status: observed implementation, 2026-08-30. This document describes the
bytes and behavior currently accepted by the Phoenix server and emitted by the
three SDKs. It is not a proposal. Where implementation and documentation
disagree, the discrepancy is marked as a gap.

The product owns the contract and server parsers. The pinned contract is
manifest `2.0.0` with checksums for exception, message, measure, and session
fixtures (`sdks/contract/manifest.json`). The SDKs live beside it under
`sdks/` and read this directory directly; each one pins the version and every
checksum in its own code (`sdks/contract/README.md`).

## Protocol layers

1. **Wire protocol:** HTTP routes, JSON/raw bodies, headers, status codes, field
   names, limits, and server authentication below.
2. **SDK convenience:** facade APIs, scopes, breadcrumbs, automatic handlers,
   queues, batching, retry loops, and field trimming. These are not additional
   server protocol fields.
3. **Server domain behavior:** source lookup, quota/rate limiting, fingerprint
   and issue lifecycle, session rollups, Measure rollups, heartbeat state
   transitions, and object storage. A successful HTTP response is not proof
   that a domain row was stored.

## Shared envelope rules

Observe error and session requests use JSON:

```json
{"header":{"key":"<optional redundant bearer>","sdk":{"name":"...","version":"...","platform":"..."},"sent_at":"<optional>"},"items":[...]}
```

The server requires exactly the top-level `header` and `items` keys and 1–100
items. A header requires `sdk`; `key` and `sent_at` are optional, and no other
header keys are allowed. SDK metadata requires `name` and `version`; `platform`
is optional, and no other SDK keys are allowed. Values are bounded but
`sent_at` is not parsed as a timestamp
(`lib/alplus/observe/error_envelope.ex:40-64,215-219`,
`lib/alplus/observe/session_envelope.ex:42-68,99-103`). Unknown item keys
are not accepted; malformed items are dropped from an otherwise valid envelope
and counted in the response.

The shared body ceiling is 1 MiB for `/e/errors` and `/e/sessions`. The raw
body reader reads at most limit + 1 bytes with a five-second read timeout and
returns `413 body_too_large` or `400 parameter_invalid`
(`lib/alplus_web/plugs/ingest_raw_body.ex:1-12,22-63`; pipelines at
`lib/alplus_web/router.ex:162-190`).

SDK-side Observe caps are intended to keep payloads below that ceiling:

| Field | Current limit |
|---|---:|
| message / exception value | 4,096 characters |
| serialized context | 8,192 bytes |
| serialized tags | 4,096 bytes |
| serialized stack trace | 16,384 bytes |
| breadcrumb message/category | 2,048 / 128 characters |
| fingerprints | 1–16 entries, 256 characters each |
| breadcrumbs | SDK default 30, server ceiling 100 |
| exception cause depth | server top level plus four causes |

Sources: JS (`sdks/javascript/src/core/observe/envelope.ts:18-57,94-121`), Elixir
(`sdks/lib/post_deploy/envelope.ex:6-32`), Ruby
(`sdks/ruby/lib/postdeploy/envelope.rb:20-45`), and server validation
(`lib/alplus/observe/error_envelope.ex:4-18,121-157`).

## `POST /e/errors`

### Request

- Authentication is `Authorization: Bearer <observe-ingest-key>`. The key must
  resolve to an active Observe Source. If the envelope includes `header.key`,
  it must match the bearer after hashing; a missing envelope key is accepted
  (`lib/alplus_web/plugs/ingest_auth.ex:1-16,29-65`,
  `lib/alplus/observe/ingest.ex:17-26`).
- Expected content type is `application/json`. The route is a POST and the body
  is read as raw bytes before parsing (`lib/alplus_web/router.ex:168-178`).
- Each item requires `id`, `type`, `timestamp`, and `level`. `type` is
  `exception` or `message`; an exception requires an `exception` object and a
  message requires a non-empty `message`. Level is `fatal`, `error`, `warning`,
  or `info` (`lib/alplus/observe/error_envelope.ex:68-101`).
- Optional item keys are `release`, `environment`, `fingerprint`, `breadcrumbs`,
  `contexts`, `tags`, `user`, and `mechanism`. User accepts only `id` and
  `email`; tags require string keys and values. Stack frames accept file,
  function, line/column, in-app, and source-context keys
  (`lib/alplus/observe/error_envelope.ex:121-205`).
- `id` must be `err_` followed by a canonical hyphenated RFC UUIDv7. The
  parser enforces version `7` and RFC variant `8`, `9`, `a`, or `b`.
- `timestamp` is currently only a 1–64 byte string at the edge. The write path
  later parses ISO-8601 and uses it as `occurred_at`
  (`lib/alplus/observe/ingest.ex:153-170`).

### Response and domain behavior

- `202` JSON: `{accepted, dropped, event_ids, dropped_reason}`. `accepted`
  means the trimmed event row and any bounded overflow outbox were committed
  in PostgreSQL. Overflow upload and alert fan-out continue through independent
  Oban jobs after the response
  (`lib/alplus_web/controllers/error_ingest_controller.ex:12-37`,
  `lib/alplus/observe/event_writer.ex:45-89`).
- `400` with `{error:{type:"invalid_request_error",code:"validation_failed"}}`
  for malformed JSON/envelope, or `parameter_invalid` for redundant-key
  mismatch. Database/admission failure returns `503` with `Retry-After: 1`
  and `ingest_overloaded`; object-store failure does not change an accepted
  response.
- On accepted items, the server derives environment from the authenticated
  Source, deduplicates by `(org, project, source, event_id)`, fingerprints,
  upserts an issue, and inserts the trimmed event in one transaction. The
  transaction also records bounded overflow bytes when needed and enqueues
  storage and alert jobs keyed by persisted IDs
  (`lib/alplus/observe/event_writer.ex:45-89,104-120`).
- Items over the inline payload threshold retain their original JSON in the
  PostgreSQL overflow outbox until storage succeeds; the inline event keeps a
  storage key. A storage retry removes the outbox only after a successful
  object PUT. Alert retries are independent and do not roll back the accepted
  event (`lib/alplus/observe/payload_storage_worker.ex`,
  `lib/alplus/observe/alert_worker.ex`).

### SDK convenience

JS and Elixir queue off the host request path and default to 10 items, 64 KiB,
and five seconds (`sdks/javascript/src/core/observe/envelope.ts:49-57`,
`sdks/lib/post_deploy/config.ex:4-27,284-290`). Ruby uses bounded error
and session worker queues; each transport envelope is JSON and is sent on a
worker thread (`sdks/ruby/lib/postdeploy/worker.rb:16-25,47-69`,
`sdks/ruby/lib/postdeploy/transport.rb:25-55`). All three treat permanent 400,
401, 403, and 404 responses as non-retryable. JS and Elixir error transports
use three attempts, jittered 500 ms exponential backoff, 30-second Retry-After
cap, and bounded request timeouts (`sdks/javascript/src/core/observe/transport.ts:11-17,43-84`,
`sdks/lib/post_deploy/transport.ex:8-12,56-75`). Ruby has the same default
retry constants (`sdks/ruby/lib/postdeploy/retry.rb:14-21,40-83`).

## `POST /e/sessions`

### Request

- Authentication, redundant key matching, content type, and 1 MiB body limit
  match `/e/errors` (`lib/alplus_web/router.ex:180-190`,
  `lib/alplus_web/controllers/session_ingest_controller.ex:16-62`).
- Each item requires exactly `id` and `status`; `release` and `environment`
  are optional. Status is `healthy`, `errored`, or `crashed`; ID is a 4–64
  byte string. Current SDKs omit retired timing keys. The server temporarily
  accepts and discards `started_at` and `duration_ms` from released Elixir
  0.2.0 clients; these keys are not part of contract 2.0.0
  (`lib/alplus/observe/session_envelope.ex`).
- Elixir and Ruby SDKs emit `ses_` UUIDv7 IDs. JS intentionally has no session
  API (`sdks/contract/README.md`).

### Response and domain behavior

- `202` JSON: `{accepted, dropped, dropped_reason}`. Duplicate IDs are counted
  as dropped with reason `duplicate`; malformed items use `malformed`; mixed
  results use `mixed` (`lib/alplus_web/controllers/session_ingest_controller.ex:64-87`).
- `400` uses `validation_failed` for malformed envelopes and
  `parameter_invalid` for key mismatch. Database failure returns `503`,
  `Retry-After: 1`, and `ingest_overloaded` (`lib/alplus_web/controllers/session_ingest_controller.ex:38-46,110-114`).
- The server trusts environment from the authenticated Source, not the item
  (`lib/alplus_web/controllers/session_ingest_controller.ex:90-107`).
  It claims the session ID for 24-hour retry dedup and stores only aggregate
  session/errored/crashed rollups; no raw session row is stored
  (`lib/alplus/observe/session_rollup_writer.ex:8-14,48-114`).

### SDK convenience

Elixir batches sessions with the same limits as errors and bounds its session
queue at 1,000 (`sdks/lib/post_deploy/config.ex:11-25`). Ruby has a
separate bounded session worker (`sdks/ruby/lib/postdeploy/worker.rb:16-25`).
Retries are transport behavior, not a new session identity; the same `ses_` ID
must be reused for all attempts.

## `GET|POST /h/:token`

### Request

The token is the authentication boundary and is a path segment. Routes also
accept `/h/:token/:exit_code`; exit code 0 means finish and any other parsed
code means fail (`lib/alplus_web/router.ex:219-228`,
`lib/alplus_web/controllers/heartbeat_controller.ex:21-59`). The normal
query contract is `state=start|finish|fail`, omitted state means
finish. `ping_id` is optional for legacy callers. SDKs send a generated
idempotency ID, and JS may add `msg` (`sdks/javascript/src/core/heartbeat.ts:69-88`,
`sdks/lib/post_deploy.ex:268-296`, `sdks/ruby/lib/postdeploy/heartbeat.rb:45-88`).
There is no request body contract.

### Retry and idempotency

Each SDK makes at most two HTTP attempts. It retries transport failures,
`408`, `429`, and `5xx` responses only. Each attempt has a five-second timeout.
A delta-seconds `Retry-After` is capped at two seconds. Other retries use
jittered backoff around 500ms. The same `ping_id` stays on both attempts.
Heartbeat diagnostics never include the full token.

The server atomically claims `(monitor_id, ping_id)` for 24 hours in the same
transaction as the runtime transition. Concurrent or post-commit retries
therefore return the same successful `202` meaning without creating another
check, incident transition, or notification effect. Requests without
`ping_id` retain legacy behavior.

### Response and domain behavior

Recognized active or paused token: `202` with an empty body. Unknown token:
`404`. Persistence failure: `503` with `Retry-After: 1`
(`lib/alplus_web/controllers/heartbeat_controller.ex:25-59`).
Accepted state transitions update the monitor runtime state, check history,
incident state, cache, and status notifications
(`lib/alplus/monitoring/heartbeat.ex:58-90,143-182`).

### SDK convenience

All three SDKs make at most two attempts. They retry transport failures,
`408`, `429`, and `5xx` responses only, with a five-second attempt timeout,
two-second `Retry-After` cap, and jittered backoff around 500ms. They preserve
one `ping_id` across retries and redact heartbeat tokens from diagnostics.

## `POST /m` and `GET /m.js`

### Request

`POST /m` accepts a JSON or text body with allowed keys `site`, `url`, `referrer`,
`type`, `name`, `props`, and `device`. `site` and `url` are required; site is
1–64 bytes and URL is 1–2,048 bytes. Type defaults to `pageview`; `custom_event`
and legacy `event` require a 1–64 byte lower-case name matching
`^[a-z0-9_-]+$` (`lib/alplus_web/controllers/measure_controller.ex:11-68`).

Authentication is the site token plus the HTTP `Origin`. The source resolves
from `site`; the origin hostname must match the URL hostname and the project's
allowlist (`lib/alplus/measure/ingest.ex:24-56`). Missing/unknown tokens
are silently answered with 204 before normal write processing
(`lib/alplus_web/plugs/ingest_measure_source.ex:53-89`).

### Response and domain behavior

- `204` is returned for accepted and rejected hits, including unknown project
  or disallowed Origin. This prevents project/domain enumeration. `400` means
  malformed or invalid input; `429` means rate limited; database failures are
  `503` with `Retry-After: 1` (`lib/alplus_web/controllers/measure_controller.ex:38-49`,
  `lib/alplus_web/plugs/ingest_rate_limit.ex:49-80`).
- `props` is accepted for forward compatibility but discarded. Custom event
  names must already exist in `custom_event_definitions`; the normalized type
  is stored as `event` (`lib/alplus/measure/hit.ex:20-52`,
  `lib/alplus/measure/ingest.ex:58-68,95-103`).
- Raw referrer, IP, and user agent are not persisted. `m.js` sends the page
  origin plus pathname and a referrer hostname or `direct`; the server keeps
  only closed-set aggregate dimensions.
- Daily visitor uniqueness uses a day-scoped HMAC row. The daily salt and seen
  rows retain today and yesterday only. Visits, landing pages, bounce state,
  and duration use a separate 30-minute in-memory inactivity window.
- `GET /m.js` installs one singleton on `window.postdeployMeasure`.
  `window.alplusMeasure` remains a temporary alias for existing snippets. If
  one global already holds the tracker and the other holds a queue, the script
  reuses the tracker and drains that queue once. It wraps `pushState` and
  `replaceState` once, and owns one `popstate`, `hashchange`, and `pageshow`
  listener set. A logical URL sends once. Each persisted `pageshow` sends once
  even when the URL is unchanged.
- Delivery tries `sendBeacon` first. A synchronous beacon rejection starts one
  `fetch` fallback with `mode: "no-cors"` and a handled rejection. There are no
  timers, observers, DOM scans, retries, or response-status claims.

### Browser SDK

The browser `sendMeasureHit` helper uses
`Content-Type: text/plain;charset=UTF-8`, `mode: "no-cors"`, no credentials,
and no custom headers. The request remains CORS-simple. Phoenix deliberately
has no `OPTIONS` route and sends no `Access-Control-Allow-Origin`; callers
cannot override the HTTP Origin.

## `POST /e/artifacts`

This is a deploy/source-map endpoint, not an SDK capture endpoint. No JS,
Elixir, or Ruby SDK convenience API uploads artifacts.

### Request

- Authentication is the same Observe bearer key and Source lookup as errors.
- Query parameters `release` and `name` are required. After trimming, release
  is 1–200 bytes; name is 1–512 bytes, must end in `.map`, and must not contain
  `/`, `\\`, or `..` (`lib/alplus_web/controllers/artifact_upload_controller.ex:32-66`).
- The expected content type is `application/octet-stream`; the raw body is one
  source-map object, with no base64 or multipart encoding
  (`lib/alplus_web/controllers/artifact_upload_controller.ex:1-19`).
- Body limit is 20 MiB (`lib/alplus_web/router.ex:192-205`). The current
  shallow validation fully decodes JSON and requires `version: 3`, string
  `mappings`, and list `sources` (`lib/alplus_web/controllers/artifact_upload_controller.ex:68-80`).

### Response and domain behavior

- `201` JSON `{id,name,sha256}` after storing raw bytes and upserting the
  `(release, name)` artifact. Re-upload replaces the metadata/object
  (`lib/alplus_web/controllers/artifact_upload_controller.ex:35-49,82-95,127-153`).
- Invalid query parameters return `400 parameter_invalid`; invalid source-map
  shape returns `400 validation_failed`; storage failure returns `503
  artifact_store_unavailable` with `Retry-After: 1`
  (`lib/alplus_web/controllers/artifact_upload_controller.ex:43-50,158-170`).
- The database constrains artifact type to `source_map` or `debug_file`, SHA-256
  to 64 lowercase hex characters, and stored object keys to 1–1,024 bytes
  (`priv/repo/migrations/20260811133500_add_observe_releases.exs:33-59`).
  This endpoint currently creates `source_map` rows only.
- Raw source maps remain in the configured payload store. The inactive-
  organization purge and daily Observe cleanup delete database references
  before their queued object jobs run. Each object job rechecks for a live
  reference before deletion (`lib/alplus/observe/retention.ex`,
  `lib/alplus/billing/data_purge_object_worker.ex`).
- The deployed bucket applies a 120-day lifecycle rule as a safety ceiling for
  events and artifacts (`elixir/deploy/tofu/s3.tf:27-40`). The application
  cleanup job enforces plan windows: events retain 7 / 30 / 90 days, and
  artifacts retain 37 / 60 / 120 days.

## Authentication, limits, and common errors

All `/e/*` routes authenticate before body buffering and rate limit after source
resolution. Errors, sessions, and artifacts have separate rate-limit buckets;
429 includes `Retry-After`, and inactive plans return 402
(`lib/alplus_web/plugs/ingest_rate_limit.ex:1-25,31-80`). Global and
tenant admission can also reject overloaded traffic before or after body read
(`lib/alplus_web/router.ex:149-205`).

The documented error object is `{error:{type,code}}`. Current codes include
`invalid_api_key`, `validation_failed`, `parameter_invalid`,
`rate_limit_exceeded`, `plan_inactive`, `ingest_overloaded`, and
`artifact_store_unavailable`, with endpoint-specific status codes cited above.
Clients must treat unknown 5xx/429 as retryable only when their idempotency key
is stable; 400/401/403/404 are permanent for Observe transports.

## Compatibility and versioning rules

- The manifest version and every fixture checksum are the compatibility gate.
  Contract changes are additive only unless a new manifest version and SDK/server
  migration are agreed (`sdks/contract/README.md:39-47`,
  `elixir/docs/ARCHITECTURE.md:138-144`).
- SDK envelope `sdk.name`, `sdk.version`, and `platform` are metadata, not
  authentication. The server trusts the bearer Source and derives environment
  from it.
- Clients treat timestamps as opaque strings. Error IDs are enforced as
  `err_` UUIDv7; session SDKs emit `ses_` UUIDv7 IDs.
- A literal byte-identical envelope is not the current runtime guarantee:
  timestamp formatting and SDK identity differ by language. The tested guarantee
  is fixture/schema compatibility after nondeterministic fields are normalized.
- `/e/errors` and `/e/sessions` have a 100-item envelope ceiling, while SDK
  batching is a client policy. `/m` and `/e/artifacts` are one logical request
  per HTTP call and have no server-side retry idempotency key.

## Pass 1 resolved contracts

| Area | Current contract |
|---|---|
| Heartbeat idempotency | An optional `ping_id` is claimed per monitor for 24 hours. Concurrent and post-commit retries return 202 without repeating effects. |
| Browser Measure | The helper sends `text/plain;charset=UTF-8` with `mode: "no-cors"`, no credentials, no custom headers, and no Origin override. The server has no OPTIONS route. |
| Error IDs | The parser accepts only `err_` plus canonical UUIDv7. There is no opaque-ID compatibility path. |
| Sessions | Contract 2.0.0 items contain required `id` and `status`, plus optional `release` and `environment`. Current SDKs emit no timing fields; the server accepts and discards them only for the published Elixir 0.2.0 transition. |
| Sensitive-field scrubbing | Every SDK recursively applies the mandatory default key list immediately before serialization. Caller hooks cannot bypass it. |
| Contract fixtures | Every SDK reads `sdks/contract` from this repository, pins manifest `2.0.0` in its own code, and verifies every checksum. |
| Retention | Application jobs enforce plan-aware event and artifact windows. Object-store lifecycle is a 120-day safety ceiling. |

## Minimal executable requests

Use an active Observe ingest key and a source/project that exists in the
target environment. These examples show the current wire shape; response
status and body are the authoritative behavior described above.

```sh
# Observe error: 202 with accepted/dropped/event_ids.
curl -i -X POST "$BASE/e/errors" \
  -H "Authorization: Bearer $INGEST_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @- <<JSON
{"header":{"key":"$INGEST_KEY","sdk":{"name":"probe","version":"1","platform":"test"},"sent_at":"2024-01-01T00:00:00Z"},"items":[{"id":"err_00000000-0000-7000-8000-000000000001","type":"message","timestamp":"2024-01-01T00:00:00Z","level":"error","message":"probe"}]}
JSON

# Session: 202 with aggregate accepted/dropped counts.
curl -i -X POST "$BASE/e/sessions" \
  -H "Authorization: Bearer $INGEST_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @- <<JSON
{"header":{"sdk":{"name":"probe","version":"1","platform":"test"}},"items":[{"id":"ses_00000000-0000-7000-8000-000000000001","status":"healthy"}]}
JSON

# Heartbeat: 202 for a known token; an optional ping_id deduplicates for 24 hours.
curl -i -X POST "$BASE/h/$HEARTBEAT_TOKEN?state=finish&ping_id=probe-1"

# Measure: 204 for accepted or rejected; Origin must be allowlisted and match URL host.
curl -i -X POST "$BASE/m" \
  -H 'Origin: https://app.example.test' \
  -H 'Content-Type: text/plain' \
  --data '{"site":"proj_example","url":"https://app.example.test/","type":"pageview","referrer":null}'

# Source map: 201 with id/name/sha256.
curl -i -X POST "$BASE/e/artifacts?release=1.0.0&name=app.js.map" \
  -H "Authorization: Bearer $INGEST_KEY" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @app.js.map
```

## Compatibility checks

The following checks exercise the pinned fixtures and real endpoint parsers:

```sh
# From the repository root. No environment setup: each suite reads
# sdks/contract from this checkout.
(cd sdks/javascript && npm ci && npm test)
(cd sdks/elixir && mix deps.get && mix test)
(cd sdks/ruby && bundle install && bundle exec rspec)

mix test test/alplus/observe/golden_envelope_test.exs \
  test/alplus_web/e2e/sdk_ingest_e2e_test.exs
```

The fixture suites must verify the manifest version and every checksum against
the digests each SDK pins in its own code. The real server tests should cover
the documented statuses, 1 MiB/20 MiB caps, redundant-key mismatch, source
environment trust, error/session dedup, Measure Origin rejection, and artifact
replacement.
