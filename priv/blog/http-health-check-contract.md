---
title: "Design an HTTP health check that detects real outages"
description: "Define status, response content, dependencies, and timeouts for HTTP health checks. Test failure modes before trusting a green monitor."
slug: "http-health-check-contract"
published_at: "2026-10-12T09:00:00Z"
cluster: "uptime"
intent: "informational"
keywords:
  - "http health check endpoint"
  - "readiness vs liveness"
  - "uptime health checks"
internal_links:
  - "/monitoring/uptime"
  - "/monitoring/api"
sources:
  - "https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/"
  - "https://curl.se/docs/manpage.html"
---

A health endpoint needs a contract. A successful response should mean that a specific capability works within a defined deadline. A route that always returns 200 can prove that one process answers HTTP while the application cannot serve customers.

Start with the operation you care about. For a read-only catalogue, check that the application can retrieve catalogue data. For a static site, check the delivered page and a stable content marker. A database dependency belongs in a check only when its failure makes that capability unavailable.

## Separate restart decisions from traffic decisions

Liveness asks whether restarting a process could help. Readiness asks whether the instance can accept traffic. An external uptime check asks whether a user-facing path is reachable from the monitoring location.

These checks can disagree without any of them being broken. During a database outage, a process can be alive but unready. Restarting every instance may increase load without fixing the database. An external check can also fail because of DNS, TLS, or routing before the application receives a request.

Use separate endpoints when these decisions need different evidence. Do not make a restart check depend on every third-party service.

## Write the response contract

For an API backed by a database, an illustrative contract is:

~~~text
GET /ready
200 application/json {"status":"ready"}
503 application/json {"status":"unavailable"}
Deadline: 2 seconds, including dependency checks
~~~

Return a small response. Put detailed dependency failures in restricted logs. Do not expose connection strings, stack traces, or account identifiers on a public endpoint.

A check should perform bounded work. A cheap database query can test connectivity, but it cannot prove that every business operation succeeds. Avoid writing records or calling a paid API on each probe.

## Check status and content independently

This shell example requires curl and Python 3. Replace the example URL with an endpoint you control.

~~~sh
curl --fail --silent --show-error \
  --connect-timeout 2 --max-time 5 \
  https://app.example.com/ready |
python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("status") != "ready":
    raise SystemExit("unexpected readiness response")
'
~~~

Run the pipeline under Bash with `set -o pipefail` when you need its exit status to reflect either command. A login redirect can return HTML with a successful HTTP status. Parsing the expected JSON rejects that response.

A keyword check offers a simpler option for an HTML page. Choose a marker that distinguishes your application from a CDN error page. A broad marker such as “html” gives little evidence.

## Test the monitor's failure path

Use a disposable environment. Confirm that the monitor detects a 503, an unexpected body, a stalled request, and an expired or untrusted test certificate. Then restore the endpoint and confirm recovery.

Record the time between inducing failure and receiving the alert. This observed delay includes polling, confirmation thresholds, timeouts, and notification delivery. A one-minute interval does not guarantee a one-minute alert.

Check the application and CDN paths separately during diagnosis. A cached successful response can hide an unavailable origin. Exclude readiness responses from caching when the contract requires current state.

## Know what remains untested

One external location cannot establish availability from every country or network. A health endpoint cannot establish that checkout, login, or a browser interaction works unless it exercises that path.

[PostDeploy uptime monitoring](/monitoring/uptime) can watch an HTTP response and content. Use [API monitoring](/monitoring/api) for the API contract. Keep a separate acceptance check for operations that require multiple requests.

The practical finish line is a short contract, a bounded probe, and a demonstrated alert. Keep the failure test with the application so a later change cannot quietly weaken the check.

## References

- [Kubernetes probe concepts](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)
- [curl command reference](https://curl.se/docs/manpage.html)
