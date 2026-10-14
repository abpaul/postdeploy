import http from "k6/http";
import { check } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

const baseUrl = __ENV.BASE_URL || "http://127.0.0.1:4000";
const profile = __ENV.PROFILE || "burst_5k";
const kind = __ENV.KIND || "errors";
const batchSize = Number(__ENV.BATCH_SIZE || "10");
const keys = (__ENV.ALPLUS_KEYS || "").split(",").filter(Boolean);
const measureTokens = (__ENV.MEASURE_TOKENS || "").split(",").filter(Boolean);
const heartbeatTokens = (__ENV.HEARTBEAT_TOKENS || "").split(",").filter(Boolean);

const acceptedEvents = new Counter("accepted_events");
const rejectedEvents = new Counter("rejected_events");
const rateLimited = new Counter("responses_429");
const unavailable = new Counter("responses_503");
const unexpected = new Rate("unexpected_responses");
const acceptanceLatency = new Trend("acceptance_latency", true);

const profiles = {
  million_60m: arrival(28, "60m", 64, 256),
  million_30m: arrival(56, "30m", 128, 512),
  million_10m: arrival(167, "10m", 256, 1024),
  burst_5k: arrival(500, "60s", 512, 2048),
  noisy_tenant: arrival(500, "60s", 512, 2048),
  many_tenants: arrival(167, "10m", 256, 1024),
  invalid_flood: arrival(500, "60s", 512, 2048),
  database_slowdown: arrival(50, "5m", 128, 512),
  consumer_slowdown: arrival(100, "5m", 128, 512),
  outage_recovery: arrival(50, "5m", 128, 512),
};

export const options = {
  scenarios: { ingestion: profiles[profile] },
  thresholds: {
    unexpected_responses: ["rate<0.01"],
    checks: ["rate>0.99"],
    http_req_duration: ["p(95)<2000", "p(99)<5000"],
  },
  noConnectionReuse: false,
  userAgent: "alplus-k6-resilience/1.0",
};

function arrival(rate, duration, preAllocatedVUs, maxVUs) {
  return {
    executor: "constant-arrival-rate",
    rate,
    timeUnit: "1s",
    duration,
    preAllocatedVUs,
    maxVUs,
  };
}

function pick(values) {
  if (values.length === 0) return "";
  if (profile === "noisy_tenant") return values[0];
  return values[(__VU - 1) % values.length];
}

function eventId(prefix, index) {
  const run = (__ENV.RUN_ID || `${Date.now()}`).replace(/[^a-zA-Z0-9]/g, "");
  return `${prefix}_${run}_${__VU}_${__ITER}_${index}`.slice(0, 64);
}

function errorEnvelope(key) {
  const timestamp = new Date().toISOString();
  return JSON.stringify({
    header: { key: null, sent_at: timestamp, sdk: { name: "k6", version: "1.0", platform: "load" } },
    items: Array.from({ length: batchSize }, (_, index) => ({
      id: eventId("err", index),
      type: "message",
      timestamp,
      level: "error",
      release: "load-test",
      environment: "ignored-by-server",
      message: `load test ${profile}`,
      exception: null,
      fingerprint: ["load-test", `${__ITER % 100}`],
      breadcrumbs: null,
      contexts: null,
      tags: null,
      user: null,
      mechanism: "k6",
    })),
  });
}

function sessionEnvelope() {
  const timestamp = new Date().toISOString();
  return JSON.stringify({
    header: { key: null, sent_at: timestamp, sdk: { name: "k6", version: "1.0", platform: "load" } },
    items: Array.from({ length: batchSize }, (_, index) => ({
      id: eventId("ses", index),
      status: "healthy",
      started_at: timestamp,
      duration_ms: 25,
      release: "load-test",
      environment: "ignored-by-server",
    })),
  });
}

function request() {
  if (profile === "invalid_flood") {
    return http.post(`${baseUrl}/e/errors`, "{not-json", {
      headers: { Authorization: `Bearer ${pick(keys)}`, "Content-Type": "application/json" },
      timeout: "10s",
    });
  }

  if (kind === "measure") {
    const token = pick(measureTokens);
    return http.post(`${baseUrl}/m`, JSON.stringify({ site: token, url: "https://load.example.test/" }), {
      headers: { Origin: "https://load.example.test", "Content-Type": "text/plain" },
      timeout: "10s",
    });
  }

  if (kind === "heartbeat") {
    return http.get(`${baseUrl}/h/${pick(heartbeatTokens)}`, { timeout: "10s" });
  }

  const key = pick(keys);
  const path = kind === "sessions" ? "/e/sessions" : "/e/errors";
  const body = kind === "sessions" ? sessionEnvelope() : errorEnvelope(key);
  return http.post(`${baseUrl}${path}`, body, {
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    timeout: "10s",
  });
}

export default function () {
  const response = request();
  acceptanceLatency.add(response.timings.duration);

  const accepted = response.status === 202 || response.status === 204;
  const overload = response.status === 429 || response.status === 503;
  const expectedInvalid = profile === "invalid_flood" && response.status === 400;
  const deliberate = accepted || overload || expectedInvalid;

  if (accepted) acceptedEvents.add(acceptedCount(response));
  if (response.status === 429) rateLimited.add(1);
  if (response.status === 503) unavailable.add(1);
  if (!accepted) rejectedEvents.add(attemptedCount());
  unexpected.add(!deliberate);

  check(response, {
    "response is deliberate": () => accepted || deliberate,
    "overload carries Retry-After": (res) => ![429, 503].includes(res.status) || Boolean(res.headers["Retry-After"]),
  });
}

function attemptedCount() {
  return kind === "measure" || kind === "heartbeat" ? 1 : batchSize;
}

function acceptedCount(response) {
  if (kind === "measure" || kind === "heartbeat") return 1;

  try {
    const body = response.json();
    return kind === "sessions" ? body.accepted : body.event_ids.length;
  } catch (_error) {
    return 0;
  }
}
