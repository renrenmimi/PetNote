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

export const deleteUserAccount = onCall(async (request) => {
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
    { deletionPending: true, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true }
  );

  const [postsSnap, petsSnap, meetupsSnap] = await Promise.all([
    db.collection("posts").where("authorId", "==", userId).get(),
    db.collection("pets").where("ownerId", "==", userId).get(),
    db.collection("meetups").where("organizerId", "==", userId).get(),
  ]);

  for (const docSnap of postsSnap.docs) {
    await cascadeDeletePost(docSnap.id);
  }

  for (const docSnap of petsSnap.docs) {
    await cascadeDeletePet(docSnap.id);
  }

  for (const docSnap of meetupsSnap.docs) {
    await cascadeDeleteMeetup(docSnap.id);
  }

  await Promise.all([
    deleteQueryDocs(db.collection("notifications").where("userId", "==", userId)),
    deleteQueryDocs(db.collection("notifications").where("fromUserId", "==", userId)),
    deleteQueryDocs(db.collectionGroup("comments").where("authorId", "==", userId)),
    deleteQueryDocs(db.collectionGroup("likes").where("userId", "==", userId)),
    deleteQueryDocs(db.collectionGroup("checkins").where("userId", "==", userId)),
    deleteQueryDocs(db.collectionGroup("reviews").where("userId", "==", userId)),
    deleteQueryDocs(db.collectionGroup("participants").where("userId", "==", userId)),
    deleteQueryDocs(db.collectionGroup("family").where("userId", "==", userId)),
    deleteQueryDocs(db.collection("reports").where("reporterId", "==", userId)),
    deleteQueryDocs(db.collection("feedback").where("userId", "==", userId)),
    deleteCollectionPath(`users/${userId}/bookmarks`),
    deleteCollectionPath(`users/${userId}/followingPets`),
    deleteCollectionPath(`users/${userId}/followers`),
    deleteCollectionPath(`users/${userId}/following`),
    deleteCollectionPath(`users/${userId}/blockedUsers`),
    deleteCollectionPath(`users/${userId}/settings`),
  ]);

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

  await userRef.delete();

  return { success: true };
});
