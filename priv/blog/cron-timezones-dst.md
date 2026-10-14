---
title: "Cron time zones and DST: prevent missed or duplicate work"
description: "Choose UTC or local calendar scheduling deliberately. Test daylight saving transitions and use stable business keys for repeated cron executions."
slug: "cron-timezones-dst"
published_at: "2026-11-16T09:00:00Z"
cluster: "cron"
intent: "informational"
keywords:
  - "cron timezone daylight saving"
  - "cron DST duplicate jobs"
  - "CRON_TZ UTC"
internal_links:
  - "/monitoring/cron-jobs"
  - "/blog/cron-success-heartbeat-shell"
sources:
  - "https://www.man7.org/linux/man-pages/man5/crontab.5.html"
  - "https://www.man7.org/linux/man-pages/man8/crond.8.html"
  - "https://docs.python.org/3/library/zoneinfo.html"
---

“Run at 02:30 every day” is incomplete until you specify the time zone. In a zone with daylight saving changes, that local time may not exist on one date and may occur twice on another.

Choose whether the business needs a fixed UTC cadence or a local calendar event. A daily maintenance task and a report due at the start of a customer's local working day can need different schedules.

## Identify the scheduler you actually run

Cron behavior varies across implementations. The cron manual documents special handling for some clock changes, while crontab syntax alone does not describe every daemon's transition policy.

Check the installed daemon and its manual. A Linux host, a Kubernetes CronJob, and a hosted scheduler do not share one universal time-zone setting.

Some cron implementations support `CRON_TZ` for a crontab:

~~~text
CRON_TZ=UTC
30 2 * * * /srv/app/bin/daily-maintenance
~~~

Verify support before using it. Setting `TZ` inside a command can change that command's date calculations without changing the scheduler's interpretation of the crontab.

Keep timestamps in logs with a UTC offset. “02:30” alone cannot distinguish the two occurrences of a repeated local time.

## Inspect a transition explicitly

Python 3.9 or newer provides `zoneinfo`, using installed IANA time-zone data. This example illustrates the repeated time in New York:

~~~python
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

zone = ZoneInfo("America/New_York")
for fold in (0, 1):
    local = datetime(2026, 11, 1, 1, 30, tzinfo=zone, fold=fold)
    print(local.isoformat(), local.astimezone(timezone.utc).isoformat())
~~~

The two local values map to different UTC instants. This demonstrates ambiguity; it does not reproduce your scheduler's execution policy.

Generate expected run times around both seasonal transitions using the scheduler's own tooling where available. Include the time-zone database version in the test environment when exact calendar behavior matters.

## Deduplicate by the business period

If a daily report must exist once per local business date, use that date as part of the job's idempotency key. Do not use the process start timestamp, which changes on each retry.

For example, `daily-report:customer-17:2026-11-01` identifies an intended result. A uniqueness constraint can prevent two executions from creating two report records.

The reporting date must come from the intended scheduled period, not blindly from the current date after a delayed run. Specify how catch-up runs choose it.

A unique record is only one part of idempotency. Emailing a report or calling a payment provider needs its own deduplication strategy.

## Align the monitor with the intended schedule

A fixed “24 hours since last success” deadline can alert during a local daily schedule's longer seasonal interval. A generous interval can hide a missed run during the shorter interval.

Use a monitor that can represent the actual schedule, or document an interval policy that accounts for the expected variation. Verify the tool's behavior rather than assuming local calendar support.

Send completion pings as described in the [success heartbeat guide](/blog/cron-success-heartbeat-shell). A correct schedule with a failed job still needs detection.

## Make migration safe

When changing a job from local time to UTC, calculate the last old run and first new run. Look for an accidental overlap or gap.

Test in a non-production environment. Inspect output records by business period, not only scheduler logs. Logs can show that a process started even when it produced nothing useful.

[PostDeploy cron monitoring](/monitoring/cron-jobs) watches expected heartbeats. Keep the job's scheduling policy in the scheduler, and make the completion deadline match the business requirement.

## References

- [crontab syntax](https://www.man7.org/linux/man-pages/man5/crontab.5.html)
- [cron clock-change behavior](https://www.man7.org/linux/man-pages/man8/crond.8.html)
- [Python time-zone support](https://docs.python.org/3/library/zoneinfo.html)
