/**
 * Seeds the emulator with the dataset the native iOS client's stage-1
 * acceptance needs: a feed long enough to scroll, images in several aspect
 * ratios, videos spread through the list, and the degenerate cases that break
 * layouts.
 *
 * Emulator only, and it refuses to run anywhere else: GCLOUD_PROJECT must be
 * exactly `petnote-test`. Everything it writes is prefixed `TEST CONTENT` and
 * uses `ios-` document ids, so nothing here can be mistaken for real user data.
 *
 *     # from functions/, with the emulators running
 *     export FIRESTORE_EMULATOR_HOST=127.0.0.1:8088 \
 *            FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
 *            GCLOUD_PROJECT=petnote-test
 *     node scripts/seed-ios-native.mjs
 *
 * Re-running is safe: every `ios-` post and its comments are deleted first, so
 * the feed length stays what this script says it is.
 *
 * Why not seed-experience.mjs: that one lives only on feature/ios-polish-round2
 * (PR #203), has 14 posts, and has no video. Copying it here would collide with
 * that PR's file of the same name.
 *
 * Media comes from Cloudinary's public `demo` cloud, never from PetNote's
 * production cloud (`dgeunvmmn`) — production media is real users' photos.
 * Two URL shapes are seeded on purpose:
 *   - `upload/v1/<id>` with no transformation, so the client inserts its own
 *     size transform exactly as src/utils/cloudinaryUrl.ts does;
 *   - `upload/<transform>/v1/<id>`, so the "URL already carries transforms,
 *     leave it alone" path is covered too.
 */

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const functionsRoot = path.resolve(here, "..");

// Only defaulted for the emulator; the cloud branch below refuses to run with
// these set at all.
if (!process.env.PETNOTE_TEST_PROJECT || process.env.GCLOUD_PROJECT === "petnote-test") {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8088";
  }
  if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) {
    process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9099";
  }
}

// Where this may write, and nowhere else.
//
// `petnote-test` is the local emulator. A second entry is allowed for the
// independent test Firebase project, but only when it is named explicitly via
// PETNOTE_TEST_PROJECT — there is no wildcard, and production is refused by
// name as well as by omission, because a typo that happened to match a prefix
// would be an expensive way to find out this check was loose.
const PRODUCTION_PROJECT = "petnote-a9dac";
const EMULATOR_PROJECT = "petnote-test";
const TEST_CLOUD_PROJECT = process.env.PETNOTE_TEST_PROJECT || "";

const PROJECT = process.env.GCLOUD_PROJECT || EMULATOR_PROJECT;

if (PROJECT === PRODUCTION_PROJECT) {
  console.error(
    `Refusing to seed ${PRODUCTION_PROJECT}: that is production. This script ` +
      `only ever writes to the emulator or to a named test project.`
  );
  process.exit(1);
}

const allowed = [EMULATOR_PROJECT, TEST_CLOUD_PROJECT].filter(Boolean);
if (!allowed.includes(PROJECT)) {
  console.error(
    `Refusing to seed project "${PROJECT}". Allowed: ${allowed.join(", ")}.\n` +
      `To seed the independent test project, set PETNOTE_TEST_PROJECT to its ` +
      `id as well as GCLOUD_PROJECT.`
  );
  process.exit(1);
}

// Writing to a real project means no emulator hosts: if those are set the
// Admin SDK will quietly send everything to the emulator instead, and the run
// will look successful while the project stays empty.
const targetingCloud = PROJECT !== EMULATOR_PROJECT;
if (targetingCloud) {
  for (const key of ["FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST"]) {
    if (process.env[key]) {
      console.error(
        `${key} is set while targeting ${PROJECT}. Unset it, or the writes go ` +
          `to the emulator and this project stays empty.`
      );
      process.exit(1);
    }
  }
  console.log(`Seeding the CLOUD project ${PROJECT} — not the emulator.`);
}

process.env.GCLOUD_PROJECT = PROJECT;

const admin = require(path.join(functionsRoot, "node_modules", "firebase-admin"));
/**
 * Against the emulator the credential is irrelevant — the host variables
 * redirect everything and any token is accepted. Against a real project it is
 * not, and firebase-admin's Firestore client accepts exactly two things: a
 * service account certificate, or application default credentials. A bare
 * access token is refused, and so is a refresh-token credential passed
 * directly; both come back as "Must initialize the SDK with a certificate
 * credential or application default credentials".
 *
 * So point `GOOGLE_APPLICATION_CREDENTIALS` at an authorized-user ADC file
 * before running this. Deliberately not a service account key: creating one
 * would mint a new long-lived credential for a machine that only needs to run
 * a seed, and an authorized-user file re-encodes a token the machine already
 * has rather than adding one.
 */
if (admin.apps.length === 0) admin.initializeApp({ projectId: PROJECT });

const auth = admin.auth();
const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;
const Timestamp = admin.firestore.Timestamp;

// ---------------------------------------------------------------------------
// Shape of the dataset. Acceptance items that depend on each line are named so
// a later change here is visibly a change to what the acceptance run covers.
// ---------------------------------------------------------------------------
/**
 * A namespace for this run, and nothing outside it is ever touched.
 *
 * The previous design reused fixed ids — `ios-post-000` and so on — and
 * deleted them before writing them again. That is what let a delete event
 * from the *previous* run arrive after the *current* run had recreated the
 * same document and decrement its count: one post ended up claiming minus ten
 * comments, and 179 of 210 had aggregates that disagreed with the documents
 * beneath them.
 *
 * Convergence polling was the first answer and it was not good enough. "Two
 * consecutive reads agreed" is a heuristic; it cannot prove the queue is
 * empty, and it cannot promise nothing arrives a second later. Disjoint ids
 * can: an event addressed to a document in run A names a path that does not
 * exist in run B, so the question of timing stops mattering.
 */
