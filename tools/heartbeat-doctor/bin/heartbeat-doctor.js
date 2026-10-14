#!/usr/bin/env node
/**
 * heartbeat-doctor: diagnose cron heartbeat monitoring.
 *
 * Works with any heartbeat provider, because a heartbeat URL is just a URL
 * requested on a schedule. No account, no signup, no telemetry: the tool
 * makes exactly the requests you ask it to and nothing else.
 */

import { inspectCronLine, probe, redactUrl, validateUrl } from "../src/checks.js";

const USAGE = `
heartbeat-doctor - diagnose cron heartbeat monitoring

USAGE
  heartbeat-doctor ping <url>          Send one ping and explain the result
  heartbeat-doctor cron "<crontab>"    Check a crontab line for silent failures
  heartbeat-doctor --help

EXAMPLES
  heartbeat-doctor ping https://ingest.postdeploy.dev/h/hb_token
  heartbeat-doctor ping https://hc-ping.com/your-uuid
  heartbeat-doctor cron "0 3 * * * backup.sh; curl https://example.com/ping"

OPTIONS
  --timeout <ms>   Give up on the request after this long (default 10000)

Ping URLs are treated as secrets and never printed in full.
Works with any provider. No account required, and the tool sends no
telemetry of its own.
`.trim();

const EXIT_OK = 0;
const EXIT_PROBLEM = 1;
const EXIT_USAGE = 2;

function parseArgs(argv) {
  const args = { command: null, target: null, timeoutMs: 10_000 };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    if (arg === "--help" || arg === "-h") return { command: "help" };
    if (arg === "--timeout") {
      const value = Number.parseInt(argv[index + 1], 10);
      if (!Number.isFinite(value) || value <= 0) return { command: "usage_error", detail: "--timeout needs a positive number of milliseconds" };
      args.timeoutMs = value;
      index += 1;
      continue;
    }

    if (!args.command) args.command = arg;
    else if (args.target === null) args.target = arg;
  }

  return args;
}

const symbols = { ok: "PASS", info: "INFO", warning: "WARN", error: "FAIL" };

function line(level, message) {
  console.log(`  ${symbols[level] ?? "----"}  ${message}`);
}

async function runPing(target, timeoutMs) {
  if (!target) {
    console.error("ping needs a URL. See --help.");
    return EXIT_USAGE;
  }

  const validation = validateUrl(target);
  console.log(`\nChecking ${redactUrl(target)}\n`);

  if (!validation.ok) {
    line("error", `${validation.reason}: ${validation.detail}`);
    return EXIT_PROBLEM;
  }

  if (validation.warning) line("warning", validation.detail);

  const result = await probe(target, { timeoutMs });

  switch (result.outcome) {
    case "accepted":
      line("ok", `Ping accepted (HTTP ${result.status}) in ${result.latencyMs}ms.`);
      console.log(
        "\nThe endpoint recorded this ping. If your monitor still reports late,\n" +
          "the job is not reaching this line: check the schedule and the exit path.\n",
      );
      return EXIT_OK;

    default:
      line("error", `${result.outcome}${result.status ? ` (HTTP ${result.status})` : ""} after ${result.latencyMs}ms.`);
      if (result.detail) line("info", result.detail);
      if (result.hint) console.log(`\n${result.hint}\n`);
      return EXIT_PROBLEM;
  }
}

function runCron(target) {
  if (!target) {
    console.error('cron needs a crontab line in quotes. See --help.');
    return EXIT_USAGE;
  }

  console.log(`\nChecking crontab line\n`);
  const findings = inspectCronLine(target);

  for (const finding of findings) line(finding.level, finding.message);
  console.log();

  return findings.some((finding) => finding.level === "error") ? EXIT_PROBLEM : EXIT_OK;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.command === "usage_error") {
    console.error(args.detail);
    return EXIT_USAGE;
  }

  switch (args.command) {
    case "ping":
      return runPing(args.target, args.timeoutMs);
    case "cron":
      return runCron(args.target);
    case "help":
    case null:
      console.log(USAGE);
      return args.command === "help" ? EXIT_OK : EXIT_USAGE;
    default:
      console.error(`Unknown command: ${args.command}\n`);
      console.error(USAGE);
      return EXIT_USAGE;
  }
}

main().then((code) => process.exit(code));
