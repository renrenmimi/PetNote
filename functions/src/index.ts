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

type ServerNotificationType =
  | "like"
  | "comment"
  | "pet_follow"
  | "reply"
  | "meetup_join"
  | "meetup_cancelled"
  | "warning";

type ServerNotificationPayload = {
  userId: string;
  type: ServerNotificationType;
  fromUserId: string;
  fromUserName: string;
  fromUserAvatar: string;
  message: string;
  postId?: string;
  commentId?: string;
  postImage?: string;
  warningReason?: string;
  warningDetails?: string;
  read?: boolean;
};

async function getNotificationActor(userId: string): Promise<{
  fromUserId: string;
  fromUserName: string;
  fromUserAvatar: string;
  role?: string;
  banned?: boolean;
}> {
  const userSnap = await db.doc(`users/${userId}`).get();
  const data = userSnap.exists ? userSnap.data() ?? {} : {};
  const displayName =
    typeof data.displayName === "string" && data.displayName.trim().length > 0
      ? data.displayName
      : "PetNote User";
  const avatarUrl =
    typeof data.avatarUrl === "string" && data.avatarUrl.trim().length > 0
      ? data.avatarUrl
      : `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`;

  return {
    fromUserId: userId,
    fromUserName: displayName,
    fromUserAvatar: avatarUrl,
    role: typeof data.role === "string" ? data.role : undefined,
    banned: data.banned === true,
  };
}

async function shouldSendNotification(
  recipientId: string,
  type: ServerNotificationType
): Promise<boolean> {
  if (type === "warning" || type === "meetup_join" || type === "meetup_cancelled") {
    return true;
  }

  const settingsSnap = await db.doc(`users/${recipientId}/settings/preferences`).get();
  const settings = settingsSnap.exists ? settingsSnap.data() : {};
  const likeNotifications = settings?.likeNotifications ?? true;
  const commentNotifications = settings?.commentNotifications ?? true;
  const followNotifications = settings?.followNotifications ?? true;

  if (type === "like") return likeNotifications;
  if (type === "comment" || type === "reply") return commentNotifications;
  if (type === "pet_follow") return followNotifications;
  return true;
}

