import { onDocumentDeleted } from "firebase-functions/v2/firestore";
import { admin, db } from "./platform";
import { batchChunked } from "./shared";

export async function deleteCollectionPath(path: string): Promise<void> {
  const snapshot = await db.collection(path).get();
  if (snapshot.empty) return;
  await batchChunked(snapshot.docs, (batch, docSnap) => {
    batch.delete(docSnap.ref);
  });
}

export async function deleteQueryDocs(queryRef: admin.firestore.Query): Promise<void> {
  const snapshot = await queryRef.get();
  if (snapshot.empty) return;
  await batchChunked(snapshot.docs, (batch, docSnap) => {
    batch.delete(docSnap.ref);
  });
}

export async function cascadeDeletePost(postId: string): Promise<void> {
  const postRef = db.doc(`posts/${postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) return;

  const [likesSnap, commentsSnap] = await Promise.all([
    db.collection(`posts/${postId}/likes`).get(),
    db.collection(`posts/${postId}/comments`).get(),
  ]);

  if (!likesSnap.empty) {
    await batchChunked(likesSnap.docs, (batch, docSnap) => {
      batch.delete(docSnap.ref);
    });
  }

  if (!commentsSnap.empty) {
    await batchChunked(commentsSnap.docs, (batch, docSnap) => {
      batch.delete(docSnap.ref);
    });
  }

  await postRef.delete();
}

export async function cascadeDeletePet(petId: string): Promise<void> {
  await Promise.all([
    deleteCollectionPath(`pets/${petId}/family`),
    deleteCollectionPath(`pets/${petId}/followers`),
    deleteCollectionPath(`pets/${petId}/invitations`),
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

export const onPostDeleted = onDocumentDeleted("posts/{postId}", async (event) => {
  const postId = event.params.postId;

  // Bookmarks store { postId } as a field (doc id also equals postId). Use a
  // filtered collection group query so we only touch the bookmarks for this
  // post instead of scanning every user's bookmarks.
  const bookmarksSnap = await db
    .collectionGroup("bookmarks")
    .where("postId", "==", postId)
    .get();
  if (!bookmarksSnap.empty) {
    await batchChunked(bookmarksSnap.docs, (batch, doc) => {
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
