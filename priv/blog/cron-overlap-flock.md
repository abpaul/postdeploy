---
title: "Prevent cron overlap with flock and detect skipped runs"
description: "Use a local file lock for one-host cron jobs. Distinguish lock contention from successful work and verify the limits of local coordination."
slug: "cron-overlap-flock"
published_at: "2027-03-08T09:00:00Z"
cluster: "cron"
intent: "informational"
keywords:
  - "prevent cron overlap flock"
  - "cron job lock file"
  - "flock cron skipped run"
internal_links:
  - "/monitoring/cron-jobs"
  - "/blog/job-idempotency-retries"
  - "/blog/cron-success-heartbeat-shell"
sources:
  - "https://man7.org/linux/man-pages/man1/flock.1.html"
  - "https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html"
---

A job scheduled every five minutes can overlap if one run takes longer than five minutes. A local file lock can prevent simultaneous work on one machine.

A skipped run is not a successful run. Keep lock contention visible, and send a success heartbeat only when the intended work completes.

## Put the lock around the work

On Linux with util-linux `flock`, this illustrative command uses a nonblocking lock and a dedicated conflict exit code:

~~~sh
flock --nonblock --conflict-exit-code 75 \
  /srv/app/run/report-export.lock \
  /srv/app/bin/export-report-with-heartbeat
~~~

Create the lock directory with appropriate ownership before scheduling the command. Keep the lock on a filesystem whose locking behavior you understand.

The wrapped script owns report validation and the completion heartbeat. When the lock is unavailable, that script does not run and no success ping is sent.

Reserve exit code 75 for lock contention in this wrapper. If the job itself also uses 75, the outer caller cannot distinguish the cases from the exit code alone.

## Log a skipped attempt separately

A Bash wrapper can preserve the outcome:

~~~bash
#!/usr/bin/env bash
if flock --nonblock --conflict-exit-code 75 \
     /srv/app/run/report-export.lock \
     /srv/app/bin/export-report-with-heartbeat; then
  exit 0
else
  result=$?
  if [ "$result" -eq 75 ]; then
    printf '%s\n' 'Run skipped because the prior run holds the lock' >&2
  fi
  exit "$result"
fi
~~~

This assumes the wrapped script does not return the reserved code. Document that contract.

Do not place a success heartbeat after the entire wrapper regardless of its status. That would convert “skipped” into “completed” for the monitor.

## Understand the lock's scope

A local lock coordinates processes that use the same lock on the same relevant filesystem. Another host with its own copy of the file can still run the job.

A job that spawns detached work can release the lock while the detached process continues. Keep the required work inside the locked process lifetime, or use coordination suited to that architecture.

Do not delete the lock file while a process holds it. Another process can open a newly created file and acquire a different lock.

The file's presence does not itself prove that the lock is held. The operating system maintains the lock state.

## Decide what skipping means

For a refresh job where only the latest result matters, skipping an overlapping attempt can be acceptable. For billing or per-period reports, every intended period may need processing.

Use operation records to identify missing periods and catch up deliberately. A lock prevents overlap; it does not make repeated work idempotent.

The [idempotency guide](/blog/job-idempotency-retries) covers business keys and retry safety.

## Test contention before scheduling

In a disposable directory, run a command that holds the lock for thirty seconds. Start a second attempt against the same file.

The second attempt should return the reserved conflict code, produce a skip message, and send no success heartbeat. After the first command exits, another attempt should acquire the lock.

Use a local test heartbeat receiver rather than a real production monitor. Inspect which invocation sent the ping.

## Monitor useful completion

[PostDeploy cron monitoring](/monitoring/cron-jobs) can detect a missing completion signal when jobs repeatedly skip or hang. Set the deadline to the useful completion requirement, not merely the invocation interval.

The [completion heartbeat guide](/blog/cron-success-heartbeat-shell) keeps job success separate from telemetry delivery. Finish with a demonstrated contention test and a known policy for skipped periods.

## References

- [util-linux flock reference](https://man7.org/linux/man-pages/man1/flock.1.html)
- [Bash conditionals and command status](https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html)
