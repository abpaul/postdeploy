# 3. Public Measure dashboards use scoped bearer actors

Status: Accepted (2026-08-21)

## Context

An operator needs to share selected Measure results without creating an
account. A public route must not bypass tenant policies or expose disabled
panels through hidden queries.

## Decision

Create one share per Measure Source. Store only a SHA-256 token hash and a
short lookup prefix. Return the raw `shr_` token only when an owner creates or
rotates the share.

Resolve the token into an actor scoped to the share, organization, project,
Source, and enabled panels. Read public data through explicit Ash actions.
Return the same 404 for an invalid token, a revoked Source, and an inactive
plan.

Render `/share/:token` through a Phoenix controller. Do not use LiveView. Fetch
only enabled panels. Apply a fixed per-share request limit. Cache each panel
for 30 seconds with the share update time in the key.

## Consequences

Token rotation invalidates the old URL immediately. A disabled panel cannot
reach its query action. Public pages remain read-only and have no account or
navigation state.
