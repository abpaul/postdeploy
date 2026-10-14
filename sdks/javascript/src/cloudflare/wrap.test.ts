import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests } from "../core/observe/client";
import { init } from "./index";
import { wrapHandler, wrapScheduled, type MinimalExecutionContext } from "./wrap";

function fakeCtx(): MinimalExecutionContext & { waited: Array<Promise<unknown>> } {
  const waited: Array<Promise<unknown>> = [];
  return {
    waited,
    waitUntil(promise: Promise<unknown>) {
      waited.push(promise);
    },
  };
}

function okResponse(): Response {
  return { ok: true, status: 202, headers: new Headers() } as Response;
}

describe("cloudflare wrapHandler / wrapScheduled", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    __resetForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("wrapHandler: a handler that succeeds is passed through untouched, nothing captured", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    const ctx = fakeCtx();
    const wrapped = wrapHandler(async () => new Response("ok"));

    const response = await wrapped(new Request("https://example.com"), {}, ctx);
    expect(await response.text()).toBe("ok");
    expect(ctx.waited.length).toBe(0);
  });

  it("wrapHandler: a thrown error is captured with mechanism instrumentation, flushed via waitUntil, and RE-THROWN (never swallowed)", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    const ctx = fakeCtx();
    const boom = new Error("boom");
    const wrapped = wrapHandler(async () => {
      throw boom;
    });

    await expect(wrapped(new Request("https://example.com"), {}, ctx)).rejects.toBe(boom);
    expect(ctx.waited.length).toBe(1);
    await ctx.waited[0];

    const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
    expect(call).toBeDefined();
    const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
    expect(body.items[0]!.mechanism).toBe("instrumentation");
  });

  it("wrapScheduled: a thrown error is captured, flushed, and re-thrown", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    const ctx = fakeCtx();
    const boom = new Error("scheduled boom");
    const wrapped = wrapScheduled(async () => {
      throw boom;
    });

    await expect(wrapped({ cron: "* * * * *" }, {}, ctx)).rejects.toBe(boom);
    expect(ctx.waited.length).toBe(1);
    await ctx.waited[0];

    const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
    expect(call).toBeDefined();
  });

  it("captureException options accept explicit user/tags/contexts/breadcrumbs (the Cloudflare-safe scope mechanism)", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    const ctx = fakeCtx();
    const wrapped = wrapHandler(async () => {
      throw new Error("boom");
    });

    const { captureException, flush } = await import("./index");
    await expect(wrapped(new Request("https://example.com"), {}, ctx)).rejects.toThrow();
    captureException(new Error("manual"), { user: { id: "u1" }, tags: { region: "eu" } });
    await flush();

    const bodies = fetchImpl.mock.calls.filter(([url]) => url === "https://ingest.postdeploy.dev/e/errors").map(([, requestInit]) => JSON.parse((requestInit as RequestInit).body as string) as { items: Array<Record<string, unknown>> });
    const manualItem = bodies.flatMap((b) => b.items).find((item) => (item.exception as { value?: string } | undefined)?.value === "manual");
    expect(manualItem?.user).toEqual({ id: "u1" });
    expect(manualItem?.tags).toEqual({ region: "eu" });
  });
});
