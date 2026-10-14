---
title: "Create an analytics event naming schema developers can maintain"
description: "Define stable event names, exact triggers, and safe properties. Separate clicks from completed outcomes and prevent duplicate analytics events."
slug: "analytics-event-naming-schema"
published_at: "2026-11-02T09:00:00Z"
cluster: "analytics"
intent: "informational"
keywords:
  - "analytics event naming convention"
  - "custom event tracking plan"
  - "analytics event schema"
internal_links:
  - "/analytics"
  - "/guides/why-analytics-tools-disagree"
sources:
  - "https://plausible.io/docs/custom-event-goals"
  - "https://developer.mozilla.org/en-US/docs/Web/API/EventTarget/addEventListener"
---

A custom event is useful only when the team agrees on what causes it. If one developer fires “signup” on a button click and another fires it after account creation, the resulting total cannot answer how many accounts were created.

Define each event as a contract: name, trigger, excluded cases, allowed properties, and owner. Keep that contract beside the code that emits it.

## Name outcomes and intentions separately

Use a consistent naming style. The specific case matters less than stable meaning.

~~~text
signup_submitted
Trigger: form passes client validation and a request starts
Excluded: invalid forms, repeated clicks while pending

signup_completed
Trigger: the server confirms a newly created account
Excluded: failed requests, sign-in, page reload

report_download_clicked
Trigger: a person requests a download
Excluded: automatic prefetch
~~~

A click is evidence of intent. A server-confirmed creation is evidence of an outcome. If the analytics integration cannot observe the outcome reliably, keep the event's name narrow.

Do not emit “completed” from a button handler merely because the next screen usually appears.

## Use an allowlist for properties

Properties should describe useful, bounded categories. A value such as `plan: "monthly"` is easier to interpret than an arbitrary URL or free-text form field.

Avoid email addresses, access tokens, customer names, and unfiltered page URLs. Query parameters can carry secrets. A schema can reduce collection without relying on every caller to remember a warning.

This vendor-neutral JavaScript example defines a small validator:

~~~javascript
function signupProperties(input) {
  const allowedSources = new Set(["pricing", "home", "docs"]);
  if (!allowedSources.has(input.source)) {
    throw new Error("Unknown signup source");
  }
  return { source: input.source };
}

const properties = signupProperties({
  source: "pricing",
  email: "person@example.com"
});
console.assert(!("email" in properties));
~~~

Send `properties` with your analytics client's documented custom event API. The example does not imply that every service accepts the same payload.

## Prevent duplicate ownership

Assign one layer to emit each event. A button handler, a router callback, and a server success callback can otherwise count the same operation three times.

Framework components may register handlers again when they remount. Use the framework's cleanup mechanism for listeners and subscriptions. Disabling a submit button while a request is pending reduces accidental repeated attempts, but it does not establish exactly-once delivery.

Browser analytics remains best effort. A request can be blocked, lost, or retried. Use your application database for authoritative account and billing totals.

## Version meanings deliberately

Renaming an event can break a trend. Keeping the same name while changing its trigger can produce a more subtle break.

For a meaningful semantic change, introduce a new event name or an explicit schema version. Record the deployment date and compare overlapping data before retiring the old event. Avoid emitting both indefinitely unless consumers can distinguish them.

Keep low-cardinality properties stable. A new property value should correspond to a real product choice, not an unbounded identifier.

## Verify from action to recorded event

Test one successful signup, one rejected signup, a double click, and a reload of the success page. Inspect browser requests and the analytics dashboard.

Expected results are one completed event for a created account and no completed event for the rejected request. A reload should not create another account completion.

[PostDeploy analytics](/analytics) supports pageviews and custom events. Confirm supported property behavior in its documentation before designing a report around it. Do not assume a built-in funnel or conversion product.

When totals differ from another service, compare event meaning before collection mechanics. The [analytics disagreement guide](/guides/why-analytics-tools-disagree) provides a broader diagnostic path.

## References

- [Plausible custom event documentation](https://plausible.io/docs/custom-event-goals)
- [Browser event listener behavior](https://developer.mozilla.org/en-US/docs/Web/API/EventTarget/addEventListener)
