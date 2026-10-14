import { strict as assert } from "node:assert";
import { test } from "node:test";

import { inspectCronLine, probe, redactUrl, validateUrl } from "../src/checks.js";

// A stub `fetch` that returns a fixed response or throws a fixed error, so
// every branch of the diagnostic is exercised without a network.
const respondWith = (status) => async () => ({ status });
const failWith = (error) => async () => {
  throw error;
};

test("redactUrl masks the token but keeps the provider identifiable", () => {
  const redacted = redactUrl("https://ingest.postdeploy.dev/h/hb_supersecrettoken");

  assert.ok(redacted.includes("ingest.postdeploy.dev"), "provider host should survive");
  assert.ok(!redacted.includes("supersecrettoken"), "token must not be printed");
  assert.ok(redacted.includes("hb_***") || redacted.includes("hb_"), "prefix helps identify the token");
});

test("redactUrl masks a token carried in the query string", () => {
  const redacted = redactUrl("https://example.com/ping?token=secretvalue");
  assert.ok(!redacted.includes("secretvalue"));
});

test("redactUrl survives an unparseable URL", () => {
  assert.equal(redactUrl("not a url"), "<invalid url>");
});

test("validateUrl rejects nonsense and non-HTTP schemes", () => {
  assert.equal(validateUrl("not a url").ok, false);
  assert.equal(validateUrl("ftp://example.com/ping").ok, false);
});

test("validateUrl warns about http:// without rejecting it", () => {
  // Plenty of self-hosted endpoints are plain HTTP on a private network.
  // That is a warning, not a refusal to help.
  const result = validateUrl("http://example.com/ping");

  assert.equal(result.ok, true);
  assert.equal(result.warning, "insecure_scheme");
});

test("probe reports a 2xx as accepted", async () => {
  const result = await probe("https://example.com/ping", { fetchImpl: respondWith(202) });

  assert.equal(result.outcome, "accepted");
  assert.equal(result.status, 202);
});

test("probe explains a 404 as an unrecognised token", async () => {
  const result = await probe("https://example.com/ping", { fetchImpl: respondWith(404) });

  assert.equal(result.outcome, "unknown_token");
  assert.match(result.hint, /truncated when copied|mistyped/);
});

test("probe distinguishes rate limiting and provider errors", async () => {
  assert.equal((await probe("https://x/p", { fetchImpl: respondWith(429) })).outcome, "rate_limited");
  assert.equal((await probe("https://x/p", { fetchImpl: respondWith(503) })).outcome, "provider_error");
});

test("probe names blocked egress when the request times out", async () => {
  const abort = Object.assign(new Error("aborted"), { name: "AbortError" });
  const result = await probe("https://example.com/ping", { fetchImpl: failWith(abort), timeoutMs: 50 });

  assert.equal(result.outcome, "timeout");
  // The container case is the one people actually hit: job succeeds, ping
  // never leaves the network.
  assert.match(result.hint, /egress is blocked/);
});

test("probe recognises DNS failure and connection refusal", async () => {
  const dns = Object.assign(new Error("getaddrinfo"), { cause: { code: "ENOTFOUND" } });
  const refused = Object.assign(new Error("refused"), { cause: { code: "ECONNREFUSED" } });

  assert.equal((await probe("https://x/p", { fetchImpl: failWith(dns) })).outcome, "dns_failure");
  assert.equal((await probe("https://x/p", { fetchImpl: failWith(refused) })).outcome, "connection_refused");
});

test("probe times out rather than hanging forever", async () => {
  // A real hang, not a stubbed error: the AbortController must fire.
  const hang = () => new Promise(() => {});
  const result = await probe("https://example.com/ping", { fetchImpl: hang, timeoutMs: 30 });

  assert.equal(result.outcome, "timeout");
});

test("inspectCronLine flags a commented-out job", () => {
  const [finding] = inspectCronLine("# 0 3 * * * /usr/local/bin/backup.sh");

  assert.equal(finding.code, "commented_out");
  assert.equal(finding.level, "error");
});

test("inspectCronLine flags a ping that reports success unconditionally", () => {
  // The worst case: a permanently broken job that looks healthy forever.
  const findings = inspectCronLine('0 3 * * * /usr/local/bin/backup.sh; curl -fsS https://example.com/ping');

  const finding = findings.find((f) => f.code === "ping_always_succeeds");
  assert.ok(finding, "should flag an unconditional ping");
  assert.equal(finding.level, "error");
});

test("inspectCronLine accepts an exit-code ping as intentional", () => {
  const findings = inspectCronLine('0 3 * * * /usr/local/bin/backup.sh; curl -fsS "https://example.com/ping/$?"');

  assert.ok(!findings.some((f) => f.code === "ping_always_succeeds"));
});

test("inspectCronLine notes that && pings only on success", () => {
  const findings = inspectCronLine("0 3 * * * /usr/local/bin/backup.sh && curl -fsS https://example.com/ping");

  const finding = findings.find((f) => f.code === "ping_on_success_only");
  assert.ok(finding);
  // Correct, but worth explaining: failures stay silent until the grace
  // period expires.
  assert.equal(finding.level, "info");
});

test("inspectCronLine warns about curl without -f", () => {
  const findings = inspectCronLine("0 3 * * * /usr/local/bin/backup.sh && curl -s https://example.com/ping");

  assert.ok(findings.some((f) => f.code === "curl_without_fail"));
});

test("inspectCronLine warns about a relative command", () => {
  // cron's PATH is far smaller than a login shell's, which is the classic
  // "works in my terminal" failure.
  const findings = inspectCronLine("0 3 * * * backup.sh && curl -fsS https://example.com/ping");

  assert.ok(findings.some((f) => f.code === "relative_command"));
});

test("inspectCronLine does not warn about an absolute command", () => {
  const findings = inspectCronLine("0 3 * * * /usr/local/bin/backup.sh && curl -fsS https://example.com/ping");

  assert.ok(!findings.some((f) => f.code === "relative_command"));
});

test("inspectCronLine flags an unescaped percent, which truncates the command", () => {
  const findings = inspectCronLine('0 3 * * * /usr/bin/date +%Y && curl -fsS https://example.com/ping');

  const finding = findings.find((f) => f.code === "unescaped_percent");
  assert.ok(finding);
  assert.equal(finding.level, "error");
});

test("inspectCronLine reports a clean line as clean", () => {
  const findings = inspectCronLine('0 3 * * * /usr/local/bin/backup.sh; /usr/bin/curl -fsS "https://example.com/ping/$?"');

  assert.deepEqual(
    findings.map((f) => f.code),
    ["no_issues"],
  );
});
