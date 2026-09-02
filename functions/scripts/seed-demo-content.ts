/**
 * Seeds a small set of complete, plausible accounts so the live site has
 * something real to show: profiles with avatars and bios, a pet each, a few
 * posts, one place with a review, and one meetup with participants.
 *
 * Run after functions/scripts/reset-production-data.ts, from the functions/ directory:
 *
 *   cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
 *     npx ts-node scripts/seed-demo-content.ts --project=petnote-a9dac
 *
 * Passwords are set so you can sign in as these accounts and add photos through
 * the app. They are printed once, at the end, and stored nowhere.
 *
 * Photos are deliberately not seeded. Post media has to be a res.cloudinary.com
 * URL (enforced by TRUSTED_MEDIA_URL_HOSTS in functions/src/shared.ts), and
 * inventing URLs would produce broken images. Sign in as each account and
 * upload through the app, which is also the only way the Cloudinary assets end
 * up under the right petnote/users/{uid}/ folder.
 *
 * Avatars DO work without an upload: getDefaultAvatar generates a
 * api.dicebear.com URL, which is on the trusted avatar host list.
 */

import { createHash, randomBytes } from "node:crypto";
import * as admin from "firebase-admin";

const args = process.argv.slice(2);
const projectId = args.find((a) => a.startsWith("--project="))?.split("=")[1];

if (!projectId) {
  console.error("Refusing to run without --project=<id>.");
  process.exit(1);
}

admin.initializeApp({ projectId });
const db = admin.firestore();
const now = () => admin.firestore.FieldValue.serverTimestamp();

// Mirrors getDefaultAvatar in functions/src/shared.ts.
const defaultAvatar = (seed: string) =>
  `https://api.dicebear.com/9.x/thumbs/svg?seed=${encodeURIComponent(seed)}`;

// Mirrors usernameKey in functions/src/users.ts — the reservation doc id is a
// sha256 of the lowercased display name, not the name itself.
const usernameKey = (displayNameLower: string) =>
  createHash("sha256").update(displayNameLower).digest("hex");

type SeedPerson = {
  displayName: string;
  bio: string;
  city: string;
  state: string;
  pet: { name: string; species: string; breed: string; gender: string; bio: string };
  posts: Array<{ text: string; tags: string[] }>;
};

const PEOPLE: SeedPerson[] = [
  {
    displayName: "Maya Torres",
    bio: "Weekend hiker, weekday couch cushion. Here for the dog park gossip.",
    city: "Boston",
    state: "MA",
    pet: {
      name: "Juniper",
      species: "dog",
      breed: "Border Collie",
      gender: "female",
      bio: "Will herd anything that moves, including strollers.",
    },
    posts: [
      {
        text: "Juniper finally figured out the stairs. Took three weeks and a lot of cheese.",
        tags: ["puppytraining", "bordercollie"],
      },
      {
        text: "Cold morning at the reservoir. She lasted about four minutes before demanding to be carried.",
        tags: ["morningwalk"],
      },
      {
        text: "Vet says she is at a healthy weight, which is a first. The cheese was worth it.",
        tags: ["vetvisit"],
      },
    ],
  },
  {
    displayName: "Daniel Okafor",
    bio: "Cat person who got outvoted at home. Two of them now.",
    city: "Cambridge",
    state: "MA",
    pet: {
      name: "Pepper",
      species: "cat",
      breed: "Domestic Shorthair",
      gender: "male",
      bio: "Sleeps on the keyboard. Considers this a job.",
    },
    posts: [
      {
        text: "Pepper has decided the windowsill belongs to him now. I have been relocated.",
        tags: ["catsofpetnote"],
      },
      {
        text: "Tried three brands of wet food this week. He has opinions and they are expensive.",
        tags: ["pickyeater"],
      },
    ],
  },
  {
    displayName: "Ana Ribeiro",
    bio: "Adopted a senior dog last year. Best decision I have made.",
    city: "Somerville",
    state: "MA",
    pet: {
      name: "Bruno",
      species: "dog",
      breed: "Beagle mix",
      gender: "male",
      bio: "Nine years old and still convinced he is a puppy at dinner time.",
    },
    posts: [
      {
        text: "Bruno turned nine today. He got a whole scrambled egg and looked at me like I had lost my mind.",
        tags: ["seniordogs", "adoptdontshop"],
      },
      {
        text: "Rainy day, so we are doing scent games indoors. He found all six treats in under a minute.",
        tags: ["seniordogs", "rainyday"],
      },
    ],
  },
];

const PLACE = {
  name: "Danehy Park Dog Run",
  address: "99 Sherman St, Cambridge, MA 02140",
  city: "Cambridge",
  state: "MA",
  lat: 42.3925,
  lng: -71.1345,
  description:
    "Fenced double-gated run with separate small-dog area. Water fountain works from April to October.",
};

const MEETUP = {
  title: "Saturday morning beagle walk",
  description:
    "Easy loop around the park, about forty minutes. Friendly dogs of any size welcome, we go at the pace of the slowest nose.",
};

