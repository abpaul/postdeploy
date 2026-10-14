---
title: "Separate bots and internal traffic from analytics trends"
description: "Build controlled traffic tests and declare exclusions. Avoid treating browser analytics as a count of every request or every real person."
slug: "analytics-bot-internal-traffic"
published_at: "2027-02-22T09:00:00Z"
cluster: "analytics"
intent: "informational"
keywords:
  - "exclude internal traffic analytics"
  - "bot traffic web analytics"
  - "analytics visitor count accuracy"
internal_links:
  - "/analytics"
  - "/guides/why-analytics-tools-disagree"
  - "/blog/spa-pageview-duplicates"
sources:
  - "https://plausible.io/docs/excluding"
  - "https://plausible.io/docs/bot-filtering"
  - "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/User-Agent"
---

Web server requests, browser pageviews, and human visitors are different populations. A crawler may fetch HTML without running JavaScript. A browser automation script may execute the tracker exactly like a person.

Start by identifying what your analytics collects. Do not infer “all bot traffic removed” from a quiet dashboard.

## Separate acquisition evidence from request evidence

Server logs can include search crawlers, health checks, asset requests, and API traffic. Browser analytics usually records selected client events after a script runs.

Comparing those totals directly is unlikely to produce equal numbers. A page can generate many asset requests and one pageview. A failed page load can generate server requests and no analytics event.

Use each source for its purpose. Request data helps diagnose infrastructure and abuse. Aggregate analytics helps interpret collected page and event activity.

## Declare exclusions before comparing trends

Internal traffic can include developers, support staff, demonstrations, previews, and automated acceptance checks.

Choose a supported exclusion method. Some tools support browser opt-outs, IP filters, host restrictions, or event filters. Each has limitations.

An IP filter can exclude an office but also people sharing that network. Remote workers can change addresses. A browser opt-out applies only to that browser configuration.

[PostDeploy analytics](/analytics) has its own supported collection and filtering behavior. Verify it before relying on an exclusion method described for another tool.

## Use a controlled traffic ledger

Create a disposable test site and record expected actions:

~~~text
Manual browser, normal profile: one direct page load
Manual browser, tracker blocked: one direct page load
curl: one HTML request, no JavaScript execution
Browser automation: one page load with scripts enabled
Internal opt-out browser: one direct page load
~~~

Inspect the actual network payloads and dashboard entries. The expected outcome depends on your tracker's configuration.

A curl request does not execute the page's JavaScript. Browser automation can execute it. That difference explains why “bots do not run JavaScript” is an unsafe general rule.

Do not use this exercise to send artificial traffic into production reports.

## Keep classification claims narrow

A user-agent string is caller-supplied. It can help identify known clients, but it is not a reliable proof of human identity.

Bot filters use rules and signals with tradeoffs. They can miss automation and exclude legitimate traffic. Treat the result as a filtered collection, not a census.

Avoid invasive identity techniques merely to make a visitor count look precise. Choose the information the product actually needs, and keep its privacy commitments consistent with collection.

## Diagnose a sudden spike

Compare host, path, referrer, campaign, event type, and deployment time where available. Look for a repeated route or one event emitted excessively.

A tracker added twice can mimic traffic growth. A router change can add duplicate pageviews. Use the [SPA duplicate guide](/blog/spa-pageview-duplicates) before attributing a spike to bots.

A new marketing campaign can also create real growth. Verify the campaign links and collection path rather than dismissing unfamiliar traffic.

## Report exclusions and coverage

Record when a filter or tracker configuration changes. A before-and-after trend can reflect measurement changes rather than audience changes.

Compare fixed time windows and consistent populations. Include the collection boundary in important reports: browser pageviews on allowed hosts, for example.

The [analytics disagreement guide](/guides/why-analytics-tools-disagree) helps compare different services without assuming one must be wrong.

The useful finish line is a repeatable traffic test, a declared exclusion policy, and a report whose label matches the data it actually contains.

## References

- [Plausible traffic exclusions](https://plausible.io/docs/excluding)
- [Plausible bot filtering](https://plausible.io/docs/bot-filtering)
- [HTTP user-agent semantics](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/User-Agent)
