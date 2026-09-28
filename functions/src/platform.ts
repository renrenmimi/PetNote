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
import { HttpsError } from "firebase-functions/v2/https";

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
//
// **Chosen by the Firebase project the function runs in, explicitly.** The
// test project (`petnote-devtest`) has its own Cloudinary account, and the one
// thing that must never happen is a test deployment signing uploads into, or
// validating URLs against, production's. So every project is named: production
// and the emulator/CI project get exactly the values they always had; the test
// project gets its own account, or — until that account exists — nothing, and
// every media path there refuses with `failed-precondition`. A project that is
// not in the table gets nothing too. There is no fallback to production.
//
// Resolved when a media path runs, not when this module loads: every function
// imports this file, and a test deployment without an account must still be
// able to serve comments, likes and pets.
export interface CloudinaryAccount {
  cloudName: string;
  folder: string;
}

const PRODUCTION_CLOUDINARY: CloudinaryAccount = { cloudName: "dgeunvmmn", folder: "petnote" };

const CLOUDINARY_ACCOUNTS: ReadonlyMap<string, CloudinaryAccount | null> = new Map<
  string,
  CloudinaryAccount | null
>([
  ["petnote-a9dac", PRODUCTION_CLOUDINARY],
  // The emulator and CI. Nothing here reaches Cloudinary: the iOS UI tests
  // upload to a local stand-in and the functions tests stub the network, and
  // both were written against production's URL shape.
  ["petnote-test", PRODUCTION_CLOUDINARY],
  // Its own free account. Null until the owner has created it and sent the
  // cloud name; the folder stays `petnote`, which the URL check requires.
  ["petnote-devtest", null],
]);

/** The account a project uses, or null if it has none. Never production's by default. */
export function cloudinaryAccountFor(projectId: string | undefined): CloudinaryAccount | null {
  if (!projectId) return null;
  return CLOUDINARY_ACCOUNTS.get(projectId) ?? null;
}

/** The Firebase project this code is running in, as firebase-tools sets it. */
export function runningProjectId(): string | undefined {
  if (process.env.GCLOUD_PROJECT) return process.env.GCLOUD_PROJECT;
  try {
    const config = JSON.parse(process.env.FIREBASE_CONFIG ?? "{}") as { projectId?: unknown };
    return typeof config.projectId === "string" ? config.projectId : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The account for this deployment, for the signature, the delete and the URL
 * check alike — one answer for all three.
 *
 * @throws HttpsError `failed-precondition` where the project has no account.
 */
export function cloudinaryAccount(): CloudinaryAccount {
  const projectId = runningProjectId();
  const account = cloudinaryAccountFor(projectId);
  if (!account) {
    throw new HttpsError(
      "failed-precondition",
      `Media uploads are not configured for this project (${projectId ?? "unknown"}).`
    );
  }
  return account;
}

export {
  admin,
  db,
  FieldValue,
  Timestamp,
  FieldPath,
  PRODUCTION_CLOUDINARY,
  CLOUDINARY_API_KEY,
  CLOUDINARY_API_SECRET,
  GEOAPIFY_API_KEY,
};
