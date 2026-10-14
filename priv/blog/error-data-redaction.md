---
title: "Redact sensitive data before sending production errors"
description: "Use allowlisted error context and synthetic canary secrets to test redaction. Inspect request URLs, messages, breadcrumbs, and uploaded artifacts."
slug: "error-data-redaction"
published_at: "2027-01-18T09:00:00Z"
cluster: "errors"
intent: "informational"
keywords:
  - "error tracking sensitive data redaction"
  - "sanitize error reports"
  - "PII exception logging"
internal_links:
  - "/error-tracking"
  - "/blog/error-grouping-fingerprints"
sources:
  - "https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html"
  - "https://docs.sentry.io/platforms/javascript/data-management/sensitive-data/"
---

Production errors can contain more than a stack trace. Request URLs, exception messages, headers, breadcrumbs, user context, and source artifacts can all carry sensitive values.

Reduce data before it leaves the application. A server-side scrubber is useful defense, but it cannot undo sending a secret to a system you did not intend to receive it.

## Start with an allowlist

Decide which context helps diagnosis: operation name, environment, release, a bounded error category, and a correlation identifier.

Avoid copying complete request objects or arbitrary user profiles. An allowlist is easier to review than a blacklist of every possible secret field.

This standalone JavaScript example projects context into a narrow shape:

~~~javascript
function safeContext(input) {
  return {
    operation: String(input.operation).slice(0, 80),
    environment: String(input.environment).slice(0, 30),
    release: String(input.release).slice(0, 80)
  };
}

const context = safeContext({
  operation: "report_export",
  environment: "production",
  release: "web-123",
  authorization: "Bearer TEST_SECRET_DO_NOT_SEND"
});
console.assert(!("authorization" in context));
~~~

This limits fields, not the contents of every allowed value. If callers place a token in `operation`, the projection still sends it. Prefer enumerated operation names where practical.

## Inspect less obvious paths

A password-reset URL can contain a token in its query string. An exception message may include a database URL. Breadcrumbs can include form values or full request bodies.

Normalize URLs before recording them when the exact query is unnecessary. Keep a route template such as `/users/:id` instead of a raw customer-specific path when the tracker supports that context.

Do not strip every diagnostic detail indiscriminately. Preserve safe categories, status codes, and application frame locations so the remaining event is useful.

Source maps can contain original source text. Review comments and embedded configuration before uploading artifacts, especially if the files become publicly reachable.

## Use the integration's supported hook

Many error integrations provide a pre-send callback or processors. Verify when the hook runs and which event fields it can change.

Check automatic events as well as manually captured exceptions. A hook applied only to a custom helper can miss unhandled errors.

[PostDeploy error tracking](/error-tracking) accepts several integration paths. Follow the documented configuration for the path you use. Do not assume that a setting from a compatible SDK controls server-side ingestion or every event type.

## Test with synthetic canary values

Create fake secrets that are distinctive and harmless:

~~~text
TEST_QUERY_TOKEN_6A2C
TEST_HEADER_SECRET_9D11
TEST_MESSAGE_EMAIL_4F7B
~~~

Place them in a disposable test request's query string, authorization header, exception message, and breadcrumb context.

Inspect the outgoing payload and the recorded event. Search for the exact values. The expected result is absence from both places after redaction.

Also confirm that the event still contains the intended error type, stack, operation, and release. A scrubber that discards the whole event avoids leakage but defeats diagnosis.

## Handle existing leakage through the real process

If a genuine credential was sent, follow your team's credential incident process. Deleting a dashboard event does not guarantee removal from exports, backups, notifications, or third-party delivery logs.

For routine validation, use fake values so the test itself does not create an incident.

## Keep grouping independent of personal data

Customer identifiers should not determine issue fingerprints. That can leak identity through group labels and split one defect into many issues.

The [fingerprint guide](/blog/error-grouping-fingerprints) explains stable grouping inputs. Redaction and grouping should preserve the cause while removing unnecessary individual details.

Repeat the canary check when an SDK, middleware, or request-capture configuration changes. Verify the transmitted event, not only a configuration flag.

## References

- [OWASP logging guidance](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
- [Sentry sensitive data handling](https://docs.sentry.io/platforms/javascript/data-management/sensitive-data/)
