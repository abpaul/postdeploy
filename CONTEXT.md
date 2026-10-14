# PostDeploy Domain Context

PostDeploy provides organization-scoped monitoring, analytics, error observation, and billing.

## Billing and organizations

**Organization plan transition**:
The durable change to an Organization's plan identifier and Stripe subscription status after Billing resolves verified Stripe facts.
_Avoid_: Stripe update, subscription sync

**Billing reconciliation**:
The daily comparison of complete Stripe subscription and invoice lists with PostDeploy's durable billing mirror.
_Avoid_: webhook replay, Stripe refresh

**Status page**:
A project-owned public URL that shows current monitor health, uptime history, incidents, and maintenance.
_Avoid_: public dashboard, monitoring clone

**Status component**:
A customer-facing group of project monitors whose public state is the worst state of its members.
_Avoid_: monitor group configuration, private monitor list

**Published incident**:
A human-written public incident narrative with updates, linked to a detected Monitor incident when one exists.
_Avoid_: auto-drafted outage, copied incident state

**Changelog page**:
A project-owned public surface with a reserved slug, display title, optional logo, and publish state.
_Avoid_: public dashboard, shared release feed

**Changelog entry**:
A customer-facing update attached to one changelog page, with a lifecycle state and a stable slug after publication.
_Avoid_: engineering ticket, source-control record

**Published entry**:
A changelog entry whose page and entry are both public, with a publication timestamp and a frozen URL slug.
_Avoid_: draft update, archived announcement
