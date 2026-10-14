---
title: "Send a cron heartbeat only after successful work"
description: "Build a shell wrapper that preserves job failures, bounds heartbeat requests, and distinguishes completed work from monitoring delivery."
slug: "cron-success-heartbeat-shell"
published_at: "2026-10-19T09:00:00Z"
cluster: "cron"
intent: "informational"
keywords:
  - "cron success heartbeat"
  - "monitor shell script completion"
  - "cron exit code monitoring"
internal_links:
  - "/monitoring/cron-jobs"
  - "/guides/backup-heartbeat"
sources:
  - "https://healthchecks.io/docs/monitoring_cron_jobs/"
  - "https://www.gnu.org/software/bash/manual/html_node/Pipelines.html"
---

A heartbeat sent at the start of a cron job proves that the scheduler started something. It does not prove that the work finished. If the job crashes after that request, a success-only monitor can report a healthy run for failed work.

Put the success heartbeat after the operation whose completion matters. For a database export, that might include upload and validation. For a report, it might include storing the report where its consumers can read it.

## Preserve the job's exit status

This Bash wrapper expects an executable job script and a heartbeat URL supplied by the environment:

~~~bash
#!/usr/bin/env bash
set -u
set -o pipefail
: "${HEARTBEAT_URL:?Set HEARTBEAT_URL}"

if /srv/app/bin/export-report; then
  if ! curl --fail --silent --show-error \
       --connect-timeout 2 --max-time 10 \
       "$HEARTBEAT_URL" >/dev/null; then
    printf '%s\n' 'Work completed; heartbeat delivery failed' >&2
    exit 75
  fi
else
  job_status=$?
  printf 'Report failed with exit code %s\n' "$job_status" >&2
  exit "$job_status"
fi
~~~

The job's failure code survives. A heartbeat failure gets a separate code, 75, chosen here as a local convention. Document that convention in your runbook. It is not a monitoring protocol.

The job script must also return failure when its work fails. A script that catches every exception and exits zero defeats this wrapper. If it uses a pipeline, enable pipeline failure handling inside that script as well.

## Do not rerun work to repair telemetry

Suppose the report was delivered, but the heartbeat timed out. The monitor sees silence even though the report exists. Rerunning the whole job could send the report twice.

Retry the heartbeat separately when useful. Bound the total retry window and confirm that duplicate pings are safe for the chosen monitor. A transport timeout is ambiguous: the remote server may have received the request before the client gave up.

For jobs with side effects, make the work idempotent before adding automatic retries. Use the intended report date or business operation as the deduplication key.

## Choose a deadline that describes useful completion

An hourly job that normally finishes within four minutes needs room for scheduler delay and execution time. Set the alert deadline from observed completion times and the business deadline.

An illustrative policy is: expect completion each hour, tolerate up to ten minutes after the expected start, then investigate. Ten minutes is a starting hypothesis, not a universal threshold.

For an interval monitor, long execution times can shift the spacing between completion pings. A schedule-aware monitor may instead compare each expected run with its completion deadline. Confirm which behavior your tool provides.

[PostDeploy cron monitoring](/monitoring/cron-jobs) supports heartbeat checks. Use the generated URL and the documented configuration. Do not append another vendor's start or failure suffix without verifying support.

## Prove all three outcomes

In a disposable test, run a job that succeeds and confirm a ping. Run one that exits 7 and confirm exit 7 with no success ping. Then block the heartbeat endpoint while allowing the work to complete.

The third case should produce a telemetry failure message, not a false statement that the report failed. Confirm that the monitor alerts when the expected ping remains absent.

Keep the heartbeat URL secret. Anyone who has it may be able to send a false success signal. Do not print it in public CI logs.

For backups, a delivered heartbeat still does not prove restorability. The [backup monitoring guide](/guides/backup-heartbeat) covers completion signals; add periodic restore drills for the data itself.

## References

- [Healthchecks cron monitoring](https://healthchecks.io/docs/monitoring_cron_jobs/)
- [Bash pipeline behavior](https://www.gnu.org/software/bash/manual/html_node/Pipelines.html)
