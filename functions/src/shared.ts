import { admin, db } from "./platform";

// Helper: batch operations in chunks of 450 (under Firestore 500 limit)
export async function batchChunked(
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
export async function recomputeLocationAggregation(locationId: string): Promise<void> {
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

export function getDefaultAvatar(seed: string): string {
  return `https://api.dicebear.com/7.x/thumbs/svg?seed=${seed}`;
}

export function stripUndefined<T extends Record<string, unknown>>(value: T): T {
  const result = { ...value };
  Object.keys(result).forEach((key) => {
    if (result[key] === undefined) {
      delete result[key];
    }
  });
  return result;
}
