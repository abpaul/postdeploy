import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, buildKeepaliveFlushRequest, captureException, captureMessage, close, flush, init } from "./client";

function okResponse(): Response {
  return { ok: true, status: 202, headers: new Headers() } as Response;
}

function lastItem(fetchImpl: ReturnType<typeof vi.fn>): Record<string, unknown> {
  const init = fetchImpl.mock.calls.at(-1)?.[1] as RequestInit;
  const body = JSON.parse(init.body as string) as { items: Array<Record<string, unknown>> };
  return body.items[0]!;
}

describe("Observe client leftover branches", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    __resetForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("drops an oversized tags object rather than sending a truncated map", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, debug: true });
    captureException(new Error("boom"), { tags: { blob: "x".repeat(8_000) } });
    await flush();
    expect(lastItem(fetchImpl).tags).toBeUndefined();
  });

  it("forwards a custom fingerprint", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    captureException(new Error("boom"), { fingerprint: ["orders", "timeout"] });
    await flush();
    expect(lastItem(fetchImpl).fingerprint).toEqual(["orders", "timeout"]);
  });

  it("stringifies a thrown object that is not an Error", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    captureException({ code: 42 });
    await flush();
    expect((lastItem(fetchImpl).exception as { value: string }).value).toContain("42");
  });

  it("buildKeepaliveFlushRequest is null when the queue is empty", () => {
    init({ key: "alp_p_test", fetchImpl: vi.fn().mockResolvedValue(okResponse()) });
    expect(buildKeepaliveFlushRequest()).toBeNull();
  });

  it("captureMessage after close is a no-op", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, debug: true });
    await close();
    captureMessage("after close");
    await flush();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("init() logs a debug warning when called twice", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    init({ key: "alp_p_first", fetchImpl: vi.fn().mockResolvedValue(okResponse()), debug: true });
    init({ key: "alp_p_second", fetchImpl: vi.fn().mockResolvedValue(okResponse()), debug: true });
    expect(warnSpy).toHaveBeenCalled();
  });

  it("defaults environment to production when omitted", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });
    captureMessage("hi");
    await flush();
    expect(lastItem(fetchImpl).environment).toBe("production");
  });

  it("drops a 403 without retrying", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ ok: false, status: 403, headers: new Headers() } as Response);
    init({ key: "alp_p_test", fetchImpl });
    captureException(new Error("boom"));
    await flush();
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});
