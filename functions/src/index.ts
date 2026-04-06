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
  const locationSnap = await locationRef.get();
  const locationData = locationSnap.exists ? locationSnap.data() ?? {} : {};
  const reviewsSnap = await db.collection(`locations/${locationId}/reviews`).get();

  let totalRatings = 0;
  let sumRatings = 0;
  const allTags = new Set<string>();
  const basePhotos = Array.isArray(locationData.locationPhotos)
    ? (locationData.locationPhotos as string[])
    : Array.isArray(locationData.photos)
    ? (locationData.photos as string[])
    : [];
  const allPhotos = new Set<string>(basePhotos);

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
    locationPhotos: basePhotos,
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

function getDefaultAvatar(seed: string): string {
  return `https://api.dicebear.com/7.x/thumbs/svg?seed=${seed}`;
}

function normalizeTags(tags: unknown): string[] {
  if (!Array.isArray(tags)) return [];
  return Array.from(
    new Set(
      tags
        .filter((tag): tag is string => typeof tag === "string")
        .map((tag) => tag.trim().toLowerCase().replace(/^#/, ""))
        .filter(Boolean)
    )
  );
}

async function getAccessiblePet(
  petId: string,
  userId: string
): Promise<admin.firestore.DocumentData | null> {
  const petRef = db.doc(`pets/${petId}`);
  const familyRef = db.doc(`pets/${petId}/family/${userId}`);
  const [petSnap, familySnap] = await Promise.all([petRef.get(), familyRef.get()]);
  if (!petSnap.exists) return null;
  const petData = petSnap.data() ?? {};
  const canAccess =
    petData.ownerId === userId ||
    petData.primaryOwnerId === userId ||
    familySnap.exists;
  return canAccess ? petData : null;
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
    const followerMirrorRef = db.doc(`pets/${petId}/followers/${userId}`);
    const [userSnap, petSnap] = await Promise.all([userRef.get(), petRef.get()]);

    if (!petSnap.exists) {
      if (event.data) {
        await event.data.ref.delete().catch(() => undefined);
      }
      return;
    }

    const batch = db.batch();
    let hasWrites = false;
    const actor = await getNotificationActor(userId);

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
      batch.set(followerMirrorRef, {
        userId,
        userName: actor.fromUserName,
        userAvatar: actor.fromUserAvatar || getDefaultAvatar(userId),
        followedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      hasWrites = true;
    }

    if (hasWrites) {
      await batch.commit();
    }

    const petData = petSnap.data() ?? {};
    const petName =
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "this pet";
    const recipients = await getPetFamilyRecipientIds(petId, userId);
    if (recipients.length === 0) return;

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
    const followerMirrorRef = db.doc(`pets/${petId}/followers/${userId}`);
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

    batch.delete(followerMirrorRef);
    hasWrites = true;

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
    const postRef = db.doc(`posts/${postId}`);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;

    // Increment likeCount server-side (single source of truth)
    await postRef.update({ likeCount: admin.firestore.FieldValue.increment(1) });

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
// 4. Comment created: verify display fields + count + notifications
// ============================================================
export const onCommentCreated = onDocumentCreated(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const { postId, commentId } = event.params;

    // Verify/correct display fields from actual user profile
    const rawComment = event.data?.data();
    if (rawComment?.authorId) {
      const actor = await getNotificationActor(rawComment.authorId as string);
      const commentRef = db.doc(`posts/${postId}/comments/${commentId}`);
      await commentRef.update({
        authorName: actor.fromUserName,
        authorAvatar: actor.fromUserAvatar,
      });
    }

    // Increment commentCount server-side (single source of truth)
    const postRef = db.doc(`posts/${postId}`);
    await postRef.update({ commentCount: admin.firestore.FieldValue.increment(1) });

    const commentData = event.data?.data() as {
      authorId?: string;
      replyTo?: { commentId?: string };
    } | undefined;
    const commenterId = commentData?.authorId;
    if (!commenterId) return;

    const postSnap = await postRef.get();
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
      const recipients = (await getPetFamilyRecipientIds(postData.petId, commenterId))
        .filter((recipientId) => recipientId !== replyTargetUserId);
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
    // Verify/correct display fields from actual user profile
    const reviewData = event.data?.data();
    if (reviewData?.userId) {
      const actor = await getNotificationActor(reviewData.userId);
      const reviewRef = db.doc(`locations/${event.params.locationId}/reviews/${event.params.reviewId}`);
      await reviewRef.update({
        userName: actor.fromUserName,
        userAvatar: actor.fromUserAvatar,
      });
    }
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

    // Verify/correct display fields from actual user profile
    const checkinData = event.data?.data();
    if (checkinData?.userId) {
      const actor = await getNotificationActor(checkinData.userId);
      const checkinRef = db.doc(`locations/${locationId}/checkins/${event.params.checkinId}`);
      await checkinRef.update({
        userName: actor.fromUserName,
        userAvatar: actor.fromUserAvatar,
      });
    }

    // Recount all checkins (since doc ID is per-user, count = unique users)
    const checkinsSnap = await db.collection(`locations/${locationId}/checkins`).get();
    const count = checkinsSnap.size;
    const locationRef = db.doc(`locations/${locationId}`);
    await locationRef.update({
      totalCheckins: count,
      verifiedByCheckins: count >= 3,
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
    const meetupRef = db.doc(`meetups/${meetupId}`);
    const meetupSnap = await meetupRef.get();
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

  try {
    await admin.auth().deleteUser(userId);
  } catch (error) {
    const code =
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      typeof (error as { code?: unknown }).code === "string"
        ? ((error as { code: string }).code)
        : "";
    if (code !== "auth/user-not-found") {
      throw new HttpsError("internal", "Failed to delete auth account.");
    }
  }

  await db.doc(`users/${userId}`).delete();

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

// ============================================================
// 16. Callable: create post with server-derived author/pet snapshots
// ============================================================
export const createPostCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before posting.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot create posts.");
  }

  const data = request.data as {
    text?: string;
    tags?: unknown;
    media?: Array<{ url?: string; type?: "image" | "video"; thumbUrl?: string }>;
    petId?: string;
  };

  if (!data.petId || typeof data.petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

  const petData = await getAccessiblePet(data.petId, callerUid);
  if (!petData) {
    throw new HttpsError("permission-denied", "You do not have access to this pet.");
  }

  const media = Array.isArray(data.media)
    ? data.media
        .filter(
          (item): item is { url: string; type: "image" | "video"; thumbUrl?: string } =>
            !!item &&
            typeof item.url === "string" &&
            (item.type === "image" || item.type === "video")
        )
        .slice(0, 9)
    : [];
  const firstMedia = media[0];

  const result = await db.collection("posts").add({
    authorId: callerUid,
    authorName: caller.fromUserName,
    authorAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    text: typeof data.text === "string" ? data.text : "",
    media,
    mediaUrl: firstMedia?.url,
    mediaType: firstMedia?.type,
    petId: data.petId,
    petName:
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "Pet",
    petAvatarUrl:
      typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
        ? petData.avatarUrl
        : getDefaultAvatar(data.petId),
    tags: normalizeTags(data.tags),
    likeCount: 0,
    commentCount: 0,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: result.id };
});

// ============================================================
// 17. Callable: update post with server-derived pet snapshots
// ============================================================
export const updatePostCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  const data = request.data as {
    postId?: string;
    text?: string;
    tags?: unknown;
    petId?: string | null;
  };

  if (!data.postId || typeof data.postId !== "string") {
    throw new HttpsError("invalid-argument", "Missing postId.");
  }

  const postRef = db.doc(`posts/${data.postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) {
    throw new HttpsError("not-found", "Post not found.");
  }

  const postData = postSnap.data() ?? {};
  if (postData.authorId !== callerUid && caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Cannot edit this post.");
  }

  const updates: Record<string, unknown> = {
    text: typeof data.text === "string" ? data.text : "",
    tags: normalizeTags(data.tags),
  };

  if (data.petId === null || data.petId === "") {
    updates.petId = admin.firestore.FieldValue.delete();
    updates.petName = admin.firestore.FieldValue.delete();
    updates.petAvatarUrl = admin.firestore.FieldValue.delete();
  } else if (typeof data.petId === "string") {
    const petData = await getAccessiblePet(data.petId, callerUid);
    if (!petData) {
      throw new HttpsError("permission-denied", "You do not have access to this pet.");
    }
    updates.petId = data.petId;
    updates.petName =
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "Pet";
    updates.petAvatarUrl =
      typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
        ? petData.avatarUrl
        : getDefaultAvatar(data.petId);
  }

  await postRef.update(updates);
  return { success: true };
});

// ============================================================
// 18. Callable: create comment with server-derived actor snapshot
// ============================================================
export const createCommentCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before commenting.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot comment.");
  }

  const data = request.data as {
    postId?: string;
    text?: string;
    replyToCommentId?: string;
  };

  if (!data.postId || typeof data.postId !== "string") {
    throw new HttpsError("invalid-argument", "Missing postId.");
  }

  const postRef = db.doc(`posts/${data.postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) {
    throw new HttpsError("not-found", "Post not found.");
  }

  let replyTo:
    | {
        commentId: string;
        authorName: string;
      }
    | undefined;

  if (data.replyToCommentId) {
    const replyRef = db.doc(`posts/${data.postId}/comments/${data.replyToCommentId}`);
    const replySnap = await replyRef.get();
    if (!replySnap.exists) {
      throw new HttpsError("not-found", "Reply target not found.");
    }
    const replyData = replySnap.data() ?? {};
    replyTo = {
      commentId: data.replyToCommentId,
      authorName:
        typeof replyData.authorName === "string" && replyData.authorName.trim().length > 0
          ? replyData.authorName
          : "PetNote User",
    };
  }

  const commentRef = db.collection(`posts/${data.postId}/comments`).doc();
  await commentRef.set({
    authorId: callerUid,
    authorName: caller.fromUserName,
    authorAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    text: typeof data.text === "string" ? data.text : "",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(replyTo ? { replyTo } : {}),
  });

  return { id: commentRef.id };
});

// ============================================================
// 19. Callable: follow / unfollow pet using one authoritative doc
// ============================================================
export const followPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot follow pets.");
  }

  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

  const petRef = db.doc(`pets/${petId}`);
  const followingRef = db.doc(`users/${callerUid}/followingPets/${petId}`);

  await db.runTransaction(async (t) => {
    const [petSnap, followingSnap] = await Promise.all([t.get(petRef), t.get(followingRef)]);
    if (!petSnap.exists) {
      throw new HttpsError("not-found", "Pet not found.");
    }
    if (followingSnap.exists) return;

    const petData = petSnap.data() ?? {};
    t.set(followingRef, {
      petId,
      petName:
        typeof petData.name === "string" && petData.name.trim().length > 0
          ? petData.name
          : "Pet",
      petAvatar:
        typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
          ? petData.avatarUrl
          : getDefaultAvatar(petId),
      followedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { success: true };
});

export const unfollowPetCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const { petId } = request.data as { petId?: string };
  if (!petId || typeof petId !== "string") {
    throw new HttpsError("invalid-argument", "Missing petId.");
  }

  const followingRef = db.doc(`users/${callerUid}/followingPets/${petId}`);
  const followingSnap = await followingRef.get();
  if (followingSnap.exists) {
    await followingRef.delete();
  }
  return { success: true };
});

// ============================================================
// 20. Callable: submit review with exact deterministic ID
// ============================================================
export const submitReviewCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");
  if (callerAuth.token.email_verified !== true) {
    throw new HttpsError("permission-denied", "Verify your email before reviewing.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot review locations.");
  }

  const data = request.data as {
    locationId?: string;
    meetupId?: string;
    rating?: number;
    comment?: string;
    photos?: string[];
    tags?: string[];
    petFriendly?: { space?: number; safety?: number; cleanliness?: number };
  };

  if (!data.locationId || typeof data.locationId !== "string") {
    throw new HttpsError("invalid-argument", "Missing locationId.");
  }
  if (typeof data.rating !== "number" || data.rating < 1 || data.rating > 5) {
    throw new HttpsError("invalid-argument", "Rating must be between 1 and 5.");
  }

  const locationRef = db.doc(`locations/${data.locationId}`);
  const locationSnap = await locationRef.get();
  if (!locationSnap.exists) {
    throw new HttpsError("not-found", "Location not found.");
  }

  if (data.meetupId) {
    const meetupRef = db.doc(`meetups/${data.meetupId}`);
    const participantRef = db.doc(`meetups/${data.meetupId}/participants/${callerUid}`);
    const [meetupSnap, participantSnap] = await Promise.all([meetupRef.get(), participantRef.get()]);
    if (!meetupSnap.exists) {
      throw new HttpsError("not-found", "Meetup not found.");
    }
    const meetupData = meetupSnap.data() ?? {};
    if (meetupData.organizerId !== callerUid && !participantSnap.exists) {
      throw new HttpsError("permission-denied", "Only meetup participants can attach meetup reviews.");
    }
  }

  const reviewId = data.meetupId ? `${callerUid}_${data.meetupId}` : callerUid;
  const reviewRef = db.doc(`locations/${data.locationId}/reviews/${reviewId}`);
  const existingSnap = await reviewRef.get();
  if (existingSnap.exists) {
    throw new HttpsError("already-exists", "You have already reviewed this location.");
  }

  await reviewRef.set({
    userId: callerUid,
    userName: caller.fromUserName,
    userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    meetupId: data.meetupId,
    rating: data.rating,
    comment: typeof data.comment === "string" ? data.comment.trim() : "",
    photos: Array.isArray(data.photos) ? data.photos.filter((p): p is string => typeof p === "string") : [],
    tags: Array.isArray(data.tags) ? data.tags.filter((t): t is string => typeof t === "string") : [],
    petFriendly: {
      space: typeof data.petFriendly?.space === "number" ? data.petFriendly.space : data.rating,
      safety: typeof data.petFriendly?.safety === "number" ? data.petFriendly.safety : data.rating,
      cleanliness:
        typeof data.petFriendly?.cleanliness === "number"
          ? data.petFriendly.cleanliness
          : data.rating,
    },
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: reviewId };
});

// ============================================================
// 21. Callable: check in with daily deterministic ID
// ============================================================
export const checkInCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot check in.");
  }

  const data = request.data as {
    locationId?: string;
    photoUrl?: string;
    caption?: string;
    petId?: string;
  };

  if (!data.locationId || typeof data.locationId !== "string") {
    throw new HttpsError("invalid-argument", "Missing locationId.");
  }
  if (!data.photoUrl || typeof data.photoUrl !== "string") {
    throw new HttpsError("invalid-argument", "Missing photoUrl.");
  }

  const locationRef = db.doc(`locations/${data.locationId}`);
  const locationSnap = await locationRef.get();
  if (!locationSnap.exists) {
    throw new HttpsError("not-found", "Location not found.");
  }

  let petName: string | undefined;
  if (data.petId) {
    const petData = await getAccessiblePet(data.petId, callerUid);
    if (!petData) {
      throw new HttpsError("permission-denied", "You do not have access to this pet.");
    }
    petName =
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : undefined;
  }

  const dayKey = new Date().toISOString().slice(0, 10);
  const checkinId = `${callerUid}_${dayKey}`;
  const checkinRef = db.doc(`locations/${data.locationId}/checkins/${checkinId}`);
  const existingSnap = await checkinRef.get();
  if (existingSnap.exists) {
    throw new HttpsError("already-exists", "You already checked in here today.");
  }

  await checkinRef.set({
    userId: callerUid,
    userName: caller.fromUserName,
    userAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    photoUrl: data.photoUrl,
    caption: typeof data.caption === "string" ? data.caption.trim() : "",
    petId: data.petId,
    petName,
    locationId: data.locationId,
    dayKey,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: checkinId };
});

// ============================================================
// 22. Callable: submit report with server-derived reporter identity
// ============================================================
export const reportContentCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot submit reports.");
  }

  const data = request.data as {
    targetType?: "post" | "comment" | "user";
    targetId?: string;
    reason?: string;
    description?: string;
  };
  if (!data.targetType || !["post", "comment", "user"].includes(data.targetType)) {
    throw new HttpsError("invalid-argument", "Invalid targetType.");
  }
  if (!data.targetId || typeof data.targetId !== "string") {
    throw new HttpsError("invalid-argument", "Missing targetId.");
  }
  if (!data.reason || typeof data.reason !== "string" || data.reason.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Missing report reason.");
  }

  const result = await db.collection("reports").add({
    reporterId: callerUid,
    reporterName: caller.fromUserName,
    reporterAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    targetType: data.targetType,
    targetId: data.targetId,
    reason: data.reason.trim(),
    description: typeof data.description === "string" ? data.description.trim() : "",
    status: "pending",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: result.id };
});

