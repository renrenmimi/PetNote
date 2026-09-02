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
process.env.CLOUDINARY_CLOUD_NAME ||= "test-cloud";
process.env.CLOUDINARY_API_KEY ||= "test-api-key";
process.env.CLOUDINARY_API_SECRET ||= "test-api-secret";
process.env.FIREBASE_CONFIG ||= JSON.stringify({
  projectId: process.env.GCLOUD_PROJECT,
});
