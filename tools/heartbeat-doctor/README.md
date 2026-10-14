# heartbeat-doctor

Diagnose cron heartbeat monitoring. Verify that a ping URL actually reaches
its monitor, and check a crontab line for the mistakes that let a job fail
silently.

Works with any heartbeat provider (Healthchecks.io, Cronitor, Better Stack,
PostDeploy, or your own endpoint), because a heartbeat URL is just a URL requested
on a schedule. No account, no signup, and the tool sends no telemetry of its
own: it makes exactly the requests you ask it to.

MIT licensed.

## Install

Needs Node 18 or newer. Run it without installing:

```sh
npx heartbeat-doctor ping https://hc-ping.com/your-uuid
```

## Verify a ping URL

```sh
heartbeat-doctor ping https://ingest.postdeploy.dev/h/hb_your_token
```

```
Checking https://ingest.postdeploy.dev/h/hb_***

  PASS  Ping accepted (HTTP 202) in 84ms.

The endpoint recorded this ping. If your monitor still reports late,
the job is not reaching this line: check the schedule and the exit path.
```

Ping URLs are secrets, so the token is masked in all output. You can paste a
result into an issue without leaking your monitor.

Exit status is 0 when the ping was accepted and 1 otherwise, so this works in
a CI step or a pre-deploy check.

### What it distinguishes

| Result | What it usually means |
| --- | --- |
| `unknown_token` (404) | The token is mistyped, was truncated when copied, or belongs to a deleted monitor. |
| `timeout` | Egress is blocked. Common in containers and CI runners: the job succeeds, the ping never leaves the network. |
| `dns_failure` | A typo, or a container with no DNS resolver configured. |
| `connection_refused` | For a self-hosted endpoint, it is not listening or not reachable from here. |
| `rate_limited` (429) | Something is pinging far more often than the schedule. |
| `provider_error` (5xx) | The provider is having problems; the ping probably was not recorded. |

## Check a crontab line

```sh
heartbeat-doctor cron "0 3 * * * backup.sh; curl https://example.com/ping"
```

```
  FAIL  The ping runs whether or not the job succeeded, and does not report
        the exit code, so a permanently failing job will look healthy
        forever. Use `&&`, or send the exit status with `$?`.
  WARN  curl without -f exits 0 even on an HTTP error, so a failing ping
        looks like a successful one. Use `curl -fsS`.
  WARN  The command is not an absolute path. cron runs with a minimal PATH,
        so a command that works in your shell can fail here.
```

It checks for:

- **A ping that always reports success.** `cmd; curl ...` pings whether or
  not the job worked. A permanently broken job looks healthy forever. This is
  the worst failure, because monitoring actively hides the problem.
- **A ping that only reports success.** `cmd && curl ...` is usually correct,
  but a failure stays silent until the grace period expires. Reporting the
  exit code alerts immediately.
- **`curl` without `-f`.** curl exits 0 on an HTTP error, so a failing ping
  looks successful.
- **A relative command.** cron's PATH is much smaller than a login shell's,
  which is the classic "works in my terminal" cron failure.
- **An unescaped `%`.** In a crontab this becomes a newline and truncates the
  command.
- **A commented-out line.**

## Why heartbeats

A cron job that stops running produces no error to catch. There is no failed
request, no exception, and no log line: the observable fact is that nothing
happened, and nothing is hard to notice.

A heartbeat inverts the check. The job reports in when it runs, and silence
past its schedule is the alert. That catches the decommissioned server whose
crontab went with it, the commented-out schedule line, the container that
stopped being scheduled, and the job that hangs forever without exiting.

The recommended shape reports the real exit status, so both failure and
silence are covered:

```sh
0 3 * * * /usr/local/bin/backup.sh; /usr/bin/curl -fsS "https://example.com/ping/$?"
```

## Development

```sh
node --test "test/*.test.js"
```

Checks are pure functions over an injected `fetch`, so every branch is
covered without a network.
