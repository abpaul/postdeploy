import { afterEach, describe, expect, it, vi } from "vitest";
import { postJsonWithRetries } from "./transport";

function okResponse(): Response {
  return { ok: true, status: 202, headers: new Headers() } as Response;
}

function errorResponse(status: number, retryAfter?: string): Response {
  return { ok: false, status, headers: new Headers(retryAfter === undefined ? undefined : { "Retry-After": retryAfter }) } as Response;
}

describe("postJsonWithRetries", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("returns sent on the first 2xx", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    await expect(postJsonWithRetries("https://ingest.test/e/errors", "{}", { "content-type": "application/json" }, fetchImpl)).resolves.toEqual({
      outcome: "sent",
    });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("drops a permanent 400 without retrying", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(errorResponse(400));
    await expect(postJsonWithRetries("https://ingest.test/e/errors", "{}", {}, fetchImpl)).resolves.toEqual({
      outcome: "dropped_permanent",
    });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("retries a 503 then succeeds", async () => {
    vi.useFakeTimers();
    const fetchImpl = vi.fn().mockResolvedValueOnce(errorResponse(503)).mockResolvedValueOnce(okResponse());
    const promise = postJsonWithRetries("https://ingest.test/e/errors", "{}", {}, fetchImpl);
    await vi.runAllTimersAsync();
    await expect(promise).resolves.toEqual({ outcome: "sent" });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("honors Retry-After on 429", async () => {
    vi.useFakeTimers();
    vi.spyOn(Math, "random").mockReturnValue(0.5);
    const fetchImpl = vi.fn().mockResolvedValueOnce(errorResponse(429, "7")).mockResolvedValueOnce(okResponse());
    const promise = postJsonWithRetries("https://ingest.test/e/errors", "{}", {}, fetchImpl);
    await vi.advanceTimersByTimeAsync(6_999);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    await expect(promise).resolves.toEqual({ outcome: "sent" });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("treats a missing Retry-After as ordinary backoff", async () => {
    vi.useFakeTimers();
    const fetchImpl = vi.fn().mockResolvedValueOnce(errorResponse(429, "")).mockResolvedValueOnce(okResponse());
    const promise = postJsonWithRetries("https://ingest.test/e/errors", "{}", {}, fetchImpl);
    await vi.runAllTimersAsync();
    await expect(promise).resolves.toEqual({ outcome: "sent" });
  });

  it("returns exhausted after three network failures", async () => {
    vi.useFakeTimers();
    const fetchImpl = vi.fn().mockRejectedValue(new Error("down"));
    const promise = postJsonWithRetries("https://ingest.test/e/errors", "{}", {}, fetchImpl);
    await vi.runAllTimersAsync();
    const result = await promise;
    expect(result.outcome).toBe("exhausted");
    expect(fetchImpl).toHaveBeenCalledTimes(3);
  });

  it("never throws when fetchImpl throws", async () => {
    vi.useFakeTimers();
    const fetchImpl = vi.fn().mockImplementation(() => {
      throw new Error("sync boom");
    });
    const promise = postJsonWithRetries("https://ingest.test/e/errors", "{}", {}, fetchImpl);
    await vi.runAllTimersAsync();
    await expect(promise).resolves.toMatchObject({ outcome: "exhausted" });
  });
});