// ============================================================
// 23. Callable: submit feedback with server-derived identity
// ============================================================
export const submitFeedbackCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const data = request.data as {
    type?: "bug" | "feature" | "complaint" | "other";
    subject?: string;
    message?: string;
  };
  if (!data.type || !["bug", "feature", "complaint", "other"].includes(data.type)) {
    throw new HttpsError("invalid-argument", "Invalid feedback type.");
  }
  if (!data.subject || typeof data.subject !== "string" || data.subject.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Missing subject.");
  }
  if (!data.message || typeof data.message !== "string" || data.message.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Missing feedback message.");
  }

  const caller = await getNotificationActor(callerUid);
  const result = await db.collection("feedback").add({
    userId: callerUid,
    userName: caller.fromUserName,
    userEmail: typeof callerAuth.token.email === "string" ? callerAuth.token.email : "",
    type: data.type,
    subject: data.subject.trim(),
    message: data.message.trim(),
    status: "new",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: result.id };
});

// ============================================================
// joinMeetup callable: validates requirements + capacity server-side
// ============================================================
export const joinMeetupCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const callerSnap = await db.doc(`users/${callerUid}`).get();
  const callerData = callerSnap.exists ? callerSnap.data() ?? {} : {};
  if (callerData.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot join meetups.");
  }

  const { meetupId, petId } = request.data as {
    meetupId: string; petId?: string;
  };

  const meetupRef = db.doc(`meetups/${meetupId}`);
  const participantRef = db.doc(`meetups/${meetupId}/participants/${callerUid}`);

  return await db.runTransaction(async (t) => {
    const meetupSnap = await t.get(meetupRef);
    if (!meetupSnap.exists) throw new HttpsError("not-found", "Meetup not found.");
    const meetup = meetupSnap.data() as Record<string, unknown>;

    const participantSnap = await t.get(participantRef);
    if (participantSnap.exists) return { success: true };

    if (meetup.status === "cancelled" || meetup.status === "completed") {
      return { success: false, error: "Meetup is no longer accepting participants." };
    }

    const requirements = meetup.requirements as Record<string, unknown> ?? {};
    const isOrganizer = meetup.organizerId === callerUid;
    const maxPets = typeof requirements.maxPets === "number" ? requirements.maxPets : 0;
    const currentCount = typeof meetup.participantCount === "number" ? meetup.participantCount : 0;
    if (maxPets > 0 && currentCount >= maxPets) {
      return { success: false, error: "Meetup is full." };
    }

    let participantPetId = "";
    let participantPetName = "Organizer";
    let participantPetAvatar = getDefaultAvatar(callerUid);
    let participantPetSpecies: string | undefined;

    if (petId) {
      const petRef = db.doc(`pets/${petId}`);
      const familyRef = db.doc(`pets/${petId}/family/${callerUid}`);
      const [petSnap, familySnap] = await Promise.all([t.get(petRef), t.get(familyRef)]);
      if (!petSnap.exists) {
        throw new HttpsError("not-found", "Pet not found.");
      }
      const petData = petSnap.data() ?? {};
      const canAccess =
        petData.ownerId === callerUid ||
        petData.primaryOwnerId === callerUid ||
        familySnap.exists;
      if (!canAccess) {
        throw new HttpsError("permission-denied", "You do not have access to this pet.");
      }
      participantPetId = petId;
      participantPetName =
        typeof petData.name === "string" && petData.name.trim().length > 0
          ? petData.name
          : "Pet";
      participantPetAvatar =
        typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
          ? petData.avatarUrl
          : getDefaultAvatar(petId);
      participantPetSpecies =
        typeof petData.species === "string" ? petData.species : undefined;
    } else if (!isOrganizer) {
      return { success: false, error: "Select a pet to join this meetup." };
    }

    if (!isOrganizer) {
      const reasons: string[] = [];

      if (requirements.mustHavePosts) {
        const postsSnap = await db.collection("posts").where("authorId", "==", callerUid).limit(1).get();
        if (postsSnap.empty) reasons.push("Must have posted at least once.");
      }

      if (requirements.mustHavePetProfile && !participantPetSpecies) {
        reasons.push("Must have a pet profile.");
      }

      const minFollowers = typeof requirements.minFollowers === "number" ? requirements.minFollowers : 0;
      if (minFollowers > 0) {
        const followingSnap = await db.collection(`users/${callerUid}/followingPets`).get();
        if (followingSnap.size < minFollowers) {
          reasons.push(`Requires at least ${minFollowers} followed pets.`);
        }
      }

      const petType = requirements.petType as string ?? "any";
      if ((petType === "dog" || petType === "any_dog") && participantPetSpecies && participantPetSpecies !== "dog") {
        reasons.push("Dogs only.");
      }
      if ((petType === "cat" || petType === "any_cat") && participantPetSpecies && participantPetSpecies !== "cat") {
        reasons.push("Cats only.");
      }
      if (petType === "other" && participantPetSpecies && (participantPetSpecies === "dog" || participantPetSpecies === "cat")) {
        reasons.push("Other pets only.");
      }

      if (reasons.length > 0) {
        return { success: false, error: reasons.join(" ") };
      }
    }

    const actor = await getNotificationActor(callerUid);

    t.set(participantRef, {
      meetupId,
      userId: callerUid,
      userName: actor.fromUserName,
      userAvatar: actor.fromUserAvatar || getDefaultAvatar(callerUid),
      petId: participantPetId,
      petName: participantPetName,
      petAvatar: participantPetAvatar,
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      status: "confirmed",
    });
    t.update(meetupRef, {
      participantCount: admin.firestore.FieldValue.increment(1),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  });
});

// ============================================================
// checkMeetupStatus callable: any user can trigger status update
// ============================================================
export const checkMeetupStatusCallable = onCall(async (request) => {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const { meetupId } = request.data as { meetupId: string };
  if (!meetupId) throw new HttpsError("invalid-argument", "Missing meetupId.");

  const meetupRef = db.doc(`meetups/${meetupId}`);
  const meetupSnap = await meetupRef.get();
  if (!meetupSnap.exists) return { updated: false };

  const meetup = meetupSnap.data() as Record<string, unknown>;
  if (meetup.status === "cancelled" || meetup.status === "completed") {
    return { updated: false };
  }

  const dateVal = meetup.date as admin.firestore.Timestamp;
  if (!dateVal?.toDate) return { updated: false };
  const duration = typeof meetup.duration === "number" ? meetup.duration : 0;
  const endTime = new Date(dateVal.toDate().getTime() + duration * 60 * 1000);

  if (new Date() >= endTime) {
    await meetupRef.update({
      status: "completed",
      isRatingOpen: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { updated: true };
  }
  return { updated: false };
});

// Cancel notifications already handled by existing onMeetupUpdated (line ~620)
