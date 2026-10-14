# 6. One project Public page owns Status and Changelog

Status: Accepted (2026-08-25)

## Context

Status and Changelog originally carried separate public slugs, branding, and
publication switches. That split let one project expose competing public
identities and made the console present duplicate settings. Migration tickets
#90–#92 backfilled a shared identity and preserved the old public aliases.

## Decision

Each project owns exactly one `Alplus.PublicPages.PublicPage` identity and one
Status workspace. The identity owns the public title, logo, slug, and
publication state. The authenticated project navigation exposes one Public
destination with these durable sections:

- Status: services, incidents, announcements, maintenance, history, and
  operational status work.
- Changelog: entries, activity, and entry review.
- Settings: the shared identity and publication control.

Status and Changelog domain resources retain their project-owned content and
workflow rows, but no longer store duplicate public identity or publication
fields. The database keeps one public identity per project and one Status
workspace per project. The forward contract migration drops the legacy
columns only after the backfill and relationship consolidation.

Authenticated legacy management routes are compatibility redirects into the
Public workspace. Public aliases and old public URLs remain supported; a
changed slug is recorded as an alias and resolves to the same identity.

Public reads resolve the shared identity first, then use the project-scoped
Ash interface for Status or Changelog content. They do not infer publication
from legacy rows. Status-page count capacity is removed because the project
owns one Public page.

## Consequences

Operators edit identity and publication once. Status and Changelog always use
the same public address and branding. Existing public links remain valid, but
old authenticated navigation no longer opens the retired split editors.

Custom domains, uploads, subscriptions, badges, and new white-label features
remain outside this decision.
