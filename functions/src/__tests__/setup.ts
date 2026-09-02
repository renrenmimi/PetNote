// The Firestore emulator must be reachable before ../platform is imported,
// because that module calls admin.initializeApp() at import time.
if (!process.env.FIRESTORE_EMULATOR_HOST) {
  process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8088";
}
process.env.GCLOUD_PROJECT ||= "petnote-test";
process.env.FIREBASE_CONFIG ||= JSON.stringify({
  projectId: process.env.GCLOUD_PROJECT,
});
