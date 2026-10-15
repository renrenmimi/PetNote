/**
 * Supplementary emulator seed for experience review.
 *
 * `seed-acceptance.mjs` gives the account matrix — verified owner, co-owner,
 * unverified, admin — and one pet with one place. That is the right shape for
 * checking authorisation, and the wrong shape for looking at a feed: two
 * posts cannot show whether a long list reads well, whether a card survives a
 * 600-character caption, whether a CJK name truncates or overflows, or
 * whether the identity header does the right thing for a post with no pet.
 *
 * So this adds content variety on top, to the emulator only. Run
 * seed-acceptance.mjs first.
 *
 *   node scripts/seed-experience.mjs
 *
 * Refuses to run against anything but the emulator, and every document it
 * writes is obviously test content — the captions say so. Nothing here is
 * meant to look like real user data, because pretending otherwise is how you
 * end up reviewing a screen that will never exist.
 */
import admin from "firebase-admin";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8088";
}
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9099";
}
const PROJECT = process.env.GCLOUD_PROJECT || "petnote-test";
if (PROJECT !== "petnote-test") {
  console.error(`Refusing to seed project "${PROJECT}". Emulator only.`);
  process.exit(1);
}

admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();
const { FieldValue, Timestamp } = admin.firestore;

const minutesAgo = (m) => Timestamp.fromMillis(Date.now() - m * 60_000);

/** Deterministic placeholder images at stated aspect ratios. */
const img = (w, h, seed) => ({
  url: `https://picsum.photos/seed/${seed}/${w}/${h}`,
  thumbUrl: `https://picsum.photos/seed/${seed}/${Math.round(w / 3)}/${Math.round(h / 3)}`,
  type: "image",
  width: w,
  height: h,
});

const LONG_CAPTION =
  "TEST CONTENT. A deliberately long caption, so the card has to decide what " +
  "to do with more text than it was designed for: whether it clamps, whether " +
  "it pushes the action row off the screen, and whether the photo above it " +
  "still gets the space it needs. It keeps going for a while on purpose, " +
  "because a caption of one line proves nothing at all about a caption of " +
  "eight, and the only way to find out is to put eight on the screen and " +
  "look at it on a phone rather than in a desktop browser window.";

