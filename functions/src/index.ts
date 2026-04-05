import * as admin from "firebase-admin";
import { setGlobalOptions } from "firebase-functions/v2";
import { onDocumentDeleted, onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

setGlobalOptions({ maxInstances: 5 });

admin.initializeApp();
const db = admin.firestore();

// Helper: batch operations in chunks of 450 (under Firestore 500 limit)
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

// Helper: recompute location aggregation from all remaining reviews
async function recomputeLocationAggregation(locationId: string): Promise<void> {
  const locationRef = db.doc(`locations/${locationId}`);
  const reviewsSnap = await db.collection(`locations/${locationId}/reviews`).get();

  let totalRatings = 0;
  let sumRatings = 0;
  const allTags = new Set<string>();
  const allPhotos = new Set<string>();

  reviewsSnap.docs.forEach((d) => {
    const data = d.data();
    totalRatings++;
    sumRatings += data.rating || 0;
    (data.tags || []).forEach((t: string) => allTags.add(t));
    (data.photos || []).forEach((p: string) => allPhotos.add(p));
  });

  const averageRating = totalRatings === 0 ? 0 : sumRatings / totalRatings;
  await locationRef.update({
    averageRating: Number(averageRating.toFixed(2)),
    totalRatings,
    tags: Array.from(allTags),
    photos: Array.from(allPhotos),
    totalPhotos: allPhotos.size,
  });
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
// 2. Post deleted: clean up bookmarks, reports, notifications
// ============================================================
export const onPostDeleted = onDocumentDeleted("posts/{postId}", async (event) => {
  const postId = event.params.postId;

  const bookmarksSnap = await db.collectionGroup("bookmarks").get();
  const matchingBookmarks = bookmarksSnap.docs.filter((d) => d.id === postId);
  if (matchingBookmarks.length > 0) {
    await batchChunked(matchingBookmarks as admin.firestore.QueryDocumentSnapshot[], (batch, doc) => {
      batch.delete(doc.ref);
    });
  }

  const reportsSnap = await db.collection("reports")
    .where("targetId", "==", postId)
    .where("targetType", "==", "post").get();
  if (!reportsSnap.empty) {
    await batchChunked(reportsSnap.docs, (batch, doc) => {
      batch.delete(doc.ref);
    });
  }

  const notifSnap = await db.collection("notifications")
    .where("postId", "==", postId).get();
  if (!notifSnap.empty) {
    await batchChunked(notifSnap.docs, (batch, doc) => {
      batch.delete(doc.ref);
    });
  }
});

// ============================================================
// 3. Review created/deleted: recompute location aggregation
//    Recount from all remaining reviews — no incremental math.
// ============================================================
export const onReviewCreated = onDocumentCreated(
  "locations/{locationId}/reviews/{reviewId}",
  async (event) => {
    await recomputeLocationAggregation(event.params.locationId);
  }
);

export const onReviewDeleted = onDocumentDeleted(
  "locations/{locationId}/reviews/{reviewId}",
  async (event) => {
    await recomputeLocationAggregation(event.params.locationId);
  }
);

// ============================================================
// 4. Checkin created: update location totalCheckins + verified
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
// 4b. Checkin deleted: recompute totalCheckins + verified
// ============================================================
export const onCheckinDeleted = onDocumentDeleted(
  "locations/{locationId}/checkins/{checkinId}",
  async (event) => {
    const locationId = event.params.locationId;
    const locationRef = db.doc(`locations/${locationId}`);
    const checkinsSnap = await db.collection(`locations/${locationId}/checkins`).get();
    const count = checkinsSnap.size;
    await locationRef.update({
      totalCheckins: count,
      verifiedByCheckins: count >= 3,
    });
  }
);

// ============================================================
// 5. Post written: maintain hashtag postCount server-side
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
// 6. Like deleted: decrement post likeCount
// ============================================================
export const onLikeDeleted = onDocumentDeleted(
  "posts/{postId}/likes/{likeId}",
  async (event) => {
    const postRef = db.doc(`posts/${event.params.postId}`);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;
    await postRef.update({
      likeCount: admin.firestore.FieldValue.increment(-1),
    });
  }
);

// ============================================================
// 7. Comment deleted: decrement post commentCount
// ============================================================
export const onCommentDeleted = onDocumentDeleted(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const postRef = db.doc(`posts/${event.params.postId}`);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;
    await postRef.update({
      commentCount: admin.firestore.FieldValue.increment(-1),
    });
  }
);

// ============================================================
// 8. Participant deleted: decrement meetup participantCount
// ============================================================
export const onParticipantDeleted = onDocumentDeleted(
  "meetups/{meetupId}/participants/{participantId}",
  async (event) => {
    const meetupRef = db.doc(`meetups/${event.params.meetupId}`);
    const meetupSnap = await meetupRef.get();
    if (!meetupSnap.exists) return;
    await meetupRef.update({
      participantCount: admin.firestore.FieldValue.increment(-1),
    });
  }
);

// ============================================================
// 9. User updated: sync displayName/avatarUrl to denormalized copies
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

  const postFields: Record<string, string> = {};
  if (nameChanged) postFields.authorName = after.displayName;
  if (avatarChanged) postFields.authorAvatar = after.avatarUrl;
  await syncCollection(db.collection("posts").where("authorId", "==", userId), postFields);

  const commentFields: Record<string, string> = {};
  if (nameChanged) commentFields.authorName = after.displayName;
  if (avatarChanged) commentFields.authorAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("comments").where("authorId", "==", userId), commentFields);

  const notifFields: Record<string, string> = {};
  if (nameChanged) notifFields.fromUserName = after.displayName;
  if (avatarChanged) notifFields.fromUserAvatar = after.avatarUrl;
  await syncCollection(db.collection("notifications").where("fromUserId", "==", userId), notifFields);

  const partFields: Record<string, string> = {};
  if (nameChanged) partFields.userName = after.displayName;
  if (avatarChanged) partFields.userAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("participants").where("userId", "==", userId), partFields);

  const reviewFields: Record<string, string> = {};
  if (nameChanged) reviewFields.userName = after.displayName;
  if (avatarChanged) reviewFields.userAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("reviews").where("userId", "==", userId), reviewFields);

  const familyFields: Record<string, string> = {};
  if (nameChanged) familyFields.userName = after.displayName;
  if (avatarChanged) familyFields.userAvatar = after.avatarUrl;
  await syncCollection(db.collectionGroup("family").where("userId", "==", userId), familyFields);
});

