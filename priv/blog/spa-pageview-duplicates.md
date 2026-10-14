---
title: "Debug duplicate pageviews in a single-page application"
description: "Trace initial loads, history changes, and router hooks to find duplicate pageviews. Give one integration responsibility for each navigation."
slug: "spa-pageview-duplicates"
published_at: "2026-12-28T09:00:00Z"
cluster: "analytics"
intent: "informational"
keywords:
  - "spa duplicate pageviews"
  - "single page application analytics tracking"
  - "pushState pageview tracking"
internal_links:
  - "/analytics"
  - "/blog/analytics-event-naming-schema"
sources:
  - "https://plausible.io/docs/spa-support"
  - "https://developer.mozilla.org/en-US/docs/Web/API/History/pushState"
  - "https://developer.mozilla.org/en-US/docs/Web/API/Window/popstate_event"
---

A single-page application can report one navigation twice when an automatic tracker and a router hook both emit pageviews. It can also report none when the tracker only observes full document loads.

Debug the requests for one known navigation before changing dashboard calculations. The browser gives better evidence than a total collected over several days.

## Identify every pageview producer

Search your application for the tracker snippet, manual pageview calls, tag-manager rules, router subscriptions, and component lifecycle handlers.

Check whether the tracker observes history changes automatically. Plausible documents automatic handling for supported SPA navigation. Other integrations can behave differently.

Do not add a manual hook until you know what the installed script already does. A copied framework example may assume manual tracking mode.

[PostDeploy analytics](/analytics) provides a browser tracker. Verify its documented navigation behavior and current script version before combining it with router events.

## Build a small navigation matrix

Use an illustrative route sequence:

~~~text
1. Load /docs directly
2. Navigate within the app to /pricing
3. Press Back to return to /docs
4. Change a filter without changing the page
5. Reload /docs
~~~

Decide which actions count as pageviews. A filter change might be an event rather than a new page. A hash change might select an article section without creating a new view.

For this policy, actions 1, 2, 3, and 5 each count once. Action 4 counts zero times. Your product can choose another policy, but write it down.

## Inspect requests in the browser

Open the Network panel and preserve the log. Filter for the analytics endpoint. Perform one action at a time.

Inspect the event type, recorded URL, initiator, and request timing. Two near-simultaneous pageview requests for the same route suggest duplicate emitters. One initial document request and one analytics request are not duplicates; they serve different purposes.

A tracker may batch events, so inspect payloads rather than counting HTTP requests alone. One request can contain several events.

## Understand browser history events

Calling `history.pushState()` changes history without loading a document. It does not itself dispatch a `popstate` event. Back and forward navigation can dispatch `popstate`.

This standalone diagnostic logs back and forward events:

~~~javascript
window.addEventListener("popstate", () => {
  console.log("History traversal", window.location.pathname);
});
~~~

It is not a complete SPA pageview implementation. Your router can expose a navigation callback that covers its own transitions more reliably than a partial history listener.

Use the framework's cleanup mechanism when registering listeners. A remounted component that adds another subscription can create duplicates only after navigating several times.

## Give one layer ownership

Choose the automatic tracker or a documented manual integration as the pageview owner. Use custom events for interactions that are not pageviews.

Normalize URLs deliberately. A query parameter containing a campaign can matter to attribution; a transient filter value may fragment page reports. Do not strip parameters before the tracker has extracted the campaign data it needs.

The [event schema guide](/blog/analytics-event-naming-schema) helps separate interactions from completed outcomes.

## Verify the fix through the same sequence

Repeat the five actions with a fresh browser session and a preserved network log. Assert the literal expected number of pageview events for each action.

Then inspect the recorded paths in the dashboard after ingestion. Check for duplicate initial loads, missing back navigation, and sensitive query parameters.

Collection can still be blocked by browser extensions or network conditions. That limitation affects coverage, but it does not excuse emitting two events for a navigation you observe.

## References

- [Plausible SPA support](https://plausible.io/docs/spa-support)
- [Browser pushState behavior](https://developer.mozilla.org/en-US/docs/Web/API/History/pushState)
- [Browser popstate behavior](https://developer.mozilla.org/en-US/docs/Web/API/Window/popstate_event)
