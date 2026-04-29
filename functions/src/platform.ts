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
const CLOUDINARY_CLOUD_NAME = defineSecret("CLOUDINARY_CLOUD_NAME");
const CLOUDINARY_API_KEY = defineSecret("CLOUDINARY_API_KEY");
const CLOUDINARY_API_SECRET = defineSecret("CLOUDINARY_API_SECRET");
const GEOAPIFY_API_KEY = defineSecret("GEOAPIFY_API_KEY");
const CLOUDINARY_FOLDER = "petnote";

export {
  admin,
  db,
  CLOUDINARY_CLOUD_NAME,
  CLOUDINARY_API_KEY,
  CLOUDINARY_API_SECRET,
  GEOAPIFY_API_KEY,
  CLOUDINARY_FOLDER,
};
