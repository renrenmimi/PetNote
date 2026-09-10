/**
 * Optional consistency backfill: stamps `countedContribution` onto posts that
 * predate the contribution protocol in functions/src/posts.ts.
 *
 * ## Is this required?
 *
 * **No.** onPostWritten handles a post with no marker by falling back to the
 * event's `before` snapshot, which is exactly the delta the old handler used —
 * so legacy posts keep counting correctly, and each one adopts the marker on
 * its next write. Nothing is broken until this runs.
 *
 * What it buys is uniformity: once every post carries the marker, the
 * order-independence guarantee applies to all of them rather than to posts
 * written after the deploy, and `countedContribution` becomes a field you can
 * reason about without a "unless it's old" caveat.
 *
 * The legacy fallback is the reason this is safe to skip *and* safe to run: for
 * an existing post, "what has been applied" is its current petId and tags,
 * which is what this writes.
 *
 * ## Modes
 *
 * Run from the functions/ directory, like the other backfills here:
 *
 *   node scripts/backfill-post-contribution.js              # dry run (default)
 *   node scripts/backfill-post-contribution.js --apply
 *   node scripts/backfill-post-contribution.js --rollback
 *
 * Dry run reads only: it reports how many posts lack the field and prints a
 * sample of what would be written. `--apply` writes in batches of 400 and
 * records a resume cursor, so an interrupted run continues where it stopped.
 * `--rollback` deletes the field again, returning every post to the legacy
 * fallback path — which is why rollback is safe rather than destructive.
 *
 * The resume cursor is per mode, so a rollback is not silently skipped by a
 * completed apply. Add `--restart` to ignore the cursor and scan from the
 * beginning (needed if posts were written after a run finished).
 *
 * One thing to know about rollback: it strips the field from *every* post that
 * has it, including posts createPostCallable stamped itself. That is what you
 * want when rolling the functions deploy back as well. If you keep the new
 * code and roll back only the data, posts created after the deploy lose their
 * explicit "nothing counted yet" marker and fall back to the legacy path,
 * where a delete event overtaking its create can miscount again. Roll back
 * code and data together, or not at all.
 *
 * ## Rehearsal
 *
 * Against the emulator, with no production credentials in the environment:
 *
 *   export JAVA_HOME=/opt/homebrew/opt/openjdk
 *   export PATH="$JAVA_HOME/bin:$PATH"
 *   npx firebase emulators:start --only firestore --project petnote-test
 *   # in another shell, from functions/:
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8088 GCLOUD_PROJECT=petnote-test \
 *     node scripts/backfill-post-contribution.js --apply
 *
 * Seed a few posts with and without the field first and check that the ones
 * that already had it are reported as skipped, not rewritten.
 *
 * ## Credentials
 *
 * Reuses the Firebase CLI login at ~/.config/configstore/firebase-tools.json,
 * the same way scripts/backfill-like-postid.js does — this machine has no
 * gcloud and no service-account key. Set FIRESTORE_EMULATOR_HOST to point at
 * the emulator instead, in which case no credential is read at all.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const admin = require("firebase-admin");

const BATCH_SIZE = 400;
const PAGE_SIZE = 400;
// One checkpoint per mode. Sharing a single cursor was a real trap, caught in
// the emulator rehearsal: after a completed --apply, a --rollback resumed from
// the end and reported zero changes, looking like a successful no-op rollback.
const checkpointPath = (forMode) =>
  `migrations/backfill-post-contribution-${forMode}`;
const TAG_FORBIDDEN_CHARACTERS = /[.*~/[\]]/;
const MAX_TAGS = 20;
const MAX_TAG_LENGTH = 40;

const restart = process.argv.includes("--restart");
const mode = process.argv.includes("--apply")
  ? "apply"
  : process.argv.includes("--rollback")
  ? "rollback"
  : "dry-run";

const projectId =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.FIREBASE_PROJECT_ID ||
  "petnote-a9dac";

function credentialFromFirebaseCli() {
  const configPath = path.join(
    os.homedir(),
    ".config",
    "configstore",
    "firebase-tools.json"
  );
  if (!fs.existsSync(configPath)) {
    throw new Error(
      `Firebase CLI config not found at ${configPath}. Run \`firebase login\`, ` +
        `or set FIRESTORE_EMULATOR_HOST to run against the emulator.`
    );
  }
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const refreshToken = config?.tokens?.refresh_token;
  if (!refreshToken) {
    throw new Error("Firebase CLI config has no refresh token; run `firebase login`.");
  }
  return admin.credential.refreshToken({
    type: "authorized_user",
    client_id:
      process.env.FIREBASE_CLIENT_ID ||
      "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com",
    client_secret:
      process.env.FIREBASE_CLIENT_SECRET || "j9iVZfS8kkCEFUPaAeJV0sAi",
    refresh_token: refreshToken,
  });
}

if (process.env.FIRESTORE_EMULATOR_HOST) {
  admin.initializeApp({ projectId });
} else {
  admin.initializeApp({ projectId, credential: credentialFromFirebaseCli() });
}
const db = admin.firestore();

/**
 * Must match normalizeTags in functions/src/posts.ts. Kept as a copy rather
 * than an import because that module is TypeScript compiled for the Functions
 * runtime; if the rule there changes, change it here and re-run a dry run to
 * see how many posts move.
 */
