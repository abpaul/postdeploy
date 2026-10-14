/**
 * Golden-envelope contract test (issue #18). Builds each wire item through
 * the REAL production path (`init`/`captureException`/`captureMessage`
 * with a mocked `fetch`, asserting on the exact body posted) from the
 * canonical input documented in `sdks/contract/README.md`, and asserts it
 * equals the golden fixture, after stripping the non-deterministic fields
 * (`id`, `timestamp`) both sides carry.
 *
 * The exception item passes `frames` as a `captureException` option --
 * `client.ts`'s `buildExceptionItem` uses it in place of the normal
 * `parseStack(error.stack)` capture when present. That override exists
 * only for this test: V8's `Error.stack` format ties every frame's
 * file/line to THIS test file's own call site, which can never be
 * byte-identical to what Elixir/Ruby produce from their own raise sites --
 * see the contract README's "why literal frames" note. Every other field
 * (type/value/tags/contexts/user/breadcrumbs/fingerprint/mechanism) goes
 * through the real, unmodified assembly code.
 *
 * No session item here: `packages/sdk` has no `POST /e/sessions` builder
 * (see the contract README's "known gap"). Session is covered by the
 * monolith's server anchor and the Elixir/Ruby SDKs.
 */
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, captureException, captureMessage, flush, init } from "./client";
import { sendMeasureHit } from "../measure";

// The golden contract is owned by the product and lives in the same repository
// at `sdks/contract`, which is the default below. POSTDEPLOY_CONTRACT_DIR
// overrides it to test this SDK against another checkout of the fixtures.
// Either way the manifest version and per-item digests are verified.
const CONTRACT_VERSION = "2.0.0";
const NON_DETERMINISTIC_KEYS = ["id", "timestamp"];
const EXPECTED_DIGESTS: Record<string, string> = {
  "exception_item.json": "sha256:a970a83c0b7f8a1d74b8602afd886941634c711e600e41e2dc6ea579f868a380",
  "message_item.json": "sha256:0f14c4f20605fed9a844646905047835033a7c6ade38fc1cb1d7da0158362e8f",
  "measure_event.json": "sha256:132914d7468c8909baad2509bfb17de8ee30d585259c783a72d21f9446b6a483",
  "session_item.json": "sha256:3bfe1d1458a03a3ced1b725c86d2a9aabbd57129f7aeb6a529d2d923ede8ec40",
};


const DEFAULT_CONTRACT_DIR = fileURLToPath(new URL("../../../../contract", import.meta.url));

function contractDir(): string {
  const dir = process.env.POSTDEPLOY_CONTRACT_DIR || DEFAULT_CONTRACT_DIR;
  if (!existsSync(dir)) {
    throw new Error(
      `contract fixtures not found at ${dir}. They live in this repository at ` +
        "sdks/contract; set POSTDEPLOY_CONTRACT_DIR to use another checkout.",
    );
  }
  const manifest = JSON.parse(readFileSync(`${dir}/manifest.json`, "utf8")) as {
    version: string;
    items: Record<string, string>;
  };
  if (manifest.version !== CONTRACT_VERSION) {
    throw new Error(`contract version mismatch: pinned ${CONTRACT_VERSION}, got ${manifest.version}`);
  }
  const checksumFile = Object.fromEntries(
    readFileSync(`${dir}/SHA256SUMS`, "utf8")
      .trim()
      .split("\n")
      .map((line) => {
        const [digest, name] = line.trim().split(/\s+/, 2);
        return [name, `sha256:${digest}`];
      }),
  ) as Record<string, string>;
  for (const [name, expected] of Object.entries(EXPECTED_DIGESTS)) {
    if (manifest.items[name] !== expected || checksumFile[name] !== expected) {
      throw new Error(`contract digest pin mismatch for ${name}`);
    }
    const actual = `sha256:${createHash("sha256").update(readFileSync(`${dir}/${name}`)).digest("hex")}`;
    if (actual !== expected) {
      throw new Error(`contract checksum mismatch for ${name}: expected ${expected}, got ${actual}`);
    }
  }
  return dir;
}

class ContractTestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ContractTestError";
  }
}

function golden(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(`${contractDir()}/${name}`, "utf8")) as Record<string, unknown>;
}

function normalize(item: Record<string, unknown>): Record<string, unknown> {
  const copy = { ...item };
  for (const key of NON_DETERMINISTIC_KEYS) delete copy[key];
  return JSON.parse(JSON.stringify(copy)) as Record<string, unknown>;
}

function okResponse(): Response {
  return { ok: true, status: 202, headers: new Headers() } as Response;
}

function lastPostedItem(fetchImpl: ReturnType<typeof vi.fn>): Record<string, unknown> {
  const call = fetchImpl.mock.calls.at(-1)!;
  const body = JSON.parse((call[1] as RequestInit).body as string) as { items: Record<string, unknown>[] };
  return body.items[0]!;
}

describe("golden envelope contract (issue #18), via the real init/capture*/flush flow", () => {
  afterEach(() => {
    __resetForTests();
    vi.restoreAllMocks();
  });

  it("matches the golden exception item", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_contract_test", environment: "test", release: "1.0.0", fetchImpl, autoFlushIntervalMs: 0 });

    captureException(new ContractTestError("canonical contract test exception"), {
      frames: [
        { file: "app/worker.ex", function: "MyApp.Worker.perform/1", lineno: 42, colno: 5, in_app: true },
        { file: "lib/some_lib.ex", function: "SomeLib.call/2", lineno: 10, in_app: false },
      ],
      fingerprint: ["checkout", "timeout"],
      breadcrumbs: [
        { category: "nav", message: "clicked checkout", level: "info", ts: "2024-01-01T00:00:00.000Z" },
        { category: "http", message: "POST /api/orders", level: "info", ts: "2024-01-01T00:00:01.000Z" },
      ],
      contexts: { extra: { cart_id: "cart_123", items: 3 } },
      tags: { team: "observability", flow: "checkout" },
      user: { id: "user_42", email: "person@example.com" },
    });
    await flush();

    expect(normalize(lastPostedItem(fetchImpl))).toEqual(normalize(golden("exception_item.json")));
  });

  it("matches the golden message item", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_contract_test", environment: "test", release: "1.0.0", fetchImpl, autoFlushIntervalMs: 0 });

    captureMessage("canonical contract test message", "warning", {
      contexts: { extra: { note: "message-level context" } },
      tags: { team: "observability" },
      breadcrumbs: [{ category: "nav", message: "opened settings", level: "info", ts: "2024-01-01T00:00:00.000Z" }],
      user: { id: "user_42", email: "person@example.com" },
    });
    await flush();

    expect(normalize(lastPostedItem(fetchImpl))).toEqual(normalize(golden("message_item.json")));
  });

  it("matches the golden Measure event", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 204 } as Response);

    await sendMeasureHit({
      site: "msr_contract_site",
      url: "https://app.example.test/pricing",
      referrer: null,
      type: "custom_event",
      name: "signup",
      props: { campaign: "contract-test", discarded: true },
      fetchImpl,
    });

    const call = fetchImpl.mock.calls.at(-1)!;
    const body = JSON.parse((call[1] as RequestInit).body as string) as Record<string, unknown>;
    expect(body).toEqual(golden("measure_event.json"));
  });
});
