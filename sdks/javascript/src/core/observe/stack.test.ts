import { describe, expect, it } from "vitest";
import { parseStack } from "./stack";

describe("parseStack", () => {
  it("returns an empty array for undefined", () => {
    expect(parseStack(undefined)).toEqual([]);
  });

  it("parses a V8 stack with named function frames", () => {
    const stack = ["TypeError: Cannot read properties of undefined", "    at processOrder (/assets/checkout.js:142:18)", "    at onSubmit (/assets/checkout.js:88:5)"].join("\n");
    expect(parseStack(stack)).toEqual([
      { function: "processOrder", file: "/assets/checkout.js", lineno: 142, colno: 18 },
      { function: "onSubmit", file: "/assets/checkout.js", lineno: 88, colno: 5 },
    ]);
  });

  it("parses an anonymous frame with no function name", () => {
    const stack = ["Error: boom", "    at /assets/main.js:10:2"].join("\n");
    expect(parseStack(stack)).toEqual([{ file: "/assets/main.js", lineno: 10, colno: 2 }]);
  });

  it("skips a line that doesn't match the V8 frame shape", () => {
    const stack = ["Error: boom", "    at fn (native)", "    at real (/app.js:1:1)"].join("\n");
    expect(parseStack(stack)).toEqual([{ function: "real", file: "/app.js", lineno: 1, colno: 1 }]);
  });

  it("preserves top-of-stack-first order", () => {
    const stack = ["Error", "    at inner (/a.js:1:1)", "    at outer (/b.js:2:2)"].join("\n");
    const frames = parseStack(stack);
    expect(frames[0]?.function).toBe("inner");
    expect(frames[1]?.function).toBe("outer");
  });
});
