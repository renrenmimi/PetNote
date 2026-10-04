import { act, render, screen } from "@testing-library/react";
import { fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The screen, with the code flag on.
 *
 * `passwordResetOtpEnabled` is read once at module scope — a build either has
 * this path or it does not — so switching it means resetting the module
 * registry and importing again. Everything below therefore imports inside the
 * test rather than at the top of the file.
 */

const requestPasswordResetCode = vi.fn();
const confirmPasswordResetCode = vi.fn();
const sendPasswordResetEmail = vi.fn();

vi.mock("../../services/firebase", () => ({
  auth: {},
  functions: {},
}));

vi.mock("firebase/auth", () => ({
  sendPasswordResetEmail: (...a: unknown[]) => sendPasswordResetEmail(...a),
}));

/**
 * The real translator, without the provider.
 *
 * LanguageProvider pulls in useAuth and the settings service, none of which
 * this screen's copy depends on. Mocking `t` to echo its key would be worse
 * than useless here: half these tests are *about* the copy, and would pass
 * against a screen that said "forgot.subtitleCode" to a person. So the mock
 * uses the same `messages` table the app ships.
 */
vi.mock("../../hooks/useLanguage", async () => {
  const { messages, formatMessage } =
    await vi.importActual<typeof import("../../i18n/messages")>(
      "../../i18n/messages"
    );
  return {
    useLanguage: () => ({
      language: "en",
      locale: "en-US",
      setLanguage: async () => {},
      t: (key: string, values?: Record<string, unknown>) =>
        formatMessage(
          (messages as Record<string, Record<string, string>>).en[key] ?? key,
          values as never
        ),
    }),
  };
});

async function renderPage({ otp }: { otp: boolean }) {
  vi.resetModules();
  vi.stubEnv("VITE_PASSWORD_RESET_OTP", otp ? "1" : "0");

  vi.doMock("../../services/passwordReset", async (importOriginal) => {
    const original =
      await importOriginal<typeof import("../../services/passwordReset")>();
    return {
      ...original,
      passwordResetOtpEnabled: otp,
      requestPasswordResetCode: (...a: unknown[]) =>
        requestPasswordResetCode(...a),
      confirmPasswordResetCode: (...a: unknown[]) =>
        confirmPasswordResetCode(...a),
    };
  });

  const { ForgotPassword } = await import("../ForgotPassword");
  return render(
    <MemoryRouter>
      <ForgotPassword />
    </MemoryRouter>
  );
}

/** Walks the email step through to the code step. */
async function reachCodeStep() {
  requestPasswordResetCode.mockResolvedValueOnce({
    challengeId: "11111111-2222-3333-4444-555555555555",
    expiresInSeconds: 600,
  });
  fireEvent.change(screen.getByPlaceholderText("you@example.com"), {
    target: { value: "someone@example.com" },
  });
  await act(async () => {
    fireEvent.submit(screen.getByRole("button", { name: /send code/i }));
    await Promise.resolve();
  });
}

describe("ForgotPassword", () => {
  beforeEach(() => {
    requestPasswordResetCode.mockReset();
    confirmPasswordResetCode.mockReset();
    sendPasswordResetEmail.mockReset();
    vi.unstubAllEnvs();
  });

  it("does not promise a link when the build sends a code", async () => {
    await renderPage({ otp: true });
    // The email step is shared by both flows, and its copy used to say "we'll
    // send you a reset link" no matter which one the build actually ran.
    expect(screen.getByText(/send you a code/i)).toBeTruthy();
    expect(screen.queryByText(/reset link/i)).toBeNull();
  });

  it("still says link when the code flow is off", async () => {
    await renderPage({ otp: false });
    // Both the subtitle and the button say it, which is the point: the old
    // link flow stays intact and unchanged until the code flow is verified.
    expect(screen.getByRole("button", { name: /send reset link/i })).toBeTruthy();
    expect(screen.getByText(/send you a reset link/i)).toBeTruthy();
    expect(screen.queryByRole("button", { name: /send code/i })).toBeNull();
  });

  it("carries the address into the code step for a password manager", async () => {
    await renderPage({ otp: true });
    await reachCodeStep();

    // Not for the person — for iOS Keychain and 1Password, which will not
    // offer to save a new password unless a username field in the same form
    // says which account it belongs to.
    const username = document.querySelector<HTMLInputElement>(
      'input[autocomplete="username"]'
    );
    expect(username).not.toBeNull();
    expect(username!.value).toBe("someone@example.com");
    expect(username!.readOnly).toBe(true);
    expect(username!.getAttribute("aria-hidden")).toBe("true");
    expect(username!.tabIndex).toBe(-1);
  });

  it("asks the keychain for a new password, not the saved one", async () => {
    await renderPage({ otp: true });
    await reachCodeStep();
    const password = document.querySelector<HTMLInputElement>(
      'input[type="password"]'
    );
    expect(password?.getAttribute("autocomplete")).toBe("new-password");
  });

  it("ends on a way back to login rather than a sentence", async () => {
    await renderPage({ otp: true });
    await reachCodeStep();

    fireEvent.change(screen.getByLabelText(/verification code/i), {
      target: { value: "123456" },
    });
    fireEvent.change(
      document.querySelector<HTMLInputElement>('input[type="password"]')!,
      { target: { value: "Str0ng!Passw0rd" } }
    );

    confirmPasswordResetCode.mockResolvedValueOnce(undefined);
    await act(async () => {
      fireEvent.submit(screen.getByRole("button", { name: /set new password/i }));
      await Promise.resolve();
    });

    const link = screen.getByRole("link", { name: /go to login/i });
    expect(link.getAttribute("href")).toBe("/login");
    // The form is gone, so there is nothing left to submit by accident.
    expect(screen.queryByLabelText(/verification code/i)).toBeNull();
  });

  it("lets somebody who mistyped their address start again", async () => {
    await renderPage({ otp: true });
    await reachCodeStep();

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /different email/i }));
    });

    // Back on the email step, with the old challenge dropped rather than
    // carried into a resend for a different address.
    expect(screen.getByRole("button", { name: /send code/i })).toBeTruthy();
    expect(screen.queryByLabelText(/verification code/i)).toBeNull();
  });

  it("holds the resend button for the server's cooldown", async () => {
    await renderPage({ otp: true });
    await reachCodeStep();

    const resend = screen.getByRole("button", { name: /resend in/i });
    // Disabled and saying how long, rather than enabled into a request the
    // server will refuse.
    expect((resend as HTMLButtonElement).disabled).toBe(true);
  });
});
