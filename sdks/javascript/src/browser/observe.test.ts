import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, captureException } from "../core/observe/client";
import { unregisterAutoBreadcrumbs } from "./auto-breadcrumbs";
import { unregisterGlobalHandlers } from "./global-handlers";
import { __resetForTests as __resetBrowserObserveForTests, close, init } from "./observe";

/**
 * The vitest project this package runs under uses `environment: "node"`
 * (see the root `vitest.config.ts`), so `window`/`navigator` are not real
 * DOM globals here -- they're stubbed per test with `vi.stubGlobal`. That's
 * enough to exercise this adapter's own logic (does it register exactly one
 * listener, does the listener build and send the right keepalive request);
 * it does not exercise real browser `pagehide`/bfcache behavior, which has
 * no fidelity in a non-jsdom environment anyway.
 */
function fakeWindow() {
  const listeners: Record<string, Array<() => void>> = {};
  return {
    addEventListener: vi.fn((event: string, handler: () => void) => {
      (listeners[event] ??= []).push(handler);
    }),
    removeEventListener: vi.fn((event: string, handler: () => void) => {
      listeners[event] = (listeners[event] ?? []).filter((h) => h !== handler);
    }),
    fire(event: string) {
      for (const handler of listeners[event] ?? []) handler();
    },
    listeners,
    document: {},
  };
}

function pagehideCallCount(win: ReturnType<typeof fakeWindow>): number {
  return win.addEventListener.mock.calls.filter(([event]) => event === "pagehide").length;
}

describe("browser Observe init", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    unregisterGlobalHandlers();
    unregisterAutoBreadcrumbs();
    __resetForTests();
    __resetBrowserObserveForTests();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("registers a pagehide listener that flushes the queue via fetch keepalive with the Authorization header", async () => {
    const win = fakeWindow();
    vi.stubGlobal("window", win);
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);
    vi.stubGlobal("fetch", fetchImpl);

    init({ key: "alp_p_test", fetchImpl });
    captureException(new Error("boom"));

    win.fire("pagehide");
    await vi.runAllTimersAsync();

    expect(fetchImpl).toHaveBeenCalledTimes(1);
    const [url, requestInit] = fetchImpl.mock.calls[0]! as [string, RequestInit];
    expect(url).toBe("https://ingest.postdeploy.dev/e/errors");
    expect(requestInit.keepalive).toBe(true);
    expect((requestInit.headers as Record<string, string>).Authorization).toBe("Bearer alp_p_test");
  });

  it("does not send anything on pagehide when the queue is empty", async () => {
    const win = fakeWindow();
    vi.stubGlobal("window", win);
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);
    vi.stubGlobal("fetch", fetchImpl);

    init({ key: "alp_p_test", fetchImpl });
    win.fire("pagehide");
    await vi.runAllTimersAsync();

    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("registers only one pagehide listener across repeated init() calls", () => {
    const win = fakeWindow();
    vi.stubGlobal("window", win);
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);

    init({ key: "alp_p_first", fetchImpl });
    init({ key: "alp_p_second", fetchImpl });

    expect(pagehideCallCount(win)).toBe(1);
  });
  it("unregisters global error handlers when reinit disables captureUnhandled", () => {
    const win = fakeWindow();
    vi.stubGlobal("window", win);

    init({ key: "alp_p_first", fetchImpl: vi.fn() });
    expect(win.listeners.error ?? []).toHaveLength(1);
    expect(win.listeners.unhandledrejection ?? []).toHaveLength(1);

    init({ key: "alp_p_second", captureUnhandled: false, fetchImpl: vi.fn() });

    expect(win.listeners.error ?? []).toHaveLength(0);
    expect(win.listeners.unhandledrejection ?? []).toHaveLength(0);
    expect(
      win.removeEventListener.mock.calls.filter(([event]) =>
        event === "error" || event === "unhandledrejection"
      )
    ).toHaveLength(2);
  });

  it("test reset removes the registered pagehide callback", () => {
    const win = fakeWindow();
    vi.stubGlobal("window", win);

    init({ key: "alp_p_test", fetchImpl: vi.fn() });
    __resetBrowserObserveForTests();

    expect(win.removeEventListener).toHaveBeenCalledTimes(1);
    expect(win.listeners.pagehide ?? []).toHaveLength(0);
  });

  it("close removes the actual pagehide callback and reinit leaves one current handler", async () => {
    const win = fakeWindow();
    vi.stubGlobal("window", win);
    const fetchImpl = vi.fn().mockResolvedValue({ ok: true, status: 202, headers: new Headers() } as Response);
    vi.stubGlobal("fetch", fetchImpl);

    init({ key: "alp_p_first", fetchImpl, postErrorLogWindowMs: 0 });
    captureException(new Error("first"));
    await close();

    expect(win.listeners.pagehide ?? []).toHaveLength(0);

    init({ key: "alp_p_second", fetchImpl, postErrorLogWindowMs: 0 });
    captureException(new Error("second"));
    expect(win.listeners.pagehide ?? []).toHaveLength(1);

    win.fire("pagehide");
    await vi.runAllTimersAsync();

    expect(fetchImpl).toHaveBeenCalledTimes(2);
    const sentItems = fetchImpl.mock.calls.flatMap((call) => {
      const body = JSON.parse((call[1] as RequestInit).body as string) as { items: unknown[] };
      return body.items;
    });
    expect(sentItems).toHaveLength(2);
  });

  it("does not throw when there is no window global at all", () => {
    vi.stubGlobal("window", undefined);
    expect(() => init({ key: "alp_p_test", fetchImpl: vi.fn() })).not.toThrow();
  });
});
