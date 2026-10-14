import { afterEach, describe, expect, it, vi } from "vitest";
import { sendMeasureHit } from "./measure";

function noContentResponse(): Response {
  return { ok: true, status: 204, headers: new Headers() } as Response;
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("sendMeasureHit", () => {
  it("posts to /m with the pageview body shape", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(noContentResponse());
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/pricing", fetchImpl });

    expect(fetchImpl).toHaveBeenCalledTimes(1);
    const [url, requestInit] = fetchImpl.mock.calls[0]! as [string, RequestInit];
    expect(url).toBe("https://ingest.postdeploy.dev/m");
    expect((requestInit.headers as Record<string, string>)["Content-Type"]).toBe("text/plain;charset=UTF-8");
    expect(requestInit.headers).not.toHaveProperty("Origin");
    expect(requestInit.mode).toBe("no-cors");
    expect(requestInit.credentials).toBe("omit");

    const body = JSON.parse(requestInit.body as string) as Record<string, unknown>;
    expect(body).toEqual({ site: "proj_abc", url: "https://shop.example.com/pricing", referrer: null, type: "pageview" });
  });

  it("sends a custom_event with its name and props", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(noContentResponse());
    await sendMeasureHit({
      site: "proj_abc",
      url: "https://shop.example.com/checkout/complete",
      type: "custom_event",
      name: "signup_completed",
      props: { plan: "indie" },
      fetchImpl,
    });

    const requestInit = fetchImpl.mock.calls[0]![1] as RequestInit;
    const body = JSON.parse(requestInit.body as string) as Record<string, unknown>;
    expect(body.type).toBe("custom_event");
    expect(body.name).toBe("signup_completed");
    expect(body.props).toEqual({ plan: "indie" });
  });

  it("refuses to send a custom_event with no name, and never calls fetch", async () => {
    const fetchImpl = vi.fn();
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", type: "custom_event", fetchImpl });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("passes an explicit referrer through, and defaults a missing one to null", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(noContentResponse());
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", referrer: "https://twitter.com/", fetchImpl });
    const body = JSON.parse((fetchImpl.mock.calls[0]![1] as RequestInit).body as string) as Record<string, unknown>;
    expect(body.referrer).toBe("https://twitter.com/");
  });

  it("respects a custom baseUrl", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(noContentResponse());
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", baseUrl: "https://ingest.example.test", fetchImpl });
    expect(fetchImpl.mock.calls[0]![0]).toBe("https://ingest.example.test/m");
  });

  it("never throws when fetch rejects", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("network down"));
    await expect(sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", fetchImpl })).resolves.toBeUndefined();
  });

  it("never throws when there is no fetch implementation available", async () => {
    vi.stubGlobal("fetch", undefined);
    await expect(sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/" })).resolves.toBeUndefined();
  });

  it("does not retry a failed send", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("network down"));
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", fetchImpl });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("logs via console.warn on failure only when debug is true", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const fetchImpl = vi.fn().mockRejectedValue(new Error("network down"));
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", fetchImpl, debug: true });
    expect(warnSpy).toHaveBeenCalled();
  });

  it("stays silent on failure when debug is not set", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const fetchImpl = vi.fn().mockRejectedValue(new Error("network down"));
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", fetchImpl });
    expect(warnSpy).not.toHaveBeenCalled();
  });

  it("warns in debug mode when custom_event has no name", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const fetchImpl = vi.fn();
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", type: "custom_event", name: "", fetchImpl, debug: true });
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(warnSpy).toHaveBeenCalled();
  });

  it("warns in debug mode when fetch is missing", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", undefined);
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", debug: true });
    expect(warnSpy).toHaveBeenCalled();
  });

  it("strips a trailing slash from baseUrl", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(noContentResponse());
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", baseUrl: "https://ingest.example.test/", fetchImpl });
    expect(fetchImpl.mock.calls[0]![0]).toBe("https://ingest.example.test/m");
  });

  it("omits name and props on a pageview", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(noContentResponse());
    await sendMeasureHit({ site: "proj_abc", url: "https://shop.example.com/", fetchImpl });
    const body = JSON.parse((fetchImpl.mock.calls[0]![1] as RequestInit).body as string) as Record<string, unknown>;
    expect(body).not.toHaveProperty("name");
    expect(body).not.toHaveProperty("props");
  });
});
