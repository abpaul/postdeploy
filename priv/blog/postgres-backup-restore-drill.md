---
title: "Verify PostgreSQL backups with a restore drill"
description: "Restore a PostgreSQL dump into an isolated database, verify business invariants, and measure recovery time before relying on a successful backup job."
slug: "postgres-backup-restore-drill"
published_at: "2027-02-08T09:00:00Z"
cluster: "cron"
intent: "informational"
keywords:
  - "postgresql backup restore test"
  - "verify pg_dump backup"
  - "database restore drill"
internal_links:
  - "/guides/backup-heartbeat"
  - "/blog/job-idempotency-retries"
  - "/monitoring/cron-jobs"
sources:
  - "https://www.postgresql.org/docs/current/backup-dump.html"
  - "https://www.postgresql.org/docs/current/app-pgrestore.html"
  - "https://www.postgresql.org/docs/current/app-pgdump.html"
---

A completed backup job proves that a command completed under its own checks. It does not prove that the backup can restore the application.

Run periodic restore drills in an isolated environment. Verify the restored data and the application's critical reads, then record how long recovery took.

## Define the drill's boundary

Use a dedicated restore server or a disposable database that cannot reach production services. Restored application data may contain sensitive information; apply the same access controls as the source.

Disable outbound email, payment calls, and scheduled jobs before running an application against restored data. A drill should not repeat production side effects.

Choose the recovery question. A logical dump tests restoration of the exported database state. Point-in-time recovery requires a different backup and recovery design, including the relevant base backups and write-ahead logs.

## Restore with errors visible

For a custom-format dump, an illustrative command sequence is:

~~~sh
createdb --host=127.0.0.1 --port=5432 \
  --username=restore_operator postdeploy_restore_drill

pg_restore --host=127.0.0.1 --port=5432 \
  --username=restore_operator \
  --dbname=postdeploy_restore_drill \
  --exit-on-error --no-owner \
  /secure/backups/app.dump
~~~

Run this only against a dedicated local or isolated restore environment. The names and port are examples.

Use the PostgreSQL client version appropriate to the dump and target server. A dump can also contain commands from its source environment, so restore only backups you trust.

`--no-owner` avoids restoring original ownership. It can be useful for a drill, but it means the result does not verify production ownership and grants. Test those separately if they are part of recovery.

## Check business invariants

A successful restore is one layer of evidence. Verify that required tables and relationships contain plausible data.

An illustrative query is:

~~~sql
SELECT count(*) AS orphaned_orders
FROM orders o
LEFT JOIN customers c ON c.id = o.customer_id
WHERE c.id IS NULL;
~~~

Expected output is zero when the application's contract requires every order to have a customer. Adapt the schema and expected values to your application.

Check a known recent record, a known historical record, and representative reads. Compare with metadata captured at backup time rather than current production counts, which can change during the drill.

A database dump may omit external files or object storage. Include those dependencies in the recovery plan instead of calling the database restore a complete application recovery.

## Measure recovery objectives

Recovery point describes how much recent data the chosen backup can lose. Recovery time describes how long restoration and validation take.

Record download time, restore time, migration or compatibility checks, and application validation. A restore that finishes quickly but needs hours of manual repair does not meet a short recovery target.

Use a monotonic timer for elapsed measurements. Keep backup creation timestamps and business data timestamps in UTC.

## Monitor backup and drill completion separately

A backup heartbeat should follow export, storage, and the validations the backup job owns. A restore drill needs a separate completion signal because it runs on a different schedule.

The [backup heartbeat guide](/guides/backup-heartbeat) covers detecting silent backup failures. [PostDeploy cron monitoring](/monitoring/cron-jobs) can watch expected completion of both jobs.

A failed drill should produce a concrete failure category and retain the relevant logs. Preserve the failed backup until you can investigate it.

## Finish the drill with evidence

Record the backup identifier, target PostgreSQL version, validation results, measured duration, and remaining gaps. Clean up only the disposable restore environment you created after the evidence is retained.

The useful result is a backup you restored and checked, not a green upload notification.

## References

- [PostgreSQL logical backup concepts](https://www.postgresql.org/docs/current/backup-dump.html)
- [pg_restore options](https://www.postgresql.org/docs/current/app-pgrestore.html)
- [pg_dump scope and limitations](https://www.postgresql.org/docs/current/app-pgdump.html)