const RUN_ID = `r${Date.now().toString(36)}`;
const POST_ID_PREFIX = `ios-${RUN_ID}-post-`;
const postID = (index) => `${POST_ID_PREFIX}${String(index).padStart(3, "0")}`;
// Places and meetups get the same per-run namespace as posts, for the same
// reason: an event from a previous run addresses a document this run never
// wrote.
const PLACE_ID_PREFIX = `ios-${RUN_ID}-place-`;
const MEETUP_ID_PREFIX = `ios-${RUN_ID}-meetup-`;
/** What every write of this run's register entry carries, so a later run can clean all of it. */
const RUN_RECORD = {
  runId: RUN_ID,
  postIdPrefix: POST_ID_PREFIX,
  placeIdPrefix: PLACE_ID_PREFIX,
  meetupIdPrefix: MEETUP_ID_PREFIX,
};

/** Where a run records what it created, so cleanup never has to guess. */
const RUN_REGISTRY = "seedRuns";

const LIKED_POST_LIMIT = 60;         // real like documents on the first 60 only
const POST_COUNT = 210;              // ≥200 for scroll/memory budget (5A.2, 7.3, 7.4)
const VIDEO_INDEXES = [2, 26, 63, 117, 170, 203]; // 6 videos, spread apart (5D.1–5D.7)
const BROKEN_MEDIA_INDEX = 8;        // image 404 → retryable failure state (5A.7)
const BROKEN_VIDEO_INDEX = 41;       // video 404 → retryable failure state (5D.8)
const TEXT_ONLY_INDEX = 4;           // no media at all → layout degrades (5A.1)
const LONG_TEXT_INDEX = 6;           // >600 chars → truncation and expansion
const NO_PET_INDEX = 11;             // no pet → identity row degrades
const CJK_PET_INDEX = 13;            // CJK pet name → truncation, not overflow
const MANY_COMMENTS_INDEX = 1;       // 60 comments → comment paging (5C.11)
const MANY_COMMENTS_COUNT = 60;

const DEMO = "https://res.cloudinary.com/demo";

/** Untransformed: the client is expected to insert its own size transform. */
const plainImage = (publicId) => `${DEMO}/image/upload/v1/${publicId}`;
/** Already transformed: the client must leave the URL as it is. */
const ratioImage = (ratio, width, publicId) =>
  `${DEMO}/image/upload/ar_${ratio},c_fill,w_${width}/v1/${publicId}`;
const video = (publicId) => `${DEMO}/video/upload/v1/${publicId}`;
/** Cloudinary's frame-0 poster, the same trick MediaCarousel.tsx uses. */
const videoPoster = (publicId) =>
  `${DEMO}/video/upload/so_0,w_800,q_auto,f_auto/v1/${publicId}`.replace(/\.[^/.]+$/, ".jpg");

// Verified reachable on 2026-09-18; `sample.jpg` is 4:3, so the squares and
// portraits below are made with c_fill rather than by hunting for assets that
// happen to have those shapes.
const IMAGE_VARIANTS = [
  { label: "landscape 4:3 (no transform in URL)", url: plainImage("sample.jpg") },
  { label: "square 1:1", url: ratioImage("1:1", 800, "sample.jpg") },
  { label: "portrait 4:5", url: ratioImage("4:5", 800, "sample.jpg") },
  { label: "wide 16:9", url: ratioImage("16:9", 1280, "sample.jpg") },
  { label: "tall 9:16", url: ratioImage("9:16", 720, "sample.jpg") },
];
const VIDEO_VARIANTS = ["dog.mp4", "sea_turtle.mp4", "elephants.mp4"];

const BROKEN_IMAGE = plainImage("petnote-test-missing-asset.jpg"); // returns 404
const BROKEN_VIDEO = video("petnote-test-missing-clip.mp4");       // returns 404

const LONG_TEXT =
  "TEST CONTENT 这是一条故意写得很长的文案，用来检验正文的截断与展开。" +
  "它需要超过六百个字，所以下面会把同一件事换着说法讲很多遍：" +
  "宠物主人在记录一天的时候，往往不只写一句话，他们会写清楚天气、走了哪条路、" +
  "在哪个路口停下来闻了很久、遇到了哪只熟悉的狗、对方的主人说了什么、" +
  "回家以后吃了多少、有没有把水喝完、睡觉的姿势和平时有什么不同。" +
  "这些细节对别人可能没有意义，对写的人却是全部意义所在，所以产品不应该用一个" +
  "生硬的省略号把它们切断，而应该让人能够展开读完，并且展开之后仍然能顺畅地滚动。" +
  "与此同时，列表里的其它卡片不应该因为这一条变长而跳动，已经读到的位置也不应该" +
  "因为展开而丢失。这就是这条数据要验证的东西。" +
  "为了把字数堆到六百以上，这里再重复一次上面的意思：" +
  "长文案的展开与收起都必须是可逆的，收起之后高度要回到原来的值，" +
  "不能留下多余的空白，也不能把下面的卡片往上拽。" +
  "如果实现是用固定行数加渐变遮罩，那么在动态字体放大到 AX5 的时候，" +
  "遮罩的位置必须跟着字号走，而不是停在一个写死的像素高度上。" +
  "如果实现是用测量文本高度的方式，那么测量必须发生在正确的宽度下，" +
  "否则在横屏或者 iPad 的分屏里会算错。" +
  "最后，这条文案本身也是一个中文断行的样本：" +
  "中文没有空格，断行规则和英文不同，标点不应该出现在行首，" +
  "这些都需要在真机上看一眼才能确认，不是跑一遍单元测试就能证明的。" +
  "补充一点，展开之后如果正文里出现了链接或者话题标签，它们的点击区域不能和" +
  "展开收起的手势抢，否则人想收起却打开了别的页面，这也是要在真机上试的。";

