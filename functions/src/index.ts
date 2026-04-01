import * as admin from "firebase-admin";
import { onDocumentDeleted, onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";

admin.initializeApp();
const db = admin.firestore();

// ============================================================
// 1. Orphan cleanup: when a pet is deleted, clean up cross-user
//    followingPets mirrors and unlink posts referencing the pet.
// ============================================================
export const onPetDeleted = onDocumentDeleted("pets/{petId}", async (event) => {
  const petId = event.params.petId;

  // Remove all users' followingPets entries for this pet
  const followingSnap = await db.collectionGroup("followingPets")
    .where("petId", "==", petId).get();
  if (!followingSnap.empty) {
    const batch = db.batch();
    for (const doc of followingSnap.docs) {
      batch.delete(doc.ref);
      // Decrement the user's followingPetsCount
      const userRef = doc.ref.parent.parent;
      if (userRef) {
        batch.update(userRef, {
          followingPetsCount: admin.firestore.FieldValue.increment(-1),
        });
      }
    }
    await batch.commit();
  }

  // Clear petId from posts that reference this pet
  const postsSnap = await db.collection("posts")
    .where("petId", "==", petId).get();
  if (!postsSnap.empty) {
    const batch = db.batch();
    for (const doc of postsSnap.docs) {
      batch.update(doc.ref, { petId: "", petName: "", petAvatarUrl: "" });
    }
    await batch.commit();
  }
});

// ============================================================
// 2. Orphan cleanup: when a post is deleted, clean up cross-user
//    bookmarks and reports referencing the post.
// ============================================================
export const onPostDeleted = onDocumentDeleted("posts/{postId}", async (event) => {
  const postId = event.params.postId;

  // Remove all users' bookmarks for this post
  const bookmarksSnap = await db.collectionGroup("bookmarks")
    .where("__name__", ">=", postId)
    .where("__name__", "<=", postId)
    .get();
  // collectionGroup __name__ query may not work as expected,
  // so also try by document ID pattern
  if (!bookmarksSnap.empty) {
    const batch = db.batch();
    for (const doc of bookmarksSnap.docs) {
      if (doc.id === postId) {
        batch.delete(doc.ref);
      }
    }
    await batch.commit();
  }

  // Remove reports targeting this post
  const reportsSnap = await db.collection("reports")
    .where("targetId", "==", postId)
    .where("targetType", "==", "post").get();
  if (!reportsSnap.empty) {
    const batch = db.batch();
    for (const doc of reportsSnap.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();
  }
});

// ============================================================
// 3. Aggregation: maintain location averageRating/totalRatings
//    server-side when reviews are created or deleted.
// ============================================================
export const onReviewCreated = onDocumentCreated(
  "locations/{locationId}/reviews/{reviewId}",
  async (event) => {
    const locationId = event.params.locationId;
    const reviewData = event.data?.data();
    if (!reviewData) return;

    const locationRef = db.doc(`locations/${locationId}`);
    await db.runTransaction(async (t) => {
      const locSnap = await t.get(locationRef);
      const current = locSnap.data() || { averageRating: 0, totalRatings: 0 };
      const totalRatings = (current.totalRatings || 0) + 1;
      const averageRating =
        ((current.averageRating || 0) * (current.totalRatings || 0) + reviewData.rating) /
        totalRatings;
      t.update(locationRef, {
        averageRating: Number(averageRating.toFixed(2)),
        totalRatings,
      });
    });
  }
);

export const onReviewDeleted = onDocumentDeleted(
  "locations/{locationId}/reviews/{reviewId}",
  async (event) => {
    const locationId = event.params.locationId;
    const reviewData = event.data?.data();
    if (!reviewData) return;

    const locationRef = db.doc(`locations/${locationId}`);
    await db.runTransaction(async (t) => {
      const locSnap = await t.get(locationRef);
      const current = locSnap.data() || { averageRating: 0, totalRatings: 0 };
      const totalRatings = Math.max(0, (current.totalRatings || 0) - 1);
      const averageRating = totalRatings === 0
        ? 0
        : ((current.averageRating || 0) * (current.totalRatings || 0) - reviewData.rating) /
          totalRatings;
      t.update(locationRef, {
        averageRating: Number(Math.max(0, averageRating).toFixed(2)),
        totalRatings,
      });
    });
  }
);

// ============================================================
// 4. Aggregation: maintain hashtag postCount server-side when
//    posts are created or deleted.
// ============================================================
export const onPostWritten = onDocumentWritten("posts/{postId}", async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();

  const oldTags: string[] = before?.tags || [];
  const newTags: string[] = after?.tags || [];

  const added = newTags.filter((t) => !oldTags.includes(t));
  const removed = oldTags.filter((t) => !newTags.includes(t));

  const batch = db.batch();
  for (const tag of added) {
    const tagRef = db.doc(`hashtags/${tag}`);
    batch.set(tagRef, {
      name: tag,
      postCount: admin.firestore.FieldValue.increment(1),
      lastUsed: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  for (const tag of removed) {
    const tagRef = db.doc(`hashtags/${tag}`);
    batch.set(tagRef, {
      postCount: admin.firestore.FieldValue.increment(-1),
      lastUsed: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  if (added.length > 0 || removed.length > 0) {
    await batch.commit();
  }
});

// ============================================================
// 5. Name sync: when user profile displayName or avatarUrl
//    changes, sync to all denormalized copies atomically.
// ============================================================
export const onUserUpdated = onDocumentWritten("users/{userId}", async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!before || !after) return;

  const nameChanged = before.displayName !== after.displayName;
  const avatarChanged = before.avatarUrl !== after.avatarUrl;
  if (!nameChanged && !avatarChanged) return;

  const userId = event.params.userId;

  // Sync posts (authorName, authorAvatar)
  const postsSnap = await db.collection("posts")
    .where("authorId", "==", userId).get();
  if (!postsSnap.empty) {
    const batch = db.batch();
    const updates: Record<string, string> = {};
    if (nameChanged) updates.authorName = after.displayName;
    if (avatarChanged) updates.authorAvatar = after.avatarUrl;
    for (const doc of postsSnap.docs) {
      batch.update(doc.ref, updates);
    }
    await batch.commit();
  }

  // Sync comments (authorName, authorAvatar)
  const commentsSnap = await db.collectionGroup("comments")
    .where("authorId", "==", userId).get();
  if (!commentsSnap.empty) {
    const batch = db.batch();
    const updates: Record<string, string> = {};
    if (nameChanged) updates.authorName = after.displayName;
    if (avatarChanged) updates.authorAvatar = after.avatarUrl;
    for (const doc of commentsSnap.docs) {
      batch.update(doc.ref, updates);
    }
    await batch.commit();
  }

  // Sync notifications (fromUserName, fromUserAvatar)
  const notifSnap = await db.collection("notifications")
    .where("fromUserId", "==", userId).get();
  if (!notifSnap.empty) {
    const batch = db.batch();
    const updates: Record<string, string> = {};
    if (nameChanged) updates.fromUserName = after.displayName;
    if (avatarChanged) updates.fromUserAvatar = after.avatarUrl;
    for (const doc of notifSnap.docs) {
      batch.update(doc.ref, updates);
    }
    await batch.commit();
  }

  // Sync meetup participants (userName, userAvatar)
  const participantsSnap = await db.collectionGroup("participants")
    .where("userId", "==", userId).get();
  if (!participantsSnap.empty) {
    const batch = db.batch();
    const updates: Record<string, string> = {};
    if (nameChanged) updates.userName = after.displayName;
    if (avatarChanged) updates.userAvatar = after.avatarUrl;
    for (const doc of participantsSnap.docs) {
      batch.update(doc.ref, updates);
    }
    await batch.commit();
  }

  // Sync reviews (userName, userAvatar)
  const reviewsSnap = await db.collectionGroup("reviews")
    .where("userId", "==", userId).get();
  if (!reviewsSnap.empty) {
    const batch = db.batch();
    const updates: Record<string, string> = {};
    if (nameChanged) updates.userName = after.displayName;
    if (avatarChanged) updates.userAvatar = after.avatarUrl;
    for (const doc of reviewsSnap.docs) {
      batch.update(doc.ref, updates);
    }
    await batch.commit();
  }

  // Sync pet family (userName, userAvatar)
  const familySnap = await db.collectionGroup("family")
    .where("userId", "==", userId).get();
  if (!familySnap.empty) {
    const batch = db.batch();
    const updates: Record<string, string> = {};
    if (nameChanged) updates.userName = after.displayName;
    if (avatarChanged) updates.userAvatar = after.avatarUrl;
    for (const doc of familySnap.docs) {
      batch.update(doc.ref, updates);
    }
    await batch.commit();
  }
});
