# Golden envelope contract (issue #18)

`protocol.md` is the authoritative wire document.
`exception_item.json`, `message_item.json`, `session_item.json`, and
`measure_event.json` are authoritative, server-validated wire items. Every SDK
must reproduce the items for the features it supports. Three things anchor them:

1. **Independent digest anchor**: `SHA256SUMS` records the contract file
   digests, and each SDK pins the expected fixture digests in its own code.
   Updating this directory alone cannot make a consumer accept drift.
2. **Server anchor**: `test/alplus/observe/golden_envelope_test.exs`
   feeds each fixture through the real
   `Alplus.Observe.ErrorEnvelope.parse/1` / `Alplus.Observe.SessionEnvelope.parse/1`
   parsers, including `Alplus.Measure.Hit.normalize/1`. "Matches golden"
   therefore means "the server accepts it."
3. **Per-SDK match**: each SDK builds an item from the canonical input below
   and asserts it equals the golden JSON, after normalizing non-deterministic
   fields.

## Versioning and consumption

The product owns this directory. `manifest.json` assigns the fixture set a
semantic version and records a SHA-256 for each item. The current version is
`2.0.0`.

The SDKs live in this repository under `sdks/`, and their contract tests read
these files directly:

- The default is this directory, resolved relative to the test file.
  `POSTDEPLOY_CONTRACT_DIR` overrides it to run an SDK against another
  checkout of the fixtures.
- Each SDK pins one contract version and the expected fixture digests in its
  own code. It loads `manifest.json`, asserts the version and each advertised
  digest, verifies the fixture bytes, and verifies `SHA256SUMS`. Editing this
  directory alone therefore cannot make an SDK accept drift: the pinned
  digests in three languages have to be updated in the same change.

`SHA256SUMS` covers this directory's documents as well as the fixtures.
Regenerate it after editing anything here:

```sh
cd sdks/contract
shasum -a 256 README.md protocol.md manifest.json \
  exception_item.json message_item.json measure_event.json session_item.json \
  > SHA256SUMS
```

Change the fixture set only through a compatibility change: bump the manifest
version and update the checksums in the same pull request as the three SDK
pins. Every such change runs the product suite (which contains the server
anchor) and all three SDK suites, because each SDK's CI workflow is filtered
on `sdks/contract/**` as well as its own directory.

## Non-deterministic fields

`id`, `sent_at`, and `timestamp` are client-generated (clock/random) and
cannot be pinned identically across three languages without an injectable
clock every SDK would need to add. The golden files carry fixed placeholder
values for readability; every comparison (server anchor and each SDK)
**deletes these keys from both sides** before comparing, rather than trying
to match the literal placeholder. Treat the placeholder values as
documentation, not as something a test must reproduce byte-for-byte.

## Canonical input

### Exception item

- Exception type: `ContractTestError`, value:
  `canonical contract test exception`.
- Stack frames supplied as two literal, already-built wire frames (see
  below for why), not captured from a real raised exception:
  1. `{file: "app/worker.ex", function: "MyApp.Worker.perform/1", lineno: 42, colno: 5, in_app: true}`
  2. `{file: "lib/some_lib.ex", function: "SomeLib.call/2", lineno: 10, in_app: false}` (no `colno` — exercises the optional-field-absent case)
- `level`: `"error"`, `release`: `"1.0.0"`, `environment`: `"test"`, `mechanism`: `"generic"`.
- `fingerprint`: `["checkout", "timeout"]`.
- `breadcrumbs`: two entries, each with `category`/`message`/`level`/`ts`.
- `contexts`: `{"extra": {"cart_id": "cart_123", "items": 3}}`.
- `tags`: `{"team": "observability", "flow": "checkout"}`.
- `user`: `{"id": "user_42", "email": "person@example.com"}`.

**Why literal frames, not a real raised exception**: each language's native
stack-trace representation (Elixir's `Exception.stacktrace`, Ruby's
`Exception#backtrace`/`#backtrace_locations`, V8's `Error.stack`) has a
different shape, and the file paths/function names a real raise produces are
tied to that SDK's own test file location — they can never be byte-identical
across three languages. Exercising `in_app` on one frame and
leaving it absent on the other, and exercising `colno` present/absent, is
what issue #18 asks the fixture to cover; supplying the frames directly (as
each SDK's low-level item-builder helpers already accept, independent of
where a real stack trace came from) is how three languages can converge on
one golden byte shape. Per-SDK contract tests document exactly which
building block they call for this reason (see each spec/test file's module
doc).

### Message item

- `message`: `"canonical contract test message"`, `level`: `"warning"`.
- Same `release`/`environment`/`user`/`tags` shape as the exception item
  (different values), one breadcrumb, one `contexts.extra` entry.
- No `fingerprint` — exercises the field being entirely absent from an item.

### Session item

- `status`: `"crashed"` (one of the three enum values `healthy`/`errored`/`crashed`).
- `release`: `"1.0.0"`, `environment`: `"test"`.

### Measure event

- Site token: `msr_contract_site`. SDK contract tests replace this readable
  placeholder with their configured test token before transport.
- URL: `https://app.example.test/pricing`.
- Referrer: `null` for a direct visit.
- Type: `custom_event`; registered name: `signup`.
- `props` contains representative values. The server accepts and discards the
  full object before persistence.

## Known gap: JS has no session support

`@postdeploy/sdk` (`sdks/javascript`) does not implement `POST /e/sessions` (no
session builder anywhere under its `src`). Its contract test therefore covers only
the exception and message items; the session golden is matched by the
Elixir and Ruby SDKs plus the product's server anchor. Adding session
support to the JS SDK is a product decision (new public surface), out of
scope for this contract-test issue — flagged here rather than silently
skipped.
