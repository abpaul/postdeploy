---
title: "Calculate conversion rates with a consistent denominator"
description: "Avoid dividing repeated events by daily visitors. Define cohort, time window, and identity before calculating an analytics conversion rate."
slug: "analytics-funnel-denominators"
published_at: "2026-11-30T09:00:00Z"
cluster: "analytics"
intent: "informational"
keywords:
  - "conversion rate denominator"
  - "events vs unique conversions"
  - "cookieless analytics conversion rate"
internal_links:
  - "/analytics"
  - "/blog/analytics-event-naming-schema"
  - "/guides/why-analytics-tools-disagree"
sources:
  - "https://plausible.io/docs/goal-conversions"
  - "https://plausible.io/data-policy"
---

A conversion rate is a fraction with a contract. The numerator and denominator must describe compatible populations. Dividing download events by visitors can produce a value above 100 percent when one visitor downloads several files.

Decide whether you want an event ratio, a session conversion rate, or an account conversion rate. These answer different questions and require different data.

## Write the fraction in words first

An illustrative acquisition question is: “Of accounts created in November, how many completed setup within seven days?”

The denominator is accounts created in that month. The numerator is those same accounts with a qualifying setup completion inside the stated window. Both use the same account identity.

Another question is: “How many signup submissions occurred per 1,000 landing pageviews?” This is a useful event ratio, but it is not the probability that a visitor signed up.

Keep those names explicit in reports. A percentage sign does not make mismatched units comparable.

## Calculate a cohort from application data

For an authoritative account cohort, use your application records. This illustrative PostgreSQL query assumes one row per account and a stored first setup timestamp:

~~~sql
WITH cohort AS (
  SELECT id, created_at, first_setup_completed_at
  FROM accounts
  WHERE created_at >= TIMESTAMPTZ '2026-11-01T00:00:00Z'
    AND created_at < TIMESTAMPTZ '2026-12-01T00:00:00Z'
)
SELECT
  count(*) AS created_accounts,
  count(*) FILTER (
    WHERE first_setup_completed_at >= created_at
      AND first_setup_completed_at < created_at + INTERVAL '7 days'
  ) AS completed_accounts,
  round(
    100.0 * count(*) FILTER (
      WHERE first_setup_completed_at >= created_at
        AND first_setup_completed_at < created_at + INTERVAL '7 days'
    ) / NULLIF(count(*), 0),
    2
  ) AS completion_percent
FROM cohort;
~~~

Adapt the schema rather than copying the table names. Run this only after every account has had its seven-day observation window. Otherwise recent accounts have less opportunity to complete setup.

A zero denominator returns null. Label it “no eligible accounts” rather than reporting zero percent.

## Respect cookieless identity limits

An analytics service may use a daily visitor identifier that cannot link a person across days. Adding daily unique visitor counts can therefore count the same person more than once.

That design can support aggregate traffic trends while limiting cross-day funnels. It does not make the analytics broken. It changes the questions the data can answer.

Do not infer an account cohort from anonymous visitor totals. Use aggregate analytics for acquisition patterns and your application database for account outcomes, within your privacy commitments.

[PostDeploy analytics](/analytics) provides pageviews and custom events. It does not provide a built-in goal conversion product. Perform calculations from suitable exports or application data instead of assuming a funnel dashboard.

## Check collection coverage

Browser events can be blocked or lost. Server records can include test accounts, imported accounts, or automated activity. Declare exclusions for each data source.

Use [stable event definitions](/blog/analytics-event-naming-schema) so “submitted” and “completed” remain separate. Inspect duplicates before deduplicating them; repeated events might describe repeated legitimate actions.

Compare equal time zones and closed windows. A rolling seven-day report is different from a calendar week report.

## Verify with a tiny known cohort

Create a fixture with ten eligible accounts: four complete within seven days, one completes later, and five never complete. The expected rate is 40 percent.

Run the same calculation with no accounts and with accounts near the observation boundary. These tests catch denominator and time-window errors better than comparing two large dashboard totals.

When tools disagree, the [analytics disagreement guide](/guides/why-analytics-tools-disagree) helps distinguish measurement definitions from transport failures.

## References

- [Plausible goal conversion definitions](https://plausible.io/docs/goal-conversions)
- [Plausible data policy](https://plausible.io/data-policy)
