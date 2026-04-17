import { onDocumentCreated, onDocumentDeleted, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { getDefaultAvatar } from "./shared";

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
  const avatarUrl =
    typeof data.avatarUrl === "string" && data.avatarUrl.trim().length > 0
      ? data.avatarUrl
      : getDefaultAvatar(userId);

  return {
    fromUserId: userId,
    fromUserName: displayName,
    fromUserAvatar: avatarUrl,
    role: typeof adminData.role === "string" ? adminData.role : undefined,
    banned: adminData.banned === true,
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

export async function createNotificationIfAllowed(
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

export const onLikeCreated = onDocumentCreated(
  "posts/{postId}/likes/{likeId}",
  async (event) => {
    const { postId, likeId } = event.params;
    const postRef = db.doc(`posts/${postId}`);
    const postSnap = await postRef.get();
    if (!postSnap.exists) return;

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

export const onCommentCreated = onDocumentCreated(
  "posts/{postId}/comments/{commentId}",
  async (event) => {
    const { postId, commentId } = event.params;

    const rawComment = event.data?.data();
    if (rawComment?.authorId) {
      const actor = await getNotificationActor(rawComment.authorId as string);
      const commentRef = db.doc(`posts/${postId}/comments/${commentId}`);
      await commentRef.update({
        authorName: actor.fromUserName,
        authorAvatar: actor.fromUserAvatar,
      });
    }

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