function normalizeTags(tags) {
  if (!Array.isArray(tags)) return [];
  return Array.from(
    new Set(
      tags
        .slice(0, MAX_TAGS)
        .filter((tag) => typeof tag === "string")
        .map((tag) => tag.trim().toLowerCase().replace(/^#/, ""))
        .filter(
          (tag) =>
            tag.length > 0 &&
            tag.length <= MAX_TAG_LENGTH &&
            !TAG_FORBIDDEN_CHARACTERS.test(tag) &&
            !/^__.*__$/.test(tag)
        )
    )
  );
}

function petIdOf(data) {
  return typeof data.petId === "string" && data.petId.trim().length > 0
    ? data.petId
    : null;
}

function hasMarker(data) {
  return !!data.countedContribution && typeof data.countedContribution === "object";
}

async function readCheckpoint() {
  if (mode === "dry-run" || restart) return null;
  const snap = await db.doc(checkpointPath(mode)).get();
  const last = snap.exists ? snap.data()?.lastPostId : null;
  return typeof last === "string" && last ? last : null;
}

async function writeCheckpoint(lastPostId, counters) {
  if (mode === "dry-run") return;
  await db.doc(checkpointPath(mode)).set(
    {
      migration: "backfill-post-contribution",
      mode,
      lastPostId,
      ...counters,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

async function main() {
  console.log(
    `Project ${projectId}${
      process.env.FIRESTORE_EMULATOR_HOST
        ? ` (emulator ${process.env.FIRESTORE_EMULATOR_HOST})`
        : ""
    } — mode: ${mode}`
  );
  if (mode === "dry-run") {
    console.log("Reading only. Nothing will be written. Pass --apply to write.");
  }

  let cursor = await readCheckpoint();
  if (cursor) console.log(`Resuming after post ${cursor}`);

  let scanned = 0;
  let changed = 0;
  let skipped = 0;
  const samples = [];

  for (;;) {
    let query = db
      .collection("posts")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) break;

    let batch = db.batch();
    let batched = 0;

    for (const docSnap of page.docs) {
      scanned += 1;
      const data = docSnap.data() ?? {};

      if (mode === "rollback") {
        if (!hasMarker(data)) {
          skipped += 1;
          continue;
        }
        batch.update(docSnap.ref, {
          countedContribution: admin.firestore.FieldValue.delete(),
        });
        batched += 1;
        changed += 1;
      } else {
        if (hasMarker(data)) {
          skipped += 1;
          continue;
        }
        const contribution = {
          petId: petIdOf(data),
          tags: normalizeTags(data.tags),
        };
        if (samples.length < 5) {
          samples.push({ postId: docSnap.id, contribution });
        }
        changed += 1;
        if (mode === "apply") {
          batch.update(docSnap.ref, { countedContribution: contribution });
          batched += 1;
        }
      }

      if (batched >= BATCH_SIZE) {
        await batch.commit();
        batch = db.batch();
        batched = 0;
      }
    }

    if (batched > 0) await batch.commit();

    cursor = page.docs[page.docs.length - 1].id;
    await writeCheckpoint(cursor, { scanned, changed, skipped });
    console.log(`  …${scanned} scanned, ${changed} changed, ${skipped} skipped`);
    if (page.size < PAGE_SIZE) break;
  }

  if (samples.length > 0) {
    console.log("\nSample of what would be written:");
    for (const sample of samples) {
      console.log(`  ${sample.postId} → ${JSON.stringify(sample.contribution)}`);
    }
  }

  console.log(
    `\nDone. Scanned ${scanned}, ${
      mode === "dry-run" ? "would change" : "changed"
    } ${changed}, skipped ${skipped}.`
  );
  if (mode === "dry-run" && changed > 0) {
    console.log("Re-run with --apply to write. --rollback undoes it.");
  }
  if (mode !== "dry-run" && scanned === 0 && !restart) {
    console.log(
      "Scanned nothing: this mode's cursor is already at the end. " +
        "Pass --restart to scan from the beginning."
    );
  }
}

main().catch((error) => {
  console.error("Backfill failed:", error);
  process.exit(1);
});
