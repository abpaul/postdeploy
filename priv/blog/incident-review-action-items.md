---
title: "Write incident review action items that prevent repeat failures"
description: "Turn an incident timeline into bounded corrective actions with owners and verification. Separate observed facts, hypotheses, and customer impact."
slug: "incident-review-action-items"
published_at: "2027-04-05T09:00:00Z"
cluster: "observability"
intent: "informational"
keywords:
  - "incident review action items"
  - "postmortem corrective actions"
  - "small team incident review template"
internal_links:
  - "/monitoring"
  - "/blog/monitor-alert-thresholds"
  - "/blog/deployment-observability-checklist"
  - "/blog/observability-logs-metrics-traces"
sources:
  - "https://sre.google/workbook/postmortem-culture/"
---

An incident review is useful when it changes the conditions that made the incident possible or hard to diagnose. “Be more careful” does neither.

Build the review from evidence, then choose a few actions with clear owners and a test of completion. Keep the scope small enough that the team can finish the work.

## Separate facts from hypotheses

Record customer impact, the UTC timeline, detection, mitigation, and recovery evidence.

An illustrative timeline is:

~~~text
09:00: release begins
09:04: first failed API check
09:06: alert created
09:08: responder receives notification
09:12: rollback starts
09:15: controlled API operation succeeds
09:17: monitoring confirms sustained recovery
~~~

These are invented values showing the format. Replace them with observed times. Do not call the service recovered merely because the rollback command exited.

Label uncertain claims. A log gap may mean lost collection rather than no execution. An error event's arrival time may differ from the time the failure occurred.

## Describe the system conditions

Ask what allowed the failure, what amplified it, and what delayed recovery. A single code mistake may sit inside several missing safeguards.

For example, a changed response schema can break a client. Missing compatibility tests allow the release. A health endpoint that returns constant 200 delays detection. A stale rollback procedure extends impact.

Avoid making one person's action the entire explanation. The review should identify conditions the team can change.

## Turn each action into an observable result

A weak action says “improve monitoring.” A useful action identifies the checked capability and its failure test.

~~~text
Action: require the expected API response field in the external check
Owner: release maintainer
Due: next release
Completion evidence:
  a test 200 response without the field fails the check
  a valid response passes
  a controlled failure delivers the expected notification
~~~

A second action might add a contract test that rejects the incompatible response. The verification should exercise the boundary that failed, not grep a document for a promise.

The [health and alert guidance](/blog/monitor-alert-thresholds) helps separate check coverage from notification delay.

## Keep the action set bounded

Prioritize actions by the specific risk they reduce. One root-cause correction and one detection improvement may be more useful than a long list of unrelated cleanup.

Give every action an owner, due condition, and completion evidence. If an action has no owner or practical verification, it is unlikely to change behavior.

Distinguish prevention, detection, mitigation, and diagnosis. Faster alerts do not prevent the underlying failure, but they can reduce its duration.

## Verify recovery separately from telemetry

Inspect the affected operation and the monitoring evidence. A passing probe can recover before a backlog clears. An error dashboard can become quiet because ingestion stopped.

Use the [deployment checklist](/blog/deployment-observability-checklist) to record the artifact and capability. Use the [signal guide](/blog/observability-logs-metrics-traces) to identify missing evidence.

[PostDeploy monitoring](/monitoring) can contribute uptime and job completion observations. Application data and customer-facing checks establish whether the intended work recovered.

## Close the loop after implementation

Repeat the failure scenario in a disposable environment where practical. Confirm that the new check detects it or the corrected boundary rejects it.

Store that behavior test with the code when the failure can recur. A written runbook remains useful for decisions that require human judgment, but it should not carry an invariant the compiler or test can enforce.

Review action completion after the next relevant release. If the action did not reduce the intended risk, revise it using the new evidence.

The review's strongest result is a demonstrated change that prevents, detects, or shortens the same failure.

## References

- [Google SRE incident review practices](https://sre.google/workbook/postmortem-culture/)
