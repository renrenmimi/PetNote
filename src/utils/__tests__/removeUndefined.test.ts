import { describe, expect, it } from "vitest";
import { removeUndefined } from "../removeUndefined";

describe("removeUndefined", () => {
  it("removes undefined keys from a plain object", () => {
    const result = removeUndefined({ a: 1, b: undefined, c: "x" });
    expect(result).toEqual({ a: 1, c: "x" });
    expect("b" in result).toBe(false);
  });

  it("preserves null, false, 0, and empty string", () => {
    const result = removeUndefined({
      a: null,
      b: false,
      c: 0,
      d: "",
      e: undefined,
    });
    expect(result).toEqual({ a: null, b: false, c: 0, d: "" });
  });

  it("recurses into nested plain objects", () => {
    const result = removeUndefined({
      outer: { kept: 1, dropped: undefined },
      sibling: undefined,
    });
    expect(result).toEqual({ outer: { kept: 1 } });
  });

  it("filters undefined entries out of arrays and recurses", () => {
    const result = removeUndefined([
      1,
      undefined,
      { keep: 2, drop: undefined },
      [undefined, 3],
    ]);
    expect(result).toEqual([1, { keep: 2 }, [3]]);
  });

  it("returns primitives untouched", () => {
    expect(removeUndefined(42)).toBe(42);
    expect(removeUndefined("hello")).toBe("hello");
    expect(removeUndefined(null)).toBeNull();
  });

  it("does not strip prototype-bearing class instances", () => {
    class Ref {
      kept = 1;
    }
    const ref = new Ref();
    const out = removeUndefined({ ref });
    // Ref is not a plain object, so it must be passed through as-is rather
    // than serialized into a stripped POJO.
    expect(out.ref).toBe(ref);
  });
});
