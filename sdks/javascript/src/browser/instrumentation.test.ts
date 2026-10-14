import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, captureException, captureMessage, flush } from "../core/observe/client";
import { unregisterAutoBreadcrumbs } from "./auto-breadcrumbs";
import { unregisterGlobalHandlers } from "./global-handlers";
import { close, init, __resetForTests as __resetBrowserObserveForTests } from "./observe";
import { __resetScopeForTests, setContext, setTag, setUser } from "./scope";

/**
 * Runs under `environment: "node"` (root vitest.config.ts), so every browser
 * global below is a hand-built stub, not real jsdom -- enough to exercise
 * this adapter's own wiring (listeners attached/detached, breadcrumbs
 * recorded, mechanism set correctly, the underlying call never swallowed),
 * not real browser event timing.
 */
function fakeWindow() {
  const listeners: Record<string, Array<(event: unknown) => void>> = {};
  return {
    location: { pathname: "/start", hash: "" },
    history: {
      pushState: vi.fn(),
      replaceState: vi.fn(),
    },
    addEventListener: vi.fn((event: string, handler: (event: unknown) => void) => {
      (listeners[event] ??= []).push(handler);
    }),
    removeEventListener: vi.fn((event: string, handler: (event: unknown) => void) => {
      listeners[event] = (listeners[event] ?? []).filter((h) => h !== handler);
    }),
    fire(event: string, payload: unknown = {}) {
      for (const handler of [...(listeners[event] ?? [])]) handler(payload);
    },
    listenerCount(event: string) {
      return (listeners[event] ?? []).length;
    },
    document: {},
  };
}

function fakeDocument() {
  const listeners: Array<(event: unknown) => void> = [];
  return {
    addEventListener: vi.fn((_event: string, handler: (event: unknown) => void) => {
      listeners.push(handler);
    }),
    removeEventListener: vi.fn((_event: string, handler: (event: unknown) => void) => {
      const i = listeners.indexOf(handler);
      if (i >= 0) listeners.splice(i, 1);
    }),
    fire(payload: unknown) {
      for (const handler of [...listeners]) handler(payload);
    },
  };
}

function okResponse(): Response {
  return { ok: true, status: 200, headers: new Headers() } as Response;
}

