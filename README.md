# PostDeploy

One repository: the SaaS application, the MCP server, and the three
first-party SDKs.

```text
lib/alplus/          domains (Observe, Measure, Monitoring, Mcp, Billing, ...)
lib/alplus_web/      Phoenix endpoint, LiveViews, ingest controllers
sdks/contract/       golden wire fixtures the product owns
sdks/elixir/         postdeploy_sdk   (Hex)
sdks/javascript/     @postdeploy/sdk  (npm)
sdks/ruby/           postdeploy       (RubyGems)
docs/                architecture, build, runbooks, ADRs
```

Clone once and everything is editable together. Each SDK keeps its own
version, tests and registry release; each publishes from its own directory
when you push its namespaced tag (`elixir-v*`, `js-v*`, `ruby-v*`). CI is
path-filtered, so an SDK change does not run the Phoenix suite, and a contract
change runs all four. See [`AGENTS.md`](AGENTS.md) for the SDK rules and each
SDK's README for its public API.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Working in this repo

Read [`docs/BUILD.md`](docs/BUILD.md) and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before making changes. They are
the authoritative project documents for implementation constraints, tenant
scoping, deployment, and architecture.

## Changelog workspace

Use the organization-qualified Streamable HTTP MCP endpoint at
`POST /mcp/org/:org_public_token` for agent work across all current and future
projects. Connect the MCP client through OAuth: sign in, confirm the organization,
and approve Read or Read and write access. The client transports its issued OAuth
access token in the `Authorization` header; users never copy a manual MCP token.
MCP 2026-07-28 uses an OAuth authorization server and resource server. The flow
records the approved grant and scopes, exchanges authorization codes for short-lived
access tokens and refresh tokens, and binds them to the selected organization and
project. Authorization codes and token secrets are stored only as SHA-256 hashes
with lookup prefixes; raw values are returned only by the OAuth flow.
See [`docs/mcp-oauth.md`](docs/mcp-oauth.md) for the complete discovery,
authorization, token, scope, revocation, security, and operational design.
Review entries at `/dashboard/orgs/:org_token/projects/:project_token/changelog`.
Serve public changelogs as HTML, RSS, or JSON.
Return 404 for archived entries and 410 for permanently deleted entries.

## Visual inspection account

Create the deterministic development workspace before inspecting authenticated
screens in a browser:

```sh
mix run priv/repo/visual_seed.exs
```

The script is idempotent and refuses to run outside `MIX_ENV=dev`. It prints the
status-page editor URL after creating the local workspace.

- Email: `visual-review@example.com`
- Password: `visual-review-only`
- Sign in: [`localhost:4000/sign-in`](http://localhost:4000/sign-in)

Use this account only with the local development database. Never copy it to a
staging or production environment.

## Local release check

Run this before a production deploy:

```sh
docker compose -f compose.release.yml up --build --abort-on-container-exit
curl -fsS http://localhost:3000/health
docker compose -f compose.release.yml down --volumes
```

The release image runs migrations in a dedicated `migrate` container before
the web container starts. `compose.release.yml` uses only disposable Postgres
and MinIO containers. Copy no values from `env.release.example` to production.

## Configuration

Production reads its settings from the environment. `config/runtime.exs` lists
every variable and stops the boot when a required one is missing.

Stripe Billing requires these variables:

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_PRICE_POSTDEPLOY_MONTHLY` (the $29 monthly price id)
- `STRIPE_ENVIRONMENT` (`staging` or `production`)

Stripe webhooks target `POST /webhooks/stripe`. The endpoint verifies the raw
Stripe signature and rejects a live/test mode mismatch.

## License

PostDeploy is licensed under the [GNU Affero General Public License v3.0](LICENSE).
Read [`CONTRIBUTING.md`](CONTRIBUTING.md) to learn how a change gets into this repository.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
