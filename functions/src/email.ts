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

/**
 * Every secret this module reads, as one list.
 *
 * A callable only receives the secrets named in its own `secrets` option, and
 * `.value()` throws for any it was not given — which `readSecret` turns into
 * an empty string, which this module reports as `not-configured`. So a
 * callable that binds a subset of this list does not fail loudly; it silently
 * behaves as if email were switched off, forever, no matter how the
 * environment is configured.
 *
 * That had already happened: `requestPasswordResetCodeCallable` bound the API
 * key and the digest secret but not the From address, so the flow could never
 * have been enabled. Spreading this list is what stops the two drifting again.
 */
export const EMAIL_SECRETS = [
  TRANSACTIONAL_EMAIL_API_KEY,
  TRANSACTIONAL_EMAIL_FROM,
] as const;

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
 * Whether the transport could send at all, without trying.
 *
 * A property of the environment, not of any address, so asking it costs
 * nothing and tells a caller nothing about whose account exists. That matters
 * now that the send itself happens on a queue: the request handler can no
 * longer report a provider failure, but it can still refuse to invite
 * somebody into a flow whose email was never configured — which is the
 * failure that would otherwise be silent and permanent.
 */
export function emailTransportConfigured(): boolean {
  return (
    readSecret(TRANSACTIONAL_EMAIL_API_KEY).length > 0 &&
    readSecret(TRANSACTIONAL_EMAIL_FROM).length > 0
  );
}

/**
 * The one place that talks to the provider. Both templates go through it, so
 * they cannot drift on timeout, error handling or what gets logged.
 */
async function send(
  to: string,
  subject: string,
  text: string,
  what: string
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

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SEND_TIMEOUT_MS);

  try {
    const response = await fetch(PROVIDER_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from, to: [to], subject, text }),
      signal: controller.signal,
    });

    const elapsedMs = Date.now() - startedAt;
    if (!response.ok) {
      // Status only. The body can echo the recipient.
      logger.warn("Transactional email provider rejected a send", {
        what,
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
    // here is how long the API call took. Delivery latency is a different
    // measurement and needs the provider's own event webhook.
    logger.info("Transactional email accepted by provider", {
      what,
      elapsedMs,
      providerMessageId,
    });
    return { sent: true, providerMessageId, elapsedMs };
  } catch (error) {
    const elapsedMs = Date.now() - startedAt;
    const aborted = (error as { name?: string } | null)?.name === "AbortError";
    logger.warn("Transactional email send failed", { what, elapsedMs, aborted });
    return {
      sent: false,
      reason: aborted ? "timeout" : "provider-error",
      elapsedMs,
    };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Told to someone whose account signs in with Google and has no password.
 *
 * The API response for their address is byte-identical to every other
 * address — saying "this one is a Google account" in the response would be an
 * account-existence oracle with extra detail. The inbox is the private
 * channel, so the answer goes there.
 *
 * Without this they were sent into a dead end: the request said a code was on
 * its way, no mail ever arrived because no code was minted for them, and the
 * only reachable outcome was "that code is not correct".
 */
export async function sendGoogleOnlyNoticeEmail(args: {
  to: string;
}): Promise<EmailSendResult> {
  const subject = "Signing in to PetNote";
  const text = [
    "Somebody asked to reset the password for this address.",
    "",
    "This PetNote account signs in with Google, so it has no password to",
    "reset. Open PetNote and choose Continue with Google.",
    "",
    "If that was not you, nothing has changed and there is nothing to do.",
  ].join("\n");
  return send(args.to, subject, text, "google-only-notice");
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
  const { subject, text } = renderCodeEmail(args.code, args.expiresInMinutes);
  return send(args.to, subject, text, "password-reset-code");
}