async function main() {
  const auth = admin.auth();
  const a = (await auth.getUserByEmail("accept-a@example.com")).uid;
  const b = (await auth.getUserByEmail("accept-b@example.com")).uid;

  // ---- a second pet, different species, so the feed is not one animal ----
  const petTwo = "exp-pet-cat";
  await db.doc(`pets/${petTwo}`).set(
    {
      name: "测试猫 Biscuit",
      nameLower: "测试猫 biscuit",
      species: "cat",
      gender: "male",
      // No breed on purpose: exercises the species-name fallback in the
      // pet header where the duplicate species emoji used to be.
      bio: "TEST CONTENT. A CJK name, to check truncation rather than overflow.",
      ownerId: b,
      primaryOwnerId: b,
      followerCount: 0,
      postCount: 0,
      createdAt: minutesAgo(2000),
    },
    { merge: true }
  );
  await db.doc(`pets/${petTwo}/family/${b}`).set(
    {
      userId: b,
      userName: "Accept B",
      relationship: "dad",
      role: "primary",
      joinedAt: minutesAgo(2000),
    },
    { merge: true }
  );

  // ---- co-owner on Mochi, so the family row has more than one member ----
  await db.doc(`pets/accept-pet/family/${b}`).set(
    {
      userId: b,
      userName: "Accept B",
      relationship: "custom",
      customRelationship: "co-owner",
      role: "member",
      joinedAt: minutesAgo(1200),
    },
    { merge: true }
  );

  // ---- posts: enough to scroll, and varied where variety matters ----
  const posts = [
    { id: "exp-p01", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT. Square photo.", media: [img(1080, 1080, "sq1")], likes: 7, tags: ["walkies", "shiba"] },
    { id: "exp-p02", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT. Tall photo, 4:5.", media: [img(1080, 1350, "tall1")], likes: 12, tags: ["walkies"] },
    { id: "exp-p03", pet: petTwo, petName: "测试猫 Biscuit", owner: b, caption: "TEST CONTENT. Wide photo, 16:9.", media: [img(1600, 900, "wide1")], likes: 3, tags: ["napping"] },
    { id: "exp-p04", pet: "accept-pet", petName: "Mochi", owner: a, caption: LONG_CAPTION, media: [img(1080, 1080, "sq2")], likes: 9, tags: ["walkies", "shiba"] },
    // No pet at all: PostIdentity must lead with the author and not invent one.
    { id: "exp-p05", pet: null, petName: null, owner: a, caption: "TEST CONTENT. A post with no pet attached.", media: [img(1080, 1080, "sq3")], likes: 1, tags: [] },
    { id: "exp-p06", pet: petTwo, petName: "测试猫 Biscuit", owner: b, caption: "TEST CONTENT. Two photos.", media: [img(1080, 1080, "sq4"), img(1080, 1350, "tall2")], likes: 5, tags: ["napping"] },
    { id: "exp-p07", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT. No photo, text only.", media: [], likes: 2, tags: ["shiba"] },
    { id: "exp-p08", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT 8.", media: [img(1080, 1080, "sq5")], likes: 15, tags: ["walkies"] },
    { id: "exp-p09", pet: petTwo, petName: "测试猫 Biscuit", owner: b, caption: "TEST CONTENT 9.", media: [img(1080, 1080, "sq6")], likes: 4, tags: ["napping"] },
    { id: "exp-p10", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT 10.", media: [img(1080, 1350, "tall3")], likes: 6, tags: ["shiba"] },
    { id: "exp-p11", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT 11.", media: [img(1080, 1080, "sq7")], likes: 8, tags: ["walkies"] },
    { id: "exp-p12", pet: petTwo, petName: "测试猫 Biscuit", owner: b, caption: "TEST CONTENT 12.", media: [img(1600, 900, "wide2")], likes: 2, tags: [] },
    { id: "exp-p13", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT 13.", media: [img(1080, 1080, "sq8")], likes: 11, tags: ["shiba"] },
    { id: "exp-p14", pet: "accept-pet", petName: "Mochi", owner: a, caption: "TEST CONTENT 14.", media: [img(1080, 1080, "sq9")], likes: 0, tags: [] },
  ];

  const names = { [a]: "Accept A", [b]: "Accept B" };
  let minute = 30;
  for (const post of posts) {
    await db.doc(`posts/${post.id}`).set(
      {
        authorId: post.owner,
        authorName: names[post.owner],
        authorAvatar: "",
        petId: post.pet,
        petName: post.petName,
        petAvatarUrl: "",
        // `text` and `tags`, which is what services/posts.ts reads. My first
        // version wrote `caption` and `hashtags`, and the app correctly
        // rendered nothing — a seed bug that would have had me reviewing
        // screens with no body text and drawing conclusions from it.
        text: post.caption,
        media: post.media,
        mediaUrl: post.media[0]?.url ?? "",
        visibility: "public",
        likeCount: post.likes,
        commentCount: 0,
        tags: post.tags,
        createdAt: minutesAgo(minute),
        updatedAt: minutesAgo(minute),
      },
      { merge: true }
    );
    minute += 45;
  }

  // ---- tags with a spread of counts, so the "popular" threshold is
  //      exercised from both sides rather than only the thin one ----
  const tagCounts = { walkies: 5, shiba: 4, napping: 3, onlyonce: 1 };
  for (const [name, postCount] of Object.entries(tagCounts)) {
    await db.doc(`hashtags/${name}`).set(
      { name, postCount, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  }

  console.log(`Seeded ${posts.length} posts, 1 extra pet, 1 co-owner, 4 tags.`);
  console.log("All captions are prefixed TEST CONTENT. Emulator only.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
