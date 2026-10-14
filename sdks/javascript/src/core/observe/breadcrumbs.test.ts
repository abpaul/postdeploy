import { describe, expect, it } from "vitest";
import { createRingBuffer, pushBreadcrumb, snapshotBreadcrumbs, clearBreadcrumbs, stripQueryString } from "./breadcrumbs";
import { MAX_BREADCRUMB_CATEGORY_CHARS, MAX_BREADCRUMB_MESSAGE_CHARS } from "./envelope";

describe("stripQueryString", () => {
  it("strips everything from ? onward", () => {
    expect(stripQueryString("https://example.com/path?token=secret&x=1")).toBe("https://example.com/path");
  });

  it("passes through a URL with no query string unchanged", () => {
    expect(stripQueryString("https://example.com/path")).toBe("https://example.com/path");
  });
});

describe("ring buffer", () => {
  it("returns undefined for an empty buffer", () => {
    const buf = createRingBuffer(30);
    expect(snapshotBreadcrumbs(buf)).toBeUndefined();
  });

  it("appends breadcrumbs in order, oldest first", () => {
    const buf = createRingBuffer(30);
    pushBreadcrumb(buf, { category: "nav", message: "first" });
    pushBreadcrumb(buf, { category: "nav", message: "second" });
    const snap = snapshotBreadcrumbs(buf)!;
    expect(snap.map((c) => c.message)).toEqual(["first", "second"]);
  });

  it("evicts the oldest breadcrumb once max is exceeded", () => {
    const buf = createRingBuffer(2);
    pushBreadcrumb(buf, { message: "one" });
    pushBreadcrumb(buf, { message: "two" });
    pushBreadcrumb(buf, { message: "three" });
    const snap = snapshotBreadcrumbs(buf)!;
    expect(snap.map((c) => c.message)).toEqual(["two", "three"]);
  });

  it("a max of 0 makes pushBreadcrumb a permanent no-op", () => {
    const buf = createRingBuffer(0);
    pushBreadcrumb(buf, { message: "dropped" });
    expect(snapshotBreadcrumbs(buf)).toBeUndefined();
  });

  it("clearBreadcrumbs empties the buffer", () => {
    const buf = createRingBuffer(30);
    pushBreadcrumb(buf, { message: "one" });
    clearBreadcrumbs(buf);
    expect(snapshotBreadcrumbs(buf)).toBeUndefined();
  });

  it("stamps every breadcrumb with an ISO timestamp", () => {
    const buf = createRingBuffer(30);
    pushBreadcrumb(buf, { message: "one" });
    const [crumb] = snapshotBreadcrumbs(buf)!;
    expect(crumb!.ts).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it("truncates an oversized message/category to their caps", () => {
    const buf = createRingBuffer(30);
    pushBreadcrumb(buf, { category: "x".repeat(MAX_BREADCRUMB_CATEGORY_CHARS + 50), message: "y".repeat(MAX_BREADCRUMB_MESSAGE_CHARS + 50) });
    const [crumb] = snapshotBreadcrumbs(buf)!;
    expect(crumb!.category!.length).toBe(MAX_BREADCRUMB_CATEGORY_CHARS);
    expect(crumb!.message!.length).toBe(MAX_BREADCRUMB_MESSAGE_CHARS);
  });
});

describe("breadcrumb data scrubbing (AGENTS.md \"no raw personal data without a bound\")", () => {
  it("redacts password/secret/token/api-key-shaped keys in breadcrumb data", () => {
    const buf = createRingBuffer(30);
    pushBreadcrumb(buf, { category: "fetch", data: { password: "hunter2", authToken: "abc", api_key: "xyz", apiKey: "xyz2", secret: "s", safe: "kept" } });
    const [crumb] = snapshotBreadcrumbs(buf)!;
    const data = crumb!.data as Record<string, unknown>;
    expect(data.password).toBe("[Redacted]");
    expect(data.authToken).toBe("[Redacted]");
    expect(data.api_key).toBe("[Redacted]");
    expect(data.apiKey).toBe("[Redacted]");
    expect(data.secret).toBe("[Redacted]");
    expect(data.safe).toBe("kept");
  });
});
