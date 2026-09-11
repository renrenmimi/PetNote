import { describe, expect, it } from "vitest";

import { mapAuthError } from "../authErrors";
import { messages } from "../../i18n/messages";

const err = (code: string) => ({ code, message: `Firebase: Error (${code}).` });

describe("mapAuthError", () => {
  it("gives the same notice for every wrong-credential code", () => {
    const notices = [
      "auth/user-not-found",
      "auth/wrong-password",
      "auth/invalid-credential",
      "auth/invalid-login-credentials",
    ].map((code) => mapAuthError(err(code)));

    // Telling these apart is account enumeration. They must be
    // indistinguishable to the person signing in.
    for (const notice of notices) {
      expect(notice).toEqual(notices[0]);
    }
    expect(notices[0]?.titleKey).toBe("login.invalidTitle");
  });

  it("names the email or the password, not the account's existence", () => {
    const notice = mapAuthError(err("auth/wrong-password"));
    const en = messages.en[notice!.titleKey];
    const zh = messages.zh[notice!.titleKey];
    const enBody = messages.en[notice!.messageKey];
    const zhBody = messages.zh[notice!.messageKey];

    expect(en.toLowerCase()).toContain("email or password");
    expect(zh).toContain("邮箱或密码");

    // The old copy pushed people to register again after a typo.
    expect(enBody.toLowerCase()).not.toContain("create an account");
    expect(zhBody).not.toContain("注册");
    // And it must not answer "does this email exist?" either way.
    for (const body of [enBody, zhBody, en, zh]) {
      expect(body.toLowerCase()).not.toContain("not registered");
      expect(body).not.toContain("没有注册");
      expect(body).not.toContain("找不到");
    }
  });

  it("distinguishes the failures a person can act on", () => {
    expect(mapAuthError(err("auth/network-request-failed"))?.titleKey).toBe(
      "auth.networkErrorTitle"
    );
    expect(mapAuthError(err("auth/too-many-requests"))?.titleKey).toBe(
      "auth.tooManyRequestsTitle"
    );
    expect(mapAuthError(err("auth/user-disabled"))?.titleKey).toBe(
      "auth.userDisabledTitle"
    );
    expect(mapAuthError(err("auth/popup-blocked"))?.titleKey).toBe(
      "auth.popupBlockedTitle"
    );
    expect(mapAuthError(err("auth/invalid-email"))?.titleKey).toBe(
      "signup.invalidEmailTitle"
    );
  });

  it("says nothing when the person closed the Google sheet themselves", () => {
    expect(mapAuthError(err("auth/popup-closed-by-user"))).toBeNull();
    expect(mapAuthError(err("auth/cancelled-popup-request"))).toBeNull();
    expect(mapAuthError(err("auth/user-cancelled"))).toBeNull();
  });

  it("never leaks the raw SDK text for an unrecognised code", () => {
    const notice = mapAuthError(err("auth/some-code-nobody-mapped"));
    expect(notice).not.toBeNull();
    expect(notice?.messageKey).toBe("auth.genericErrorMessage");
    for (const lang of ["en", "zh"] as const) {
      const text = messages[lang][notice!.messageKey];
      expect(text).not.toContain("Firebase");
      expect(text).not.toContain("auth/");
    }
  });

  it("handles a thrown value that is not a Firebase error at all", () => {
    expect(mapAuthError(new Error("boom"))?.messageKey).toBe(
      "auth.genericErrorMessage"
    );
    expect(mapAuthError("boom")?.messageKey).toBe("auth.genericErrorMessage");
    expect(mapAuthError(undefined)?.messageKey).toBe("auth.genericErrorMessage");
  });

  it("has both languages for every key it can return", () => {
    const codes = [
      "auth/invalid-email",
      "auth/wrong-password",
      "auth/network-request-failed",
      "auth/too-many-requests",
      "auth/user-disabled",
      "auth/popup-blocked",
      "auth/account-exists-with-different-credential",
      "auth/operation-not-allowed",
      "auth/unknown",
    ];
    for (const code of codes) {
      const notice = mapAuthError(err(code));
      expect(notice, code).not.toBeNull();
      for (const lang of ["en", "zh"] as const) {
        expect(messages[lang][notice!.titleKey], `${code} ${lang} title`).toBeTruthy();
        expect(
          messages[lang][notice!.messageKey],
          `${code} ${lang} message`
        ).toBeTruthy();
      }
    }
  });
});
