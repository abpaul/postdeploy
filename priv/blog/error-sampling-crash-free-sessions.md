---
title: "Error sampling and crash-free sessions measure different things"
description: "Keep issue events, sessions, and affected users separate. Understand how sampling and missing session reports change reliability metrics."
slug: "error-sampling-crash-free-sessions"
published_at: "2027-02-15T09:00:00Z"
cluster: "errors"
intent: "informational"
keywords:
  - "error sampling crash free sessions"
  - "error events vs affected users"
  - "crash free session calculation"
internal_links:
  - "/error-tracking"
  - "/blog/error-grouping-fingerprints"
  - "/blog/analytics-funnel-denominators"
sources:
  - "https://docs.sentry.io/product/releases/health/"
  - "https://docs.sentry.io/platforms/javascript/configuration/options/"
---

An error event count and a crash-free session rate use different units. One broken session can emit many error events. Sampling can reduce stored events without improving reliability.

Declare the metric's population and collection method before interpreting a trend. A dashboard showing fewer events after a sampling change does not establish fewer failures.

## Define a session failure

A session needs a start, an end or expiry policy, and a rule for whether it failed. An unhandled exception, a process crash, and a handled recoverable error can have different meanings.

A common illustrative formula is:

~~~text
crash-free sessions =
  (eligible sessions - crashed eligible sessions) / eligible sessions
~~~

This Python calculation distinguishes event count from session impact:

~~~python
sessions = 1000
crashed_sessions = 20
error_events = 240

rate = (sessions - crashed_sessions) / sessions
assert rate == 0.98
print(f"{rate:.1%} crash-free sessions")
print(f"{error_events} error events")
~~~

The result is 98 percent crash-free sessions and 240 events. The event count does not belong in that fraction.

If no eligible sessions were recorded, report the measure as unavailable. Do not report 100 percent because no crashes arrived.

## Understand what sampling changes

Uniform event sampling can reduce the number of stored events. It can also reduce the chance of observing an uncommon defect.

At a 10 percent independent sampling rate, a defect that occurs once has a 10 percent chance of being retained. A frequent defect is more likely to appear at least once, but its observed count remains sampled.

Do not multiply every sampled count by ten and describe the result as an exact affected-user count. Sampling can be biased by error type, client, quota, or delivery failure.

A dedicated session report may preserve session health independently of event sampling. Verify your integration's behavior rather than assuming that both use the same sampling rule.

## Check collection completeness

Browser crashes, network failure, blockers, and shutdown timing can prevent reports from arriving. Missing session endings can require expiry logic.

A change in the number of reported sessions can move the denominator. Compare traffic and SDK coverage before concluding that a release improved reliability.

Keep session health separate from cookieless web visitor counts. These systems can define identity and time windows differently.

The [denominator guide](/blog/analytics-funnel-denominators) explains why compatible units matter for any rate.

## Compare releases fairly

Use the same metric definition, environment, observation window, and sampling configuration when comparing releases.

A release used by ten sessions provides less evidence than one used by ten thousand. Include counts beside percentages so readers can judge the sample.

Avoid comparing the first hour of a new release with a full week of an old release without stating that difference. User mix and exposure can change as rollout proceeds.

## Verify with known sessions

In a disposable environment, create a successful session, a session with one intended failure, and a session with repeated instances of that same failure.

Inspect the recorded session statuses and event counts. The repeated events should not create several crashed sessions if they all belong to one session under your definition.

[PostDeploy error tracking](/error-tracking) receives errors and session data through supported integrations. Confirm the metric definitions and supported sampling settings for your SDK. Do not assume another tracker's configuration options apply.

Use [error grouping](/blog/error-grouping-fingerprints) to organize causes. Use session metrics to assess exposure. Neither replaces evidence about the actual affected operation.

## References

- [Sentry release health concepts](https://docs.sentry.io/product/releases/health/)
- [Sentry JavaScript sampling options](https://docs.sentry.io/platforms/javascript/configuration/options/)
