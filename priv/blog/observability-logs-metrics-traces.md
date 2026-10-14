---
title: "Logs, metrics, and traces: choose the signal for the question"
description: "Map operational questions to logs, metrics, traces, errors, and external checks. Add the missing signal without building a large observability stack."
slug: "observability-logs-metrics-traces"
published_at: "2027-03-01T09:00:00Z"
cluster: "observability"
intent: "informational"
keywords:
  - "logs metrics traces difference"
  - "observability signals small teams"
  - "monitoring vs observability"
internal_links:
  - "/monitoring"
  - "/error-tracking"
  - "/analytics"
  - "/blog/error-grouping-fingerprints"
sources:
  - "https://opentelemetry.io/docs/concepts/signals/"
---

Start an observability decision with a question. “Did the API respond?” needs different evidence from “Which downstream call made this request slow?”

Logs, metrics, traces, error events, and external checks overlap, but they do not answer every question equally well. Choose the smallest useful collection for the failure you need to investigate.

## Match the question to evidence

An illustrative mapping is:

| Question | Useful evidence | Important limit |
| --- | --- | --- |
| Can the public API respond? | External HTTP check | Observes one path and location |
| How often does this exception occur? | Error events grouped into issues | Delivery and sampling affect counts |
| Did latency increase across requests? | Request duration metrics | Aggregation can hide individual detail |
| Where did one request spend time? | Trace spans | Instrumentation and sampling limit coverage |
| What did this worker decide? | Structured logs | Volume and context determine usefulness |
| Did a scheduled report finish? | Completion heartbeat and output record | A start log is insufficient |

A signal's name is less important than the evidence it records. A large dashboard can still leave the important question unanswered.

## Use correlation without collecting everything

A request or operation identifier can connect a safe error event with restricted application logs. A release identifier can connect both with a deployment.

An illustrative structured log is:

~~~json
{
  "level": "error",
  "operation": "report_export",
  "request_id": "req-test-42",
  "release": "web-123",
  "error_type": "StorageTimeout"
}
~~~

Do not place customer secrets in the identifier or unfiltered context. Keep the same identifier format across the systems you actually use.

Time stamps help, but correlation by time alone becomes unreliable under concurrency. Two failures within one second can belong to different operations.

## Distinguish aggregation from individual events

A metric can summarize many observations efficiently. An average can hide a slow tail, and a percentile needs a clearly defined window and aggregation method.

A log records an event or decision. It can explain why code took a branch, but it does not automatically provide a complete request timeline.

A trace can show linked spans across an operation. Missing spans do not establish that a dependency was never called; instrumentation or sampling may have omitted it.

## Add one missing signal at a time

Suppose errors show that exports time out, but you cannot tell whether database reads or storage uploads dominate duration. A bounded duration measurement for each stage may be enough.

If you need to follow one request across several services, distributed tracing can justify its cost. If every incident concerns a missed cron run, a completion heartbeat may solve the immediate problem more directly.

Estimate collection volume, retention needs, and access requirements before adding a system. Avoid collecting unbounded attributes as metric labels.

## Keep product boundaries explicit

[PostDeploy monitoring](/monitoring) provides uptime checks and heartbeat evidence. [Error tracking](/error-tracking) provides grouped failures and release context. [Analytics](/analytics) provides pageviews and custom events.

PostDeploy does not provide general log aggregation, distributed tracing, or infrastructure metrics. Use another suitable tool when those signals are required. Do not label an error tracker as a full tracing system.

## Verify that a signal answers the question

Create one controlled failure or delay in a disposable environment. Attempt the investigation using only the available evidence.

If the evidence cannot distinguish two plausible causes, write down the missing observation. Add that observation and repeat.

The [grouping guide](/blog/error-grouping-fingerprints) helps preserve error causes. A useful observability stack is one that shortens a real investigation, demonstrated with a concrete failure.

## References

- [OpenTelemetry signal concepts](https://opentelemetry.io/docs/concepts/signals/)
