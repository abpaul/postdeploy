import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, captureException, flush, init } from "../core/observe/client";
import { addBreadcrumb, configureScope, setContext, setTag, setUser, withScope } from "./scope";

function okResponse(): Response {
  return { ok: true, status: 202, headers: new Headers() } as Response;
}

async function capturedItem(fetchImpl: ReturnType<typeof vi.fn>): Promise<Record<string, unknown>> {
  const call = fetchImpl.mock.calls.find(([url]: [string]) => url === "https://ingest.postdeploy.dev/e/errors");
  const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
  return body.items[0]!;
}

describe("node scope: AsyncLocalStorage-backed, per-withScope (section 4)", () => {
  beforeEach(() => {
    configureScope({ debug: false });
  });

  afterEach(() => {
    __resetForTests();
    vi.restoreAllMocks();
  });

  it("setUser/setTag/setContext/addBreadcrumb called inside withScope apply only to captures made inside it", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });

    await withScope(async () => {
      setUser({ id: "u1" });
      setTag("plan", "agency");
      setContext("device", { os: "mac" });
      addBreadcrumb({ category: "manual", message: "inside scope" });
      captureException(new Error("inside"));
    });
    captureException(new Error("outside"));
    await flush();

    const bodies = fetchImpl.mock.calls.filter(([url]) => url === "https://ingest.postdeploy.dev/e/errors").map(([, requestInit]) => JSON.parse((requestInit as RequestInit).body as string) as { items: Array<Record<string, unknown>> });
    const items = bodies.flatMap((b) => b.items);
    const insideItem = items.find((i) => (i.exception as { value?: string }).value === "inside")!;
    const outsideItem = items.find((i) => (i.exception as { value?: string }).value === "outside")!;

    expect(insideItem.user).toEqual({ id: "u1" });
    expect(insideItem.tags).toEqual({ plan: "agency" });
    expect((insideItem.contexts as Record<string, unknown>).device).toEqual({ os: "mac" });
    expect(insideItem.breadcrumbs).toEqual([expect.objectContaining({ message: "inside scope" })]);

    expect(outsideItem.user).toBeUndefined();
    expect(outsideItem.tags).toBeUndefined();
    expect(outsideItem.breadcrumbs).toBeUndefined();
  });

  it("two concurrent withScope calls never leak one request's user into the other (the exact footgun the spec forbids)", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });

    const requestA = withScope(async () => {
      setUser({ id: "user-a" });
      await new Promise((resolve) => setTimeout(resolve, 5));
      captureException(new Error("error-a"));
    });
    const requestB = withScope(async () => {
      setUser({ id: "user-b" });
      captureException(new Error("error-b"));
    });
    await Promise.all([requestA, requestB]);
    await flush();

    const bodies = fetchImpl.mock.calls.filter(([url]) => url === "https://ingest.postdeploy.dev/e/errors").map(([, requestInit]) => JSON.parse((requestInit as RequestInit).body as string) as { items: Array<Record<string, unknown>> });
    const items = bodies.flatMap((b) => b.items);
    const itemA = items.find((i) => (i.exception as { value?: string }).value === "error-a")!;
    const itemB = items.find((i) => (i.exception as { value?: string }).value === "error-b")!;

    expect(itemA.user).toEqual({ id: "user-a" });
    expect(itemB.user).toEqual({ id: "user-b" });
  });

  it("setUser called OUTSIDE withScope is a no-op (never a naive module-global) and logs a debug warning", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    configureScope({ debug: true });
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });

    setUser({ id: "leaked" });
    captureException(new Error("unscoped"));
    await flush();

    const item = await capturedItem(fetchImpl);
    expect(item.user).toBeUndefined();
    expect(warnSpy).toHaveBeenCalled();
  });

  it("nested withScope calls get independent scopes", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl });

    await withScope(async () => {
      setUser({ id: "outer" });
      await withScope(async () => {
        setUser({ id: "inner" });
        captureException(new Error("inner-error"));
      });
      captureException(new Error("outer-error"));
    });
    await flush();

    const bodies = fetchImpl.mock.calls.filter(([url]) => url === "https://ingest.postdeploy.dev/e/errors").map(([, requestInit]) => JSON.parse((requestInit as RequestInit).body as string) as { items: Array<Record<string, unknown>> });
    const items = bodies.flatMap((b) => b.items);
    const innerItem = items.find((i) => (i.exception as { value?: string }).value === "inner-error")!;
    const outerItem = items.find((i) => (i.exception as { value?: string }).value === "outer-error")!;
    expect(innerItem.user).toEqual({ id: "inner" });
    expect(outerItem.user).toEqual({ id: "outer" });
  });
});
