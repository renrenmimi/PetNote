/**
 * One-time migration script: removes the `email` field from all user documents.
 *
 * Email is private data that should not be stored in publicly readable user documents.
 * New signups no longer write email; this script cleans up historical data.
 *
 * Usage:
 *   npx ts-node scripts/migrate-remove-email.ts
 *
 * Or via Firebase Admin (must be run with service account credentials):
 *   GOOGLE_APPLICATION_CREDENTIALS=path/to/serviceAccount.json npx ts-node scripts/migrate-remove-email.ts
 */

import * as admin from "firebase-admin";

admin.initializeApp();
const db = admin.firestore();

async function main() {
  const usersSnap = await db.collection("users").get();
  let cleaned = 0;
  let skipped = 0;

  const chunkSize = 450;
  for (let i = 0; i < usersSnap.docs.length; i += chunkSize) {
    const batch = db.batch();
    let batchHasWrites = false;

    usersSnap.docs.slice(i, i + chunkSize).forEach((doc) => {
      const data = doc.data();
      if ("email" in data) {
        batch.update(doc.ref, {
          email: admin.firestore.FieldValue.delete(),
        });
        cleaned++;
        batchHasWrites = true;
      } else {
        skipped++;
      }
    });

    if (batchHasWrites) {
      await batch.commit();
    }
  }

  console.log(`Done. Cleaned ${cleaned} users, skipped ${skipped} (no email field).`);
}

main().catch((err) => {
  console.error("Migration failed:", err);
  process.exit(1);
});
