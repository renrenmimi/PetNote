import * as admin from "firebase-admin";
// `FieldValue`, `Timestamp` and `FieldPath` are re-exported from the
// `firebase-admin/firestore` subpath rather than read off `admin.firestore`,
// and every module imports them from here.
//
// They are the same objects either way — `require("firebase-admin/firestore")
// .FieldValue === admin.firestore.FieldValue` is true — so this changes nothing
// at run time in production. What it changes is whether the code can run under
// the Cloud Functions emulator at all. firebase-tools proxies `firebase-admin`
// and answers every `admin.firestore` access with `admin.firestore.bind(module)`;
// `bind()` returns a fresh function that carries none of the original's own
// properties, so inside that runtime `admin.firestore.FieldValue` is
// `undefined`. Since every authenticated callable reaches `assertRateLimit`,
// which calls `FieldValue.serverTimestamp()`, the whole backend used to return
// 500 there and the emulator was unusable. The subpath is not proxied.
//
// The `admin` namespace is still exported, and still used for `admin.auth()`,
// `admin.firestore.Query<T>` type positions and so on. Only these three value
// imports moved.
import { FieldPath, FieldValue, Timestamp } from "firebase-admin/firestore";
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
  FieldValue,
  Timestamp,
  FieldPath,
  CLOUDINARY_CLOUD_NAME,
  CLOUDINARY_API_KEY,
  CLOUDINARY_API_SECRET,
  GEOAPIFY_API_KEY,
  CLOUDINARY_FOLDER,
};
