import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import {
  cascadeDeleteMeetup,
  cascadeDeletePet,
  cascadeDeletePost,
  deleteCollectionPath,
  deleteQueryDocs,
} from "./cleanup";
import { getNotificationActor } from "./notifications";
import { batchChunked, getDefaultAvatar } from "./shared";

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

export const onFamilyCreated = onDocumentCreated(
  "pets/{petId}/family/{userId}",
  async (event) => {
    const userId = event.params.userId;
    const actor = await getNotificationActor(userId);
    await db.doc(`pets/${event.params.petId}/family/${userId}`).update({
      userId,
      userName: actor.fromUserName,
      userAvatar: actor.fromUserAvatar || getDefaultAvatar(userId),
    });
  }
);

// Account deletion can take a while for heavy accounts. Allow up to nine
// minutes so large cascades finish in a single run; the function is still
// idempotent and safe to retry if it times out.
export const deleteUserAccount = onCall({ timeoutSeconds: 540 }, async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const { userId } = request.data as { userId: string };
  if (callerUid !== userId) {
    throw new HttpsError("permission-denied", "Can only delete your own account.");
  }

  const userRef = db.doc(`users/${userId}`);
  await userRef.set(
    {
      deletionPending: true,
      deletionStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  const failures: string[] = [];
  const runStep = async (label: string, task: () => Promise<void>) => {
    try {
      await task();
    } catch (error) {
      console.error(`deleteUserAccount step failed: ${label}`, error);
      failures.push(label);
    }
  };

  await runStep("posts", async () => {
    const postsSnap = await db.collection("posts").where("authorId", "==", userId).get();
    for (const docSnap of postsSnap.docs) {
      await cascadeDeletePost(docSnap.id);
    }
  });

  await runStep("pets", async () => {
    const petsSnap = await db.collection("pets").where("ownerId", "==", userId).get();
    for (const docSnap of petsSnap.docs) {
      await cascadeDeletePet(docSnap.id);
    }
  });

  await runStep("meetups", async () => {
    const meetupsSnap = await db.collection("meetups").where("organizerId", "==", userId).get();
    for (const docSnap of meetupsSnap.docs) {
      await cascadeDeleteMeetup(docSnap.id);
    }
  });

  const crossRefSteps: Array<[string, () => Promise<void>]> = [
    ["notifications.userId", () =>
      deleteQueryDocs(db.collection("notifications").where("userId", "==", userId))],
    ["notifications.fromUserId", () =>
      deleteQueryDocs(db.collection("notifications").where("fromUserId", "==", userId))],
    ["comments", () =>
      deleteQueryDocs(db.collectionGroup("comments").where("authorId", "==", userId))],
    ["likes", () =>
      deleteQueryDocs(db.collectionGroup("likes").where("userId", "==", userId))],
    ["checkins", () =>
      deleteQueryDocs(db.collectionGroup("checkins").where("userId", "==", userId))],
    ["reviews", () =>
      deleteQueryDocs(db.collectionGroup("reviews").where("userId", "==", userId))],
    ["participants", () =>
      deleteQueryDocs(db.collectionGroup("participants").where("userId", "==", userId))],
    ["family", () =>
      deleteQueryDocs(db.collectionGroup("family").where("userId", "==", userId))],
    ["reports", () =>
      deleteQueryDocs(db.collection("reports").where("reporterId", "==", userId))],
    ["feedback", () =>
      deleteQueryDocs(db.collection("feedback").where("userId", "==", userId))],
    ["bookmarks", () => deleteCollectionPath(`users/${userId}/bookmarks`)],
    ["followingPets", () => deleteCollectionPath(`users/${userId}/followingPets`)],
    ["followers", () => deleteCollectionPath(`users/${userId}/followers`)],
    ["following", () => deleteCollectionPath(`users/${userId}/following`)],
    ["blockedUsers", () => deleteCollectionPath(`users/${userId}/blockedUsers`)],
    ["settings", () => deleteCollectionPath(`users/${userId}/settings`)],
  ];
  await Promise.all(crossRefSteps.map(([label, task]) => runStep(label, task)));

  // Data cleanup had a failure; keep Auth/user doc in place so the client
  // can retry and pick up remaining orphans. Error message tells the UI to
  // call deleteUserAccount again rather than silently leaving dangling data.
  if (failures.length > 0) {
    throw new HttpsError(
      "internal",
      "Partial data cleanup failure; please retry account deletion.",
      { failedSteps: failures }
    );
  }

  await runStep("auth", async () => {
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
        throw error;
      }
    }
  });

  if (failures.includes("auth")) {
    throw new HttpsError("internal", "Failed to delete auth account; please retry.");
  }

  await userRef.delete().catch((error) => {
    console.error("deleteUserAccount: final user doc delete failed", error);
    throw new HttpsError("internal", "Failed to finalize account deletion; please retry.");
  });

  return { success: true };
});
