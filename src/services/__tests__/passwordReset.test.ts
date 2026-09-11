import { describe, expect, it, vi } from "vitest";

// services/firebase throws without the Vite env vars, and nothing here needs
// a real Functions instance — only the pure classifier is under test.
vi.mock("../firebase", () => ({ functions: {} }));

const { classifyResetFailure, passwordResetOtpEnabled, RESET_CODE_LENGTH } =
  await import("../passwordReset");

const callableError = (code: string, message = "") => ({ code, message });

describe("classifyResetFailure", () => {
  it("separates an already-used code from a wrong one", () => {
    // This is the lost-response case: the password did change, the client
    // never heard, and the retry lands here. Telling somebody their correct
    // code was wrong would send them round the loop again.
    expect(
      classifyResetFailure(
        callableError(
          "functions/failed-precondition",
          "That code has already been used. Request a new one."
        )
      )
    ).toBe("already-used");

    expect(
      classifyResetFailure(
        callableError("functions/invalid-argument", "That code is not correct.")
      )
    ).toBe("wrong-code");
  });

  it("names expiry, rate limiting and a weak password distinctly", () => {
    expect(
      classifyResetFailure(callableError("functions/deadline-exceeded"))
    ).toBe("expired");
    expect(
      classifyResetFailure(callableError("functions/resource-exhausted"))
    ).toBe("too-many");
    expect(
      classifyResetFailure(
        callableError(
          "functions/invalid-argument",
          "Password needs an uppercase letter."
        )
      )
    ).toBe("weak-password");
  });

  it("recognises the account states the server may report", () => {
    expect(
      classifyResetFailure(
        callableError(
          "functions/failed-precondition",
          "This account signs in with Google. Use Continue with Google instead."
        )
      )
    ).toBe("google-only");
    expect(
      classifyResetFailure(
        callableError(
          "functions/failed-precondition",
          "Email delivery is not configured for this environment."
        )
      )
    ).toBe("not-configured");
    expect(
      classifyResetFailure(
        callableError(
          "functions/failed-precondition",
          "This account cannot be used to sign in right now."
        )
      )
    ).toBe("account-unavailable");
  });

  it("falls back without inventing a cause", () => {
    expect(classifyResetFailure(new Error("boom"))).toBe("unknown");
    expect(classifyResetFailure(undefined)).toBe("unknown");
    expect(classifyResetFailure("nope")).toBe("unknown");
  });

  it("is off unless the build set the flag", () => {
    // Guards the thing that matters most about this feature right now: an
    // unconfigured environment must not invite people into it.
    expect(passwordResetOtpEnabled).toBe(false);
    expect(RESET_CODE_LENGTH).toBe(6);
  });
});
