# 5. Public changelogs use a page surface and frozen entry URLs

Status: Superseded by [ADR 0006](0006-public-project-page.md) (2026-08-25)

## Context

Customers need a stable public place for product updates. The Measure share
decision in ADR 0003 establishes the public-read shape: an explicit scoped
actor, a sessionless controller, a short cache, and a uniform not-found result.

A changelog has two durable objects. The page owns the public slug and the
publication state. An entry owns customer-facing content and its permanent
URL. Engineering source references support draft work but are not public
content.

## Decision (historical)

Model `Alplus.Changelog.Page` as the publishable surface for one project. Keep
the page slug globally unique and reserve it when the page is unpublished. Do
not add a destroy action. Unpublishing clears `published_at`, so a previous
public URL cannot be reassigned to another page.

Model `Alplus.Changelog.Entry` under the page and project. Generate its slug
when it is first published. Keep that slug unchanged when the title changes.
Treat published and archived entries as read-only through the agent API.

Read public pages through the same shape as ADR 0003: use a least-privilege
public actor, a Phoenix controller, a sessionless route, the existing
single-flight cache, and a per-page rate limit. Return one 404 result for an
unknown slug, an unpublished page, a draft or archived entry, a wrong-page
entry, and an organization whose plan no longer resolves.

Apply the plan check to public reads even though changelogs are free on every
tier. A lapsed organization goes dark instead of serving stale product
claims from a PostDeploy-hosted URL.

Expose only customer-facing page and entry fields. Keep source references,
`generated_by`, internal identifiers, organization identifiers, project
identifiers, and author identity out of HTML and embed JSON. Authenticated
changelog Source responses may include source references for engineering use.

## Consequences

Launch announcements can link to an entry without depending on an account or
LiveView socket. Page publication and entry publication invalidate cached
public reads through their timestamps and published-entry snapshot.

An operator cannot reclaim a retired page slug or change a published entry's
URL. A lapsed organization must renew its plan before its public changelog
becomes visible again.
