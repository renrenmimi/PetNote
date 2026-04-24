import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { cascadeDeletePost, deleteQueryDocs } from "./cleanup";
import { getNotificationActor } from "./notifications";
import { getDefaultAvatar } from "./shared";
import { getAccessiblePet } from "./pets";

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

export const deleteCommentCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
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
