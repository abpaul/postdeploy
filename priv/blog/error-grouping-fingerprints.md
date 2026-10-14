---
title: "Error grouping: choose fingerprints that preserve the cause"
description: "Prevent error groups from splitting on request IDs or merging unrelated failures. Test fingerprint changes with representative exceptions."
slug: "error-grouping-fingerprints"
published_at: "2026-10-26T09:00:00Z"
cluster: "errors"
intent: "informational"
keywords:
  - "error grouping fingerprint"
  - "exception deduplication"
  - "group production errors"
internal_links:
  - "/error-tracking"
  - "/guides/investigate-errors-after-release"
sources:
  - "https://docs.sentry.io/platforms/javascript/usage/sdk-fingerprinting/"
  - "https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/"
---

Error grouping decides which failures appear as one issue. A group that splits on every request ID becomes a stream of duplicates. A group that merges every exception with the same message hides separate causes.

Use the error type and meaningful application frames as the starting point. Add a stable operation label when two operations need separate treatment. Keep variable customer data out of the grouping key.

## Distinguish cause from context

Consider two illustrative errors:

~~~text
PaymentTimeout: provider request expired, order=8421
PaymentTimeout: provider request expired, order=9917
~~~

The order IDs help investigate individual events. They should not create separate issues when both failures come from the same call site.

Now consider a timeout in a payment request and a timeout in a report export. The exception class may match, but the responsible code and recovery steps differ. A grouping system needs enough stack or operation context to keep them apart.

Normalize values only where you know what they represent. Replacing every number in a message can erase meaningful HTTP status codes or protocol versions.

## Try a narrow fingerprint policy

This standalone Python example shows the decision without depending on a vendor SDK:

~~~python
def fingerprint(error_type, application_frame, operation):
    return (error_type, application_frame, operation)

payment_a = fingerprint(
    "PaymentTimeout", "payments.py:charge", "charge"
)
payment_b = fingerprint(
    "PaymentTimeout", "payments.py:charge", "charge"
)
report = fingerprint(
    "PaymentTimeout", "reports.py:upload", "export"
)

assert payment_a == payment_b
assert payment_a != report
~~~

A real stack grouping algorithm must handle wrappers, recursion, and missing frames. Do not replace it with this tuple unless your requirements are equally narrow.

If your error tracker supports custom fingerprints, confirm whether a custom key replaces its default grouping or extends it. Different trackers can treat that choice differently. A copied SDK option may silently override useful stack information.

## Keep releases as investigation context

Release identifiers explain when an issue appeared. Including a release hash in every fingerprint can split the same persistent defect into one issue per deployment.

Keep release and environment as event attributes unless separation serves a clear workflow. For example, test and production events should be distinguishable, but a fix deployed under a new release should not hide an unresolved defect.

The [release investigation guide](/guides/investigate-errors-after-release) explains how to compare failures around a deployment. Grouping should support that comparison.

## Test before changing production grouping

Collect a small, redacted corpus: repeated examples of one defect, similar messages from separate defects, wrapped exceptions, and events with incomplete stacks. Declare the expected relationships before trying a new rule.

Count false splits and false merges. Review the actual events inside each candidate group. A smaller issue count is not proof of better grouping; one giant group has an excellent count and poor diagnostic value.

Keep the original events long enough to inspect the change. Determine whether the tracker can regroup historical events or whether the change affects only new ones. Do not promise historical repair without testing it.

## Use issue volume carefully

An issue count measures the number of groups under the current rules. It does not measure the number of affected requests or customers.

Prioritize with event frequency, recent occurrence, release context, and user impact where available. An uncommon failure on a critical operation may matter more than frequent errors from a nonessential widget.

[PostDeploy error tracking](/error-tracking) groups events into issues. Use its supported grouping behavior, then validate representative errors through the actual integration. A deliberate test exception should arrive with the expected stack and context before you depend on production triage.

## References

- [Sentry fingerprinting concepts](https://docs.sentry.io/platforms/javascript/usage/sdk-fingerprinting/)
- [OpenTelemetry exception attributes](https://opentelemetry.io/docs/specs/semconv/exceptions/exceptions-spans/)
