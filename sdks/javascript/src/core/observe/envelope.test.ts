import { describe, expect, it } from "vitest";
import { capContext, capFrames, capText, type WireStackFrame } from "./envelope";

describe("capText", () => {
  it("passes undefined through unchanged", () => {
    expect(capText(undefined, 10)).toBeUndefined();
  });

  it("passes a short string through unchanged", () => {
    expect(capText("hello", 10)).toBe("hello");
  });

  it("truncates a long string to maxLength", () => {
    expect(capText("x".repeat(20), 10)).toHaveLength(10);
  });

  it("strips a trailing lone high surrogate left by a naive slice", () => {
    const surrogatePair = "😀"; // one emoji, 2 UTF-16 code units
    const value = `abc${surrogatePair}`; // length 5; a cut at 4 splits the pair
    const capped = capText(value, 4)!;
    expect(capped).toBe("abc");
    expect(capped.charCodeAt(capped.length - 1)).toBeLessThan(0xd800);
  });
});

describe("capContext", () => {
  it("returns the value unchanged when under the cap", () => {
    const value = { extra: { a: 1 } };
    expect(capContext(value, 1000)).toBe(value);
  });

  it("replaces an oversized value with a truncation marker", () => {
    const value = { extra: { blob: "x".repeat(1000) } };
    const capped = capContext(value, 50);
    expect(capped).toEqual({ _truncated: true, _original_chars: expect.any(Number) });
  });
});

describe("capFrames", () => {
  function frame(n: number): WireStackFrame {
    return { file: `/app/file-${n}.js`, function: `fn${n}`, lineno: n, colno: n };
  }

  it("returns all frames when under the budget", () => {
    const frames = [frame(1), frame(2)];
    expect(capFrames(frames, 10_000)).toEqual(frames);
  });

  it("drops trailing frames until the serialized array fits the budget", () => {
    const frames = Array.from({ length: 50 }, (_, i) => frame(i));
    const capped = capFrames(frames, 200);
    expect(capped.length).toBeLessThan(frames.length);
    expect(JSON.stringify(capped).length).toBeLessThanOrEqual(200);
    // Kept frames are a prefix (top-of-stack first, per ingest.md's frame ordering).
    expect(capped).toEqual(frames.slice(0, capped.length));
  });

  it("returns an empty array rather than throwing when even one frame exceeds the budget", () => {
    expect(capFrames([frame(1)], 1)).toEqual([]);
  });
});
