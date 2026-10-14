---
title: "Calculate uptime percentage and the downtime budget correctly"
description: "Convert an availability target into a downtime budget. Distinguish sampled uptime, request success, and unknown monitoring periods."
slug: "uptime-percentage-error-budget"
published_at: "2026-12-07T09:00:00Z"
cluster: "uptime"
intent: "informational"
keywords:
  - "calculate uptime percentage"
  - "99.9 uptime downtime budget"
  - "availability error budget"
internal_links:
  - "/monitoring/uptime"
  - "/blog/monitor-alert-thresholds"
sources:
  - "https://sre.google/workbook/implementing-slos/"
---

An uptime percentage needs a window and a measurement method. “99.9 percent uptime” over a 30-day month allows a different amount of downtime from the same percentage over a year.

It also matters whether you measure elapsed availability, successful requests, or successful external probes. These measures can disagree because they observe different things.

## Calculate a time-based budget

For a time-based target:

~~~text
availability = available time / eligible time
downtime budget = eligible time × (1 - target)
~~~

This Python example uses decimal arithmetic to avoid distracting floating-point output:

~~~python
from decimal import Decimal

window_minutes = Decimal(30 * 24 * 60)
target = Decimal("0.999")
budget_minutes = window_minutes * (Decimal(1) - target)
print(budget_minutes)
assert budget_minutes == Decimal("43.200")
~~~

For this illustrative 30-day window, the result is 43.2 minutes. A 31-day window gives 44.64 minutes. Neither is a universal monthly allowance.

Define planned maintenance and excluded periods before calculating results. Do not remove an incident from the denominator after it happens merely because it makes the target harder to meet.

## Distinguish sampled uptime from exact duration

A monitor checking once per minute does not continuously observe the service. If checks pass at 12:00 and fail at 12:01, the failure began somewhere between those observations, unless you have better evidence.

Tools can estimate incident start and end differently. Some use the first failed check, some attribute an interval, and some apply confirmation rules. Read the calculation policy.

Three failed checks out of 1,000 eligible checks produces a 99.7 percent successful-check ratio. It does not automatically prove exactly three minutes of customer downtime.

Probe gaps need a declared treatment. A missing sample is unknown evidence, not automatically a success or a failure. Report coverage alongside the estimate when gaps materially affect it.

## Choose a request-based measure when it fits

For an API, successful eligible requests divided by total eligible requests can describe customer experience better than elapsed time.

Declare what counts as success. Excluding all 4xx responses may be appropriate for invalid client input, but an application defect that returns 400 for valid requests should not disappear from the measure.

A traffic-weighted ratio gives busy periods more weight. A time-based measure weights a quiet minute and a busy minute equally. Choose based on the reliability commitment.

External probes remain useful for reachability when customer request data is absent. They are evidence about the checked path from the monitoring location.

## Use the budget to make a decision

An error budget is the tolerated unreliability under a stated target. It can guide rollout pace, reliability work, or an incident response.

An illustrative policy might pause risky feature releases after the monthly budget is exhausted, while allowing changes that repair reliability. The team must define who can make exceptions.

Avoid showing a precise target without an action. A tiny team can start with one critical API and a simple reviewed window rather than creating targets for every endpoint.

## Verify the arithmetic and the evidence

Test a fully healthy window, one known incident, no eligible samples, and a monitoring gap. Check that the empty case is not presented as 100 percent.

Compare the dashboard's incident timestamps with the underlying observations. Recalculate a small window by hand to establish what the displayed metric means.

[PostDeploy uptime monitoring](/monitoring/uptime) supplies external check evidence. Use [alert threshold calculations](/blog/monitor-alert-thresholds) to understand detection delay separately. A high uptime percentage and a fast alert are different properties.

## References

- [Google SRE guidance on defining SLOs](https://sre.google/workbook/implementing-slos/)
