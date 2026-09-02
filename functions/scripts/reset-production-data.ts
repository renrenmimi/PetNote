/**
 * Clears application data from a Firestore project and deletes the matching
 * Auth users. Written because the live site is showing test content — a user
 * named "666" and a first video that is a screen recording of a browser inside
 * a browser.
 *
 * THIS REMOVES DATA AND CANNOT BE UNDONE. It reports and exits by default, and
 * will not touch anything until you pass --confirm AND name the project.
 *
 * Take a backup FIRST. See functions/scripts/production-reset.md; the short version:
 *
 *   gcloud firestore export gs://<bucket>/backups/$(date +%Y%m%d-%H%M) \
 *     --project=petnote-a9dac
 *
 * Then, from the functions/ directory (which is where firebase-admin lives):
 *
 *   # 1. Report only. Changes nothing.
 *   cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
 *     npx ts-node scripts/reset-production-data.ts --project=petnote-a9dac
 *
 *   # 2. Apply, after reading the output of step 1. Add --keep=uid1,uid2 to
 *   #    spare real accounts.
 *   cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
 *     npx ts-node scripts/reset-production-data.ts --project=petnote-a9dac --confirm
 *
 * Cloudinary assets are NOT touched. Media uploaded by these accounts stays in
 * Cloudinary under petnote/users/{uid}/ and has to be removed there separately.
 */

import * as admin from "firebase-admin";

const args = process.argv.slice(2);
const confirmed = args.includes("--confirm");
const projectArg = args.find((a) => a.startsWith("--project="));
const projectId = projectArg?.split("=")[1];

if (!projectId) {
  console.error(
    "Refusing to run without --project=<id>.\n" +
      "Naming the project is deliberate: it is the difference between clearing\n" +
      "a scratch project and clearing production."
  );
  process.exit(1);
}

// Accounts to spare, as --keep=uid1,uid2. A flag rather than a constant you
// edit: changing source to configure a destructive script means the thing you
// reviewed and the thing you ran are not the same file.
const KEEP_UIDS = new Set(
  (args.find((a) => a.startsWith("--keep="))?.split("=")[1] ?? "")
    .split(",")
    .map((uid) => uid.trim())
    .filter(Boolean)
);

// Every top-level collection the app writes, with the field that says who owns
// a document. Sparing an account has to spare what it owns as well, or you keep
// a profile whose pets and posts are gone — which is not what "keep this
// account" means to anyone.
//
// ownerField null means the collection has no owner and is cleared outright.
// Subcollections (likes, comments, family, participants, reviews, checkins,
// private, settings, admin, invitations, bookmarks, following, followingPets,
// blockedUsers) go with their parent through recursiveDelete.
const COLLECTIONS: Array<{ name: string; ownerField: string | null }> = [
  { name: "users", ownerField: "__id__" },
  { name: "pets", ownerField: "ownerId" },
  { name: "posts", ownerField: "authorId" },
  { name: "meetups", ownerField: "organizerId" },
  { name: "locations", ownerField: "createdBy" },
  { name: "notifications", ownerField: "userId" },
  { name: "reports", ownerField: "reporterId" },
  { name: "feedback", ownerField: "userId" },
  { name: "usernames", ownerField: "userId" },
  { name: "hashtags", ownerField: null },
  { name: "invitationCodes", ownerField: "createdBy" },
  { name: "callableRateLimits", ownerField: null },
  { name: "geoapifyRateLimits", ownerField: null },
  { name: "userDeletionTombstones", ownerField: null },
  { name: "processedEvents", ownerField: null },
];

function isSpared(
  doc: admin.firestore.QueryDocumentSnapshot,
  ownerField: string | null
): boolean {
  if (KEEP_UIDS.size === 0 || ownerField === null) return false;
  if (ownerField === "__id__") return KEEP_UIDS.has(doc.id);
  const owner = doc.data()?.[ownerField];
  return typeof owner === "string" && KEEP_UIDS.has(owner);
}

admin.initializeApp({ projectId });
const db = admin.firestore();

async function listAuthUsers(): Promise<admin.auth.UserRecord[]> {
  const found: admin.auth.UserRecord[] = [];
  let pageToken: string | undefined;
  do {
    const page = await admin.auth().listUsers(1000, pageToken);
    found.push(...page.users.filter((u) => !KEEP_UIDS.has(u.uid)));
    pageToken = page.pageToken;
  } while (pageToken);
  return found;
}

async function main() {
  console.log(`project : ${projectId}`);
  console.log(
    `mode    : ${confirmed ? "APPLY — data will be removed" : "report only — nothing will change"}`
  );
  console.log(
    `keeping : ${KEEP_UIDS.size > 0 ? [...KEEP_UIDS].join(", ") : "nothing — pass --keep=uid1,uid2 to spare accounts"}`
  );
  console.log("");

  let totalDocs = 0;
  let totalSpared = 0;
  for (const { name, ownerField } of COLLECTIONS) {
    const snap = await db.collection(name).get();
    const docs = snap.docs.filter((d) => !isSpared(d, ownerField));
    const spared = snap.size - docs.length;
    totalDocs += docs.length;
    totalSpared += spared;
    console.log(
      `${name.padEnd(24)} ${String(docs.length).padStart(5)}` +
        (spared > 0 ? `   (${spared} kept)` : "")
    );
    if (!confirmed) continue;
    for (const docSnap of docs) {
      await db.recursiveDelete(docSnap.ref);
    }
  }
  if (totalSpared > 0) {
    console.log(
      `\nhashtag counts are NOT recomputed, so a kept post's tags may read high.\n` +
        "Sparing accounts is the exception; if you use it, check /hashtags after."
    );
  }

  const authUsers = await listAuthUsers();
  console.log(`${"auth accounts".padEnd(24)} ${String(authUsers.length).padStart(5)}`);
  if (confirmed) {
    for (const user of authUsers) {
      await admin.auth().deleteUser(user.uid);
    }
  }

  console.log("");
  if (confirmed) {
    console.log(`Removed ${totalDocs} documents and ${authUsers.length} auth accounts.`);
    console.log(
      "Cloudinary assets were NOT touched — remove those in the Cloudinary console."
    );
    console.log("Next: npx ts-node scripts/seed-demo-content.ts --project=" + projectId);
  } else {
    console.log(
      `Report only. ${totalDocs} documents and ${authUsers.length} auth accounts would be removed.\n` +
        "Re-run with --confirm once you have taken a backup and read the list above."
    );
  }
}

main().then(
  () => process.exit(0),
  (error) => {
    console.error(error);
    process.exit(1);
  }
);
