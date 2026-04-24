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

export type ReviewAggregationDelta = {
  ratingSum: number;
  count: number;
  tagsToAdd?: string[];
  photosToAdd?: string[];
};

// Apply a per-review delta to location aggregation counters in a single
// transaction. Avoids re-reading every review on the location on every
// write, which previously scaled O(totalReviews) per create/delete.
export async function applyReviewAggregationDelta(
  locationId: string,
  delta: ReviewAggregationDelta
): Promise<void> {
  const locationRef = db.doc(`locations/${locationId}`);
  await db.runTransaction(async (t) => {
    const snap = await t.get(locationRef);
    if (!snap.exists) return;
    const data = snap.data() ?? {};

    const prevCount = typeof data.totalRatings === "number" ? data.totalRatings : 0;
    const prevAverage =
      typeof data.averageRating === "number" ? data.averageRating : 0;
    // sumRating may not exist on legacy docs; reconstruct from average×count.
    const prevSum =
      typeof data.sumRating === "number"
        ? data.sumRating
        : prevAverage * prevCount;

    const newCount = Math.max(0, prevCount + delta.count);
    const newSum = Math.max(0, prevSum + delta.ratingSum);
    const averageRating = newCount === 0 ? 0 : Number((newSum / newCount).toFixed(2));

    const update: Record<string, unknown> = {
      sumRating: newSum,
      totalRatings: newCount,
      averageRating,
    };
    if (delta.tagsToAdd && delta.tagsToAdd.length > 0) {
      update.tags = admin.firestore.FieldValue.arrayUnion(...delta.tagsToAdd);
    }
    if (delta.photosToAdd && delta.photosToAdd.length > 0) {
      update.photos = admin.firestore.FieldValue.arrayUnion(...delta.photosToAdd);
    }

    t.update(locationRef, update);
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
