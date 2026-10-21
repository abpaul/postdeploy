# PostDeploy

PostDeploy tracks errors and structured logs.
The sections below describe local runs and application behavior.

Use Rust 1.99 and the locked dependencies. Run these commands from `PostDeploy/rust-web`.
Keep test databases and build output in separate directories.

## Local development

Start the app from `rust-web` after creating your development credentials:

```sh
./scripts/dev.sh
```

Open `http://127.0.0.1:5167` and create a local account. Stop with `Ctrl+C`.
The first run compiles the app. Later runs reuse `target/`. Local accounts and
projects persist in `data/development/`; object storage uses `local-verification/dev/`.
No Docker services are required.

Before the first run, install the Credseal CLI and create your own development credentials.
The snapshot does not ship credential files. Run:

```sh
credseal edit --app postdeploy --environment development --directory config/credentials
credseal validate --app postdeploy --environment development --directory config/credentials
```

Enter the `[r2]` and `[security]` fields shown under **Prepare isolated test credentials** below, using your own R2 credentials and a Base64-encoded 32-byte data key.
Use a dedicated test bucket. Keep the generated `development.key` private and
back it up separately. If the encrypted file already exists, restore its matching
key instead of generating another key.

The script reads `config/credentials/development.toml.enc` and
`config/credentials/development.key`. Set `POSTDEPLOY_CREDENTIALS_FILE` and
`CREDSEAL_KEY_FILE` to use existing files elsewhere. Set `POSTDEPLOY_STORAGE_PREFIX`
to a separate `local-verification/<name>/` prefix when sharing the test bucket.
Development and test credentials use separate environments.
The isolated verification commands below continue to use the test environment.

Check the launcher without credentials or a Rust build:

```sh
python3 -B scripts/test_dev.py
```

## Build and check the application

```sh
python3 scripts/local.py build --state ../../.audit/postdeploy-rust/local-state --target ../../.audit/postdeploy-rust/target
python3 scripts/local.py fmt --state ../../.audit/postdeploy-rust/local-state --target ../../.audit/postdeploy-rust/target
python3 scripts/local.py clippy --state ../../.audit/postdeploy-rust/local-state --target ../../.audit/postdeploy-rust/target
```

## Prepare isolated test credentials

Use your own dedicated R2 test bucket and a new `local-verification/` prefix for each run.
The ignored R2 tests write only to the bucket name they assert, such as `TEST_BUCKET` in `tests/backup_r2.rs`. Change those names to your bucket before you run them.
Keep the unlocking key outside this application directory with mode `0600`.
The application reads secrets only through Credseal with application `postdeploy` and environment `test`.

For a new test environment, use the installed Credseal CLI.
Do not replace an existing credential file or key.

```sh
credseal edit --app postdeploy --environment test --directory /absolute/private/postdeploy-test
credseal validate --app postdeploy --environment test --directory /absolute/private/postdeploy-test
```

Enter the following fields in the editor. Supply real values instead of the placeholders.

```toml
[r2]
endpoint = "https://<account-id>.r2.cloudflarestorage.com"
bucket = "<dedicated-test-bucket>"
access_key_id = "<test-access-key>"
secret_access_key = "<test-secret-key>"

[security]
data_key = "<Base64-encoded-32-byte-data-key>"
```

Add `[smtp]` only when you have approved SMTP test credentials.
Use the fields in [`SmtpConfig`](src/notifications.rs).
SMTP also delivers the 70%, 90% and 100% monthly usage alerts to organization owners.
SMTP sends each organization owner one email three days before the trial ends, and one email when the trial ends with no paid period. Each email is sent once. A trial that ended more than three days ago gets no email.

Add `[stripe]` to enable checkout, the billing portal and the Stripe webhook.
Without it, billing actions return `billing_unconfigured` and trials still work.
Production requires a live-mode key.

```toml
[stripe]
secret_key = "<sk_ or rk_ key>"
webhook_secret = "<whsec_ endpoint signing secret>"
price_id = "<price_ ID of the USD 449 yearly price>"
```

Checkout refuses a price that is not USD 449, yearly, interval count 1.

