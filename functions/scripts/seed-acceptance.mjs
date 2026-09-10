/**
 * Seeds the local acceptance environment with test accounts and content.
 *
 * Emulator only, and it refuses to run against anything else: it requires
 * FIRESTORE_EMULATOR_HOST and a project id that starts with `petnote-test` or
 * `demo-`. Nothing here should ever be pointed at production.
 *
 *     # from functions/, with the emulators and the shim running
 *     node scripts/seed-acceptance.mjs
 *
 * Creates:
 *   accept-a@example.com   Passw0rd!x   verified    — owner, has a pet
 *   accept-b@example.com   Passw0rd!x   verified    — co-owner to invite
 *   accept-new@example.com Passw0rd!x   UNVERIFIED  — for the verification gate
 *   accept-admin@example.com Passw0rd!x verified    — admin role
 *
 * The unverified account is the one to use for "verification blocks
 * publishing"; the Auth emulator will not send mail, so the verification link
 * itself is a production-only test.
 */

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const functionsRoot = path.resolve(here, "..");

const PROJECT = process.env.GCLOUD_PROJECT || "petnote-test";
if (!process.env.FIRESTORE_EMULATOR_HOST) {
  process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8088";
}
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9099";
}
process.env.GCLOUD_PROJECT = PROJECT;

// Belt and braces: an emulator host can be set and still point somewhere real,
// so the project id is checked too.
if (!/^(petnote-test|demo-)/.test(PROJECT)) {
  console.error(
    `Refusing to seed project "${PROJECT}". This script is for the local ` +
      `emulator only; use petnote-test or a demo-* project.`
  );
  process.exit(1);
}

const admin = require(path.join(functionsRoot, "node_modules", "firebase-admin"));
if (admin.apps.length === 0) admin.initializeApp({ projectId: PROJECT });
const auth = admin.auth();
const db = admin.firestore();

const ACCOUNTS = [
  { email: "accept-a@example.com", name: "Accept A", verified: true },
  { email: "accept-b@example.com", name: "Accept B", verified: true },
  { email: "accept-new@example.com", name: "Accept New", verified: false },
  { email: "accept-admin@example.com", name: "Accept Admin", verified: true, admin: true },
];

async function upsertUser({ email, name, verified, admin: isAdmin }) {
  let record;
  try {
    record = await auth.getUserByEmail(email);
    await auth.updateUser(record.uid, {
      password: "Passw0rd!x",
      emailVerified: verified,
      displayName: name,
    });
  } catch {
    record = await auth.createUser({
      email,
      password: "Passw0rd!x",
      emailVerified: verified,
      displayName: name,
    });
  }
  await db.doc(`users/${record.uid}`).set(
    {
      displayName: name,
      displayNameLower: name.toLowerCase(),
      avatarUrl: `https://api.dicebear.com/7.x/thumbs/svg?seed=${record.uid}`,
      bio: "",
      onboardingComplete: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  if (isAdmin) {
    await db.doc(`users/${record.uid}/admin/state`).set({ role: "admin" });
  } else {
    await db.doc(`users/${record.uid}/admin/state`).delete().catch(() => undefined);
  }
  return record.uid;
}

async function main() {
  console.log(`Seeding ${PROJECT} via ${process.env.FIRESTORE_EMULATOR_HOST}`);

  const uids = {};
  for (const account of ACCOUNTS) {
    uids[account.email] = await upsertUser(account);
    console.log(`  ${account.email} -> ${uids[account.email]}${account.verified ? "" : "  (unverified)"}`);
  }

  const a = uids["accept-a@example.com"];

  // A pet owned by A, with the family document the ownership model reads.
  const petId = "accept-pet";
  await db.doc(`pets/${petId}`).set(
    {
      name: "Mochi",
      nameLower: "mochi",
      species: "dog",
      gender: "female",
      breed: "Shiba",
      bio: "Seeded for acceptance testing.",
      ownerId: a,
      primaryOwnerId: a,
      followerCount: 0,
      postCount: 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  await db.doc(`pets/${petId}/family/${a}`).set(
    {
      userId: a,
      userName: "Accept A",
      relationship: "mom",
      role: "primary",
      joinedAt: admin.firestore.Timestamp.fromMillis(Date.now() - 86_400_000),
    },
    { merge: true }
  );
  console.log(`  pet ${petId} (Mochi) owned by accept-a`);

  // A place, so "review a place" and "check in without a pet" have a target
  // that does not have to be created through Geoapify first.
  const locationId = "accept-place";
  await db.doc(`locations/${locationId}`).set(
    {
      name: "Acceptance Park",
      category: "dog_park",
      description: "Seeded for acceptance testing.",
      address: "1 Test Road",
      lat: 42.3505,
      lng: -71.1054,
      city: "Boston",
      state: "MA",
      features: ["off_leash", "water_access"],
      addedBy: a,
      addedByName: "Accept A",
      photos: [],
      totalRatings: 0,
      sumRating: 0,
      averageRating: 0,
      totalCheckins: 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  console.log(`  location ${locationId} (Acceptance Park)`);

  console.log("\nAccounts all use password: Passw0rd!x");
  console.log("Sign in at http://localhost:5173 (npm run dev with VITE_FIREBASE_EMULATORS=1).");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Seed failed:", error);
    process.exit(1);
  });