async function seedPerson(person: SeedPerson) {
  const password = randomBytes(12).toString("base64url");
  const email = `${person.displayName.toLowerCase().replace(/\s+/g, ".")}@example.com`;
  const displayNameLower = person.displayName.toLowerCase();
  const avatarUrl = defaultAvatar(person.displayName);

  const authUser = await admin.auth().createUser({
    email,
    password,
    emailVerified: true,
    displayName: person.displayName,
    photoURL: avatarUrl,
  });
  const uid = authUser.uid;

  await db.doc(`usernames/${usernameKey(displayNameLower)}`).set({
    userId: uid,
    displayName: person.displayName,
    displayNameLower,
    createdAt: now(),
    updatedAt: now(),
  });

  await db.doc(`users/${uid}`).set({
    displayName: person.displayName,
    displayNameLower,
    avatarUrl,
    bio: person.bio,
    onboardingComplete: true,
    location: { city: person.city, state: person.state, updatedAt: now() },
    followerCount: 0,
    followingCount: 0,
    followingPetsCount: 0,
    createdAt: now(),
  });

  const petRef = db.collection("pets").doc();
  const petAvatar = defaultAvatar(person.pet.name);
  await petRef.set({
    name: person.pet.name,
    nameLower: person.pet.name.toLowerCase(),
    species: person.pet.species,
    breed: person.pet.breed,
    gender: person.pet.gender,
    bio: person.pet.bio,
    avatarUrl: petAvatar,
    ownerId: uid,
    primaryOwnerId: uid,
    followerCount: 0,
    postCount: person.posts.length,
    createdAt: now(),
  });
  await db.doc(`pets/${petRef.id}/family/${uid}`).set({
    userId: uid,
    userName: person.displayName,
    userAvatar: avatarUrl,
    relationship: person.pet.gender === "female" ? "mom" : "dad",
    joinedAt: now(),
  });

  const postIds: string[] = [];
  for (const post of person.posts) {
    const postRef = db.collection("posts").doc();
    await postRef.set({
      authorId: uid,
      authorName: person.displayName,
      authorAvatar: avatarUrl,
      text: post.text,
      media: [],
      tags: post.tags,
      petId: petRef.id,
      petName: person.pet.name,
      petAvatar,
      likeCount: 0,
      commentCount: 0,
      createdAt: now(),
    });
    postIds.push(postRef.id);

    for (const tag of post.tags) {
      await db.doc(`hashtags/${tag}`).set(
        {
          name: tag,
          postCount: admin.firestore.FieldValue.increment(1),
          lastUsed: now(),
        },
        { merge: true }
      );
    }
  }

  return { uid, email, password, displayName: person.displayName, avatarUrl, petId: petRef.id, petName: person.pet.name, petAvatar, postIds };
}

async function main() {
  console.log(`project : ${projectId}`);
  console.log("");

  const seeded = [];
  for (const person of PEOPLE) {
    seeded.push(await seedPerson(person));
    console.log(`seeded ${person.displayName} with ${person.pet.name} and ${person.posts.length} posts`);
  }

  // A place, with one review so it does not read as empty.
  const locationRef = db.collection("locations").doc();
  const reviewer = seeded[0];
  await locationRef.set({
    name: PLACE.name,
    nameLower: PLACE.name.toLowerCase(),
    address: PLACE.address,
    city: PLACE.city,
    state: PLACE.state,
    lat: PLACE.lat,
    lng: PLACE.lng,
    description: PLACE.description,
    createdBy: reviewer.uid,
    photos: [],
    locationPhotos: [],
    totalPhotos: 0,
    totalRatings: 1,
    sumRating: 5,
    averageRating: 5,
    totalCheckins: 0,
    verifiedByCheckins: false,
    createdAt: now(),
  });
  await db.doc(`locations/${locationRef.id}/reviews/${reviewer.uid}`).set({
    counted: true,
    userId: reviewer.uid,
    userName: reviewer.displayName,
    userAvatar: reviewer.avatarUrl,
    rating: 5,
    comment:
      "Double gate is a real one, not a symbolic one. Small-dog side is quieter in the mornings.",
    tags: ["fenced", "water"],
    photos: [],
    createdAt: now(),
  });
  console.log(`seeded place ${PLACE.name} with 1 review`);

  // A meetup, organised by the third account, with the other two joined.
  const organizer = seeded[2];
  const meetupRef = db.collection("meetups").doc();
  await meetupRef.set({
    title: MEETUP.title,
    description: MEETUP.description,
    organizerId: organizer.uid,
    organizerName: organizer.displayName,
    organizerAvatar: organizer.avatarUrl,
    status: "upcoming",
    locationVisibility: "participants_only",
    location: { name: PLACE.name, city: PLACE.city, state: PLACE.state },
    participantCount: seeded.length,
    dateTime: admin.firestore.Timestamp.fromMillis(Date.now() + 5 * 24 * 60 * 60 * 1000),
    createdAt: now(),
  });
  // Exact address lives in the private subcollection, readable only by the
  // organizer, confirmed participants and admins.
  await db.doc(`meetups/${meetupRef.id}/private/location`).set({
    address: PLACE.address,
    lat: PLACE.lat,
    lng: PLACE.lng,
  });
  for (const person of seeded) {
    await db.doc(`meetups/${meetupRef.id}/participants/${person.uid}`).set({
      meetupId: meetupRef.id,
      userId: person.uid,
      userName: person.displayName,
      userAvatar: person.avatarUrl,
      petId: person.petId,
      petName: person.petName,
      petAvatar: person.petAvatar,
      status: "confirmed",
      joinedAt: now(),
      // Set in the same breath as participantCount above, exactly as
      // joinMeetupCallable does, so onParticipantDeleted knows to subtract.
      counted: true,
    });
  }
  console.log(`seeded meetup "${MEETUP.title}" with ${seeded.length} participants`);

  console.log("\nSign-in details — printed once, stored nowhere:\n");
  for (const person of seeded) {
    console.log(`  ${person.email.padEnd(28)} ${person.password}`);
  }
  console.log(
    "\nPhotos were not seeded. Sign in as each account and upload through the app so\n" +
      "the assets land under petnote/users/{uid}/ in Cloudinary, then reshoot the\n" +
      "README screenshots."
  );
}

main().then(
  () => process.exit(0),
  (error) => {
    console.error(error);
    process.exit(1);
  }
);
