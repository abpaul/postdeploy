---
title: "A deployment observability checklist for small teams"
description: "Verify the deployed artifact, external responses, error delivery, scheduled work, and analytics behavior. Record evidence for rollback decisions."
slug: "deployment-observability-checklist"
published_at: "2027-03-15T09:00:00Z"
cluster: "observability"
intent: "informational"
keywords:
  - "deployment monitoring checklist"
  - "post deployment verification"
  - "release observability checklist"
internal_links:
  - "/monitoring"
  - "/guides/investigate-errors-after-release"
  - "/blog/javascript-source-maps-release-checklist"
  - "/blog/cron-success-heartbeat-shell"
sources:
  - "https://sre.google/workbook/canarying-releases/"
---

A deployment finishing successfully proves that the deployment mechanism completed its steps. It does not prove that customers can use the new release.

Keep a short checklist that verifies the deployed artifact and the important user-facing paths. Each item should produce evidence someone can use for a rollback decision.

## Declare the release identity

Record the commit, immutable build artifact, deployment time in UTC, and configuration changes. Use the same release identifier in supported error reporting.

An illustrative local checklist record is:

~~~text
Release: web-7c2e1f
Deployment started: 2027-03-15T09:00:00Z
Artifact: app.a83d91.js
Changed capability: report export
Rollback target: prior validated release
Owner: developer responsible for the release
~~~

Use your real artifact and rollback mechanism. A branch name can move, so it is weaker evidence than an immutable identity.

Keep source maps attached to the exact build as described in the [source map checklist](/blog/javascript-source-maps-release-checklist).

## Verify a critical operation

Choose one or two operations affected by the change. For a report export, create a disposable report, retrieve it through the customer-facing path, and inspect its content.

A homepage 200 is insufficient for a change to authenticated exports. A process health response is insufficient for a data migration.

Run checks against the candidate environment before routing production traffic when your deployment architecture supports that. After release, use authorized test data and the normal customer-facing path.

## Inspect external monitoring evidence

Confirm the checked hostname, status, body marker, and latest sample time. A monitor left paused during maintenance does not establish post-release health.

Compare the origin and public edge when CDN behavior matters. Cached content can serve an older release while the origin has changed.

[PostDeploy monitoring](/monitoring) supplies uptime and heartbeat evidence. Its single monitoring location does not establish availability from every network.

Do not define a universal waiting period. Observe long enough to cover the failure modes the release can introduce, including low-frequency tasks.

## Verify error reporting without creating noise

In a disposable environment, generate one controlled exception through the deployed integration. Confirm its release and original source location.

For production, inspect new errors, existing error rates, and the affected operation's evidence within your approved workflow. Avoid intentionally breaking a real customer's action just to test telemetry.

Use the [release investigation guide](/guides/investigate-errors-after-release) to compare the relevant periods. A lower event count can result from broken ingestion, so check collection coverage as well.

## Check scheduled work and analytics separately

A scheduled job may not run during the deployment's immediate observation window. Verify its next expected completion or run a safe representative operation.

Check that a successful run sends its heartbeat and a failure does not. The [heartbeat pattern](/blog/cron-success-heartbeat-shell) explains the boundary.

For analytics changes, perform one known navigation and inspect the outgoing pageview or event. Dashboard totals take time to aggregate and cannot prove a single flow immediately.

## Make the rollback condition concrete

Write conditions before rollout: a broken critical operation, sustained unexpected errors, or a failed migration validation, for example.

Consider data compatibility. Reverting application code may not reverse a schema or external side effect. A rollback plan must cover the actual change.

Record which checks passed, which remain unobserved, and which findings need follow-up. Do not convert “not yet checked” into a green status.

The strongest release evidence is a completed operation through the deployed interface, connected to the expected artifact and observable telemetry.

## References

- [Google SRE release verification and canaries](https://sre.google/workbook/canarying-releases/)
