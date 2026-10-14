import { afterEach, describe, expect, it } from "vitest";
import { __resetDedupForTests, resolveDedupId } from "./dedup";

describe("resolveDedupId", () => {
  afterEach(() => {
    __resetDedupForTests();
  });

  it("a fresh Error object is never a duplicate", () => {
    const result = resolveDedupId(new Error("boom"), "err_fresh");
    expect(result).toEqual({ id: "err_fresh", isDuplicate: false });
  });

  it("the SAME Error object captured again returns the first id and is marked a duplicate", () => {
    const error = new Error("boom");
    const first = resolveDedupId(error, "err_first");
    const second = resolveDedupId(error, "err_second");
    expect(first).toEqual({ id: "err_first", isDuplicate: false });
    expect(second).toEqual({ id: "err_first", isDuplicate: true });
  });

  it("two DIFFERENT Error objects (even with the same message) are never deduped against each other", () => {
    const first = resolveDedupId(new Error("boom"), "err_a");
    const second = resolveDedupId(new Error("boom"), "err_b");
    expect(first.isDuplicate).toBe(false);
    expect(second.isDuplicate).toBe(false);
  });

  it("the same primitive thrown value (e.g. a string) is deduped too", () => {
    const first = resolveDedupId("just a string", "err_a");
    const second = resolveDedupId("just a string", "err_a-dup");
    expect(first).toEqual({ id: "err_a", isDuplicate: false });
    expect(second).toEqual({ id: "err_a", isDuplicate: true });
  });

  it("different primitive values are not deduped against each other", () => {
    const first = resolveDedupId("string one", "err_a");
    const second = resolveDedupId("string two", "err_b");
    expect(first.isDuplicate).toBe(false);
    expect(second.isDuplicate).toBe(false);
  });
});