describe("browser instrumentation", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    // Order matters: these read/mutate the CURRENT stubbed `window`, so they
    // must run before `vi.unstubAllGlobals()` removes it -- otherwise
    // `unregisterGlobalHandlers`'s `getWindow()` sees no window, no-ops, and
    // leaves this module's listener references pointing at a discarded fake
    // window, blocking the next test's `registerGlobalHandlers` call (the
    // "already registered" guard would never see them as cleared).
    unregisterGlobalHandlers();
    unregisterAutoBreadcrumbs();
    __resetForTests();
    __resetBrowserObserveForTests();
    __resetScopeForTests();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  describe("automatic global error capture (section 2)", () => {
    it("window 'error' is captured with mechanism onerror and does NOT call preventDefault (never swallow)", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      const preventDefault = vi.fn();
      win.fire("error", { error: new Error("uncaught"), message: "uncaught", preventDefault });
      await flush();

      expect(preventDefault).not.toHaveBeenCalled();
      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
      expect(body.items[0]!.mechanism).toBe("onerror");
    });

    it("window 'unhandledrejection' is captured with mechanism onunhandledrejection", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      win.fire("unhandledrejection", { reason: new Error("rejected") });
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
      expect(body.items[0]!.mechanism).toBe("onunhandledrejection");
    });

    it("captureUnhandled: false skips registering the global listeners", () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      init({ key: "alp_p_test", fetchImpl: vi.fn(), captureUnhandled: false });
      expect(win.listenerCount("error")).toBe(0);
      expect(win.listenerCount("unhandledrejection")).toBe(0);
    });

    it("close() detaches the global handlers", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      init({ key: "alp_p_test", fetchImpl: vi.fn().mockResolvedValue(okResponse()) });
      expect(win.listenerCount("error")).toBe(1);
      await close();
      expect(win.listenerCount("error")).toBe(0);
    });

    it("a manual captureException for the SAME error object the global handler also sees produces only ONE event (dedup)", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      const error = new Error("shared");
      win.fire("error", { error, message: "shared" });
      captureException(error);
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: unknown[] };
      expect(body.items.length).toBe(1);
    });
  });

  describe("breadcrumbs (section 3)", () => {
    it("history.pushState records a navigation breadcrumb, still calls the original pushState (never breaks the app)", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);
      const originalPushState = win.history.pushState;

      init({ key: "alp_p_test", fetchImpl });
      win.location.pathname = "/next";
      win.history.pushState({}, "", "/next");
      captureException(new Error("boom"));
      await flush();

      expect(originalPushState).toHaveBeenCalled();
      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ category?: string }> }> };
      const categories = body.items[0]!.breadcrumbs?.map((b) => b.category) ?? [];
      expect(categories).toContain("navigation");
    });

    it("a click is recorded with a CSS selector, never element text", async () => {
      const win = fakeWindow();
      const doc = fakeDocument();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", doc);
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      class FakeElement {
        tagName = "BUTTON";
        id = "submit";
        className = "btn-primary";
      }
      vi.stubGlobal("Element", FakeElement);
      const target = new FakeElement();
      doc.fire({ target });
      captureException(new Error("boom"));
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ category?: string; message?: string }> }> };
      const click = body.items[0]!.breadcrumbs?.find((b) => b.category === "ui.click");
      expect(click?.message).toBe("button#submit.btn-primary");
    });

    it("console.warn is recorded as a breadcrumb and still calls the original console.warn", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);
      const originalWarn = vi.spyOn(console, "warn");

      init({ key: "alp_p_test", fetchImpl });
      console.warn("careful now");
      captureException(new Error("boom"));
      await flush();

      expect(originalWarn).toHaveBeenCalledWith("careful now");
      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ category?: string; message?: string }> }> };
      const crumb = body.items[0]!.breadcrumbs?.find((b) => b.category === "console");
      expect(crumb?.message).toBe("careful now");
    });

    it("console.info and console.debug are recorded with their own levels (issue #47)", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      console.info("cache warmed");
      console.debug("payload bytes: 512");
      captureException(new Error("boom"));
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ category?: string; message?: string; level?: string }> }> };
      const crumbs = body.items[0]!.breadcrumbs?.filter((b) => b.category === "console") ?? [];
      expect(crumbs.find((b) => b.message === "cache warmed")?.level).toBe("info");
      expect(crumbs.find((b) => b.message === "payload bytes: 512")?.level).toBe("debug");
    });

    it("the SDK's own [@postdeploy/sdk] diagnostics are never recorded as breadcrumbs (issue #47)", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      console.warn("[@postdeploy/sdk] internal diagnostic line");
      captureException(new Error("boom"));
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ message?: string }> }> };
      const crumbs = body.items[0]!.breadcrumbs ?? [];
      expect(crumbs.some((b) => b.message?.includes("internal diagnostic"))).toBe(false);
    });

    it("a console line after the error joins the same event through the post-error window (issue #47)", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      captureException(new Error("boom"));
      console.error("request aborted after failure");
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ message?: string; data?: { after_error?: boolean } }> }> };
      const crumb = body.items[0]!.breadcrumbs?.find((b) => b.message === "request aborted after failure");
      expect(crumb?.data?.after_error).toBe(true);
    });

    it("a fetch call is recorded with method/status, query string stripped, and the response is still returned to the caller", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const appFetch = vi.fn().mockResolvedValue({ ok: true, status: 204, headers: new Headers() } as Response);
      vi.stubGlobal("fetch", appFetch);

      init({ key: "alp_p_test", fetchImpl: appFetch });
      const response = await globalThis.fetch("https://api.example.com/data?token=secret", { method: "GET" });
      expect(response.status).toBe(204);

      captureException(new Error("boom"));
      await flush();

      const call = appFetch.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ category?: string; message?: string }> }> };
      const crumb = body.items[0]!.breadcrumbs?.find((b) => b.category === "fetch");
      expect(crumb?.message).toBe("GET https://api.example.com/data");
    });

    it("addBreadcrumb data is scrubbed of password/token-shaped keys before it reaches the wire", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      const { addBreadcrumb } = await import("./scope");
      init({ key: "alp_p_test", fetchImpl });
      addBreadcrumb({ category: "manual", data: { password: "hunter2", safe: "ok" } });
      captureException(new Error("boom"));
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<{ breadcrumbs?: Array<{ data?: Record<string, unknown> }> }> };
      const crumb = body.items[0]!.breadcrumbs!.find((b) => b.data !== undefined)!;
      expect(crumb.data!.password).toBe("[FILTERED]");
      expect(crumb.data!.safe).toBe("ok");
    });
  });

  describe("scope (section 4)", () => {
    it("setUser/setTag/setContext merge into every subsequent event", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      setUser({ id: "u1", email: "jane@example.com" });
      setTag("plan", "agency");
      setContext("device", { os: "mac" });
      captureException(new Error("boom"));
      captureMessage("also scoped");
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
      for (const item of body.items) {
        expect(item.user).toEqual({ id: "u1", email: "jane@example.com" });
        expect(item.tags).toEqual({ plan: "agency" });
        expect((item.contexts as Record<string, unknown>).device).toEqual({ os: "mac" });
      }
    });

    it("setUser(null) clears a previously-set user", async () => {
      const win = fakeWindow();
      vi.stubGlobal("window", win);
      vi.stubGlobal("document", fakeDocument());
      const fetchImpl = vi.fn().mockResolvedValue(okResponse());
      vi.stubGlobal("fetch", fetchImpl);

      init({ key: "alp_p_test", fetchImpl });
      setUser({ id: "u1" });
      setUser(null);
      captureException(new Error("boom"));
      await flush();

      const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
      const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
      expect(body.items[0]!.user).toBeUndefined();
    });
  });
});