// ============================================================
// 10. Callable: delete user document + Firebase Auth account
//     Uses admin SDK to bypass admin-only delete rule.
//     Called from client deleteAccount() after Firestore cleanup.
// ============================================================
export const deleteUserAccount = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const { userId } = request.data as { userId: string };
  if (callerUid !== userId) {
    throw new HttpsError("permission-denied", "Can only delete your own account.");
  }

  // Delete user document with admin SDK
  try {
    await db.doc(`users/${userId}`).delete();
  } catch {
    // May already be deleted
  }

  // Delete Firebase Auth account with admin SDK (no recent-login required)
  try {
    await admin.auth().deleteUser(userId);
  } catch {
    // May already be deleted
  }

  return { success: true };
});

// ============================================================
// 11. Callable: create notification with server-side settings check
//     Reads recipient's settings with admin SDK (owner-only rule)
//     then creates notification if preferences allow it.
// ============================================================
export const sendNotification = onCall(async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const callerUid = request.auth.uid;
  const data = request.data as {
    userId: string;
    type: string;
    fromUserId: string;
    fromUserName: string;
    fromUserAvatar: string;
    postId?: string;
    commentId?: string;
    postImage?: string;
    message: string;
    warningReason?: string;
    warningDetails?: string;
    read?: boolean;
  };

  const allowedTypes = new Set([
    "like",
    "comment",
    "follow",
    "pet_follow",
    "reply",
    "meetup_join",
    "meetup_cancelled",
    "warning",
  ]);
  if (!allowedTypes.has(data.type)) {
    throw new HttpsError("invalid-argument", "Unsupported notification type.");
  }

  if (data.fromUserId !== callerUid) {
    throw new HttpsError("permission-denied", "fromUserId must match caller.");
  }

  if (!data.userId) {
    throw new HttpsError("invalid-argument", "Missing notification recipient.");
  }

  const callerSnap = await db.doc(`users/${callerUid}`).get();
  const isCallerAdmin = callerSnap.exists && callerSnap.data()?.role === "admin";
  if (data.type === "warning" && !isCallerAdmin) {
    throw new HttpsError("permission-denied", "Only admins can send warning notifications.");
  }

  // Read recipient's settings with admin SDK
  const settingsSnap = await db.doc(`users/${data.userId}/settings/preferences`).get();
  const settings = settingsSnap.exists ? settingsSnap.data() : {};
  const likeNotif = settings?.likeNotifications ?? true;
  const commentNotif = settings?.commentNotifications ?? true;
  const followNotif = settings?.followNotifications ?? true;

  const mappedType = data.type === "reply" ? "comment" : data.type;
  const shouldNotify =
    data.type === "warning" ||
    data.type === "meetup_join" ||
    data.type === "meetup_cancelled" ||
    (mappedType === "like" && likeNotif) ||
    (mappedType === "comment" && commentNotif) ||
    ((mappedType === "follow" || mappedType === "pet_follow") && followNotif);

  if (!shouldNotify) {
    return { id: "" };
  }

  const payload: Record<string, unknown> = { ...data };
  delete payload.read;
  payload.read = data.read ?? false;
  payload.createdAt = admin.firestore.FieldValue.serverTimestamp();

  // Remove undefined values
  Object.keys(payload).forEach((key) => {
    if (payload[key] === undefined) delete payload[key];
  });

  const result = await db.collection("notifications").add(payload);
  return { id: result.id };
});
