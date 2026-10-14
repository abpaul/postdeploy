# 4. Public status pages separate observation from declaration

Status: Superseded by [ADR 0006](0006-public-project-page.md) (2026-08-25)

## Context

Monitor already owns health observations, incident state, uptime math, and
maintenance pauses. Customers also need a stable public page that explains
what an outage means. A public page must not copy monitoring state or expose
monitor configuration.

## Decision (historical)

Add `Alplus.Status` as a domain beside `Alplus.Monitoring`. A StatusComponent
reads existing monitors. Its public state is the worst member state, with
maintenance taking precedence. A fixed ninety-day history uses daily rollups
and computes today with the existing `Alplus.Monitoring.Uptime` function.

The machine reports observations. A human declares meaning. A
`StatusIncident` stores customer-facing title and body beside the detected
`Alplus.Monitoring.Incident`; it does not add prose fields to Monitoring or
create rows from the check hot path. When a linked detected incident resolves,
an idempotent worker posts one recovery update. It leaves the public incident
open until a human resolves it, and the recovery has no actor or audit entry.

Render `/status/:status_slug` with a controller and HEEx. Resolve the slug
into a scoped public actor and read through explicit Ash actions. Unknown,
unpublished, empty, and inactive-plan pages all return the same 404. Cache
the read for thirty seconds and rate-limit each page with Hammer. The feed
and embed use the same snapshot.

The embed has a separate sessionless and CSRF-free router pipeline. It omits
`X-Frame-Options` and sets `frame-ancestors *`. This exception is safe because
the route has no session, cookies, or authenticated action. Every other route
keeps `frame-ancestors 'none'`.

## Consequences

Operators publish the narrative they want customers to see. Monitor remains
the only source of health truth and pause semantics. Lapsed-plan pages go
dark instead of serving stale operational claims. Status pages cannot use
custom domains, subscribers, uploads, or response-time charts yet.
