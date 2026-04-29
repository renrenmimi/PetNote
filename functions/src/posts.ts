import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { cascadeDeletePost, deleteQueryDocs } from "./cleanup";
import { getNotificationActor } from "./notifications";
import { getDefaultAvatar, optionalTrimmedString, VALIDATION_LIMITS } from "./shared";
import { getAccessiblePet } from "./pets";

function normalizeTags(tags: unknown): string[] {
  if (!Array.isArray(tags)) return [];
  return Array.from(
    new Set(
      tags
        .slice(0, VALIDATION_LIMITS.maxTags)
        .filter((tag): tag is string => typeof tag === "string")
        .map((tag) => tag.trim().toLowerCase().replace(/^#/, ""))
        .filter((tag) => tag.length <= VALIDATION_LIMITS.tag)
        .filter(Boolean)
    )
  );
}

function getPostPetId(data: admin.firestore.DocumentData | undefined): string | null {
  return typeof data?.petId === "string" && data.petId.trim().length > 0
    ? data.petId
    : null;
}

async function applyPetPostCountDelta(
  petId: string,
  delta: number
): Promise<void> {
  if (!petId || delta === 0) return;
  const petRef = db.doc(`pets/${petId}`);
  try {
    await db.runTransaction(async (transaction) => {
      const petSnap = await transaction.get(petRef);
      if (!petSnap.exists) return;
      const current = petSnap.data()?.postCount;
      const currentCount = typeof current === "number" ? current : 0;
      transaction.update(petRef, {
        postCount: Math.max(0, currentCount + delta),
      });
    });
  } catch (error) {
    console.error("Failed to update pet post count", { petId, delta, error });
  }
}

export const onPostWritten = onDocumentWritten("posts/{postId}", async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();

  const oldTags = normalizeTags(before?.tags);
  const newTags = normalizeTags(after?.tags);

  const added = newTags.filter((t) => !oldTags.includes(t));
  const removed = oldTags.filter((t) => !newTags.includes(t));

  const tasks: Array<Promise<unknown>> = [];

  if (added.length > 0 || removed.length > 0) {
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
    tasks.push(batch.commit());
  }

  const petDeltas = new Map<string, number>();
  const previousPetId = getPostPetId(before);
  const nextPetId = getPostPetId(after);
  if (previousPetId) {
    petDeltas.set(previousPetId, (petDeltas.get(previousPetId) ?? 0) - 1);
  }
  if (nextPetId) {
    petDeltas.set(nextPetId, (petDeltas.get(nextPetId) ?? 0) + 1);
  }
  petDeltas.forEach((delta, petId) => {
    if (delta !== 0) {
      tasks.push(applyPetPostCountDelta(petId, delta));
    }
  });

  await Promise.all(tasks);
});

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
        .map((item) => {
          const mediaItem: {
            url: string;
            type: "image" | "video";
            thumbUrl?: string;
          } = {
            url: optionalTrimmedString(item.url, VALIDATION_LIMITS.url, "Media URL"),
            type: item.type,
          };
          if (item.thumbUrl) {
            mediaItem.thumbUrl = optionalTrimmedString(
              item.thumbUrl,
              VALIDATION_LIMITS.url,
              "Media thumbnail URL"
            );
          }
          return mediaItem;
        })
    : [];
  const firstMedia = media[0];
  const text = optionalTrimmedString(
    data.text,
    VALIDATION_LIMITS.postText,
    "Post text"
  );

  const result = await db.collection("posts").add({
    authorId: callerUid,
    authorName: caller.fromUserName,
    authorAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    text,
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

export const updatePostCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot edit posts.");
  }
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
    text: optionalTrimmedString(
      data.text,
      VALIDATION_LIMITS.postText,
      "Post text"
    ),
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

export const setPinnedPostCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot pin posts.");
  }

  const { postId } = request.data as { postId?: string | null };
  const userRef = db.doc(`users/${callerUid}`);

  // postId === null or missing means "unpin"
  if (postId === null || postId === undefined || postId === "") {
    await userRef.set(
      { pinnedPostId: admin.firestore.FieldValue.delete() },
      { merge: true }
    );
    return { success: true };
  }

  if (typeof postId !== "string") {
    throw new HttpsError("invalid-argument", "Invalid postId.");
  }

  const postSnap = await db.doc(`posts/${postId}`).get();
  if (!postSnap.exists) {
    throw new HttpsError("not-found", "Post not found.");
  }
  const postData = postSnap.data() ?? {};
  if (postData.authorId !== callerUid) {
    throw new HttpsError("permission-denied", "You can only pin your own posts.");
  }

  await userRef.set({ pinnedPostId: postId }, { merge: true });
  return { success: true };
});

export const deletePostCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot delete posts.");
  }

  const { postId } = request.data as { postId?: string };
  if (!postId || typeof postId !== "string") {
    throw new HttpsError("invalid-argument", "Missing postId.");
  }

  const postRef = db.doc(`posts/${postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) {
    return { success: true };
  }

  const postData = postSnap.data() ?? {};
  if (postData.authorId !== callerUid && caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Cannot delete this post.");
  }

  await cascadeDeletePost(postId);
  return { success: true };
});

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
  const text = requiredCommentText(data.text);
  await commentRef.set({
    authorId: callerUid,
    authorName: caller.fromUserName,
    authorAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    text,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(replyTo ? { replyTo } : {}),
  });

  return { id: commentRef.id };
});

function requiredCommentText(value: unknown): string {
  const text = optionalTrimmedString(
    value,
    VALIDATION_LIMITS.commentText,
    "Comment text"
  );
  if (!text) {
    throw new HttpsError("invalid-argument", "Comment text is required.");
  }
  return text;
}

export const deleteCommentCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot delete comments.");
  }

  const { postId, commentId } = request.data as { postId?: string; commentId?: string };
  if (!postId || !commentId) {
    throw new HttpsError("invalid-argument", "Missing postId or commentId.");
  }

  const commentRef = db.doc(`posts/${postId}/comments/${commentId}`);
  const postRef = db.doc(`posts/${postId}`);
  const [commentSnap, postSnap] = await Promise.all([commentRef.get(), postRef.get()]);
  if (!commentSnap.exists || !postSnap.exists) {
    return { success: true };
  }

  const commentData = commentSnap.data() ?? {};
  const postData = postSnap.data() ?? {};
  const canDelete =
    commentData.authorId === callerUid ||
    postData.authorId === callerUid ||
    caller.role === "admin";
  if (!canDelete) {
    throw new HttpsError("permission-denied", "Cannot delete this comment.");
  }

  await deleteQueryDocs(
    db.collection("notifications").where("postId", "==", postId).where("commentId", "==", commentId)
  );
  await commentRef.delete();
  return { success: true };
});
