import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions";

/**
 * Transactional email, for the password reset code.
 *
 * Firebase Authentication sends its own templated mail for the link-based
 * reset, but it has no way to send a message this project composes, so a
 * numeric code needs a transactional provider.
 *
 * Nothing here is active until both secrets are set. With them unset,
 * `sendPasswordResetCodeEmail` reports `not-configured` and the caller
 * refuses the request rather than telling somebody a code is on its way. That
 * is why the OTP entry point stays behind a flag that is off by default: an
 * unconfigured environment must not invite people into a flow that cannot
 * finish.
 *
 * The provider is one function, so swapping vendors is one edit. The request
 * shape below is Resend's (`POST /emails`, bearer token, JSON); Postmark and
 * SendGrid differ only in field names and path.
 */

export const TRANSACTIONAL_EMAIL_API_KEY = defineSecret(
  "TRANSACTIONAL_EMAIL_API_KEY"
);

/**
 * The From address. A secret only because it has to be set per environment,
 * not because it is confidential — and it must be on a domain verified with
 * the provider, or mail is either rejected outright or lands in spam, which
 * is indistinguishable from "slow" to the person waiting for it.
 */
export const TRANSACTIONAL_EMAIL_FROM = defineSecret(
  "TRANSACTIONAL_EMAIL_FROM"
);

/** The HMAC key that protects stored code digests. Never leaves the server. */
export const PASSWORD_RESET_CODE_SECRET = defineSecret(
  "PASSWORD_RESET_CODE_SECRET"
);

const PROVIDER_ENDPOINT = "https://api.resend.com/emails";
const SEND_TIMEOUT_MS = 10_000;

export type EmailSendResult =
  | { sent: true; providerMessageId: string | null; elapsedMs: number }
  | {
      sent: false;
      reason: "not-configured" | "provider-error" | "timeout";
      elapsedMs: number;
    };

function readSecret(secret: { value: () => string }): string {
  try {
    return secret.value() ?? "";
  } catch {
    // `.value()` throws when the secret was never bound to the function.
    return "";
  }
}

type SendArgs = {
  to: string;
  code: string;
  expiresInMinutes: number;
};

function renderCodeEmail(code: string, expiresInMinutes: number) {
  const subject = `Your PetNote password reset code: ${code}`;
  const text = [
    `Your PetNote password reset code is ${code}.`,
    "",
    `It expires in ${expiresInMinutes} minutes and can be used once.`,
    "",
    "If you did not ask to reset your password, you can ignore this message —",
    "nothing has changed on your account.",
  ].join("\n");
  return { subject, text };
}

/**
 * Sends the code and reports what happened, including how long the provider
 * took. The elapsed time is returned rather than logged with the address so
 * the caller can record latency without recording who it was for.
 *
 * The code itself is never logged, here or anywhere.
 */
export async function sendPasswordResetCodeEmail(
  args: SendArgs
): Promise<EmailSendResult> {
  const startedAt = Date.now();
  const apiKey = readSecret(TRANSACTIONAL_EMAIL_API_KEY);
  const from = readSecret(TRANSACTIONAL_EMAIL_FROM);

  if (apiKey.length === 0 || from.length === 0) {
    return {
      sent: false,
      reason: "not-configured",
      elapsedMs: Date.now() - startedAt,
    };
  }

  const { subject, text } = renderCodeEmail(args.code, args.expiresInMinutes);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SEND_TIMEOUT_MS);

  try {
    const response = await fetch(PROVIDER_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [args.to],
        subject,
        text,
      }),
      signal: controller.signal,
    });

    const elapsedMs = Date.now() - startedAt;
    if (!response.ok) {
      // Status only. The body can echo the recipient.
      logger.warn("Transactional email provider rejected a send", {
        status: response.status,
        elapsedMs,
      });
      return { sent: false, reason: "provider-error", elapsedMs };
    }

    let providerMessageId: string | null = null;
    try {
      const body = (await response.json()) as { id?: unknown };
      providerMessageId = typeof body.id === "string" ? body.id : null;
    } catch {
      // A 2xx with an unreadable body still means accepted.
    }

    // Accepted by the provider. That is not the same as delivered to an
    // inbox, and this log line says so deliberately: the only thing measured
    // here is how long the API call took.
    logger.info("Password reset code accepted by provider", {
      elapsedMs,
      providerMessageId,
    });
    return { sent: true, providerMessageId, elapsedMs };
  } catch (error) {
    const elapsedMs = Date.now() - startedAt;
    const aborted = (error as { name?: string } | null)?.name === "AbortError";
    logger.warn("Transactional email send failed", {
      elapsedMs,
      aborted,
    });
    return {
      sent: false,
      reason: aborted ? "timeout" : "provider-error",
      elapsedMs,
    };
  } finally {
    clearTimeout(timer);
  }
}
