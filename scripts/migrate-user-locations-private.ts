/**
 * One-time migration script: moves exact user location out of public `users` docs
 * into owner-only `users/{uid}/settings/location`.
 *
 * Public `users.location` should only keep `city`, `state`, and `updatedAt`.
 * Exact `lat/lng` is copied into the private settings document.
 *
 * IMPORTANT: Must be run from the functions/ directory (which has firebase-admin installed):
 *
 *   cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json npx ts-node ../scripts/migrate-user-locations-private.ts
 */

import * as admin from "firebase-admin";

admin.initializeApp();
const db = admin.firestore();

type PublicLocation = {
  lat?: unknown;
  lng?: unknown;
  city?: unknown;
  state?: unknown;
  updatedAt?: unknown;
};

async function main() {
  const usersSnap = await db.collection("users").get();
  let migrated = 0;
  let skipped = 0;

  for (const userDoc of usersSnap.docs) {
    const location = (userDoc.data().location ?? null) as PublicLocation | null;
    if (
      !location ||
      typeof location.lat !== "number" ||
      typeof location.lng !== "number"
    ) {
      skipped += 1;
      continue;
    }

    const city = typeof location.city === "string" ? location.city : "";
    const state = typeof location.state === "string" ? location.state : "";
    const updatedAt =
      location.updatedAt ?? admin.firestore.FieldValue.serverTimestamp();

    const batch = db.batch();
    batch.set(
      db.doc(`users/${userDoc.id}/settings/location`),
      {
        lat: location.lat,
        lng: location.lng,
        city,
        state,
        updatedAt,
      },
      { merge: true }
    );
    batch.update(userDoc.ref, {
      location: {
        city,
        state,
        updatedAt,
      },
    });
    await batch.commit();
    migrated += 1;
  }

  console.log(
    `Done. Migrated ${migrated} users, skipped ${skipped} (no public exact location).`
  );
}

main().catch((err) => {
  console.error("Location migration failed:", err);
  process.exit(1);
});
