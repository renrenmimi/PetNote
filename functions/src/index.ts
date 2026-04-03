import * as admin from "firebase-admin";
import { setGlobalOptions } from "firebase-functions/v2";
import { onDocumentDeleted, onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";

setGlobalOptions({ maxInstances: 5 });

admin.initializeApp();
const db = admin.firestore();

// Helper: batch delete/update in chunks of 450 (under Firestore 500 limit)
async function batchChunked(
  docs: admin.firestore.QueryDocumentSnapshot[],
  operation: (batch: admin.firestore.WriteBatch, doc: admin.firestore.QueryDocumentSnapshot) => void
): Promise<void> {
  const chunkSize = 450;
  for (let i = 0; i < docs.length; i += chunkSize) {
    const batch = db.batch();
    docs.slice(i, i + chunkSize).forEach((d) => operation(batch, d));
    await batch.commit();
  }
}

// ============================================================
// 1. Pet deleted: clean up cross-user followingPets + unlink posts
// ============================================================
export const onPetDeleted = onDocumentDeleted("pets/{petId}", async (event) => {
  const petId = event.params.petId;

  const followingSnap = await db.collectionGroup("followingPets")
    .where("petId", "==", petId).get();
  if (!followingSnap.empty) {
    await batchChunked(followingSnap.docs, (batch, doc) => {
      batch.delete(doc.ref);
      const userRef = doc.ref.parent.parent;
      if (userRef) {
        batch.update(userRef, {
          followingPetsCount: admin.firestore.FieldValue.increment(-1),
        });
      }
    });
  }

  const postsSnap = await db.collection("posts")
    .where("petId", "==", petId).get();
  if (!postsSnap.empty) {
    await batchChunked(postsSnap.docs, (batch, doc) => {
      batch.update(doc.ref, { petId: "", petName: "", petAvatarUrl: "" });
    });
  }
});

// ============================================================
// 2. Post deleted: clean up bookmarks, reports, AND notifications
// ============================================================
export const onPostDeleted = onDocumentDeleted("posts/{postId}", async (event) => {
  const postId = event.params.postId;

  // Clean bookmarks referencing this post
  const bookmarksSnap = await db.collectionGroup("bookmarks").get();
  const matchingBookmarks = bookmarksSnap.docs.filter((d) => d.id === postId);
  if (matchingBookmarks.length > 0) {
    await batchChunked(matchingBookmarks as admin.firestore.QueryDocumentSnapshot[], (batch, doc) => {
      batch.delete(doc.ref);
    });
  }

  // Clean reports targeting this post
  const reportsSnap = await db.collection("reports")
    .where("targetId", "==", postId)
    .where("targetType", "==", "post").get();
  if (!reportsSnap.empty) {
    await batchChunked(reportsSnap.docs, (batch, doc) => {
      batch.delete(doc.ref);
    });
  }

  // Clean ALL notifications referencing this post
  const notifSnap = await db.collection("notifications")
    .where("postId", "==", postId).get();
  if (!notifSnap.empty) {
    await batchChunked(notifSnap.docs, (batch, doc) => {
      batch.delete(doc.ref);
    });
  }
});

// ============================================================
// 3. Review created: update location aggregation
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

      const update: Record<string, unknown> = {
        averageRating: Number(averageRating.toFixed(2)),
        totalRatings,
      };
      if (reviewData.tags?.length > 0) {
        update.tags = admin.firestore.FieldValue.arrayUnion(...reviewData.tags);
      }
      if (reviewData.photos?.length > 0) {
        update.photos = admin.firestore.FieldValue.arrayUnion(...reviewData.photos);
        update.totalPhotos = admin.firestore.FieldValue.increment(reviewData.photos.length);
      }
      t.update(locationRef, update);
    });
  }
);

// ============================================================
// 4. Review deleted: update location aggregation
// ============================================================
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
// 5. Checkin created: update location totalCheckins + verified
// ============================================================
export const onCheckinCreated = onDocumentCreated(
  "locations/{locationId}/checkins/{checkinId}",
  async (event) => {
    const locationId = event.params.locationId;
    const locationRef = db.doc(`locations/${locationId}`);
    await db.runTransaction(async (t) => {
      const locSnap = await t.get(locationRef);
      const current = locSnap.data() || { totalCheckins: 0 };
      const nextTotal = (current.totalCheckins || 0) + 1;
      t.update(locationRef, {
        totalCheckins: nextTotal,
        verifiedByCheckins: nextTotal >= 3,
      });
    });
  }
);

// ============================================================
// 6. Post written: maintain hashtag postCount server-side
// ============================================================
export const onPostWritten = onDocumentWritten("posts/{postId}", async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();

  const oldTags: string[] = before?.tags || [];
  const newTags: string[] = after?.tags || [];

  const added = newTags.filter((t) => !oldTags.includes(t));
  const removed = oldTags.filter((t) => !newTags.includes(t));

  if (added.length === 0 && removed.length === 0) return;

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
  await batch.commit();
});

// ============================================================
// 7. User updated: sync displayName/avatarUrl to denormalized copies
// ============================================================
export const onUserUpdated = onDocumentWritten("users/{userId}", async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!before || !after) return;

  const nameChanged = before.displayName !== after.displayName;
  const avatarChanged = before.avatarUrl !== after.avatarUrl;
  if (!nameChanged && !avatarChanged) return;

  const userId = event.params.userId;

  const syncCollection = async (
    collectionQuery: admin.firestore.Query,
    fields: Record<string, string>
  ) => {
    const snap = await collectionQuery.get();
    if (snap.empty) return;
    await batchChunked(snap.docs, (batch, doc) => {
      batch.update(doc.ref, fields);
    });
  };

  // Posts
  const postFields: Record<string, string> = {};
  if (nameChanged) postFields.authorName = after.displayName;
  if (avatarChanged) postFields.authorAvatar = after.avatarUrl;
  await syncCollection(db.collection("posts").where("authorId", "==", userId), postFields);

  // Comments
  const commentFields: Record<string, string> = {};
  if (nameChanged) commentFields.authorName = after.displayName;
  if (avatarChanged) commentFields.authorAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("comments").where("authorId", "==", userId), commentFields);

  // Notifications
  const notifFields: Record<string, string> = {};
  if (nameChanged) notifFields.fromUserName = after.displayName;
  if (avatarChanged) notifFields.fromUserAvatar = after.avatarUrl;
  await syncCollection(db.collection("notifications").where("fromUserId", "==", userId), notifFields);

  // Participants
  const partFields: Record<string, string> = {};
  if (nameChanged) partFields.userName = after.displayName;
  if (avatarChanged) partFields.userAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("participants").where("userId", "==", userId), partFields);

  // Reviews
  const reviewFields: Record<string, string> = {};
  if (nameChanged) reviewFields.userName = after.displayName;
  if (avatarChanged) reviewFields.userAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("reviews").where("userId", "==", userId), reviewFields);

  // Family
  const familyFields: Record<string, string> = {};
  if (nameChanged) familyFields.userName = after.displayName;
  if (avatarChanged) familyFields.userAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("family").where("userId", "==", userId), familyFields);
});