async function createNotificationIfAllowed(
  payload: ServerNotificationPayload
): Promise<string> {
  if (!(await shouldSendNotification(payload.userId, payload.type))) {
    return "";
  }

  const docData: Record<string, unknown> = {
    ...payload,
    read: payload.read ?? false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  Object.keys(docData).forEach((key) => {
    if (docData[key] === undefined) {
      delete docData[key];
    }
  });

  const result = await db.collection("notifications").add(docData);
  return result.id;
}

async function getPetFamilyRecipientIds(
  petId: string,
  excludeUserId?: string
): Promise<string[]> {
  const familySnap = await db.collection(`pets/${petId}/family`).get();
  return Array.from(
    new Set(
      familySnap.docs
        .map((docSnap) => docSnap.data().userId as string | undefined)
        .filter((userId): userId is string => !!userId && userId !== excludeUserId)
    )
  );
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
// 2. followingPets created/deleted: maintain user/pet counters
// ============================================================
export const onFollowingPetCreated = onDocumentCreated(
  "users/{userId}/followingPets/{petId}",
  async (event) => {
    const { userId, petId } = event.params;
    const userRef = db.doc(`users/${userId}`);
    const petRef = db.doc(`pets/${petId}`);
    const [userSnap, petSnap] = await Promise.all([userRef.get(), petRef.get()]);

    const batch = db.batch();
    let hasWrites = false;

    if (userSnap.exists) {
      batch.update(userRef, {
        followingPetsCount: admin.firestore.FieldValue.increment(1),
      });
      hasWrites = true;
    }

    if (petSnap.exists) {
      batch.update(petRef, {
        followerCount: admin.firestore.FieldValue.increment(1),
      });
      hasWrites = true;
    }

    if (hasWrites) {
      await batch.commit();
    }

    if (!petSnap.exists) return;
    const petData = petSnap.data() ?? {};
    const petName =
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "this pet";
    const recipients = await getPetFamilyRecipientIds(petId, userId);
    if (recipients.length === 0) return;

    const actor = await getNotificationActor(userId);
    await Promise.all(
      recipients.map((recipientId) =>
        createNotificationIfAllowed({
          userId: recipientId,
          type: "pet_follow",
          fromUserId: actor.fromUserId,
          fromUserName: actor.fromUserName,
          fromUserAvatar: actor.fromUserAvatar,
          message: `started following ${petName}`,
        })
      )
    );
  }
);

export const onFollowingPetDeleted = onDocumentDeleted(
  "users/{userId}/followingPets/{petId}",
  async (event) => {
    const { userId, petId } = event.params;
    const userRef = db.doc(`users/${userId}`);
    const petRef = db.doc(`pets/${petId}`);
    const [userSnap, petSnap] = await Promise.all([userRef.get(), petRef.get()]);

    const batch = db.batch();
    let hasWrites = false;

    if (userSnap.exists) {
      batch.update(userRef, {
        followingPetsCount: admin.firestore.FieldValue.increment(-1),
      });
      hasWrites = true;
    }

    if (petSnap.exists) {
      batch.update(petRef, {
        followerCount: admin.firestore.FieldValue.increment(-1),
      });
      hasWrites = true;
    }

    if (hasWrites) {
      await batch.commit();
    }
  }
);

// ============================================================
// 3. Like created: send notifications server-side
// ============================================================
export const onLikeCreated = onDocumentCreated(
  "posts/{postId}/likes/{likeId}",
  async (event) => {
    const { postId, likeId } = event.params;
    const postSnap = await db.doc(`posts/${postId}`).get();
    if (!postSnap.exists) return;

    const postData = postSnap.data() as {
      authorId?: string;
      petId?: string;
      petName?: string;
      mediaUrl?: string;
    };
    const actor = await getNotificationActor(likeId);

    if (postData.petId) {
      const recipients = await getPetFamilyRecipientIds(postData.petId, likeId);
      if (recipients.length === 0) return;
      const petName = postData.petName || "this pet";
      await Promise.all(
        recipients.map((recipientId) =>
          createNotificationIfAllowed({
            userId: recipientId,
            type: "like",
            fromUserId: actor.fromUserId,
            fromUserName: actor.fromUserName,
            fromUserAvatar: actor.fromUserAvatar,
            postId,
            postImage: postData.mediaUrl,
            message: `${actor.fromUserName} liked ${petName}'s post`,
          })
        )
      );
      return;
    }

    if (postData.authorId && postData.authorId !== likeId) {
      await createNotificationIfAllowed({
        userId: postData.authorId,
        type: "like",
        fromUserId: actor.fromUserId,
        fromUserName: actor.fromUserName,
        fromUserAvatar: actor.fromUserAvatar,
        postId,
        postImage: postData.mediaUrl,
        message: "liked your post",
      });
    }
  }
);

// ============================================================
// 4. Comment created: send notifications server-side
// ============================================================
export const onCommentCreated = onDocumentCreated(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const { postId, commentId } = event.params;
    const commentData = event.data?.data() as {
      authorId?: string;
      replyTo?: { commentId?: string };
    } | undefined;
    const commenterId = commentData?.authorId;
    if (!commenterId) return;

    const postSnap = await db.doc(`posts/${postId}`).get();
    if (!postSnap.exists) return;
    const postData = postSnap.data() as {
      authorId?: string;
      petId?: string;
      petName?: string;
      mediaUrl?: string;
    };
    const actor = await getNotificationActor(commenterId);

    let replyTargetUserId: string | null = null;
    const replyCommentId = commentData?.replyTo?.commentId;
    if (replyCommentId) {
      const replyTargetSnap = await db.doc(`posts/${postId}/comments/${replyCommentId}`).get();
      if (replyTargetSnap.exists) {
        const replyTargetData = replyTargetSnap.data() as { authorId?: string };
        replyTargetUserId = replyTargetData.authorId ?? null;
      }
    }

    if (postData.petId) {
      const recipients = await getPetFamilyRecipientIds(postData.petId, commenterId);
      const petName = postData.petName || "this pet";
      await Promise.all(
        recipients.map((recipientId) =>
          createNotificationIfAllowed({
            userId: recipientId,
            type: "comment",
            fromUserId: actor.fromUserId,
            fromUserName: actor.fromUserName,
            fromUserAvatar: actor.fromUserAvatar,
            postId,
            commentId,
            postImage: postData.mediaUrl,
            message: `${actor.fromUserName} commented on ${petName}'s post`,
          })
        )
      );
    } else if (
      postData.authorId &&
      postData.authorId !== commenterId &&
      replyTargetUserId !== postData.authorId
    ) {
      await createNotificationIfAllowed({
        userId: postData.authorId,
        type: "comment",
        fromUserId: actor.fromUserId,
        fromUserName: actor.fromUserName,
        fromUserAvatar: actor.fromUserAvatar,
        postId,
        commentId,
        postImage: postData.mediaUrl,
        message: "commented on your post",
      });
    }

    if (replyTargetUserId && replyTargetUserId !== commenterId) {
      await createNotificationIfAllowed({
        userId: replyTargetUserId,
        type: "reply",
        fromUserId: actor.fromUserId,
        fromUserName: actor.fromUserName,
        fromUserAvatar: actor.fromUserAvatar,
        postId,
        commentId,
        postImage: postData.mediaUrl,
        message: "replied to your comment",
      });
    }
  }
);

// ============================================================
// 5. Post deleted: clean up bookmarks, reports, notifications
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
// 4. Review created/deleted: recompute location aggregation
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
// 5b. Checkin deleted: recompute totalCheckins + verified
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
// 7. Like deleted: decrement post likeCount
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
// 8. Comment deleted: decrement post commentCount
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
// 10. Meetup participant created: notify organizer
// ============================================================
export const onMeetupParticipantCreated = onDocumentCreated(
  "meetups/{meetupId}/participants/{participantId}",
  async (event) => {
    const { meetupId, participantId } = event.params;
    const meetupSnap = await db.doc(`meetups/${meetupId}`).get();
    if (!meetupSnap.exists) return;

    const meetupData = meetupSnap.data() as {
      organizerId?: string;
      title?: string;
    };
    if (!meetupData.organizerId || meetupData.organizerId === participantId) {
      return;
    }

    const actor = await getNotificationActor(participantId);
    await createNotificationIfAllowed({
      userId: meetupData.organizerId,
      type: "meetup_join",
      fromUserId: actor.fromUserId,
      fromUserName: actor.fromUserName,
      fromUserAvatar: actor.fromUserAvatar,
      message: `joined your meetup ${meetupData.title || ""}`.trim(),
    });
  }
);

// ============================================================
// 11. Meetup cancelled: notify participants
// ============================================================
export const onMeetupUpdated = onDocumentWritten(
  "meetups/{meetupId}",
  async (event) => {
    const before = event.data?.before?.data() as
      | { status?: string }
      | undefined;
    const after = event.data?.after?.data() as
      | { status?: string; organizerId?: string; title?: string }
      | undefined;

    if (!before || !after) return;
    if (before.status === "cancelled" || after.status !== "cancelled") return;
    if (!after.organizerId) return;

    const participantsSnap = await db.collection(`meetups/${event.params.meetupId}/participants`).get();
    const recipientIds = Array.from(
      new Set(
        participantsSnap.docs
          .map((docSnap) => (docSnap.data().userId as string | undefined) ?? docSnap.id)
          .filter((userId): userId is string => !!userId && userId !== after.organizerId)
      )
    );
    if (recipientIds.length === 0) return;

    const actor = await getNotificationActor(after.organizerId);
    await Promise.all(
      recipientIds.map((recipientId) =>
        createNotificationIfAllowed({
          userId: recipientId,
          type: "meetup_cancelled",
          fromUserId: actor.fromUserId,
          fromUserName: actor.fromUserName,
          fromUserAvatar: actor.fromUserAvatar,
          message: `cancelled the meetup ${after.title || ""}`.trim(),
        })
      )
    );
  }
);

// ============================================================
// 12. Participant deleted: decrement meetup participantCount
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
// 13. User updated: sync displayName/avatarUrl to denormalized copies
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
// 14. Callable: delete user document + Firebase Auth account
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
// 15. Callable: create admin warning notifications only
// ============================================================
export const sendNotification = onCall(async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const callerUid = request.auth.uid;
  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot send notifications.");
  }

  if (caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Only admins can send warning notifications.");
  }

  const data = request.data as {
    userId: string;
    type: string;
    message: string;
    warningReason?: string;
    warningDetails?: string;
    read?: boolean;
  };

  if (!data.userId) {
    throw new HttpsError("invalid-argument", "Missing notification recipient.");
  }

  if (data.type !== "warning") {
    throw new HttpsError("invalid-argument", "Only warning notifications are supported.");
  }

  const payload: ServerNotificationPayload = {
    userId: data.userId,
    type: "warning",
    fromUserId: callerUid,
    fromUserName: "PetNote Team",
    fromUserAvatar: "",
    message: data.message,
    warningReason: data.warningReason,
    warningDetails: data.warningDetails,
    read: data.read,
  };

  const id = await createNotificationIfAllowed(payload);
  return { id };
});
