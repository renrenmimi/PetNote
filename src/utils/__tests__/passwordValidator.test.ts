import { describe, expect, it } from "vitest";
import { validatePassword } from "../passwordValidator";

describe("validatePassword", () => {
  it("flags every missing rule on a short, lowercase password", () => {
    const result = validatePassword("abc");
    expect(result.isValid).toBe(false);
    // length, uppercase, number, special — all four must surface
    expect(result.errors).toEqual(
      expect.arrayContaining([
        "At least 8 characters",
        "At least one uppercase letter (A-Z)",
        "At least one number (0-9)",
        "At least one special character (!@#$%...)",
      ])
    );
  });

  it("rejects passwords longer than 64 characters", () => {
    const long = `${"A1b!".repeat(20)}xyz`;
    const result = validatePassword(long);
    expect(result.isValid).toBe(false);
    expect(result.errors).toContain("Maximum 64 characters");
  });

  it("accepts a password meeting every rule and rates it medium", () => {
    const result = validatePassword("Abcdefg1!");
    expect(result.isValid).toBe(true);
    expect(result.errors).toEqual([]);
    expect(result.strength).toBe("medium");
  });

  it("rates 12+ char valid passwords as strong", () => {
    const result = validatePassword("Abcdefgh1234!");
    expect(result.isValid).toBe(true);
    expect(result.strength).toBe("strong");
  });

  it("returns weak strength for partially-valid short passwords", () => {
    const result = validatePassword("abc12");
    expect(result.isValid).toBe(false);
    expect(result.strength).toBe("weak");
  });
});