A settled annual-plan invoice grants its full service year. Discounts, including
100% discounts, and customer credit can settle an invoice without a cash payment.
Refunds and post-payment credits do not shorten that service year. Automatic
refund revocation is unsupported. Cancellation prevents renewal and preserves
settled paid time. After a paid period ends, ingestion continues for 3 days
(`RENEWAL_GRACE_SECS`) so that a renewal invoice can settle. Organization deletion requires Stripe to confirm that its
subscription is canceled, incomplete-expired, or set to cancel at period end.
An open or unresolved checkout blocks deletion.

Envelope admission reserves quota for all supported categories before storing
errors or logs. If quota admission refuses an envelope, neither category is
stored. Operational failures can still leave part of an envelope durable, including
storage failures, database failures, or pipeline overload. Retrying errors uses
their event IDs; log retries have no deduplication guarantee.

Point the Stripe webhook endpoint at `/webhooks/stripe`.
Subscribe it to `checkout.session.completed`, `checkout.session.async_payment_succeeded`,
`customer.subscription.*`, `invoice.paid`, `invoice.payment_succeeded`,
`invoice.payment_failed`, `invoice.voided`, `invoice.marked_uncollectible` and `invoice.updated`.
Preserve `security.data_key` with the backups. A new data key cannot decrypt existing backups.

## Start the application

Replace the absolute credential paths and the run prefix.
The local command passes only the key-file path in the environment.

```sh
python3 scripts/local.py serve \
  --state ../../.audit/postdeploy-rust/local-state \
  --target ../../.audit/postdeploy-rust/target \
  --credentials /absolute/private/postdeploy-test/test.toml.enc \
  --key-file /absolute/private/postdeploy-test/test.key \
  --storage-prefix local-verification/manual-20261016/
```

Open `http://127.0.0.1:5167`. Check `GET /healthz` before you send requests.
Stop the process with `Ctrl+C` and allow it to finish its shutdown.
Only one process can own a tenant root or a control database.

## Run the application checks

The default suite needs no credentials. Each test uses an in-memory object store and keeps its databases under `POSTDEPLOY_TEST_ROOT`.

```sh
CARGO_TARGET_DIR=../../.audit/postdeploy-rust/target \
POSTDEPLOY_TEST_ROOT=../../.audit/postdeploy-rust/test-state/test-runs \
cargo test --locked
```

`scripts/local.py test` runs the same suite. It requires the private credential paths, a separate state directory and a new prefix.

```sh
python3 scripts/local.py test \
  --state ../../.audit/postdeploy-rust/test-state \
  --target ../../.audit/postdeploy-rust/target \
  --credentials /absolute/private/postdeploy-test/test.toml.enc \
  --key-file /absolute/private/postdeploy-test/test.key \
  --storage-prefix local-verification/tests-20261016/
```

Ignored tests use real R2, external fixtures or live third-party APIs. Run them in a separate, deliberate run. The R2 tests need the private credentials.
Keep failure logs and databases when you remove regenerable build output.

## Verified SDK versions

| Language | SDK | Verified version | Verified data |
|---|---|---|---|
| Node.js | `@sentry/node` | `11.6.0` | errors and structured logs |
| Rust | `sentry` | `0.49.3` | errors and structured logs |
| Python | `sentry-sdk` | `2.72.0` | errors |
| Ruby | `sentry-ruby` | `7.1.0` | errors |
| Elixir | `sentry` | `14.0.0` | errors |

Other SDK/version pairs are unverified. `tests/fixtures/sdk/` holds sanitized error events
captured from the Python, Ruby and Elixir versions above. `tests/fixtures/releases/` holds the
bundle, source maps and `@sentry/node` events that the release tests symbolicate.

The PostDeploy Elixir, Ruby and JavaScript SDKs post errors to `/e/errors` with
`Authorization: Bearer <key>`. Those errors are stored like Sentry events. Keys that start with
`obs_` also work in DSNs whose project path is `/1`. 32-character keys require the DSN's own project ID.
With the isolated loopback server running against actual R2, run:

```sh
npm ci --prefix scripts/verification
node scripts/verification/check-app.mjs http://127.0.0.1:5167 ../../.audit/postdeploy-rust/local-state
```

Use the same state directory as the running server and test Credseal credentials without a `[turnstile]` section for automated signup.
The probe checks SDK ingestion, issue context, search, replay, and the local state files.

## Ingestion retries

Error events and log items in one envelope are processed independently.
A retryable response can follow a successful commit of some items.
Retrying an envelope can therefore repeat logs. Log delivery is not exactly once.
Error-event retries use the source and event ID for deduplication.
A success response for valid log items waits for one FULL-synchronous SQLite commit of the encrypted entries and their usage.
Error-level logs remain logs; only error-event items create issues.

