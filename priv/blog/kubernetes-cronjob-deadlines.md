---
title: "Kubernetes CronJob deadlines: missed starts versus hung jobs"
description: "Use startingDeadlineSeconds, activeDeadlineSeconds, and concurrencyPolicy for distinct failure modes. Verify job completion outside the scheduler."
slug: "kubernetes-cronjob-deadlines"
published_at: "2026-12-14T09:00:00Z"
cluster: "cron"
intent: "informational"
keywords:
  - "kubernetes cronjob startingDeadlineSeconds"
  - "cronjob activeDeadlineSeconds"
  - "kubernetes cronjob timeout"
internal_links:
  - "/guides/kubernetes-cronjob-heartbeat"
  - "/blog/cron-success-heartbeat-shell"
  - "/blog/cron-timezones-dst"
sources:
  - "https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/"
  - "https://kubernetes.io/docs/concepts/workloads/controllers/job/"
---

A Kubernetes CronJob has two different deadlines to consider. One limits how late the controller may start a scheduled Job. Another limits how long a created Job may remain active.

Mixing these settings can leave a job running indefinitely or skip a late run that you intended to catch up. Choose them from the business deadline.

## Give each setting one responsibility

This illustrative manifest runs an existing report image every fifteen minutes:

~~~yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: report-export
spec:
  schedule: "*/15 * * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 600
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: export
              image: registry.example.com/report-export:2026-11
              command: ["/app/export-report"]
~~~

Replace the image with an image you own. The command must return nonzero when the report fails.

The five-minute starting deadline limits lateness relative to an intended schedule. The ten-minute active deadline bounds the Job after it starts. The retry limit addresses failed attempts; it does not ensure exactly-once business effects.

Verify that your Kubernetes version supports the time-zone field. Kubernetes schedules use the dedicated field, not `CRON_TZ` embedded in the schedule expression.

## Decide whether overlap is safe

`Forbid` prevents overlapping Jobs from the same CronJob. It does not prevent another CronJob or a manually created Job from touching the same data.

A run can be missed because the preceding Job is still active. If every period must be processed, the application needs a catch-up design. For example, store completed report periods and process the oldest missing period on the next run.

`Replace` can terminate an active Job before starting a new one. That may leave partially written external data. Use it only when interruption and repetition are safe.

## Keep work idempotent

A scheduled operation can execute more than once because of retries and controller behavior. Use the intended business period as a stable key.

Do not choose the key from the container's start time if a delayed run belongs to an earlier period. A successful Job status only proves the process reached its completion criteria; your code defines whether the output is useful.

If a report uploads to object storage, use a deterministic object key and verify content before marking the period complete.

## Observe the failure category

Inspect the CronJob and its Jobs:

~~~sh
kubectl describe cronjob report-export
kubectl get jobs --sort-by=.metadata.creationTimestamp
kubectl describe job JOB_NAME
kubectl logs job/JOB_NAME
~~~

Use your own namespace and Job name. Logs may contain sensitive data, so inspect them through your team's restricted tooling.

A missing Job points toward scheduling or controller state. A pending Pod points toward capacity or placement. A running Job beyond its normal duration points toward execution. A failed Job points toward its exit or deadline evidence.

## Verify completion independently

A heartbeat after successful report delivery can detect silence even when you are not watching the cluster. The [Kubernetes heartbeat guide](/guides/kubernetes-cronjob-heartbeat) covers that integration.

Test in a disposable namespace: a normal run, an intentionally stalled command, a failed command, and a run longer than the schedule interval. Confirm the observed statuses and heartbeat behavior.

Keep scheduler evidence and output evidence separate. A completed Job with an empty or corrupt report still needs an application-level validation.

## References

- [Kubernetes CronJob configuration](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- [Kubernetes Job deadlines and retries](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
