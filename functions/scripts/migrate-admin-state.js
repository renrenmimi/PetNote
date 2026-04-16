/**
 * One-time migration script: moves legacy `role` / `banned` admin fields
 * out of public `users/{uid}` docs into `users/{uid}/admin/state`.
 *
 * After this runs, the app can stop reading admin flags from public user docs.
 *
 * Run from the functions/ directory:
 *
 *   node scripts/migrate-admin-state.js
 */

const admin = require("firebase-admin");

const projectId =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.FIREBASE_PROJECT_ID ||
  "petnote-a9dac";

admin.initializeApp({ projectId });
const db = admin.firestore();

async function main() {
  const usersSnap = await db.collection("users").get();

  let migratedAdminState = 0;
  let cleanedLegacyFields = 0;
  let skipped = 0;

  for (const userDoc of usersSnap.docs) {
    const data = userDoc.data();
    const hasLegacyFields =
      "role" in data ||
      "banned" in data ||
      "bannedReason" in data ||
      "bannedAt" in data;

    if (!hasLegacyFields) {
      skipped += 1;
      continue;
    }

    const adminRef = db.doc(`users/${userDoc.id}/admin/state`);
    const adminSnap = await adminRef.get();
    const adminData = adminSnap.exists ? adminSnap.data() ?? {} : {};

    const role = typeof data.role === "string" ? data.role : undefined;
    const banned = data.banned === true;
    const bannedReason =
      typeof data.bannedReason === "string" ? data.bannedReason : undefined;
    const bannedAt = data.bannedAt;

    const adminPatch = {};

    if (role === "admin" && typeof adminData.role !== "string") {
      adminPatch.role = "admin";
    }

    if (banned && !("banned" in adminData)) {
      adminPatch.banned = true;
      if (bannedReason) {
        adminPatch.bannedReason = bannedReason;
      }
      if (bannedAt) {
        adminPatch.bannedAt = bannedAt;
      }
    }

    const batch = db.batch();

    if (Object.keys(adminPatch).length > 0) {
      batch.set(adminRef, adminPatch, { merge: true });
      migratedAdminState += 1;
    }

    batch.update(userDoc.ref, {
      role: admin.firestore.FieldValue.delete(),
      banned: admin.firestore.FieldValue.delete(),
      bannedReason: admin.firestore.FieldValue.delete(),
      bannedAt: admin.firestore.FieldValue.delete(),
    });
    await batch.commit();
    cleanedLegacyFields += 1;
  }

  console.log(
    `Done. Migrated ${migratedAdminState} admin state docs, cleaned ${cleanedLegacyFields} legacy user docs, skipped ${skipped}.`
  );
}

main().catch((error) => {
  console.error("Admin state migration failed:", error);
  console.error(
    "Hint: run with Application Default Credentials or GOOGLE_APPLICATION_CREDENTIALS set."
  );
  process.exit(1);
});
