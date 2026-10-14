---
title: "Set uptime alert thresholds without hiding short outages"
description: "Calculate the delay introduced by polling and failure thresholds. Tune alerts with incident evidence instead of suppressing inconvenient failures."
slug: "monitor-alert-thresholds"
published_at: "2026-11-09T09:00:00Z"
cluster: "uptime"
intent: "informational"
keywords:
  - "uptime alert threshold"
  - "consecutive failures monitoring"
  - "reduce monitoring false positives"
internal_links:
  - "/monitoring/uptime"
  - "/blog/http-health-check-contract"
sources:
  - "https://sre.google/workbook/alerting-on-slos/"
---

An alert threshold trades detection speed for confidence. Requiring several failed checks can reduce alerts from a transient network error. It also delays an alert for a real outage.

Start by deciding how quickly someone must act. Then calculate whether the polling interval, failure threshold, request timeout, and notification path can meet that requirement.

## Calculate the earliest and latest plausible detection

Consider an illustrative monitor that checks once per minute and requires three consecutive failures. If an outage begins just before a check, the third failed check starts roughly two minutes later. If it begins just after a check, the third starts roughly three minutes later.

Request duration and notification delivery add time. The exact result depends on whether the scheduler measures intervals between starts or completions and whether checks overlap.

~~~python
interval_seconds = 60
required_failures = 3
timeout_seconds = 10

best_start_delay = (required_failures - 1) * interval_seconds
worst_start_delay = required_failures * interval_seconds

print(best_start_delay + timeout_seconds)
print(worst_start_delay + timeout_seconds)
~~~

This model prints 130 and 190 seconds for the final failed request. It excludes notification transport. It assumes checks start on a fixed cadence and each final failure consumes the full timeout.

Use it as a hypothesis. Measure the actual path by inducing a controlled failure and recording timestamps.

## Separate an outage from a bad observation

A failed probe can result from an application error, DNS failure, TLS failure, timeout, or a network problem near the checker. Save the failure category and response evidence.

Repeated failures from one location increase confidence about that location's path. They do not establish a global outage. Conversely, one location passing does not establish global health.

A content check can reject a 200 response containing a proxy error page. The [health check contract](/blog/http-health-check-contract) explains how to define that evidence.

Do not classify every 4xx as an application outage. A revoked monitor credential can produce 401 while the public application works. Route that condition to someone who can repair the integration.

## Choose thresholds from the action

For a critical API, a long confirmation delay may be unacceptable. For a low-priority documentation site, immediate interruption may cost more than a brief isolated failure.

Use separate notification policies where supported. A short failure can create a record without waking someone. A sustained failure can require immediate action. Do not describe a recorded incident as a delivered page unless you have delivery evidence.

Recovery thresholds need attention too. One passing probe during an intermittent outage can produce repeated “down” and “up” messages. Require enough recovery evidence for the action you intend.

## Validate with a small failure exercise

Choose a disposable endpoint. Test a single failed response, sustained 503 responses, a stall that exceeds the timeout, and intermittent failures.

For each case, record first failure, alert creation, notification receipt, and recovery. Verify the monitor configuration rather than assuming its defaults.

Investigate noisy alerts before increasing thresholds. A probe against a rate-limited route may need a dedicated check endpoint. A connection timeout caused by resource saturation may reveal a real service problem.

## Review missed incidents as well as noisy ones

A quiet monitor can be broken. Compare support reports and application errors with alert history. Ask whether the check exercised the affected path and whether its threshold concealed the incident.

[PostDeploy uptime monitoring](/monitoring/uptime) gives a starting point for HTTP checks. Use its supported settings and one monitoring location honestly. Request-based SLO alerts need traffic metrics and a suitable alerting system; an external ping is not a substitute for that denominator.

Keep a threshold only when it supports a clear response and survives a measured failure test.

## References

- [Google SRE guidance on alerting from SLOs](https://sre.google/workbook/alerting-on-slos/)
