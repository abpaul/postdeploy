import { describe, expect, it } from "vitest";
import { mergeScope } from "./scope";

describe("mergeScope", () => {
  it("with no ambient and no overrides, returns empty fields", () => {
    const result = mergeScope(undefined, undefined);
    expect(result.user).toBeUndefined();
    expect(result.tags).toBeUndefined();
    expect(result.contexts).toEqual({});
    expect(result.breadcrumbs).toEqual([]);
  });

  it("passes through ambient values untouched when there are no overrides", () => {
    const result = mergeScope({ user: { id: "u1" }, tags: { plan: "agency" }, contexts: { cart: { items: 3 } }, breadcrumbs: [{ message: "a" }] }, undefined);
    expect(result.user).toEqual({ id: "u1" });
    expect(result.tags).toEqual({ plan: "agency" });
    expect(result.contexts).toEqual({ cart: { items: 3 } });
    expect(result.breadcrumbs).toEqual([{ message: "a" }]);
  });

  it("an explicit per-capture user overrides the ambient one", () => {
    const result = mergeScope({ user: { id: "ambient" } }, { user: { id: "override" } });
    expect(result.user).toEqual({ id: "override" });
  });

  it("an explicit user: null clears the ambient user for this capture", () => {
    const result = mergeScope({ user: { id: "ambient" } }, { user: null });
    expect(result.user).toBeUndefined();
  });

  it("tags shallow-merge, override wins on key collision", () => {
    const result = mergeScope({ tags: { plan: "agency", region: "eu" } }, { tags: { plan: "enterprise" } });
    expect(result.tags).toEqual({ plan: "enterprise", region: "eu" });
  });

  it("contexts shallow-merge by named key, override wins on collision", () => {
    const result = mergeScope({ contexts: { cart: { items: 3 }, device: { os: "mac" } } }, { contexts: { cart: { items: 5 } } });
    expect(result.contexts).toEqual({ cart: { items: 5 }, device: { os: "mac" } });
  });

  it("breadcrumbs concatenate ambient trail first, then per-capture ones", () => {
    const result = mergeScope({ breadcrumbs: [{ message: "ambient-1" }] }, { breadcrumbs: [{ message: "explicit-1" }] });
    expect(result.breadcrumbs.map((b) => b.message)).toEqual(["ambient-1", "explicit-1"]);
  });
});
