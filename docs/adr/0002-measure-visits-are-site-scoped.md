# 2. Measure visits are site-scoped

Status: Accepted (2026-08-16)

## Context

A Measure project can contain several Measure Sources. Each Source is one
site and can share an environment with another site in the project. A visit
controls the first landing page and aggregate visit counts.

## Decision

Key the 30-minute in-memory Measure visit state by `{source_id, visitor_hash}`.
Do not key it only by project.

## Consequences

The same browser reaching two sites in one project starts one visit per site.
Each site records its own first landing page. Measure keeps no durable visitor
identifier, raw hit, IP address, or user agent.
