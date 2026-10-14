import { describe, expect, it } from "vitest";
import { generateEventId } from "./id";

describe("generateEventId", () => {
  it("is err_-prefixed", () => {
    expect(generateEventId()).toMatch(/^err_/);
  });

  it("produces a UUIDv7-shaped id (version nibble 7, variant bits 10)", () => {
    const id = generateEventId();
    const uuid = id.slice("err_".length);
    expect(uuid).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it("generates unique ids across many calls", () => {
    const ids = new Set(Array.from({ length: 1000 }, () => generateEventId()));
    expect(ids.size).toBe(1000);
  });

  it("is time-ordered: ids generated later sort lexicographically after earlier ones once the millisecond clock advances", async () => {
    const first = generateEventId();
    await new Promise((resolve) => setTimeout(resolve, 5));
    const second = generateEventId();
    expect(second.slice("err_".length).localeCompare(first.slice("err_".length))).toBeGreaterThan(0);
  });
});