// The acceptance matrix asks for a body over 600 characters, so the length is
// asserted rather than trusted: an edit that shortens the text should fail here
// instead of quietly weakening what the run covers.
if (LONG_TEXT.length <= 600) {
  console.error(`LONG_TEXT is ${LONG_TEXT.length} chars; the matrix asks for >600.`);
  process.exit(1);
}

const SHORT_TEXTS = [
  "TEST CONTENT 今天走了很久，回家就睡着了。",
  "TEST CONTENT Rolled in the grass, again.",
  "TEST CONTENT 新的零食，反应很大。",
  "TEST CONTENT First time at the water bowl by the door.",
  "TEST CONTENT 剪指甲，全程安静，值得记一下。",
  "TEST CONTENT Sunbathing spot claimed by 8am.",
  "TEST CONTENT 换了牵引绳，好像不太喜欢。",
];

const TAG_POOL = [
  ["test", "walk"],
  ["test", "nap"],
  ["test", "food"],
  ["test"],
  [],
];

// ---------------------------------------------------------------------------

async function upsertUser({ email, name, verified }) {
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
      createdAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  return record.uid;
}

async function upsertPet({ id, name, ownerId, ownerName, species, breed }) {
  await db.doc(`pets/${id}`).set(
    {
      name,
      nameLower: name.toLowerCase(),
      species,
      gender: "female",
      breed,
      bio: "TEST CONTENT seeded for the native iOS client.",
      avatarUrl: ratioImage("1:1", 200, "sample.jpg"),
      ownerId,
      primaryOwnerId: ownerId,
      followerCount: 0,
      postCount: 0,
      createdAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  await db.doc(`pets/${id}/family/${ownerId}`).set(
    {
      userId: ownerId,
      userName: ownerName,
      relationship: "mom",
      role: "primary",
      joinedAt: Timestamp.fromMillis(Date.now() - 86_400_000),
    },
    { merge: true }
  );
}

/**
 * Deletes the runs that previous invocations recorded, and nothing else.
 *
 * "Everything starting with ios-" was the old rule. It worked, and it was
 * also the reason a run could delete documents it was about to recreate. Now
 * each run registers its own prefix, and cleanup walks that register — so a
 * document is only ever deleted by the run that knows it wrote it.
 *
 * The delete events this still queues are harmless now: they name ids in an
 * old namespace, and this run's ids are different, so there is nothing of
 * ours for a late event to hit.
 */
async function clearRecordedRuns() {
  const runs = await db.collection(RUN_REGISTRY).get();
  let removedPosts = 0;
  let removedRuns = 0;

  const prefixes = [];
  const gatheringPrefixes = [];
  for (const run of runs.docs) {
    if (run.id === "current" || run.id === RUN_ID) continue;
    const prefix = run.data()?.postIdPrefix;
    if (typeof prefix === "string" && prefix.startsWith("ios-")) prefixes.push({ run, prefix });
    for (const [collection, key, subs] of [
      ["locations", "placeIdPrefix", ["reviews", "checkins", "photoEntries"]],
      ["meetups", "meetupIdPrefix", ["participants", "private"]],
    ]) {
      const recorded = run.data()?.[key];
      if (typeof recorded === "string" && recorded.startsWith("ios-")) {
        gatheringPrefixes.push({ collection, prefix: recorded, subs });
      }
    }
  }
  for (const { collection, prefix, subs } of gatheringPrefixes) {
    const all = await db.collection(collection).get();
    for (const doc of all.docs.filter((d) => d.id.startsWith(prefix))) {
      for (const sub of subs) {
        const kids = await doc.ref.collection(sub).get();
        for (const kid of kids.docs) await kid.ref.delete();
      }
      await doc.ref.delete();
    }
  }

  // One-off: data from before this script kept a register at all. Named
  // explicitly rather than matched by a wildcard, so the rule stays "delete
  // what is recorded" instead of drifting back to "delete what looks like
  // ours".
  const LEGACY_PREFIX = "ios-post-";
  prefixes.push({ run: null, prefix: LEGACY_PREFIX });

  for (const { run, prefix } of prefixes) {
    // A scan rather than a __name__ range query: the Admin SDK wants a bare
    // document id there, not a path, and a range over ids is not worth the
    // subtlety when this collection is a test dataset of a few hundred.
    const all = await db.collection("posts").get();
    const snap = { docs: all.docs.filter((d) => d.id.startsWith(prefix)) };

    for (const doc of snap.docs) {
      for (const sub of ["comments", "likes"]) {
        const kids = await doc.ref.collection(sub).get();
        for (let i = 0; i < kids.docs.length; i += 400) {
          const batch = db.batch();
          kids.docs.slice(i, i + 400).forEach((k) => batch.delete(k.ref));
          await batch.commit();
        }
      }
      await doc.ref.delete();
      removedPosts += 1;
    }
    if (run) {
      await run.ref.delete();
      removedRuns += 1;
    }
  }
  return { removedPosts, removedRuns };
}

/**
 * Waits for the triggers to bring every aggregate in line with the documents
 * that exist, and reports what it saw. It writes nothing.
 *
 * The earlier version of this corrected the numbers itself when they
 * disagreed, which made the result meaningless twice over: a dataset that
 * "matches" because the script overwrote it says nothing about whether the
 * triggers ran, and a deadline that auto-corrects on expiry turns "did not
 * converge in time" into "passed".
 */
async function waitForAggregates(postIds, deadlineMs = 120_000) {
  const startedAt = Date.now();
  let unconverged = [];
  let polls = 0;

  while (Date.now() - startedAt < deadlineMs) {
    polls += 1;
    unconverged = [];
    for (const id of postIds) {
      const ref = db.doc(`posts/${id}`);
      const [post, comments, likes] = await Promise.all([
        ref.get(),
        ref.collection("comments").get(),
        ref.collection("likes").get(),
      ]);
      const data = post.data() || {};
      if ((data.commentCount ?? 0) !== comments.size || (data.likeCount ?? 0) !== likes.size) {
        unconverged.push(
          `${id}: commentCount ${data.commentCount ?? 0}/${comments.size}, likeCount ${data.likeCount ?? 0}/${likes.size}`
        );
      }
    }
    if (unconverged.length === 0) {
      return { converged: true, polls, elapsedMs: Date.now() - startedAt, unconverged: [] };
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  return { converged: false, polls, elapsedMs: Date.now() - startedAt, unconverged };
}

/**
 * Writes one comment on one post, waits for the aggregate to move, removes it,
 * waits for it to move back.
 *
 * Deliberately narrow, and the narrowness is the point. It proves the
 * create-and-delete path responds *on the post it touched, right now*. It
 * does not prove the bulk dataset is consistent — waitForAggregates does that
 * — and it proves nothing at all about events left over from an earlier run,
 * which is what the run namespace is for. Three separate claims, three
 * separate pieces of evidence.
 */
async function proveTheCommentTriggerRuns() {
  const postRef = db.doc(`posts/${postID(0)}`);
  const before = (await postRef.get()).data()?.commentCount ?? 0;
  const probe = await postRef.collection("comments").add({
    authorId: "seed-trigger-probe",
    authorName: "seed probe",
    text: "TEST CONTENT seed trigger probe",
    createdAt: Timestamp.now(),
  });

  let moved = before;
  for (let i = 0; i < 40; i += 1) {
    await new Promise((r) => setTimeout(r, 500));
    moved = (await postRef.get()).data()?.commentCount ?? before;
    if (moved === before + 1) break;
  }
  await probe.delete();

  // Wait for the delete to land too, so the probe leaves the dataset exactly
  // as it found it rather than one comment heavier.
  let restored = false;
  for (let i = 0; i < 40; i += 1) {
    await new Promise((r) => setTimeout(r, 500));
    if (((await postRef.get()).data()?.commentCount ?? -1) === before) { restored = true; break; }
  }

  return moved === before + 1 && restored
    ? { ok: true, detail: `${before} -> ${moved} -> ${before} on ${postID(0)}` }
    : { ok: false, detail: `no movement from ${before} on ${postID(0)}; is the functions emulator running?` };
}

function mediaFor(index) {
  if (index === TEXT_ONLY_INDEX) return null;
  if (index === BROKEN_MEDIA_INDEX) {
    return [{ url: BROKEN_IMAGE, type: "image" }];
  }
  if (index === BROKEN_VIDEO_INDEX) {
    return [{ url: BROKEN_VIDEO, type: "video", thumbUrl: videoPoster("petnote-test-missing-clip.mp4") }];
  }
  if (VIDEO_INDEXES.includes(index)) {
    const clip = VIDEO_VARIANTS[VIDEO_INDEXES.indexOf(index) % VIDEO_VARIANTS.length];
    return [{ url: video(clip), type: "video", thumbUrl: videoPoster(clip) }];
  }
  // Every fifth post carries two images, so the carousel's paging is exercised
  // without making it the common case.
  const first = IMAGE_VARIANTS[index % IMAGE_VARIANTS.length];
  if (index % 5 === 0) {
    const second = IMAGE_VARIANTS[(index + 2) % IMAGE_VARIANTS.length];
    return [
      { url: first.url, type: "image" },
      { url: second.url, type: "image" },
    ];
  }
  return [{ url: first.url, type: "image" }];
}

function textFor(index) {
  if (index === LONG_TEXT_INDEX) return LONG_TEXT;
  const base = SHORT_TEXTS[index % SHORT_TEXTS.length];
  // The index is in the text so a screenshot proves which post is on screen —
  // that is what makes "came back to the same scroll position" checkable.
  return `${base} [#${String(index).padStart(3, "0")}]`;
}

/**
 * Three places and five meetups, each shaped for one thing the screens do.
 *
 * The place aggregates (rating, review and check-in counts) are left to the
 * review and check-in triggers, like the post counts. The meetup participant
 * counts are not a trigger's: the join callable increments them in the same
 * transaction as the entry, and marks the entry `counted`. The seed writes
 * both halves the same way, so leaving takes the count down exactly once.
 */
async function seedGatherings({ uidA, uidB, now }) {
  const hour = 60 * 60 * 1000;
  const day = 24 * hour;
  const avatar = (uid) => `https://api.dicebear.com/7.x/thumbs/svg?seed=${uid}`;
  const place = (key) => `${PLACE_ID_PREFIX}${key}`;
  const meetup = (key) => `${MEETUP_ID_PREFIX}${key}`;

  const places = {
    reviewed: place("park"),
    quiet: place("cafe"),
    trail: place("trail"),
  };
  const common = { source: "user", verified: false, addedBy: uidA, addedByName: "Accept A", tags: [], totalPhotos: 0 };
  await db.doc(`locations/${places.reviewed}`).set({
    ...common,
    name: "TEST CONTENT Riverside Dog Park",
    category: "dog_park",
    description: "TEST CONTENT A fenced park by the river.",
    address: "1 River St, Cambridge, MA",
    city: "Cambridge", state: "MA", lat: 42.3601, lng: -71.0942,
    features: ["off_leash", "fenced", "water_access", "parking"],
    photos: [plainImage("sample.jpg")],
    averageRating: 0, totalRatings: 0, totalCheckins: 0,
    createdAt: Timestamp.fromMillis(now - 3 * day),
  });
  await db.doc(`locations/${places.quiet}`).set({
    ...common,
    name: "TEST CONTENT Harbor Café",
    category: "cafe",
    description: "",
    address: "2 Harbor Way, Boston, MA",
    city: "Boston", state: "MA", lat: 42.3551, lng: -71.0489,
    features: [], photos: [],
    averageRating: 0, totalRatings: 0, totalCheckins: 0,
    createdAt: Timestamp.fromMillis(now - 1 * day),
  });
  await db.doc(`locations/${places.trail}`).set({
    ...common,
    name: "TEST CONTENT Hilltop Trail",
    category: "hiking_trail",
    description: "TEST CONTENT Steep in places.",
    address: "3 Hill Rd, Newton, MA",
    city: "Newton", state: "MA", lat: 42.337, lng: -71.2092,
    features: ["trails", "shade"], photos: [],
    averageRating: 0, totalRatings: 0, totalCheckins: 0,
    createdAt: Timestamp.fromMillis(now - 2 * day),
  });

  // Reviews and check-ins as the callables write them; the triggers count them.
  const review = (uid, name, rating, comment, tags, ago) => ({
    userId: uid, userName: name, userAvatar: avatar(uid), rating, comment, photos: [], tags,
    petFriendly: { space: rating, safety: rating, cleanliness: rating },
    createdAt: Timestamp.fromMillis(now - ago),
  });
  await db.doc(`locations/${places.reviewed}/reviews/${uidA}`).set(
    review(uidA, "Accept A", 5, "TEST CONTENT Mochi loved the water.", ["shady", "friendly"], 2 * hour));
  await db.doc(`locations/${places.reviewed}/reviews/${uidB}`).set(
    review(uidB, "Accept B", 4, "TEST CONTENT Busy on weekends.", ["busy"], 5 * hour));
  await db.doc(`locations/${places.trail}/reviews/${uidA}`).set(
    review(uidA, "Accept A", 3, "TEST CONTENT Muddy after rain.", [], 8 * hour));
  const dayKey = new Date(now).toISOString().slice(0, 10);
  const checkin = (uid, name, pet, caption, ago) => ({
    locationId: places.reviewed, userId: uid, userName: name, userAvatar: avatar(uid),
    photoUrl: ratioImage("1:1", 800, "sample.jpg"), caption, ...pet,
    createdAt: Timestamp.fromMillis(now - ago),
  });
  await db.doc(`locations/${places.reviewed}/checkins/${uidA}_${dayKey}`).set(
    checkin(uidA, "Accept A", { petId: "ios-pet-latin", petName: "Mochi" }, "TEST CONTENT First visit!", 1 * hour));
  await db.doc(`locations/${places.reviewed}/checkins/${uidB}_${dayKey}`).set(
    checkin(uidB, "Accept B", {}, "TEST CONTENT Quick walk.", 3 * hour));

  const meetups = {
    soon: meetup("soon"),
    later: meetup("later"),
    cancelled: meetup("cancelled"),
    private: meetup("private"),
    full: meetup("full"),
  };
  const organizerB = { organizerId: uidB, organizerName: "Accept B", organizerAvatar: avatar(uidB) };
  const requirements = (petType, maxPets) => ({
    dogSize: "any", petType, maxPets, mustHavePosts: false, mustHavePetProfile: false,
    minFollowers: 0, additionalNotes: "",
  });
  const publicPark = {
    name: "TEST CONTENT Riverside Dog Park", address: "1 River St, Cambridge, MA",
    lat: 42.3601, lng: -71.0942, city: "Cambridge", state: "MA",
  };
  const shape = (fields) => ({
    ...organizerB,
    description: "TEST CONTENT Bring water.",
    duration: 60,
    isRatingOpen: false,
    participantCount: 1,
    createdAt: Timestamp.fromMillis(now - day),
    updatedAt: Timestamp.fromMillis(now - day),
    ...fields,
  });
  await db.doc(`meetups/${meetups.soon}`).set(shape({
    title: "TEST CONTENT Sunday splash", date: Timestamp.fromMillis(now + 2 * day),
    location: publicPark, locationId: places.reviewed, locationVisibility: "everyone",
    requirements: requirements("any", 5), status: "upcoming",
  }));
  await db.doc(`meetups/${meetups.later}`).set(shape({
    ...{ organizerId: uidA, organizerName: "Accept A", organizerAvatar: avatar(uidA) },
    title: "TEST CONTENT Dogs on the trail", date: Timestamp.fromMillis(now + 10 * day),
    location: { name: "TEST CONTENT Hilltop Trail", address: "3 Hill Rd, Newton, MA", lat: 42.337, lng: -71.2092, city: "Newton", state: "MA" },
    locationId: places.trail, locationVisibility: "everyone",
    requirements: requirements("dog", 0), status: "upcoming",
  }));
  await db.doc(`meetups/${meetups.cancelled}`).set(shape({
    title: "TEST CONTENT Called off", date: Timestamp.fromMillis(now + 3 * day),
    location: publicPark, locationId: places.reviewed, locationVisibility: "everyone",
    requirements: requirements("any", 0), status: "cancelled",
  }));
  await db.doc(`meetups/${meetups.private}`).set(shape({
    title: "TEST CONTENT Backyard playdate", date: Timestamp.fromMillis(now + 3 * day),
    // The server's public copy of a participants-only meetup: no street, no
    // coordinates, and a name that says only where roughly.
    location: { name: "Meetup near Somerville, MA", address: "", lat: 0, lng: 0, city: "Somerville", state: "MA" },
    locationVisibility: "participants_only",
    requirements: requirements("any", 6), status: "upcoming",
  }));
  await db.doc(`meetups/${meetups.private}/private/address`).set({
    name: "TEST CONTENT 12 Elm St backyard", address: "12 Elm St, Somerville, MA",
    lat: 42.3876, lng: -71.0995, city: "Somerville", state: "MA",
  });
  await db.doc(`meetups/${meetups.full}`).set(shape({
    title: "TEST CONTENT One-pet walk", date: Timestamp.fromMillis(now + 4 * day),
    location: publicPark, locationId: places.reviewed, locationVisibility: "everyone",
    requirements: requirements("any", 1), status: "upcoming",
  }));
  // Every meetup has its organiser as its first participant, as the create
  // callable writes it — and the count of 1 above is that entry.
  for (const id of Object.values(meetups)) {
    const organiser = id === meetups.later
      ? { uid: uidA, name: "Accept A", pet: { id: "ios-pet-latin", name: "Mochi" } }
      : { uid: uidB, name: "Accept B", pet: { id: "ios-pet-cjk", name: "麻薯团子小豆泥花生酱" } };
    await db.doc(`meetups/${id}/participants/${organiser.uid}`).set({
      meetupId: id, userId: organiser.uid, userName: organiser.name, userAvatar: avatar(organiser.uid),
      petId: organiser.pet.id, petName: organiser.pet.name, petAvatar: ratioImage("1:1", 200, "sample.jpg"),
      joinedAt: Timestamp.fromMillis(now - day), status: "confirmed", counted: true,
    });
  }
  return { places, meetups };
}

/** The review and check-in triggers counted the seeded place, within a minute. */
async function gatheringChecks({ places }) {
  let data = {};
  for (let attempt = 0; attempt < 60; attempt += 1) {
    data = (await db.doc(`locations/${places.reviewed}`).get()).data() ?? {};
    if (data.totalRatings === 2 && data.totalCheckins === 2) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  const trail = (await db.doc(`locations/${places.trail}`).get()).data() ?? {};
  return [
    [`the review trigger counted the park's 2 reviews`, data.totalRatings === 2, `${data.totalRatings} reviews, average ${data.averageRating}`],
    [`the park's average is 4.5`, data.averageRating === 4.5, data.averageRating],
    [`the check-in trigger counted 2 check-ins`, data.totalCheckins === 2, data.totalCheckins],
    [`the trail's one review counted`, trail.totalRatings === 1, trail.totalRatings],
  ];
}

async function main() {
  console.log(
    `Seeding ${PROJECT} via ${process.env.FIRESTORE_EMULATOR_HOST || "the real backend"}`
  );

  const uidA = await upsertUser({ email: "accept-a@example.com", name: "Accept A", verified: true });
  const uidB = await upsertUser({ email: "accept-b@example.com", name: "Accept B", verified: true });
  // An account whose email is not verified, because the server refusing a
  // comment from one is an acceptance item and there is no way to exercise it
  // without such an account. It was described in the plan and never actually
  // created here — the emulator happened to have one left over from a UI test,
  // so nothing noticed until a fresh cloud project had only two accounts.
  const uidNew = await upsertUser({
    email: "accept-new@example.com", name: "Accept New", verified: false,
  });
  console.log(`  accept-a -> ${uidA}`);
  console.log(`  accept-b -> ${uidB}`);
  console.log(`  accept-new -> ${uidNew} (email not verified, on purpose)`);

  await upsertPet({ id: "ios-pet-latin", name: "Mochi", ownerId: uidA, ownerName: "Accept A", species: "dog", breed: "Shiba" });
  // A deliberately long CJK name: it must truncate, not overflow the card.
  await upsertPet({ id: "ios-pet-cjk", name: "麻薯团子小豆泥花生酱", ownerId: uidB, ownerName: "Accept B", species: "cat", breed: "狸花猫" });
  console.log("  pets: ios-pet-latin (Mochi), ios-pet-cjk (麻薯团子小豆泥花生酱)");

  // Registered before anything is written, so a run that dies halfway still
  // leaves a record of what to clean up. A crash used to leave orphans that
  // only a wildcard sweep could find, and that sweep was the original defect.
  await db.doc(`${RUN_REGISTRY}/${RUN_ID}`).set({
    ...RUN_RECORD,
    startedAt: Timestamp.now(),
    complete: false,
  });

  const removed = await clearRecordedRuns();
  console.log(`  run ${RUN_ID}; removed ${removed.removedPosts} posts from ${removed.removedRuns} recorded run(s) + legacy`);

  const now = Date.now();
  const authors = [
    { uid: uidA, name: "Accept A", pet: { id: "ios-pet-latin", name: "Mochi" } },
    { uid: uidB, name: "Accept B", pet: { id: "ios-pet-cjk", name: "麻薯团子小豆泥花生酱" } },
  ];

  let written = 0;
  for (let i = 0; i < POST_COUNT; i += 1) {
    const author = i === CJK_PET_INDEX ? authors[1] : authors[i % authors.length];
    const media = mediaFor(i);
    const id = postID(i);

    const doc = {
      authorId: author.uid,
      authorName: author.name,
      authorAvatar: `https://api.dicebear.com/7.x/thumbs/svg?seed=${author.uid}`,
      text: textFor(i),
      // Newest first, one minute apart: `orderBy createdAt desc` then gives the
      // same order as the index in the text, which is what the scroll-position
      // checks compare against.
      createdAt: Timestamp.fromMillis(now - i * 60_000),

      // No aggregate is written here at all — not commentCount, not
      // likeCount. Both are maintained by triggers, and a seed that sets them
      // is a seed that can disagree with its own documents. It did: 179 of 210
      // posts were wrong, and the fake `likeCount: i % 7` was wrong on every
      // post that never received a like document.
      //
      // A post therefore starts with no counts, the triggers put them there,
      // and waitForAggregates() below refuses to call the run successful until
      // they match what is actually stored.
      tags: TAG_POOL[i % TAG_POOL.length],
    };
    if (media) {
      doc.media = media;
      // The legacy single-media fields are still read by older clients, so keep
      // them consistent with media[0] rather than leaving them undefined.
      doc.mediaUrl = media[0].url;
      doc.mediaType = media[0].type;
    }
    if (i !== NO_PET_INDEX) {
      doc.petId = author.pet.id;
      doc.petName = author.pet.name;
      doc.petAvatarUrl = ratioImage("1:1", 200, "sample.jpg");
    }

    await db.doc(`posts/${id}`).set(doc);
    written += 1;

    if (i === MANY_COMMENTS_INDEX) {
      for (let c = 0; c < MANY_COMMENTS_COUNT; c += 1) {
        const commenter = authors[c % authors.length];
        await db.collection(`posts/${id}/comments`).add({
          authorId: commenter.uid,
          authorName: commenter.name,
          authorAvatar: `https://api.dicebear.com/7.x/thumbs/svg?seed=${commenter.uid}`,
          text: `TEST CONTENT comment ${String(c).padStart(2, "0")} — 中文和 English 混排，用来看换行。`,
          createdAt: Timestamp.fromMillis(now - c * 30_000),
        });
      }
    }

    // Real like documents, written the way a client writes them —
    // `counted: false`, so onLikeCreated counts them and stamps them. The
    // previous seed wrote `counted: true` to make the trigger skip, because
    // the fake likeCount above already included them. That is the pattern
    // this whole rewrite is removing: the seed deciding what a trigger's
    // output should be.
    //
    // Only the first 60 posts, which is what any test actually scrolls
    // through. Every like is a trigger event, and 210 posts' worth buys
    // nothing but a slower convergence deadline.
    if (i < LIKED_POST_LIMIT) {
      const likers = [];
      for (let n = 0; n < i % 5; n += 1) likers.push(authors[n % authors.length].uid);
      // accept-a on a regular cadence, so "already liked by me" is on screen
      // early rather than somewhere past the first page.
      if (i % 7 === 1) likers.push(uidA);

      for (const liker of new Set(likers)) {
        await db.doc(`posts/${id}/likes/${liker}`).set({
          userId: liker,
          postId: id,
          createdAt: Timestamp.fromMillis(now - i * 60_000),
          counted: false,
        });
      }
    }
  }

  console.log(`  posts: ${written}`);
  console.log(`    videos at indexes      ${VIDEO_INDEXES.join(", ")}`);
  console.log(`    broken image at        ${BROKEN_MEDIA_INDEX} (404)`);
  console.log(`    broken video at        ${BROKEN_VIDEO_INDEX} (404)`);
  console.log(`    text-only at           ${TEXT_ONLY_INDEX}`);
  console.log(`    long text (>600) at    ${LONG_TEXT_INDEX}`);
  console.log(`    no pet at              ${NO_PET_INDEX}`);
  console.log(`    CJK pet name at        ${CJK_PET_INDEX}`);
  console.log(`    ${MANY_COMMENTS_COUNT} comments on         ${postID(MANY_COMMENTS_INDEX)}`);
  const gatherings = await seedGatherings({ uidA, uidB, now });
  console.log(`  places: ${Object.values(gatherings.places).join(", ")}`);
  console.log(`  meetups: ${Object.values(gatherings.meetups).join(", ")}`);

  // The triggers own every aggregate. Nothing below writes one.
  const settle = await waitForAggregates(Array.from({ length: POST_COUNT }, (_, i) => postID(i)));
  console.log(
    settle.converged
      ? `  aggregates converged after ${(settle.elapsedMs / 1000).toFixed(1)}s (${settle.polls} polls)`
      : `  aggregates DID NOT converge within the deadline (${settle.unconverged.length} posts)`
  );
  const triggerAlive = await proveTheCommentTriggerRuns();

  // Read back what was written and check it against the matrix, so "the seed
  // ran" and "the seed produced the dataset" are not the same claim.
  const readBack = await db.collection("posts").orderBy("createdAt", "desc").get();
  const seeded = readBack.docs.filter((d) => d.id.startsWith(POST_ID_PREFIX));
  const videoPosts = seeded.filter((d) => (d.data().media || []).some((m) => m.type === "video"));
  const commentsOnTarget = await db
    .collection(`posts/${postID(MANY_COMMENTS_INDEX)}/comments`)
    .get();
  // The aggregate is maintained by a trigger, so it arrives after the writes
  // do. Waiting for it here is not politeness — it is the only evidence in
  // this script that the comment trigger is deployed and actually running.
  const targetPostRef = db.doc(`posts/${postID(MANY_COMMENTS_INDEX)}`);
  let aggregate = -1;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    aggregate = (await targetPostRef.get()).data()?.commentCount ?? -1;
    if (aggregate === commentsOnTarget.size) break;
    await new Promise((r) => setTimeout(r, 1000));
  }

  const checks = [
    [`>=200 posts`, seeded.length >= 200, seeded.length],
    // Counting documents is not checking the count. The previous version of
    // this script asserted only the former, which is how a commentCount of
    // 120 on 60 comments survived.
    [`commentCount matches the comments that exist`, aggregate === commentsOnTarget.size,
      `${aggregate} vs ${commentsOnTarget.size} documents`],
    // Not "settled by us". Converged on its own, or it did not, and the
    // second case is a failure rather than something to correct and move past.
    [`aggregates converged before the deadline`, settle.converged,
      settle.converged
        ? `${(settle.elapsedMs / 1000).toFixed(1)}s`
        : `未在截止时间内收敛: ${settle.unconverged.slice(0, 5).join(" | ")}${settle.unconverged.length > 5 ? ` (+${settle.unconverged.length - 5})` : ""}`],
    // A narrower claim than the line above, and it is worth keeping the two
    // apart: this proves the create-and-delete path on one post responds.
    // It does not stand in for the bulk convergence check, and it says
    // nothing about late events from a previous run.
    [`the comment trigger responds on the probed path`, triggerAlive.ok, triggerAlive.detail],
    [`>=5 video posts`, videoPosts.length >= 5, videoPosts.length],
    [`>50 comments on one post`, commentsOnTarget.size > 50, commentsOnTarget.size],
    [`one post with no media`, seeded.filter((d) => !d.data().media).length >= 1, seeded.filter((d) => !d.data().media).length],
    [`one post with no pet`, seeded.filter((d) => !d.data().petId).length >= 1, seeded.filter((d) => !d.data().petId).length],
    [`one body >600 chars`, seeded.filter((d) => (d.data().text || "").length > 600).length >= 1, Math.max(...seeded.map((d) => (d.data().text || "").length))],
    [`a CJK pet name`, seeded.some((d) => /[\u4e00-\u9fff]/.test(d.data().petName || "")), "yes"],
    [`>=3 image aspect ratios`, new Set(seeded.flatMap((d) => (d.data().media || []).map((m) => (m.url.match(/ar_[0-9:]+/) || ["none"])[0]))).size >= 3, [...new Set(seeded.flatMap((d) => (d.data().media || []).map((m) => (m.url.match(/ar_[0-9:]+/) || ["none"])[0])))].join(",")],
    [`a 404 media url`, seeded.some((d) => (d.data().media || []).some((m) => m.url.includes("missing"))), "yes"],
    // The review and check-in triggers ran on the seeded place: the numbers
    // the Places screens show are theirs, not the seed's.
    ...(await gatheringChecks(gatherings)),
  ];
  console.log("\n  self-check:");
  let failed = 0;
  for (const [label, ok, detail] of checks) {
    console.log(`    ${ok ? "ok  " : "FAIL"}  ${label}  (${detail})`);
    if (!ok) failed += 1;
  }
  if (failed) {
    // The run stays in the register, with what it wrote, so the next run can
    // remove exactly this namespace. Not publishing `current` keeps a bad
    // dataset from becoming the baseline; it must not also make the leftovers
    // untraceable, which would be the worse of the two failures.
    await db.doc(`${RUN_REGISTRY}/${RUN_ID}`).set({
      ...RUN_RECORD,
      failedAt: Timestamp.now(),
      failedChecks: checks.filter(([, ok]) => !ok).map(([label]) => label),
      complete: false,
    });
    console.error(`\n${failed} seed self-check(s) failed; the dataset does not match the acceptance matrix.`);
    console.error(`Run ${RUN_ID} stays registered at ${RUN_REGISTRY}/${RUN_ID}; its ${POST_ID_PREFIX}* posts are cleanable.`);
    process.exit(1);
  }

  // The manifest, written only once the checks have passed. A run that
  // failed its own checks must not become the one tests read from — that is
  // how a bad dataset gets treated as the baseline.
  //
  // Tests read this instead of hardcoding `ios-post-001`. A hardcoded id
  // cannot survive per-run namespaces, and more to the point it is what let
  // tests keep passing against data left behind by a run nobody remembers.
  const manifest = {
    ...RUN_RECORD,
    postCount: POST_COUNT,
    likedPostLimit: LIKED_POST_LIMIT,
    accounts: {
      verifiedA: "accept-a@example.com",
      verifiedB: "accept-b@example.com",
      unverified: "accept-new@example.com",
    },
    landmarks: {
      firstPost: postID(0),
      manyComments: postID(MANY_COMMENTS_INDEX),
      manyCommentsCount: commentsOnTarget.size,
      brokenImage: postID(BROKEN_MEDIA_INDEX),
      brokenVideo: postID(BROKEN_VIDEO_INDEX),
      textOnly: postID(TEXT_ONLY_INDEX),
      longText: postID(LONG_TEXT_INDEX),
      noPet: postID(NO_PET_INDEX),
      cjkPetName: postID(CJK_PET_INDEX),
      videos: VIDEO_INDEXES.map(postID),
      // Flat, as strings: the tests' manifest reader takes string landmarks.
      ...Object.fromEntries(Object.entries(gatherings.places).map(([k, v]) => [`place_${k}`, v])),
      ...Object.fromEntries(Object.entries(gatherings.meetups).map(([k, v]) => [`meetup_${k}`, v])),
    },
    completedAt: Timestamp.now(),
    complete: true,
  };
  await db.doc(`${RUN_REGISTRY}/${RUN_ID}`).set(manifest);
  await db.doc(`${RUN_REGISTRY}/current`).set(manifest);

  console.log(`\n  manifest at ${RUN_REGISTRY}/current (run ${RUN_ID})`);
  console.log("\nAll content is prefixed TEST CONTENT. Accounts use Passw0rd!x.");
}

main()
  .then(() => process.exit(0))
  .catch(async (error) => {
    console.error("Seed failed:", error);
    // Same reasoning as the self-check failure path: a run that died halfway
    // has written documents, and the register is the only record of which
    // ones. Best effort — if this write also fails there is nothing further
    // to be done, and the legacy sweep remains as a backstop.
    await db.doc(`${RUN_REGISTRY}/${RUN_ID}`).set({
      ...RUN_RECORD,
      crashedAt: Timestamp.now(),
      error: String(error?.message ?? error).slice(0, 500),
      complete: false,
    }).catch(() => {});
    process.exit(1);
  });
