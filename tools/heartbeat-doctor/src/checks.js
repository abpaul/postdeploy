/**
 * Diagnostic checks for a heartbeat ping URL.
 *
 * Provider-neutral on purpose. A heartbeat URL is just a URL you request on
 * a schedule, so every check here works against Healthchecks.io, Cronitor,
 * Better Stack, PostDeploy or a self-hosted endpoint. A tool that only worked with
 * one vendor would be an advert, not a diagnostic.
 *
 * Pure functions over an injected `fetch`, so the tests exercise the real
 * decision logic without a network.
 */

/** Ping URLs are secrets. Never print one, or a support paste leaks it. */
export function redactUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return "<invalid url>";
  }

  // The token is usually the last path segment; some providers put it in a
  // query parameter. Mask both, and keep enough to identify the provider.
  const segments = url.pathname.split("/").filter(Boolean);
  const masked = segments.map((segment, index) =>
    index === segments.length - 1 && segment.length > 6 ? `${segment.slice(0, 3)}***` : segment,
  );

  const query = url.search ? "?***" : "";
  return `${url.protocol}//${url.host}/${masked.join("/")}${query}`;
}

export function validateUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return { ok: false, reason: "not_a_url", detail: "could not be parsed as a URL" };
  }

  if (url.protocol === "http:") {
    return {
      ok: true,
      warning: "insecure_scheme",
      detail: "uses http://, so the token travels in clear text. Prefer https://.",
      url,
    };
  }

  if (url.protocol !== "https:") {
    return {
      ok: false,
      reason: "unsupported_scheme",
      detail: `${url.protocol} is not http or https`,
    };
  }

  return { ok: true, url };
}

/**
 * Sends one ping and classifies the outcome.
 *
 * A heartbeat endpoint that answers 2xx is working. The failures worth
 * naming separately are the ones people actually hit: a 404 (wrong or
 * revoked token), a timeout (egress blocked), and DNS failure (typo or
 * no resolver in the container).
 */
export async function probe(rawUrl, { fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const started = Date.now();
  const controller = new AbortController();

  // The timeout is raced against the request rather than relying on the
  // abort signal alone. A `fetch` implementation that ignores the signal
  // (or a stub that never settles) would otherwise keep a pending promise
  // alive and stop the process from exiting.
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      resolve({ __timedOut: true });
    }, timeoutMs);
  });

  const timedOut = () => ({
    outcome: "timeout",
    latencyMs: Date.now() - started,
    hint: `No response within ${timeoutMs}ms. In a container or CI runner this usually means egress is blocked by a network policy or firewall, which stops the ping while the job itself still succeeds.`,
  });

  try {
    const response = await Promise.race([
      fetchImpl(rawUrl, { method: "GET", signal: controller.signal, redirect: "follow" }),
      timeout,
    ]);

    if (response?.__timedOut) return timedOut();

    const latencyMs = Date.now() - started;

    if (response.status >= 200 && response.status < 300) {
      return { outcome: "accepted", status: response.status, latencyMs };
    }

    if (response.status === 404) {
      return {
        outcome: "unknown_token",
        status: 404,
        latencyMs,
        hint: "The endpoint answered but does not recognise this token. It may be mistyped, truncated when copied, or belong to a monitor that was deleted and recreated.",
      };
    }

    if (response.status === 429) {
      return {
        outcome: "rate_limited",
        status: 429,
        latencyMs,
        hint: "The provider is rate limiting these pings. Check whether something is pinging far more often than the schedule.",
      };
    }

    if (response.status >= 500) {
      return {
        outcome: "provider_error",
        status: response.status,
        latencyMs,
        hint: "The provider returned a server error. The ping was probably not recorded; check their status page.",
      };
    }

    return { outcome: "unexpected_status", status: response.status, latencyMs };
  } catch (error) {
    const latencyMs = Date.now() - started;

    if (error.name === "AbortError") return timedOut();

    const code = error.cause?.code ?? error.code;

    if (code === "ENOTFOUND" || code === "EAI_AGAIN") {
      return {
        outcome: "dns_failure",
        latencyMs,
        hint: "The hostname did not resolve. Check for a typo, or for a container with no DNS resolver configured.",
      };
    }

    if (code === "ECONNREFUSED") {
      return {
        outcome: "connection_refused",
        latencyMs,
        hint: "The host refused the connection. If this is a self-hosted endpoint, confirm it is listening and reachable from here.",
      };
    }

    return {
      outcome: "network_error",
      latencyMs,
      detail: error.message,
      hint: "The request failed before a response arrived.",
    };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The cron mistakes that cause a job to look healthy while doing nothing,
 * checked against a crontab line.
 *
 * These are the failures that make heartbeat monitoring necessary in the
 * first place, and every one of them is invisible until someone looks.
 */
export function inspectCronLine(line) {
  const findings = [];
  const trimmed = line.trim();

  if (!trimmed || trimmed.startsWith("#")) {
    return [{ level: "error", code: "commented_out", message: "This line is a comment, so cron never runs it." }];
  }

  // `command && ping` only pings on success, which is usually right, but it
  // means a failing job reports nothing at all rather than reporting failure.
  if (/&&\s*(curl|wget)/.test(trimmed)) {
    findings.push({
      level: "info",
      code: "ping_on_success_only",
      message:
        "The ping runs only when the job succeeds (&&). A failure stays silent until the grace period expires. To alert immediately, report the exit code instead: `cmd; curl -fsS \"$URL/$?\"`.",
    });
  }

  // `;` without capturing $? pings unconditionally, which is worse: a broken
  // job actively reports success.
  if (/;\s*(curl|wget)/.test(trimmed) && !/\$\?/.test(trimmed)) {
    findings.push({
      level: "error",
      code: "ping_always_succeeds",
      message:
        "The ping runs whether or not the job succeeded, and does not report the exit code, so a permanently failing job will look healthy forever. Use `&&`, or send the exit status with `$?`.",
    });
  }

  if (/(curl|wget)/.test(trimmed) && !/(-f|--fail)/.test(trimmed) && /curl/.test(trimmed)) {
    findings.push({
      level: "warning",
      code: "curl_without_fail",
      message:
        "curl without -f exits 0 even on an HTTP error, so a failing ping looks like a successful one. Use `curl -fsS`.",
    });
  }

  // A bare command name depends on cron's PATH, which is far smaller than a
  // login shell's. This is the classic "works in my terminal" cron failure.
  const command = trimmed.replace(/^(\S+\s+){5}/, "");
  if (command && !command.startsWith("/") && !/^[A-Z_]+=/.test(command)) {
    findings.push({
      level: "warning",
      code: "relative_command",
      message:
        "The command is not an absolute path. cron runs with a minimal PATH, so a command that works in your shell can fail here. Use the full path.",
    });
  }

  if (/%/.test(trimmed) && !/\\%/.test(trimmed)) {
    findings.push({
      level: "error",
      code: "unescaped_percent",
      message:
        "An unescaped % in a crontab is turned into a newline, which truncates the command. Escape it as \\%.",
    });
  }

  if (findings.length === 0) {
    findings.push({ level: "ok", code: "no_issues", message: "No common cron mistakes detected in this line." });
  }

  return findings;
}
