import { onDocumentCreated, onDocumentDeleted, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { admin, db } from "./platform";
import {
  assertRateLimit,
  batchChunked,
  FIRESTORE_BATCH_LIMIT,
  getDefaultAvatar,
  isTrustedHttpsUrl,
  optionalTrimmedString,
  processQueryInBatches,
  RATE_LIMITS,
  requestData,
  requiredDocId,
  requiredTrimmedString,
  runEventOnce,
  TRUSTED_AVATAR_URL_HOSTS,
  VALIDATION_LIMITS,
  wasCountedAtCreate,
} from "./shared";

export type ServerNotificationType =
  | "like"
  | "comment"
  | "pet_follow"
  | "reply"
  | "meetup_join"
  | "meetup_cancelled"
  | "warning";

export type ServerNotificationPayload = {
  userId: string;
  type: ServerNotificationType;
  fromUserId: string;
  fromUserName: string;
  fromUserAvatar: string;
  message: string;
  postId?: string;
  petId?: string;
  commentId?: string;
  postImage?: string;
  warningReason?: string;
  warningDetails?: string;
  read?: boolean;
};

export type NotificationActor = {
  fromUserId: string;
  fromUserName: string;
  fromUserAvatar: string;
  role?: string;
  banned?: boolean;
  // True while deleteUserAccount is in flight; mutating callables should
  // refuse new writes from this user until the cascade completes.
  deletionPending?: boolean;
};

export async function getNotificationActor(userId: string): Promise<NotificationActor> {
  const [userSnap, adminSnap] = await Promise.all([
    db.doc(`users/${userId}`).get(),
    db.doc(`users/${userId}/admin/state`).get(),
  ]);
  const data = userSnap.exists ? userSnap.data() ?? {} : {};
  const adminData = adminSnap.exists ? adminSnap.data() ?? {} : {};
  const displayName =
    typeof data.displayName === "string" && data.displayName.trim().length > 0
      ? data.displayName
      : "PetNote User";
  const storedAvatarUrl =
    typeof data.avatarUrl === "string" ? data.avatarUrl.trim() : "";
  const avatarUrl = isTrustedHttpsUrl(storedAvatarUrl, TRUSTED_AVATAR_URL_HOSTS)
    ? storedAvatarUrl
    : getDefaultAvatar(userId);

  return {
    fromUserId: userId,
    fromUserName: displayName,
    fromUserAvatar: avatarUrl,
    role: typeof adminData.role === "string" ? adminData.role : undefined,
    banned: adminData.banned === true,
    deletionPending: data.deletionPending === true,
  };
}

// Throws if the actor's account is mid-deletion. Use after the ban check on
// every mutating callable so concurrent writes can't race the cascade.
export function assertActorNotDeleting(actor: NotificationActor): void {
  if (actor.deletionPending === true) {
    throw new HttpsError(
      "failed-precondition",
      "Account deletion is in progress."
    );
  }
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

export async function createNotificationIfAllowed(
  payload: ServerNotificationPayload,
  options?: {
    // Deterministic doc id. Used to dedupe fan-outs that an attacker (or an
    // eager finger) can re-trigger cheaply — e.g. like/unlike toggling used
    // to send the pet's whole family a fresh notification per toggle.
    dedupeId?: string;
  }
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

  if (options?.dedupeId) {
    const ref = db.collection("notifications").doc(options.dedupeId);
    try {
      await ref.create(docData);
      return ref.id;
    } catch (error) {
      const code = (error as { code?: number | string }).code;
      if (code === 6 /* ALREADY_EXISTS */) {
        return ref.id;
      }
      throw error;
    }
  }

  const result = await db.collection("notifications").add(docData);
  return result.id;
}

const READ_NOTIFICATION_RETENTION_DAYS = 90;

export const cleanupOldReadNotifications = onSchedule(
  { schedule: "every 24 hours", timeoutSeconds: 540, memory: "512MiB" },
  async () => {
    const cutoff = admin.firestore.Timestamp.fromMillis(
      Date.now() - READ_NOTIFICATION_RETENTION_DAYS * 24 * 60 * 60 * 1000
    );

    while (true) {
      const snapshot = await db
        .collection("notifications")
        .where("read", "==", true)
        .where("createdAt", "<", cutoff)
        .orderBy("createdAt", "asc")
        .limit(FIRESTORE_BATCH_LIMIT)
        .get();

      if (snapshot.empty) return;
      await batchChunked(snapshot.docs, (batch, docSnap) => {
        batch.delete(docSnap.ref);
      });
      if (snapshot.size < FIRESTORE_BATCH_LIMIT) return;
    }
  }
);

export async function getPetFamilyRecipientIds(
  petId: string,
  excludeUserId?: string
): Promise<string[]> {
  const familySnap = await db.collection(`pets/${petId}/family`).get();
  return Array.from(
    new Set(
      familySnap.docs
        .map((docSnap) => docSnap.id)
        .filter((userId): userId is string => !!userId && userId !== excludeUserId)
    )
  );
}

export const onFollowingPetCreated = onDocumentCreated(
  "users/{userId}/followingPets/{petId}",
  async (event) => {
    const { userId, petId } = event.params;
    const userRef = db.doc(`users/${userId}`);
    const petRef = db.doc(`pets/${petId}`);
    const followerMirrorRef = db.doc(`pets/${petId}/followers/${userId}`);
    const petSnap = await petRef.get();

    if (!petSnap.exists) {
      if (event.data) {
        // Mark not-counted before deleting so onFollowingPetDeleted won't
        // decrement counts that were never incremented (we return before any).
        await event.data.ref
          .set({ counted: false }, { merge: true })
          .catch(() => undefined);
        await event.data.ref.delete().catch(() => undefined);
      }
      return;
    }

    const actor = await getNotificationActor(userId);
    const followRef = event.data?.ref ?? null;

    // All counting runs in one transaction that re-reads the follow doc and
    // aborts if it's already gone. The previous batch used set(...,{merge})
    // on the trigger's own doc, which RESURRECTED a follow that was deleted
    // before the trigger ran — re-firing onDocumentCreated, double-counting
    // followers, and leaving a ghost follow the user couldn't see.
    // runEventOnce wraps the transaction: re-reading the follow doc stops a
    // delete that beat this trigger from being counted, but on its own it does
    // NOT stop a redelivery of the same create event — the follow doc still
    // exists the second time, so the increments ran again. The ledger closes
    // that half.
    const counted = await runEventOnce(event.id, async (t) => {
      if (followRef) {
        const followSnap = await t.get(followRef);
        if (!followSnap.exists) return false;
        if (followSnap.data()?.counted === true) return false;
      }
      const [userTxnSnap, petTxnSnap] = await Promise.all([
        t.get(userRef),
        t.get(petRef),
      ]);
      if (!petTxnSnap.exists) return false;
      if (userTxnSnap.exists) {
        t.update(userRef, {
          followingPetsCount: admin.firestore.FieldValue.increment(1),
        });
      }
      t.update(petRef, {
        followerCount: admin.firestore.FieldValue.increment(1),
      });
      t.set(followerMirrorRef, {
        userId,
        userName: actor.fromUserName,
        userAvatar: actor.fromUserAvatar || getDefaultAvatar(userId),
        followedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      // Stamp counted:true alongside the increments so onFollowingPetDeleted
      // only decrements follows that were actually counted (legacy follows
      // without the field are treated as counted; never-counted follows are
      // explicitly marked counted:false above). update() — never set() —
      // so a concurrently deleted follow doc aborts the transaction instead
      // of being recreated.
      if (followRef) {
        t.update(followRef, { counted: true });
      }
      return true;
    });
    if (!counted) return;

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
          petId,
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

    // Always remove the follower mirror. Only adjust counts if this follow was
    // actually counted — followPetCallable writes counted:false and
    // onFollowingPetCreated flips it to true with the increments. See
    // wasCountedAtCreate for what an absent field means.
    const wasCounted = wasCountedAtCreate(event.data?.data());

    await followerMirrorRef.delete().catch(() => undefined);
    if (!wasCounted) return;

    // One transaction for both decrements, wrapped in runEventOnce. These used
    // to be two independent clamped transactions: clamping stops the count
    // going negative but does not stop a redelivered delete subtracting twice
    // from a count that had room to spare, and splitting them meant a
    // redelivery could apply one side and not the other.
    await runEventOnce(event.id, async (t) => {
      const userSnap = await t.get(userRef);
      const petSnap = await t.get(petRef);
      if (!userSnap.exists && !petSnap.exists) return false;

      if (userSnap.exists) {
        const prev =
          typeof userSnap.data()?.followingPetsCount === "number"
            ? (userSnap.data() as { followingPetsCount: number }).followingPetsCount
            : 0;
        t.update(userRef, { followingPetsCount: Math.max(0, prev - 1) });
      }
      if (petSnap.exists) {
        const prev =
          typeof petSnap.data()?.followerCount === "number"
            ? (petSnap.data() as { followerCount: number }).followerCount
            : 0;
        t.update(petRef, { followerCount: Math.max(0, prev - 1) });
      }
      return true;
    });
  }
);

export const onLikeCreated = onDocumentCreated(
  "posts/{postId}/likes/{likeId}",
  async (event) => {
    const { postId, likeId } = event.params;
    const postRef = db.doc(`posts/${postId}`);
    const likeRef = event.data?.ref ?? db.doc(`posts/${postId}/likes/${likeId}`);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;

    // The count runs inside runEventOnce so a redelivered event cannot apply
    // it twice, and re-reads the like doc so a like that was already deleted
    // is never counted. update() — never set() — on the like doc, so a
    // concurrent delete aborts the transaction rather than resurrecting the
    // like, which is the failure onFollowingPetCreated records above.
    await runEventOnce(event.id, async (t) => {
      const likeSnap = await t.get(likeRef);
      const postTxnSnap = await t.get(postRef);
      if (!likeSnap.exists || !postTxnSnap.exists) return false;
      // Belt and braces for a redelivery that arrives after the ledger entry
      // has aged out: the stamp on the like doc outlives the ledger.
      if (likeSnap.data()?.counted === true) return false;

      t.update(postRef, { likeCount: admin.firestore.FieldValue.increment(1) });
      t.update(likeRef, { counted: true });
      return true;
    });

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
          createNotificationIfAllowed(
            {
              userId: recipientId,
              type: "like",
              fromUserId: actor.fromUserId,
              fromUserName: actor.fromUserName,
              fromUserAvatar: actor.fromUserAvatar,
              postId,
              postImage: postData.mediaUrl,
              message: `${actor.fromUserName} liked ${petName}'s post`,
            },
            // Deterministic per (recipient, liker, post): like/unlike
            // toggling no longer floods the family with duplicates — likes
            // are the one mutation with no rate limit.
            { dedupeId: `like_${recipientId}_${likeId}_${postId}` }
          )
        )
      );
      return;
    }

    if (postData.authorId && postData.authorId !== likeId) {
      await createNotificationIfAllowed(
        {
          userId: postData.authorId,
          type: "like",
          fromUserId: actor.fromUserId,
          fromUserName: actor.fromUserName,
          fromUserAvatar: actor.fromUserAvatar,
          postId,
          postImage: postData.mediaUrl,
          message: "liked your post",
        },
        { dedupeId: `like_${postData.authorId}_${likeId}_${postId}` }
      );
    }
  }
);

export const onLikeDeleted = onDocumentDeleted(
  "posts/{postId}/likes/{likeId}",
  async (event) => {
    const postRef = db.doc(`posts/${event.params.postId}`);
    // Only undo a like that onLikeCreated actually counted. Firestore may
    // deliver this delete before the create it undoes; decrementing anyway
    // drives likeCount below the truth, and clamping at zero hides that
    // instead of fixing it.
    if (!wasCountedAtCreate(event.data?.data())) return;

    await runEventOnce(event.id, async (t) => {
      const postTxnSnap = await t.get(postRef);
      if (!postTxnSnap.exists) return false;
      t.update(postRef, {
        likeCount: admin.firestore.FieldValue.increment(-1),
      });
      return true;
    });
  }
);

export const onCommentCreated = onDocumentCreated(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const { postId, commentId } = event.params;

    const rawComment = event.data?.data();
    if (rawComment?.authorId) {
      const actor = await getNotificationActor(rawComment.authorId as string);
      const commentRef = db.doc(`posts/${postId}/comments/${commentId}`);
      // Cosmetic denormalization only — must never kill the handler. If the
      // comment was deleted within trigger latency, letting this NOT_FOUND
      // propagate skipped the commentCount increment below while
      // onCommentDeleted still decremented, driving the count negative.
      await commentRef
        .update({
          authorName: actor.fromUserName,
          authorAvatar: actor.fromUserAvatar,
        })
        .catch(() => undefined);
    }

    const postRef = db.doc(`posts/${postId}`);
    const commentDocRef = event.data?.ref ?? db.doc(`posts/${postId}/comments/${commentId}`);

    // Same shape as onLikeCreated: dedupe on the event id, re-read the source
    // document, and stamp it so onCommentDeleted knows this comment was
    // counted.
    await runEventOnce(event.id, async (t) => {
      const commentSnap = await t.get(commentDocRef);
      const postTxnSnap = await t.get(postRef);
      if (!commentSnap.exists || !postTxnSnap.exists) return false;
      if (commentSnap.data()?.counted === true) return false;

      t.update(postRef, {
        commentCount: admin.firestore.FieldValue.increment(1),
      });
      t.update(commentDocRef, { counted: true });
      return true;
    });

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

export const onCommentDeleted = onDocumentDeleted(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const postRef = db.doc(`posts/${event.params.postId}`);
    if (!wasCountedAtCreate(event.data?.data())) return;

    await runEventOnce(event.id, async (t) => {
      const postTxnSnap = await t.get(postRef);
      if (!postTxnSnap.exists) return false;
      t.update(postRef, {
        commentCount: admin.firestore.FieldValue.increment(-1),
      });
      return true;
    });
  }
);

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

export const sendNotification = onCall(async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const callerUid = request.auth.uid;
  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot send notifications.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "sendNotification", RATE_LIMITS.write);

  if (caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Only admins can send warning notifications.");
  }

  const data = requestData(request.data) as {
    userId?: string;
    type?: string;
    message?: string;
    warningReason?: string;
    warningDetails?: string;
  };

  const targetUserId = requiredDocId(data.userId, "userId");

  if (data.type !== "warning") {
    throw new HttpsError("invalid-argument", "Only warning notifications are supported.");
  }

  const message = requiredTrimmedString(
    data.message,
    VALIDATION_LIMITS.notificationMessage,
    "Notification message"
  );
  const warningReason =
    data.warningReason === undefined
      ? undefined
      : optionalTrimmedString(
          data.warningReason,
          VALIDATION_LIMITS.warningReason,
          "Warning reason"
        );
  const warningDetails =
    data.warningDetails === undefined
      ? undefined
      : optionalTrimmedString(
          data.warningDetails,
          VALIDATION_LIMITS.warningDetails,
          "Warning details"
        );

  // The client must not control the `read` flag — otherwise an admin (or
  // anyone replaying the call) could push warnings already marked read and
  // silence the recipient.
  const payload: ServerNotificationPayload = {
    userId: targetUserId,
    type: "warning",
    fromUserId: callerUid,
    fromUserName: "PetNote Team",
    fromUserAvatar: getDefaultAvatar("petnote-team"),
    message,
    warningReason,
    warningDetails,
    read: false,
  };

  const id = await createNotificationIfAllowed(payload);
  return { id };
});

// Mark every unread notification for the caller as read. Server-side so
// the client doesn't have to fetch all unread docs first. Uses cursor
// paging via processQueryInBatches so it stays bounded for users with a
// large unread backlog.
export const markAllNotificationsAsReadCallable = onCall(
  { timeoutSeconds: 120 },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Must be logged in.");
    }
    await assertRateLimit(
      callerUid,
      "markAllNotificationsAsRead",
      RATE_LIMITS.write
    );

    let updated = 0;
    await processQueryInBatches(
      db
        .collection("notifications")
        .where("userId", "==", callerUid)
        .where("read", "==", false),
      (batch, docSnap) => {
        batch.update(docSnap.ref, { read: true });
        updated += 1;
      }
    );
    return { updated };
  }
);
