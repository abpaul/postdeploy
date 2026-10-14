# 1. Unified telemetry Sources

Status: Accepted (2026-08-16)

## Context

PostDeploy ships three products with three inconsistent models for "where data belongs".

- **Monitor** (pull). PostDeploy probes the customer endpoint. A monitor carries an
  `environment` string, but the create form offers only a dropdown of
  environments that already exist on other monitors in the project. A new
  project starts empty, so a user cannot create the first environment. The
  field is vestigial and its creation UX is a dead end.
- **Observe** (push). The customer SDK posts errors and sessions. Requests
  authenticate with a manually created API key. The key carries the
  environment, and the server derives environment from the key, never from the
  client payload (ARCHITECTURE.md §4/§8, anti-spoofing). One key per
  environment.
- **Measure** (push). The customer beacon posts analytics. The endpoint is
  public and unauthenticated. It identifies the project by the raw project id
  sent as `site`. It has no credential and no environment at all.

The result: a broken "create an environment" flow on Monitor, manual key
management on Observe, and no environment support on Measure. The concept a
user actually wants is a single, nameable container per environment.

## Decision

Introduce one first-class entity, the **Source**: a named, environment-scoped
container for one product's data in one project. A project is a set of Sources.

Resolved decisions:

1. **Granularity.** One active Source per `(product, environment)` for
   Observe and Monitor. "Production Observe", "Staging Observe", and so on.
   Measure is the exception (issue #34, Model A, superseding the original
   text of this decision): a Measure Source is a first-class site, so a
   project may hold several active Measure Sources, including two that
   share one environment. Observe and Monitor keep the one-active-Source-
   per-environment constraint.
2. **Measure gains environments.** Each Measure Source is per environment and
   carries its own public token and snippet. This is new capability.
3. **Monitor Sources carry an environment.** The environment becomes a
   first-class attribute of the Source, replacing the broken dropdown.
4. **Drop standalone API keys.** No meaningful production usage exists, so the
   credential becomes an auto-generated property of a Source, not a separate
   object. No key migration is needed.
5. **Credential lifecycle per Source.** Reveal once, rotate, revoke.
6. **Tags are out of scope.** Drop tags for now. Sources carry the
   environment. Cross-cutting labels may return later as a separate concern.
7. **Provision on demand only.** Create no Sources automatically. The create
   flow carries guiding copy that explains a Source and when to add one.
8. **Mint a new per-Source token.** Each Source gets its own token so it can
   carry the environment. Do not reuse `project.public_token`.

Each Source auto-mints its own credential on creation:

- **Observe Source**: a secret ingest key.
- **Measure Source**: a public token plus snippet.
- **Monitor Source**: no ingest credential (pull). Heartbeats keep their
  per-monitor token.

Environment stays **server-trusted**. The credential (or Measure token)
identifies the Source, and the Source's environment is authoritative. A
payload-supplied environment is still ignored, which preserves ARCHITECTURE.md
§4/§8.

## Consequences

- Onboarding is zero-config: create a project, Sources and credentials exist,
  the SDK works.
- "Create an environment" becomes "create a Source": concrete, nameable, and it
  removes the dead-end dropdown.
- The anti-spoofing boundary is preserved. The Source is trusted, the payload
  is not.
- The API keys resource and UI are removed. A Sources resource and UI replace
  them, with per-product credential handling.
- Measure ingest must resolve the Source (and its environment) from a token
  instead of the raw project id. Measure rollups and analytics gain an
  environment dimension.
- Monitor environment stops being vestigial. The distinct-value dropdown is
  removed.
- Ingest controllers resolve the Source and its trusted environment from the
  credential or token.

## Alternatives considered

- **Keep API keys, add monitor tags only.** Rejected. It leaves three
  inconsistent models and keeps the create-environment dead end.
- **Move environment into the event payload, one key per project.** Rejected.
  It violates ARCHITECTURE.md §4/§8, because the client could then lie about
  its environment.
- **Make "Environment" the top-level object.** Rejected. Decision 1 places one
  Source per product per environment, so environment groups Sources rather than
  being a single object.

## Naming

Chose **Source** over "box". It is the standard term for a configured origin of
telemetry (Datadog, Grafana, Vector), and it reads across both the pull
(Monitor) and push (Observe, Measure) products. Runners-up: Stream, Feed.
