import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, captureException, flush } from "../core/observe/client";
import { init } from "./index";

describe("cloudflare Observe init", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    __resetForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("never auto-flushes on a background timer, even if the caller tries to set one", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);
    init({ key: "alp_p_test", fetchImpl, autoFlushIntervalMs: 100 });
    captureException(new Error("boom"));

    await vi.advanceTimersByTimeAsync(60_000);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("still flushes on explicit flush(), the ctx.waitUntil(flush()) pattern", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);
    init({ key: "alp_p_test", fetchImpl });
    captureException(new Error("boom"));

    await expect(flush()).resolves.toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("still auto-flushes once the 10-item batch threshold is crossed", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);
    init({ key: "alp_p_test", fetchImpl });
    for (let i = 0; i < 10; i++) captureException(new Error(`boom ${i}`));
    await vi.runAllTimersAsync();
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});
