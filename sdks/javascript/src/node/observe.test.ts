import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetForTests, captureException } from "../core/observe/client";
import { close, init, type NodeProcessLike } from "./observe";

/**
 * `processImpl` is injected rather than using the real `process` global
 * (see `./observe.ts`'s file comment): attaching real `uncaughtException`
 * listeners to the actual test-runner process, or calling the real
 * `process.exit`, would crash or hang the test run itself.
 */
function fakeProcess(): NodeProcessLike & { listenerCount(event: string): number; exitCalls: number[] } {
  const listeners: Record<string, Array<(...args: unknown[]) => void>> = {};
  return {
    on: vi.fn((event: string, listener: (...args: unknown[]) => void) => {
      (listeners[event] ??= []).push(listener);
    }) as NodeProcessLike["on"],
    off: vi.fn((event: string, listener: (...args: unknown[]) => void) => {
      listeners[event] = (listeners[event] ?? []).filter((l) => l !== listener);
    }),
    exitCalls: [] as number[],
    exit(code: number): never {
      // A real `process.exit` never returns; faking that with a `throw`
      // would turn the SDK's un-awaited `.finally(() => exit(1))` into an
      // unhandled rejection that's an artifact of this test double, not a
      // real product behavior -- so this fake just records the call and
      // returns (lying about `never`, which is fine for a test double).
      this.exitCalls.push(code);
      return undefined as never;
    },
    listenerCount(event: string) {
      return (listeners[event] ?? []).length;
    },
    fire(event: string, ...args: unknown[]) {
      for (const l of [...(listeners[event] ?? [])]) l(...args);
    },
  } as unknown as NodeProcessLike & { listenerCount(event: string): number; exitCalls: number[]; fire(event: string, ...args: unknown[]): void };
}

function okResponse(): Response {
  return { ok: true, status: 202, headers: new Headers() } as Response;
}

describe("node Observe: automatic global error capture (section 2)", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(async () => {
    // `close()` detaches this module's process listeners (module-level
    // state, so it outlives any one `it()` block) -- without this, the
    // NEXT test's `init()` would see a listener already registered and
    // silently no-op against its own fresh fake process.
    await close();
    __resetForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("uncaughtException is captured with mechanism uncaughtException, flushed, then the process is exited non-zero", async () => {
    const proc = fakeProcess() as ReturnType<typeof fakeProcess> & { fire(event: string, ...args: unknown[]): void };
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, processImpl: proc });

    const boom = new Error("uncaught");
    proc.fire("uncaughtException", boom);
    await vi.runAllTimersAsync();
    await Promise.resolve();

    expect(proc.exitCalls).toEqual([1]);
    const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
    expect(call).toBeDefined();
    const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
    expect(body.items[0]!.mechanism).toBe("uncaughtException");
  });

  it("unhandledRejection is captured with mechanism unhandledRejection but does NOT exit the process (deliberate -- see ./observe.ts)", async () => {
    const proc = fakeProcess() as ReturnType<typeof fakeProcess> & { fire(event: string, ...args: unknown[]): void };
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, processImpl: proc });

    proc.fire("unhandledRejection", new Error("rejected"));
    await vi.runAllTimersAsync();

    expect(proc.exitCalls).toEqual([]);
    const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
    const body = JSON.parse((call![1] as RequestInit).body as string) as { items: Array<Record<string, unknown>> };
    expect(body.items[0]!.mechanism).toBe("unhandledRejection");
  });

  it("captureUnhandled: false registers no process listeners", () => {
    const proc = fakeProcess();
    init({ key: "alp_p_test", fetchImpl: vi.fn(), processImpl: proc, captureUnhandled: false });
    expect(proc.listenerCount("uncaughtException")).toBe(0);
    expect(proc.listenerCount("unhandledRejection")).toBe(0);
  });

  it("reinit with captureUnhandled: false detaches existing process listeners", () => {
    const proc = fakeProcess();
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, processImpl: proc });
    expect(proc.listenerCount("uncaughtException")).toBe(1);
    expect(proc.listenerCount("unhandledRejection")).toBe(1);

    init({ key: "alp_p_test", fetchImpl, processImpl: proc, captureUnhandled: false });
    expect(proc.listenerCount("uncaughtException")).toBe(0);
    expect(proc.listenerCount("unhandledRejection")).toBe(0);
  });

  it("close() detaches the process listeners", async () => {
    const proc = fakeProcess();
    init({ key: "alp_p_test", fetchImpl: vi.fn().mockResolvedValue(okResponse()), processImpl: proc });
    expect(proc.listenerCount("uncaughtException")).toBe(1);
    await close();
    expect(proc.listenerCount("uncaughtException")).toBe(0);
  });

  it("a capture that lands while the uncaughtException flush is still in flight is drained too, and the process still exits (issue #43)", async () => {
    const proc = fakeProcess() as ReturnType<typeof fakeProcess> & { fire(event: string, ...args: unknown[]): void };
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, processImpl: proc });

    const boom = new Error("uncaught");
    proc.fire("uncaughtException", boom);
    // The handler's captureException + flush() call runs synchronously up
    // to sendBatch's first `await`, so exactly one POST is already in
    // flight here -- before any timer/microtask has been advanced.
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    // A second capture lands mid-flight -- e.g. a log statement or another
    // handler running before this process actually exits. It must still be
    // delivered, and the process must still exit cleanly rather than hang.
    captureException(new Error("landed mid-flight"));

    await vi.runAllTimersAsync();
    await Promise.resolve();

    expect(proc.exitCalls).toEqual([1]);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    const totalItems = fetchImpl.mock.calls.reduce((sum, call) => {
      const body = JSON.parse((call[1] as RequestInit).body as string) as { items: unknown[] };
      return sum + body.items.length;
    }, 0);
    expect(totalItems).toBe(2);
  });

  it("a manual captureException for the SAME error object the uncaughtException handler also sees is deduplicated to one event", async () => {
    const proc = fakeProcess() as ReturnType<typeof fakeProcess> & { fire(event: string, ...args: unknown[]): void };
    const fetchImpl = vi.fn().mockResolvedValue(okResponse());
    init({ key: "alp_p_test", fetchImpl, processImpl: proc });

    const shared = new Error("shared");
    captureException(shared);
    proc.fire("uncaughtException", shared);
    await vi.runAllTimersAsync();
    await Promise.resolve();

    const call = fetchImpl.mock.calls.find(([url]) => url === "https://ingest.postdeploy.dev/e/errors");
    const body = JSON.parse((call![1] as RequestInit).body as string) as { items: unknown[] };
    expect(body.items.length).toBe(1);
  });
});
