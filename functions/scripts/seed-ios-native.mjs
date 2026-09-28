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

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8088";
}
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9099";
}

// The project id is checked exactly, not by prefix: an emulator host can be set
// and still point at something real, and this script writes hundreds of docs.
const PROJECT = process.env.GCLOUD_PROJECT || "petnote-test";
if (PROJECT !== "petnote-test") {
  console.error(
    `Refusing to seed project "${PROJECT}". This script is for the local ` +
      `emulator only, and only for petnote-test.`
  );
  process.exit(1);
}
process.env.GCLOUD_PROJECT = PROJECT;

const admin = require(path.join(functionsRoot, "node_modules", "firebase-admin"));
if (admin.apps.length === 0) admin.initializeApp({ projectId: PROJECT });
const auth = admin.auth();
const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;
const Timestamp = admin.firestore.Timestamp;

// ---------------------------------------------------------------------------
// Shape of the dataset. Acceptance items that depend on each line are named so
// a later change here is visibly a change to what the acceptance run covers.
// ---------------------------------------------------------------------------
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

/** Deletes everything this script created, so post count stays deterministic. */
async function clearSeededPosts() {
  const snap = await db.collection("posts").get();
  const mine = snap.docs.filter((d) => d.id.startsWith("ios-"));
  let removed = 0;
  for (const doc of mine) {
    for (const sub of ["comments", "likes"]) {
      const kids = await doc.ref.collection(sub).get();
      // 500 is the batch limit; these subcollections are far smaller, but the
      // comment-heavy post has 60 docs, so chunk anyway.
      for (let i = 0; i < kids.docs.length; i += 400) {
        const batch = db.batch();
        kids.docs.slice(i, i + 400).forEach((k) => batch.delete(k.ref));
        await batch.commit();
      }
    }
    await doc.ref.delete();
    removed += 1;
  }
  return removed;
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

async function main() {
  console.log(`Seeding ${PROJECT} via ${process.env.FIRESTORE_EMULATOR_HOST}`);

  const uidA = await upsertUser({ email: "accept-a@example.com", name: "Accept A", verified: true });
  const uidB = await upsertUser({ email: "accept-b@example.com", name: "Accept B", verified: true });
  console.log(`  accept-a -> ${uidA}`);
  console.log(`  accept-b -> ${uidB}`);

  await upsertPet({ id: "ios-pet-latin", name: "Mochi", ownerId: uidA, ownerName: "Accept A", species: "dog", breed: "Shiba" });
  // A deliberately long CJK name: it must truncate, not overflow the card.
  await upsertPet({ id: "ios-pet-cjk", name: "麻薯团子小豆泥花生酱", ownerId: uidB, ownerName: "Accept B", species: "cat", breed: "狸花猫" });
  console.log("  pets: ios-pet-latin (Mochi), ios-pet-cjk (麻薯团子小豆泥花生酱)");

  const removed = await clearSeededPosts();
  if (removed) console.log(`  removed ${removed} previously seeded ios- posts`);

  const now = Date.now();
  const authors = [
    { uid: uidA, name: "Accept A", pet: { id: "ios-pet-latin", name: "Mochi" } },
    { uid: uidB, name: "Accept B", pet: { id: "ios-pet-cjk", name: "麻薯团子小豆泥花生酱" } },
  ];

  let written = 0;
  for (let i = 0; i < POST_COUNT; i += 1) {
    const author = i === CJK_PET_INDEX ? authors[1] : authors[i % authors.length];
    const media = mediaFor(i);
    const id = `ios-post-${String(i).padStart(3, "0")}`;

    const doc = {
      authorId: author.uid,
      authorName: author.name,
      authorAvatar: `https://api.dicebear.com/7.x/thumbs/svg?seed=${author.uid}`,
      text: textFor(i),
      // Newest first, one minute apart: `orderBy createdAt desc` then gives the
      // same order as the index in the text, which is what the scroll-position
      // checks compare against.
      createdAt: Timestamp.fromMillis(now - i * 60_000),
      likeCount: i % 7,
      commentCount: i === MANY_COMMENTS_INDEX ? MANY_COMMENTS_COUNT : i % 3,
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

    // A few likes by accept-a, so "already liked" has a state to render.
    // counted is true here because likeCount above already includes them; the
    // client must still write counted:false on its own likes (firestore.rules).
    if (i % 7 === 1) {
      await db.doc(`posts/${id}/likes/${uidA}`).set({
        userId: uidA,
        postId: id,
        createdAt: Timestamp.fromMillis(now - i * 60_000),
        counted: true,
      });
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
  console.log(`    ${MANY_COMMENTS_COUNT} comments on         ios-post-${String(MANY_COMMENTS_INDEX).padStart(3, "0")}`);
  // Read back what was written and check it against the matrix, so "the seed
  // ran" and "the seed produced the dataset" are not the same claim.
  const readBack = await db.collection("posts").orderBy("createdAt", "desc").get();
  const seeded = readBack.docs.filter((d) => d.id.startsWith("ios-"));
  const videoPosts = seeded.filter((d) => (d.data().media || []).some((m) => m.type === "video"));
  const commentsOnTarget = await db
    .collection(`posts/ios-post-${String(MANY_COMMENTS_INDEX).padStart(3, "0")}/comments`)
    .get();
  const checks = [
    [`>=200 posts`, seeded.length >= 200, seeded.length],
    [`>=5 video posts`, videoPosts.length >= 5, videoPosts.length],
    [`>50 comments on one post`, commentsOnTarget.size > 50, commentsOnTarget.size],
    [`one post with no media`, seeded.filter((d) => !d.data().media).length >= 1, seeded.filter((d) => !d.data().media).length],
    [`one post with no pet`, seeded.filter((d) => !d.data().petId).length >= 1, seeded.filter((d) => !d.data().petId).length],
    [`one body >600 chars`, seeded.filter((d) => (d.data().text || "").length > 600).length >= 1, Math.max(...seeded.map((d) => (d.data().text || "").length))],
    [`a CJK pet name`, seeded.some((d) => /[\u4e00-\u9fff]/.test(d.data().petName || "")), "yes"],
    [`>=3 image aspect ratios`, new Set(seeded.flatMap((d) => (d.data().media || []).map((m) => (m.url.match(/ar_[0-9:]+/) || ["none"])[0]))).size >= 3, [...new Set(seeded.flatMap((d) => (d.data().media || []).map((m) => (m.url.match(/ar_[0-9:]+/) || ["none"])[0])))].join(",")],
    [`a 404 media url`, seeded.some((d) => (d.data().media || []).some((m) => m.url.includes("missing"))), "yes"],
  ];
  console.log("\n  self-check:");
  let failed = 0;
  for (const [label, ok, detail] of checks) {
    console.log(`    ${ok ? "ok  " : "FAIL"}  ${label}  (${detail})`);
    if (!ok) failed += 1;
  }
  if (failed) {
    console.error(`\n${failed} seed self-check(s) failed; the dataset does not match the acceptance matrix.`);
    process.exit(1);
  }

  console.log("\nAll content is prefixed TEST CONTENT. Accounts use Passw0rd!x.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Seed failed:", error);
    process.exit(1);
  });
