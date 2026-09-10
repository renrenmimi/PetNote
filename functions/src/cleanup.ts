import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { admin, db, FieldValue } from "./platform";
import { processQueryInBatches } from "./shared";

export async function deleteCollectionPath(path: string): Promise<void> {
  await processQueryInBatches(db.collection(path), (batch, docSnap) => {
    batch.delete(docSnap.ref);
  });
}

export async function deleteQueryDocs(queryRef: admin.firestore.Query): Promise<void> {
  await processQueryInBatches(queryRef, (batch, docSnap) => {
    batch.delete(docSnap.ref);
  });
}

export async function cascadeDeletePost(postId: string): Promise<void> {
  const postRef = db.doc(`posts/${postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) return;

  await Promise.all([
    deleteCollectionPath(`posts/${postId}/likes`),
    deleteCollectionPath(`posts/${postId}/comments`),
  ]);

  await postRef.delete();
}

export async function cascadeDeletePet(petId: string): Promise<void> {
  // The top-level invitationCodes/{code} lookup has to go with the pet's
  // invitations. It was left behind before: the subcollection document was
  // deleted and the lookup — which is what redeemInvitationCallable resolves a
  // typed code through, and which carries petId — survived, pointing at a pet
  // that no longer exists. Matching on petId also reaps any lookup orphaned by
  // an earlier pet deletion.
  await Promise.all([
    deleteCollectionPath(`pets/${petId}/family`),
    deleteCollectionPath(`pets/${petId}/followers`),
    deleteCollectionPath(`pets/${petId}/invitations`),
    processQueryInBatches(
      db.collection("invitationCodes").where("petId", "==", petId),
      (batch, docSnap) => {
        batch.delete(docSnap.ref);
      }
    ),
  ]);
  await db.doc(`pets/${petId}`).delete();
}

export async function cascadeDeleteMeetup(meetupId: string): Promise<void> {
  await Promise.all([
    deleteCollectionPath(`meetups/${meetupId}/participants`),
    deleteCollectionPath(`meetups/${meetupId}/private`),
  ]);
  await db.doc(`meetups/${meetupId}`).delete();
}

export const onPetDeleted = onDocumentDeleted("pets/{petId}", async (event) => {
  const petId = event.params.petId;

  await Promise.all([
    processQueryInBatches(
      db.collectionGroup("followingPets").where("petId", "==", petId),
      (batch, doc) => {
        batch.delete(doc.ref);
      }
    ),
    processQueryInBatches(
      db.collection("posts").where("petId", "==", petId),
      (batch, doc) => {
        // FieldValue.delete() instead of empty strings: empty strings still
        // index, so where("petId","==","") would otherwise match orphaned
        // posts. Deleting the field removes them from petId-keyed indexes.
        batch.update(doc.ref, {
          petId: FieldValue.delete(),
          petName: FieldValue.delete(),
          petAvatarUrl: FieldValue.delete(),
        });
      }
    ),
  ]);
});

export const onPostDeleted = onDocumentDeleted("posts/{postId}", async (event) => {
  const postId = event.params.postId;

  // Bookmarks store { postId } as a field (doc id also equals postId). Use a
  // filtered collection group query so we only touch the bookmarks for this
  // post instead of scanning every user's bookmarks.
  await Promise.all([
    processQueryInBatches(
      db.collectionGroup("bookmarks").where("postId", "==", postId),
      (batch, doc) => {
        batch.delete(doc.ref);
      }
    ),
    processQueryInBatches(
      db.collection("reports")
        .where("targetId", "==", postId)
        .where("targetType", "==", "post"),
      (batch, doc) => {
        batch.delete(doc.ref);
      }
    ),
    processQueryInBatches(
      db.collection("notifications").where("postId", "==", postId),
      (batch, doc) => {
        batch.delete(doc.ref);
      }
    ),
  ]);
});
