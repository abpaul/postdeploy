---
title: "Make scheduled jobs idempotent before adding retries"
description: "Use stable business keys, transactions, and external idempotency support to make repeated job execution safe. Handle ambiguous timeouts explicitly."
slug: "job-idempotency-retries"
published_at: "2027-01-11T09:00:00Z"
cluster: "cron"
intent: "informational"
keywords:
  - "scheduled job idempotency"
  - "cron job retry duplicate processing"
  - "idempotent background jobs"
internal_links:
  - "/monitoring/cron-jobs"
  - "/blog/cron-success-heartbeat-shell"
  - "/blog/kubernetes-cronjob-deadlines"
sources:
  - "https://www.postgresql.org/docs/current/sql-insert.html"
  - "https://www.postgresql.org/docs/current/tutorial-transactions.html"
---

A retry is a second execution, not proof that the first execution did nothing. A request can time out after a remote service applies its side effect.

Design a scheduled job so repeated execution for the same intended operation produces a controlled result. Use a key that identifies the business work, not the attempt.

## Choose the key from the intended result

For a daily report, a useful key combines customer, report type, and reporting date. For an hourly import, it can identify the source and source period.

~~~text
daily-usage:customer-42:2027-01-18
~~~

A random UUID generated at process startup identifies an attempt. It cannot deduplicate a retry because the next process generates a new value.

Include a schema or calculation version only when changing the result should produce a new operation. Otherwise a deployment can accidentally bypass your deduplication rule.

## Make local changes atomic

For work contained in one PostgreSQL transaction, a unique operation key can guard the mutation.

This illustrative SQL applies a local credit once. It assumes `job_operations.operation_key` is unique and both tables are in the same database:

~~~sql
BEGIN;

WITH claimed AS (
  INSERT INTO job_operations (operation_key)
  VALUES ('daily-credit:account-42:2027-01-18')
  ON CONFLICT (operation_key) DO NOTHING
  RETURNING operation_key
)
UPDATE accounts
SET credits = credits + 10
WHERE id = 42
  AND EXISTS (SELECT 1 FROM claimed);

COMMIT;
~~~

If the transaction rolls back, both the claim and the credit roll back. Repeating the committed operation does not add another credit.

This pattern does not make a remote API call atomic with the database. Do not hold a database transaction open and assume it can roll back an email or payment.

## Treat external side effects separately

When the remote API supports idempotency keys, send the same business key on each retry and follow its documented retention and payload rules.

When it does not, store an operation state and a remote reference if available. Reconcile ambiguous results before repeating destructive or costly effects.

An outbox can make a local intent durable, but delivery can still happen more than once. The consumer or remote operation needs deduplication when duplicates matter.

Choose the simplest pattern that covers the actual effect. A report written under a deterministic object key has different requirements from a payment.

## Separate attempt state from completion state

Keep a record of attempts when diagnosis needs it: start time, end time, error category, and operation key. Keep one authoritative completion state for the intended work.

A “running” record can become stale after a process dies. Define how another attempt detects and recovers that state. A lease can help coordinate workers, but a lease alone does not undo a duplicate side effect.

A local file lock prevents overlap on one machine. It does not establish business idempotency across machines or after a crash.

## Test the ambiguous cases

In a disposable environment, execute the same operation twice and inspect the resulting business record. Run two attempts concurrently. Stop an attempt before commit, then retry.

For an external API, simulate a timeout after the service accepted the operation. The expected behavior should be reconciliation or a repeated request with the same supported idempotency key.

Do not test only that the second invocation returns “already done.” Verify that the credit, report, or remote operation exists exactly as intended.

## Monitor the result

Send a success heartbeat after the useful result is committed and validated. A failed heartbeat must not cause the entire non-idempotent operation to repeat.

The [completion heartbeat pattern](/blog/cron-success-heartbeat-shell) preserves this distinction. [PostDeploy cron monitoring](/monitoring/cron-jobs) can detect missing completion signals, while the application's operation records establish which work actually happened.

## References

- [PostgreSQL conflict handling](https://www.postgresql.org/docs/current/sql-insert.html)
- [PostgreSQL transactions](https://www.postgresql.org/docs/current/tutorial-transactions.html)
