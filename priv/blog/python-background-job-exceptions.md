---
title: "Handle Python job exceptions without false success"
description: "Consume futures, propagate subprocess failures, and preserve nonzero exits. Make background job failures visible to both error tracking and heartbeats."
slug: "python-background-job-exceptions"
published_at: "2026-12-21T09:00:00Z"
cluster: "errors"
intent: "informational"
keywords:
  - "python background job exception handling"
  - "ThreadPoolExecutor exceptions"
  - "python cron script exit code"
internal_links:
  - "/error-tracking"
  - "/blog/cron-success-heartbeat-shell"
sources:
  - "https://docs.python.org/3/library/concurrent.futures.html"
  - "https://docs.python.org/3/library/subprocess.html"
  - "https://docs.python.org/3/library/logging.html"
---

A Python job can fail inside a worker while the main process exits successfully. Submitting work to an executor is not the same as reading its result.

Consume each result, preserve subprocess failures, and make the final exit code reflect whether the required work completed. Only then send a success heartbeat.

## Read results from futures

This standalone example demonstrates an exception crossing the worker boundary:

~~~python
from concurrent.futures import ThreadPoolExecutor

def export_report():
    raise RuntimeError("Synthetic report failure")

with ThreadPoolExecutor(max_workers=1) as executor:
    future = executor.submit(export_report)
    future.result()
~~~

The call to `result()` raises the worker exception in the caller. Without it, waiting for executor shutdown does not by itself re-raise that exception.

For several tasks, consume every result. Decide whether one failure should stop the batch or whether independent tasks can continue. Report the failed tasks accurately either way.

Do not interpret “submitted” as “completed” in logs or analytics.

## Propagate child process errors

A child command's nonzero exit does not automatically raise in Python. Use `check=True` when failure must stop the operation:

~~~python
import subprocess
import sys

subprocess.run(
    [sys.executable, "-c", "raise SystemExit(7)"],
    check=True,
    timeout=30,
)
~~~

This raises `CalledProcessError`. A timeout raises a separate exception. Keep those categories distinct in your logs because the likely causes differ.

Use argument lists rather than `shell=True` for external values. Do not include secrets in command arguments that may appear in process listings or captured errors.

## Catch at the outer boundary when you need reporting

An illustrative command entry point is:

~~~python
import logging

def run_job():
    raise RuntimeError("Synthetic failure")

def main():
    try:
        run_job()
    except Exception:
        logging.exception("Scheduled report failed")
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
~~~

The log includes the traceback, and the process exits nonzero. This example intentionally fails so you can inspect the result.

For an error tracker, call the supported Python integration inside the exception handler if one is available. PostDeploy's first-party SDKs cover JavaScript, Elixir, and Ruby; do not assume a first-party Python SDK exists.

Use a documented compatible integration or a supported ingest API when configuring Python. Keep an unsupported SDK recommendation out of the job's critical path.

## Account for reporting shutdown

Some trackers buffer events. A short-lived process may terminate before its last error leaves the buffer.

Follow the integration's documented shutdown or flush behavior with a bounded timeout. A telemetry failure must not turn a failed job into a successful exit, and it must not hold the scheduler indefinitely.

Avoid broad `BaseException` handlers that accidentally absorb shutdown signals or keyboard interrupts unless you have a specific cleanup requirement.

## Verify from failure to evidence

Run the job manually in a disposable environment. Confirm a nonzero exit, a traceback with the expected function, and no success heartbeat.

Then verify the actual event in the tracker, including environment and job context. An SDK call returning normally is not proof of delivery.

For a successful run, inspect the produced report and the received heartbeat. The [shell completion pattern](/blog/cron-success-heartbeat-shell) can wrap a Python entry point without changing its exception policy.

[PostDeploy error tracking](/error-tracking) and heartbeat monitoring can provide complementary evidence. Errors describe observed failures. Missing heartbeats describe work that did not report successful completion, including processes that never started.

## References

- [Python futures and exception propagation](https://docs.python.org/3/library/concurrent.futures.html)
- [Python subprocess behavior](https://docs.python.org/3/library/subprocess.html)
- [Python exception logging](https://docs.python.org/3/library/logging.html)