## Ingestion policy and receipts

Every project uses its organization's ingestion policy. `GET /api/orgs/{org}/ingestion-policy` returns it to members and to API keys with `projects:read`; `GET /api/orgs/{org}/usage` and the MCP `get_usage` tool include it as `ingestion.policy`. Owners and administrators change it with `PUT /api/orgs/{org}/ingestion-policy` (session and CSRF token) or on the dashboard page **Settings > Data controls**. `PUT` takes the whole document; unknown or missing fields return `400 invalid_ingestion_policy`:

```json
{"sensitive_fields": ["customer_ssn"], "log_levels": ["warn", "error", "fatal"],
 "excluded_exception_types": ["NotFoundError"], "error_sample_percent": 100, "log_sample_percent": 100}
```

- Built-in redaction always runs before any metadata, fingerprint, identifier, SQLite row or R2 object is derived. A name is sensitive when its letters and digits, ignoring case, contain `password`, `passwd`, `passphrase`, `pwd`, `secret`, `token`, `authorization`, `cookie`, `apikey`, `accesskey`, `privatekey`, `credential`, `session`, `csrf`, `sentrykey`, `authkey`, `authcode`, `authdata`, `authheader`, `authvalue`, `codeverifier` or `amzsignature` (so `api_key`, `privateKey`, `PRIVATE-KEY`, `code_verifier` and `X-Amz-Signature` all match, and so do `token_count` and `session_count`), when its last word is `pass` (`db.pass`), or when its last word ends with `auth` (`X-Auth`, `basicAuth`, `oauth`, `XAuth`; not `author`, `authority` or `auth_provider`). In a URL query, `key` is sensitive too (`?key=...`). One rule decides for JSON object keys, `[name, value]` and `[name, value, x]` pair lists, objects whose `name`, `key` or `property` field holds a sensitive name (the `value` field is filtered; field names ignore case), log attribute keys and names found in text; every name is percent-decoded once first. The value of a sensitive name becomes `[Filtered]`; `true`, `false` and `null` stay.
- Message templates are checked with their parameters. In `logentry` and an object `message` (`message` with `params`), and in the `sentry.message.template` log attribute with `sentry.message.parameter.<n>` or `sentry.message.parameter.<name>` attributes, a parameter becomes `[Filtered]` when the template puts it in a credential position (`password=%s`, `%s=%s` with `password`), when a `name`, `key` or `property` parameter names it, or when the template has no placeholder for it. Placeholders are printf (`%s`, `%5.2f`, `%(name)s`), Ruby `%{name}`, and `{}`, `{0}` and `{name}`.
- Free text is read in one pass by the grammar documented in `src/scrub/text.rs`. A pair is a name (a word, or a `"`, `'`, `` ` `` or `\"` quoted name of up to 64 bytes) followed by `=`, `:`, `=>` or `:=`. The value is a quoted string, a whole `[...]` or `{...}` group (a quoted name's value may start on the next line, as in pretty JSON), or one bare token. An unquoted name followed by `:` at the start of a line, and any `Authorization` or `Cookie` header name, loses the rest of the line. After `:` a plain number (`5432`, `42:13`, `0.93`) that ends at a space, the end of the text or one of ``, ; ) } ] " ' ` `` is kept as a port, position or count, unless the name contains `password`, `passwd`, `passphrase`, `pwd`, `secret`, `privatekey`, `apikey` or `credential` or is an extra policy name; after `=` it is filtered. After `=`, an `Authorization` or `Cookie` value that is a scheme word (`Bearer`, `Basic`, `Digest`) loses the credential after it too. Paths and source files (`/srv/app/auth.ts:42`, `session.yml`), and exception classes (`TokenExpiredError: ...`, `SessionNotFound: ...`) are not names. `<password>...</password>` elements (with or without attributes, as in `<wsse:Password Type="...">`), Bearer, Basic and `Token` authorization values (a `Token` value needs a digit) and Oracle `thin:user/password@` are filtered too. In URLs only the password (or a user name without a password, except for `ssh` and `git+ssh`) and sensitive query values are filtered; host, port, path and other parameters stay. A password may hold a raw `/`, `?`, `#` or quote when the text after `user:` is not a port; for database schemes (`postgres`, `mysql`, `redis`, `amqp`, `mongodb` and similar) digits there count as a password. A percent-encoded token is decoded once and checked with the same rules; the whole token becomes `[Filtered]` when it holds a credential. A value encoded twice is not decoded. Other secrets and personal data in free text are not detected. `tests/fixtures/privacy/` holds the leak, harmless, accepted over-filter and known residual corpora that the tests run.
- `sensitive_fields`: up to 32 extra names of 3 to 64 characters (`a-z`, `0-9`, `.`, `_`; `-` is read as `_`). They match the same way as the built-in names: their letters and digits must be a substring of the field name's letters and digits. A name that is part of a field ingestion needs, such as `event_id`, `type`, `value`, `message` or `trace_id`, is refused.
- `log_levels`: levels stored; other log entries are refused as `filtered`.
- `excluded_exception_types`: up to 32 names matched exactly against every exception type of an event.
- `error_sample_percent`: errors are kept by a hash of the event ID, so retries of one event get the same decision. `log_sample_percent`: each log entry gets an independent random draw; log retries are not deduplicated.
- A stored policy that fails validation stops ingestion for that organization with `503 ingestion_policy_invalid`; it never falls back to the defaults. The policy endpoint and `ingestion.policy` in the usage report return `{"error": "ingestion_policy_invalid"}` in place of the policy, and the Data controls page says so. Saving a valid policy replaces it. Refusals increment the `rejected_policy_invalid` process counter. Each organization's 1st, 2nd, 4th, 8th and later power-of-two refusals log a warning with the organization ID and its count, so a refusal flood stays visible without one line per request and does not hide another organization's first refusals.

The envelope response is `{"id": ..., "receipt": {"error": {...}, "log": {...}, "other": {...}}}`. `/e/errors` adds the same `receipt` to `accepted`, `dropped` and `event_ids`; `dropped` counts invalid errors only. Each category reports `accepted`, `duplicate`, `filtered`, `sampled`, `unsupported` and `invalid` counts and a `reasons` map with these codes:

| Code | Outcome | Meaning |
|---|---|---|
| `malformed`, `missing_event_id`, `too_large` | invalid | error item not stored |
| `invalid_entry`, `record_too_large` | invalid | log entry not stored |
| `exception_type_excluded`, `level_disabled` | filtered | refused by the policy |
| `sample_rate` | sampled | refused by sampling |
| `duplicate_event_id` | duplicate | error already stored for this source |
| `unsupported_item_type` | unsupported | envelope item type that is not ingested |
| `body_truncated` | accepted | log body cut to `logs.max_body_bytes`; redaction reads the body only up to 1 KiB past that length |
| `attribute_dropped` | accepted | log attribute removed: over `logs.max_attributes`, over `logs.max_attribute_bytes`, key over 128 bytes, or unsupported type |
| `timestamp_adjusted` | accepted | log timestamp more than 5 minutes ahead replaced by the receive time |

The reason counts of successful requests are added to the organization's daily counters and shown for the current month as `ingestion.outcomes` in the usage report. They are kept as long as daily usage. Filtered, sampled and refused items never count toward billed usage. Malformed envelope structure is refused with `400` before anything is stored. Issue titles and culprits show at most 1,024 bytes and release names 200 bytes; the stored event keeps the full values.

Each organization has one request budget for all of its keys: `ingest.rate_per_second` (default 50) with a burst of `ingest.rate_burst` (default 100). Over it, ingestion returns `429 rate_limited` with `Retry-After` and `X-Sentry-Rate-Limits: <seconds>::organization` and stores nothing. At most `ingest.rate_max_orgs` (default 65,536) organizations with a partly used budget are tracked; when all of them are still refilling, a new organization gets `503 ingest_overloaded` with `Retry-After: 1`. Body memory, payload size, error-lane concurrency and the daily and monthly quotas still apply.

## Webhook verification

Each delivery is a `POST` with `PostDeploy-Event-Id`, `PostDeploy-Timestamp` and `PostDeploy-Signature: t=<timestamp>,v1=<hex>`, where `v1` is HMAC-SHA256 with the signing secret over `<timestamp>.<raw body>`. Retries keep the event ID and send a new timestamp and signature; the body is rebuilt at each attempt with current issue facts and `created_at` set to the attempt time.
The receiver must:

1. Verify the signature over the raw body bytes, with a constant-time comparison, before parsing.
2. Refuse timestamps outside its tolerance (for example 300 seconds).
3. Take the event ID from the signed body `id`, and record it durably before acting. Answer `2xx` without acting again when the ID was already recorded.

The signature alone does not stop a replay inside the tolerance window; only step 3 does. Any `2xx` ends delivery. `408`, `429` and `5xx` are retried within the bounded attempts; other `4xx` and redirects stop delivery.

## Log storage

Accepted log entries are redacted, encrypted with `security.data_key` and committed to the organization database before the response.
Each organization has one open batch. A batch is sealed after 240 seconds, 5,000 entries, 1 MiB of accepted log bytes or a UTC day change.
The archiver checks every 5 seconds or less and writes each sealed batch once to R2 as `logs/v1/{org}/v2/{hour}/{batch}.ndjson.zst`, with conditional creation.
With R2 healthy, the oldest entry of a batch reaches R2 within 300 seconds. Unarchived entries are lost if the whole server disk is lost.
During an R2 outage, entries stay in SQLite and stay searchable. Ingestion returns `503 log_backlog_full` when an organization holds 64 MiB of encrypted unarchived entries (`logs.org_backlog_bytes`), all organizations hold `logs.backlog_bytes`, or `logs.max_pending_orgs` organizations have unarchived entries. The existing local disk guard returns `503 local_storage_pressure`.
Retention is 90 days from receive time for archived and unarchived entries.
`GET /api/orgs/{org}/logs/storage` reports open and sealed batches, unarchived bytes, the oldest unarchived age, the last archive and the current archive failure.

## Backups and restore

The server writes one encrypted backup set per hour, starting 300 seconds after boot (`settings.backup`).
A set holds a `VACUUM INTO` snapshot of the control database and of every active organization, then an authenticated manifest written last.
Keys: `backups/sets/{set}/control.pdbk`, `backups/sets/{set}/org/{org}.pdbk` and `backups/sets/{set}/manifest.pdbk` under the store prefix.
Ingestion and reads continue during a snapshot. No write fence is held across R2 uploads.
One worker runs at a time. A member that exceeds `deadline_secs` (180) fails the cycle; its seal finishes in the background, never starts an upload, and blocks the next cycle (`busy`) until it ends.
A snapshot above `max_snapshot_bytes` (512 MiB) or an encrypted object above `max_object_bytes` (256 MiB) fails the cycle. Nothing is truncated. The final-schema sizing fixture with a full 64 MiB log backlog measured 165.8 MiB raw and 92.4 MiB encrypted.
A failed attempt keeps its scratch directory, which holds an unencrypted snapshot, under `<data>/backup-scratch` for diagnosis. `max_scratch_dirs` (2) counts the running attempt, so only the newest failure is kept. The first attempt after two backup intervals deletes it. Organization deletion and the next start after an `abandoned` cycle delete it too. The failure detail stays in `backup_cycles`.
`GET /healthz` reports backup health in `backups`: `{"state": "ok" | "failing" | "stale", "last_complete_age_secs": <seconds> | null}`. `failing`: the newest finished cycle is `failed` or `changed`. `stale`: no complete set within 2 × `interval_secs` + `initial_delay_secs` + `deadline_secs` (7,680 seconds by default), counted from the last complete set or, before the first one, from process start. The status code stays 200, so alert on the field.
A set is current only when its manifest authenticates. A failed, interrupted or changed cycle writes no manifest, so the previous set stays current.
If organizations, projects or sources are created, deleted or moved during collection, the cycle retries with a new set, at most `revision_attempts` (3) times, and then records `changed`.
Each cycle is one row in the control table `backup_cycles` (`complete`, `failed`, `busy`, `changed`; a row left open by a stopped process becomes `abandoned` at the next start).
After a complete cycle, sets older than `retention_days` (14) are deleted, except the set just written. Retention lists and deletes only `backups/sets/`. Older `backups/control/` and `backups/org/` objects are not touched.
Deleting an organization removes its `backups/org/{org}/` objects. Its members in earlier sets expire with retention. Restore refuses a set that contains an organization deleted in the live control database.
SQLite temporary files must stay off the `/tmp` memory file system. Production refuses to start unless `SQLITE_TMPDIR` is `<data>/sqlite-tmp`; the image sets it and the server creates the directory.

`postdeploy task backup` writes one set while the server is stopped.

`postdeploy task restore set:<id> destination:<new directory>` writes `control.sqlite` and `tenants/<org>.db` into a new offline directory.
The task authenticates the manifest and every member, compares sizes and SHA-256 values, checks integrity, foreign keys and migrations, checks that the restored control's active organizations equal the manifest, that every `project_id` and `source_id` in each organization database belongs to that organization, and that every pending log entry opens with the data key.
Each organization file is marked restored before the directory appears. On rejection nothing appears at the destination and `<destination>.partial` stays for diagnosis.
The task prints one JSON line:

- `security_interval_from_us`: the control snapshot time. Credentials revoked after it (ingestion keys, API keys, sessions, OAuth grants) are valid again in the restored control. Review and revoke them again before activation.
- `billing_refresh_required`: refresh each organization from Stripe after activation (dashboard billing page, **Refresh**, or `POST /api/orgs/{org}/billing/refresh`). No startup path refreshes billing.
- `project_id_floor`, `source_id_floor`: the task migrates `control.sqlite` and raises its id floor above every project and source id in live control and in the organizations' R2 log objects that the restored files do not hold. The task also records the organizations in `control.sqlite`. At the first start with that control database, before it serves requests, the server repeats the scan against the active organization files and raises the floor again, so ids issued by a server restarted between the task and activation are covered too. Projects and sources created after activation never take an id that recovered log entries carry. Each scan downloads each such log object once. That start needs R2 and fails while a scan fails; the next start retries.
- `organizations[].unreferenced`: per payload kind, objects in R2 that the restored file does not reference, split into `after_snapshot` and `before_snapshot`. Keys created up to 120 seconds before the snapshot count as after it, because a payload is named before its commit. Error payloads newer than the snapshot cannot be re-indexed; they are kept and reported for an operator decision. Releases and reports likewise.

To activate, stop the server. If you also replace the control database, put the restored `control.sqlite` at the control path and run `control-migrate` before the start. Replace `<tenant root>/<org>.db` with the restored file, delete the old `-wal` and `-shm` files, and start the server.
The first use reconciles the organization's log objects in R2 before log ingestion and log reads for that organization. It recovers newer archived entries with their original identity and charges their usage once.
Each completed restore starts a new cursor epoch, including repeated activation of the same marked file. Cursors issued before the restore return `409 cursor_reset_required`. Search again without `before`, or start a tail without a cursor. Malformed cursors return `400 invalid_cursor`. Ordinary restarts preserve cursor tokens.
Stored report evidence remains valid. Report links use current cursors; the original report document keeps the cursor submitted by its author and its stored body stays unchanged.
Until it finishes, ingestion and log reads return `503 log_restore_pending`. A batch in R2 that does not match the restored entries stops it with `503 log_restore_conflict` and `restore_conflict` in the storage status. Nothing is overwritten or deleted; resolve the conflict manually.
Orphan payload cleanup stays held for a restored organization (`orphan_cleanup_held`). No code clears the hold. Each hourly orphan sweep counts unreferenced payloads created after `restore_state.snapshot_captured_at` minus 120 seconds, deletes nothing and logs a warning. Discarding protected payloads needs an explicit, approved operator decision. Error and log retention still delete expired data during the hold.
Never activate a database copy without this marker. The server cannot detect an unmarked older copy and could then reuse log cursors.

### Recovery after control database loss

Run the tasks below with the server stopped. `backup-sets` reads no control data. `restore` reads the empty control database for deletion tombstones and id floors.

1. Move the damaged control database and its `-wal` and `-shm` files aside. Keep them.
2. `postdeploy task control-migrate` creates an empty control database at the control path. The restore task needs its tables for the deletion check.
3. `postdeploy task backup-sets` prints one JSON line per set under `backups/sets/`, newest first: `set`, `created_at_us`, `objects`, `complete` (the manifest authenticates), `organizations`, `sealed_bytes` and `manifest_error`.
4. `postdeploy task backup-sets set:<id>` authenticates the manifest and every member, compares sizes and SHA-256 values and checks each snapshot's integrity in `<data>/backup-scratch`, then deletes the scratch copies. It prints a summary line or fails with the first error. It checks no ownership against control.
5. `postdeploy task restore set:<id> destination:<new directory>`, then activate the restored `control.sqlite` and every restored organization file as above.
6. The empty control has no deletion tombstones, so the set can contain organizations that were deleted after it. The only deletion record is the `organization_deletions` table in the damaged control database moved aside in step 1. Compare `billing_refresh_required` with it, or with your own records if it is unreadable, and delete such organizations again after activation. Users, memberships and keys created after the set are absent from the restored control.

## Agent access

Agents and CI authenticate with `Authorization: Bearer <token>`: an OAuth access token from `/oauth/token`, or an API key.
A signed-in member creates API keys in the dashboard (organization settings) or with `POST /api/orgs/{org}/api-keys`.
The body is `{"name":"ci","scopes":["deployments:write"],"expires_in_days":30}`.
The response shows the `pdk_` secret once. Lists and details show its last four characters only.
Without `scopes`, a key, a registered OAuth client and a scope-less authorization get `issues:read logs:read projects:read`.
The consent page offers every scope the user's role allows, including scopes the client did not request, and starts with the requested read scopes checked.
For an organization without projects whose owner or admin approves, `projects:write` also starts checked, so the agent can create the first project and source.
A signed-in user without an organization who opens an authorization request is sent to create one and then returns to the same request.
Keys expire after 30 days by default and after 90 days at most.
One account holds at most 50 unrevoked, unexpired keys per organization. Creating one more returns `409 api_key_limit`.
`issues:triage`, `projects:write` and `deployments:write` need an owner or admin, at creation and on every request.
Members list and revoke their own keys (`GET`, `DELETE /api/orgs/{org}/api-keys/{key}`). Owners and admins manage every key of the organization.
Key management accepts only a session with its CSRF token. A bearer gets `403`.
A password reset revokes the account's keys. Removing a member revokes their keys and OAuth grants for that organization. Deleting the organization deletes its keys.

`GET /api/orgs/{org}/projects` and `GET /api/orgs/{org}/projects/{project}/sources` return 25 items by default and 100 at most (`limit`).
Pass `next` as `after` for the next page. The key list pages the same way with `before`, newest first.
A `limit` outside 1 to 100, a cursor below 1, a value that is not a number, or any other parameter returns `400 invalid_pagination`.
The MCP tools `list_projects` and `list_sources` take the same `limit` and `after` and refuse the same values with `invalid_arguments`.

Log searches, tail replays, comparisons, recurrence checks and error context share one admission budget per organization:
two at a time and 30 per minute, across the API, the dashboard and MCP.
Above that budget the API returns `429 rate_limited` with `Retry-After`, and MCP returns `rate_limited` with `retry_after_secs`.
When all four server-wide slots are busy, the API returns `503 log_query_overloaded` with `Retry-After: 1`, and MCP returns the same code with `retry_after_secs`.
Dashboard pages still render when a query is refused. The refused part shows the wait, and the page answers with the same status and `Retry-After`.
MCP accepts 120 tool calls per organization per minute. A call refused for its scope or role does not count.
Configure the budgets in `settings.query_admission` and `settings.logs.search.max_active_queries`.

## Record deployments

Record each deployment from CI with an API key or OAuth token that has `deployments:write`.
That scope records deployments only. It cannot create projects, sources or DSNs:

```sh
curl -X POST "$POSTDEPLOY_URL/api/orgs/$ORG/projects/$PROJECT/deployments" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"version":"web@1.4.2","environment":"production","commit_sha":"<40 or 64 hex>","deployed_at":<Unix microseconds>}'
```

`deployed_at` defaults to the receive time. Repeating a request with the same project, environment,
version and `deployed_at` returns the stored row with `created: false`. The same identity with another
commit returns `409 deployment_exists`.

Read endpoints, with the scopes they require:

| Endpoint | Scopes |
|---|---|
| `GET /api/orgs/{org}/projects/{project}/deployments` | `projects:read` |
| `GET /api/orgs/{org}/deployments/{id}/comparison` | `issues:read` |
| `GET /api/orgs/{org}/issues/{issue}/recurrence` | `issues:read` |
| `GET /api/orgs/{org}/issues/{issue}/context?event=&source=` | `issues:read` and `logs:read` |

Comparisons count error events in equal windows before and after a deployment, as events per
minute. They report correlation in time, not cause. The MCP tools `list_deployments`,
`compare_deployment`, `issue_recurrence`, `get_error_context` and `get_usage` return the same data.
