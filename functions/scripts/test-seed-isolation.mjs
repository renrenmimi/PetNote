/**
 * Does a previous run's deletions corrupt the run that replaces it?
 *
 * The failure this exists for was real and had been silently wrong for as
 * long as the seed script existed. Deleting a post's comments queues one
 * onCommentDeleted per comment. The post is deleted immediately afterwards,
 * and the trigger correctly does nothing when the post is gone — but if a new
 * run recreates a post *under the same id*, the events still in flight arrive
 * to find it there and decrement it. One post ended up claiming minus ten
 * comments; 179 of 210 disagreed with the documents beneath them.
 *
 * Polling for convergence was the first answer and it was not one. "Two reads
 * agreed" cannot prove a queue is empty and cannot promise nothing lands a
 * second later. Disjoint ids can, and this checks that they do.
 *
 * Two halves, and the second is the one that makes the first mean anything:
 *
 *   isolated — delete run A's comments, immediately build run B under a
 *              different prefix, and watch B's count. It must reach the right
 *              number and stay there.
 *
 *   control  — the same thing with the *same* id, which is what the seed used
 *              to do. This must be seen to break. A test that cannot produce
 *              the failure it guards against is not evidence that the failure
 *              is gone; it is evidence of nothing.
 *
 * Run against the emulator only:
 *
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8088 node scripts/test-seed-isolation.mjs
 */
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const functionsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  console.error("FIRESTORE_EMULATOR_HOST is not set. This test only runs against the emulator.");
  process.exit(1);
}
// The same refusal the seed script makes, for the same reason: a test that
// writes and deletes hundreds of documents must never find itself pointed at
// real data.
if ((process.env.GCLOUD_PROJECT || "petnote-test") === "petnote-a9dac") {
  console.error("Refusing to run against production.");
  process.exit(1);
}
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "petnote-test";

const admin = require(path.join(functionsRoot, "node_modules", "firebase-admin"));
admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

/** Enough in-flight deletions that a straggler is likely rather than lucky. */
const COMMENTS = 30;
const PREFIX = `ios-isolation-${Date.now().toString(36)}`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function addComments(postId, count, tag) {
  for (let i = 0; i < count; i += 1) {
    await db.collection(`posts/${postId}/comments`).add({
      authorId: "isolation-test",
      authorName: "isolation",
      text: `TEST CONTENT ${tag} ${i}`,
      createdAt: Timestamp.now(),
    });
  }
}

async function countOf(postId) {
  return (await db.doc(`posts/${postId}`).get()).data()?.commentCount ?? null;
}

async function waitForCount(postId, want, timeoutMs) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if ((await countOf(postId)) === want) return true;
    await sleep(400);
  }
  return false;
}

/** Deletes a post's comments and then the post, the way the seed does. */
async function tearDown(postId) {
  const kids = await db.collection(`posts/${postId}/comments`).get();
  const batch = db.batch();
  kids.docs.forEach((k) => batch.delete(k.ref));
  await batch.commit();
  await db.doc(`posts/${postId}`).delete();
}

async function createPost(postId) {
  await db.doc(`posts/${postId}`).set({
    authorId: "isolation-test",
    authorName: "isolation",
    text: "TEST CONTENT isolation post",
    createdAt: Timestamp.now(),
  });
}

/**
 * Builds a post, tears it down, and immediately builds `second` — then watches
 * `second` for as long as stragglers could plausibly take.
 *
 * Returns the lowest and highest counts observed after it first reached the
 * expected number, because the corruption shows up as a dip *after* arriving
 * at the right value, not as never getting there.
 */
async function interleave(first, second) {
  await createPost(first);
  await addComments(first, COMMENTS, "run-a");
  if (!(await waitForCount(first, COMMENTS, 60_000))) {
    throw new Error(`setup failed: ${first} never reached ${COMMENTS}`);
  }

  // Queue the deletions and do not wait for them.
  await tearDown(first);
  await createPost(second);
  await addComments(second, COMMENTS, "run-b");

  const reached = await waitForCount(second, COMMENTS, 60_000);
  let low = COMMENTS;
  let high = COMMENTS;
  // Fifteen seconds of watching after it settles. The stragglers that caused
  // the original defect arrived within a few.
  for (let i = 0; i < 38; i += 1) {
    await sleep(400);
    const n = await countOf(second);
    if (n === null) continue;
    low = Math.min(low, n);
    high = Math.max(high, n);
  }
  return { reached, low, high };
}

async function main() {
  const results = [];

  console.log(`isolated: run A and run B under different ids (${COMMENTS} comments each)`);
  const isolated = await interleave(`${PREFIX}-a-post`, `${PREFIX}-b-post`);
  console.log(`  reached ${COMMENTS}: ${isolated.reached}; observed range ${isolated.low}..${isolated.high}`);
  results.push([
    "isolated run is untouched by the previous run's deletions",
    isolated.reached && isolated.low === COMMENTS && isolated.high === COMMENTS,
    `range ${isolated.low}..${isolated.high}, expected ${COMMENTS}..${COMMENTS}`,
  ]);

  console.log(`control: the old behaviour — run B reuses run A's id`);
  const shared = `${PREFIX}-shared-post`;
  const control = await interleave(shared, shared);
  console.log(`  reached ${COMMENTS}: ${control.reached}; observed range ${control.low}..${control.high}`);
  results.push([
    "control reproduces the corruption (otherwise the check above proves nothing)",
    control.low < COMMENTS,
    `range ${control.low}..${control.high}; a dip below ${COMMENTS} is the defect`,
  ]);

  for (const id of [`${PREFIX}-a-post`, `${PREFIX}-b-post`, shared]) {
    await tearDown(id).catch(() => {});
  }

  console.log("\nresult:");
  let failed = 0;
  for (const [label, ok, detail] of results) {
    console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}  (${detail})`);
    if (!ok) failed += 1;
  }
  if (failed) {
    console.error(`\n${failed} check(s) failed.`);
    process.exit(1);
  }
}

main().then(() => process.exit(0)).catch((e) => {
  console.error("isolation test failed:", e);
  process.exit(1);
});
