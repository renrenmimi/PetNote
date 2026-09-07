import * as admin from "firebase-admin";
import { defineSecret } from "firebase-functions/params";
import { setGlobalOptions } from "firebase-functions/v2";

// Keep a global cap for cost control, but avoid the previous five-instance
// ceiling that could queue normal traffic spikes across unrelated callables.
setGlobalOptions({ maxInstances: 20 });

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const db = admin.firestore();
const CLOUDINARY_API_KEY = defineSecret("CLOUDINARY_API_KEY");
const CLOUDINARY_API_SECRET = defineSecret("CLOUDINARY_API_SECRET");
const GEOAPIFY_API_KEY = defineSecret("GEOAPIFY_API_KEY");
const CLOUDINARY_FOLDER = "petnote";

// Not a secret, and it was a mistake to store it as one. The cloud name is the
// first path segment of every image URL the app serves — it is public by
// construction, and anyone who has loaded a single photo has it.
//
// Treating it as a secret invented a failure mode with no upside: any callable
// that validates a media URL had to remember `secrets: [CLOUDINARY_CLOUD_NAME]`,
// and one that forgot passed CI — the emulator drives handlers through .run(),
// which bypasses secret mounting entirely, and setup.ts sets the variable
// directly — then threw in production on the first upload. Eleven callables
// carried that binding purely to read a value that was never confidential.
//
// The API key and secret stay in Secret Manager. Those are the credentials.
const CLOUDINARY_CLOUD_NAME = "dgeunvmmn";

export {
  admin,
  db,
  CLOUDINARY_CLOUD_NAME,
  CLOUDINARY_API_KEY,
  CLOUDINARY_API_SECRET,
  GEOAPIFY_API_KEY,
  CLOUDINARY_FOLDER,
};
