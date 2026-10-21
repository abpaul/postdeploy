<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="rust-web/assets/static/brand/postdeploy-mark-white.svg">
    <img src="rust-web/assets/static/brand/postdeploy-mark-black.svg" alt="" width="72">
  </picture>
</p>

<h1 align="center">PostDeploy</h1>

<p align="center">
  Your coding agent can read your code. Now it can read production.<br>
  Errors, logs and deployments for teams that debug with coding agents.
</p>

<p align="center">
  <a href="https://postdeploy.dev">Website</a> ·
  <a href="https://postdeploy.dev/register">Start a free trial</a> ·
  <a href="#run-locally">Run locally</a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="AGPL-3.0 license" src="https://img.shields.io/badge/license-AGPL--3.0-blue"></a>
  <a href="rust-web/rust-toolchain.toml"><img alt="Built with Rust" src="https://img.shields.io/badge/built_with-Rust-dea584"></a>
  <a href="https://postdeploy.dev/docs/quickstart"><img alt="Works with Sentry SDKs" src="https://img.shields.io/badge/Sentry_SDKs-compatible-4b7561"></a>
</p>

PostDeploy stores the errors, logs and deployments of your applications and lets your coding agent read them over MCP. Your application keeps its Sentry SDK and sends to a PostDeploy DSN. Your CI records each deployment. One agent call returns an error with its stack trace, up to 50 related logs and the deployment that was live.

Use the hosted application at [postdeploy.dev](https://postdeploy.dev), or run the source locally. To leave, change the DSN back.

## What you can do

- **Keep your Sentry SDK.** Point it at a PostDeploy DSN. Node.js sends errors and structured logs. Python, Ruby and Elixir send errors. A test event on the source page checks the path before you deploy.
- **Read errors with their logs.** Errors are grouped into issues that you search, filter by severity and status, and resolve. Each error links to the logs that share its trace ID, then its request ID, then its service and release. The result says which match it used.
- **Search and tail logs.** Search by text, level and time range, or follow new log lines live.
- **Compare deployments.** Record each deployment from CI with one HTTP call. Compare error events per minute before and after it, and check whether an issue came back.
- **Connect your agent.** Add the MCP server to Claude Code, Codex or another MCP client. You approve each connection in the browser and choose its access. New connections can only read. Agents can also publish an investigation report for a project, with every finding linked to its evidence.
- **Get notified.** Send email or a signed webhook when an issue is new, an issue regresses, or an agent publishes a report.
- **Control what is stored.** Credentials are redacted before storage. Owners and admins add sensitive field names, choose stored log levels, exclude exception types and sample errors and logs.
- **Work as a team.** Invite members as members or admins, and give API keys only the scopes they need. Keys expire after 30 days by default and after 90 days at most.

## Get your first error

1. [Create an account](https://postdeploy.dev/register), then create an organization.
2. Create a project for your application and a source for one environment, such as production. Copy the DSN from the source page. It is shown once.
3. Add the DSN to your Sentry SDK and select **Send test event** on the source page.
4. Connect your agent:

   ```sh
   claude mcp add --transport http postdeploy https://postdeploy.dev/mcp
   ```

   Your browser opens. Choose the organization and the access, then ask your agent what broke.

The hosted application includes a 14-day trial with no credit card. The trial starts when you create the organization. After the trial, the plan is $449 per year per organization with 1,000,000 error events and 100 GB of logs per month, 90-day retention, and unlimited projects and members. When an allowance is used up, PostDeploy refuses new data of that type until the next month. Nothing is billed on top of the plan. See [current pricing](https://postdeploy.dev/pricing).

## Hosted application or local source

| | [postdeploy.dev](https://postdeploy.dev) | This repository |
| --- | --- | --- |
| Getting started | Create an account and copy a DSN | Install Rust and Credseal, then start the application |
| Hosting and updates | Managed for you | You operate and maintain the application |
| Storage | Configured for the hosted application | Provide your own R2 bucket |
| Email, billing and sign-up checks | Configured for the hosted application | Optional. Configure your own SMTP, Stripe and Turnstile credentials |

This repository contains the application source, migrations and tests under [AGPL-3.0-only](LICENSE). It receives source snapshots. Real credentials are excluded.

## Run locally

You need:

- [Rust through rustup](https://rustup.rs/). The pinned toolchain is installed on the first Cargo command.
- The [Credseal CLI](https://github.com/abpaul/credseal).
- A dedicated R2 test bucket with an access key.

Clone the repository and create your development credentials:

```sh
git clone https://github.com/abpaul/postdeploy.git
cd postdeploy/rust-web
credseal edit --app postdeploy --environment development --directory config/credentials
```

Enter these fields in the editor with your own values:

```toml
[r2]
endpoint = "https://<account-id>.r2.cloudflarestorage.com"
bucket = "<dedicated-test-bucket>"
access_key_id = "<test-access-key>"
secret_access_key = "<test-secret-key>"

[security]
data_key = "<Base64 of 32 random bytes>"
```

Credseal writes `config/credentials/development.toml.enc` and `config/credentials/development.key`. Keep the key private and back it up. Check the file, then start the application:

```sh
credseal validate --app postdeploy --environment development --directory config/credentials
./scripts/dev.sh
```

Open http://127.0.0.1:5167 and create a local account. Stop with `Ctrl+C`. The first run compiles the application. Accounts and projects are stored in `data/development/`. Stored objects go under the `local-verification/dev/` prefix of your bucket. Set `POSTDEPLOY_STORAGE_PREFIX` to another `local-verification/<name>/` prefix when you share the bucket.

Email needs an `[smtp]` section. Checkout and the billing portal need a `[stripe]` section. Without Stripe, trials still work. The fields are in [`rust-web/README.md`](rust-web/README.md#prepare-isolated-test-credentials).

## Development

Run the checks from `rust-web` before you commit. CI runs the same commands.

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 -B scripts/test_dev.py
```

The default tests need no credentials. They use an in-memory object store and keep their databases under `POSTDEPLOY_TEST_ROOT`. Ignored tests use real R2 or external services.

| Read | For |
| --- | --- |
| [Quickstart](https://postdeploy.dev/docs/quickstart) | DSN setup and tested SDK versions |
| [Agent setup](https://postdeploy.dev/docs/agents) | MCP clients, approval and access scopes |
| [HTTP API](https://postdeploy.dev/docs/api) | Endpoints, scopes and deployment records |
| [Usage and retention](https://postdeploy.dev/docs/usage) | Allowances, limits and data retention |
| [Application README](rust-web/README.md) | Local runs, ingestion, log storage, backups and agent access |
| [Contributing](CONTRIBUTING.md) | How changes reach the public source snapshot |
| [Agent instructions](AGENTS.md) | Rules for user-facing copy |

<details>
<summary>Tested SDK versions</summary>

| Language | Package | Version | Tested data |
| --- | --- | --- | --- |
| Node.js | `@sentry/node` | 11.6.0 | Errors and structured logs |
| Python | `sentry-sdk` | 2.72.0 | Errors |
| Ruby | `sentry-ruby` | 7.1.0 | Errors |
| Elixir | `sentry` | 14.0.0 | Errors |

Other SDKs and versions are not tested. Check the source page before you depend on logs from Python, Ruby or Elixir.

</details>
