// The Firestore emulator must be reachable before ../platform is imported,
// because that module calls admin.initializeApp() at import time.
if (!process.env.FIRESTORE_EMULATOR_HOST) {
  process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8088";
}
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9099";
}
process.env.GCLOUD_PROJECT ||= "petnote-test";

// defineSecret(...).value() reads process.env, so the Cloudinary signature
// tests can supply values without a real Secret Manager. These are obviously
// fake and exist only so the signing path can be exercised end to end.
//
// The cloud name is deliberately NOT here. It is chosen per project in
// platform.ts, not read from a secret, so tests read the same value production does —
// which is the point: a test can no longer pass because the environment
// happened to supply something the deployed function would not have.
process.env.CLOUDINARY_API_KEY ||= "test-api-key";
process.env.CLOUDINARY_API_SECRET ||= "test-api-secret";
// Same reason, for the password reset code digests. Obviously fake, and no
// real provider is ever contacted: the email transport is stubbed in the
// password reset tests, so a code only ever leaves through the fake.
process.env.PASSWORD_RESET_CODE_SECRET ||= "test-password-reset-hmac-key";
process.env.TRANSACTIONAL_EMAIL_API_KEY ||= "test-email-api-key";
process.env.TRANSACTIONAL_EMAIL_FROM ||= "no-reply@example.invalid";
process.env.FIREBASE_CONFIG ||= JSON.stringify({
  projectId: process.env.GCLOUD_PROJECT,
});
