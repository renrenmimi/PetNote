import { HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";

export const VALIDATION_LIMITS = {
  displayName: 30,
  bio: 150,
  petName: 20,
  petBreed: 80,
  petCustomRelationship: 30,
  postText: 2000,
  commentText: 500,
  tag: 40,
  maxTags: 20,
  meetupTitle: 60,
  meetupDescription: 500,
  meetupCustomPetType: 30,
  meetupAdditionalNotes: 200,
  placeName: 60,
  placeDescription: 500,
  address: 200,
  city: 100,
  state: 100,
  reviewComment: 300,
  checkInCaption: 150,
  reportReason: 500,
  reportDescription: 1000,
  feedbackSubject: 100,
  feedbackMessage: 1000,
  notificationMessage: 500,
  warningReason: 200,
  warningDetails: 1000,
  url: 2048,
} as const;

export function trimString(value: unknown, fieldName: string): string {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `${fieldName} must be a string.`);
  }
  return value.trim();
}

export function validateMaxLength(
  value: string,
  maxLength: number,
  fieldName: string
): string {
  if (value.length > maxLength) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must be ${maxLength} characters or fewer.`
    );
  }
  return value;
}

export function optionalTrimmedString(
  value: unknown,
  maxLength: number,
  fieldName: string
): string {
  if (value === undefined || value === null) return "";
  return validateMaxLength(trimString(value, fieldName), maxLength, fieldName);
}

export function requiredTrimmedString(
  value: unknown,
  maxLength: number,
  fieldName: string
): string {
  const trimmed = optionalTrimmedString(value, maxLength, fieldName);
  if (!trimmed) {
    throw new HttpsError("invalid-argument", `${fieldName} is required.`);
  }
  return trimmed;
}

export function validateCoordinateRange(lat: number, lng: number): boolean {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    Math.abs(lat) <= 90 &&
    Math.abs(lng) <= 180
  );
}

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
