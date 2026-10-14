---
title: "Track UTM campaigns without fragmenting analytics page reports"
description: "Define campaign parameters, preserve attribution during collection, and normalize page URLs without collecting tokens or personal data."
slug: "utm-attribution-clean-urls"
published_at: "2027-01-25T09:00:00Z"
cluster: "analytics"
intent: "informational"
keywords:
  - "UTM campaign tracking clean URLs"
  - "analytics query parameter normalization"
  - "UTM attribution debugging"
internal_links:
  - "/analytics"
  - "/blog/analytics-event-naming-schema"
  - "/blog/spa-pageview-duplicates"
sources:
  - "https://plausible.io/docs/custom-query-params"
  - "https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams"
---

Campaign parameters answer where a visit came from. Page paths answer what the visitor viewed. Mixing these dimensions can turn one pricing page into dozens of rows.

Keep campaign extraction and page normalization as separate decisions. If you remove UTM parameters before collection, the tracker may lose the campaign evidence.

## Define a small campaign vocabulary

Use stable, lowercase values for source, medium, and campaign. An illustrative newsletter link is:

~~~text
https://app.example.com/pricing?utm_source=newsletter&utm_medium=email&utm_campaign=launch_notes
~~~

Agree whether “email” and “e-mail” are the same medium before sending links. Case and spelling drift can split a campaign across several values.

Do not put a recipient's email address or account ID in a campaign parameter. A campaign names a group or initiative, not a person.

Keep campaign names useful outside the team that created them. Include an initiative or date convention where it helps interpretation, without encoding secrets.

## Inspect the URL the tracker sees

Redirects can preserve, remove, or replace query parameters. A link shortener can add another redirect. A single-page router can rewrite the URL before the analytics script loads.

Open the final page and inspect `location.href`. Then inspect the analytics payload. Do not assume the URL in a marketing email is the URL recorded by the tracker.

A landing page can return 200 while a client redirect strips the campaign before collection. That makes network inspection essential.

## Separate extraction from display normalization

This standalone JavaScript example illustrates an allowlist:

~~~javascript
function campaignAndPage(input) {
  const url = new URL(input);
  const campaign = {};
  for (const key of ["utm_source", "utm_medium", "utm_campaign"]) {
    const value = url.searchParams.get(key);
    if (value) campaign[key] = value.slice(0, 100);
  }
  return {
    campaign,
    page: url.origin + url.pathname
  };
}

console.log(campaignAndPage(
  "https://app.example.com/pricing?utm_source=newsletter&token=TEST_ONLY"
));
~~~

The page value omits the query, and only allowed campaign fields are extracted. This is a conceptual projection, not an instruction to replace your tracker's API.

Some query parameters define real content, such as a catalogue category. Removing every query can merge pages you intend to distinguish. Declare those cases separately and verify support for custom URL reporting.

## Avoid changing the URL too early

Cleaning the address bar with `history.replaceState` can be appropriate after attribution is captured, but timing depends on the tracker. Do not assume a fixed delay proves collection.

If the tracker reads the current URL at send time, an early cleanup can remove campaign evidence. If it captures the landing URL earlier, the behavior may differ.

Use the documented integration path rather than racing a script with a timeout. The [SPA pageview guide](/blog/spa-pageview-duplicates) helps diagnose router interactions.

## Verify a controlled campaign

Create a test campaign with a distinctive name. Visit once with its tagged link, once without tags, and once through the production redirect path.

Check the recorded campaign, page path, and event count. Confirm that no token-like parameters appear in the payload. A URL allowlist should not create duplicate pageviews.

Traffic classification is not an authoritative identity system. Referrer policies, blockers, and copied links can change what attribution is available.

## Use results within their limits

[PostDeploy analytics](/analytics) provides aggregate traffic and events. Verify its supported campaign dimensions before designing a campaign report.

Use the [event schema](/blog/analytics-event-naming-schema) to connect campaign traffic with clearly defined interactions. For account or revenue outcomes, use suitable application records and a declared attribution policy.

A clean page report and a campaign report can coexist. The requirement is a deliberate collection contract, demonstrated with one tagged visit.

## References

- [Plausible query parameter handling](https://plausible.io/docs/custom-query-params)
- [Browser URLSearchParams](https://developer.mozilla.org/en-US/docs/Web/API/URLSearchParams)
