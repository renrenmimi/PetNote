import { HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";

export const FIRESTORE_BATCH_LIMIT = 450;
export const LOCATION_PHOTO_PREVIEW_LIMIT = 30;
export const TRUSTED_AVATAR_URL_HOSTS = [
  "res.cloudinary.com",
  "api.dicebear.com",
  "lh3.googleusercontent.com",
] as const;
export const TRUSTED_MEDIA_URL_HOSTS = ["res.cloudinary.com"] as const;

export const RATE_LIMITS = {
  read: { limit: 120, windowMs: 60_000 },
  write: { limit: 30, windowMs: 60_000 },
  strictWrite: { limit: 10, windowMs: 60_000 },
  uploadSignature: { limit: 30, windowMs: 60_000 },
  accountDeletion: { limit: 3, windowMs: 60 * 60_000 },
} as const;

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

export function validateTrustedHttpsUrl(
  value: string,
  fieldName: string,
  allowedHosts: readonly string[]
): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new HttpsError("invalid-argument", `${fieldName} must be a valid URL.`);
  }
  if (parsed.protocol !== "https:" || !allowedHosts.includes(parsed.hostname)) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must use a trusted HTTPS host.`
    );
  }
  return value;
}

export function isTrustedHttpsUrl(
  value: unknown,
  allowedHosts: readonly string[]
): value is string {
  if (typeof value !== "string") return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  if (parsed.protocol !== "https:" || !allowedHosts.includes(parsed.hostname)) {
    return false;
  }
  return true;
}

export function optionalTrustedHttpsUrl(
  value: unknown,
  maxLength: number,
  fieldName: string,
  allowedHosts: readonly string[]
): string {
  const trimmed = optionalTrimmedString(value, maxLength, fieldName);
  if (!trimmed) return "";
  return validateTrustedHttpsUrl(trimmed, fieldName, allowedHosts);
}

export function requiredTrustedHttpsUrl(
  value: unknown,
  maxLength: number,
  fieldName: string,
  allowedHosts: readonly string[]
): string {
  const trimmed = requiredTrimmedString(value, maxLength, fieldName);
  return validateTrustedHttpsUrl(trimmed, fieldName, allowedHosts);
}

export function mergeCappedStrings(
  existing: unknown,
  additions: string[],
  limit: number
): string[] {
  const existingStrings = Array.isArray(existing)
    ? existing.filter((item): item is string => typeof item === "string" && item.length > 0)
    : [];
  const seen = new Set<string>();
  const merged: string[] = [];
  [...existingStrings, ...additions].forEach((item) => {
    if (seen.has(item)) return;
    seen.add(item);
    merged.push(item);
  });
  return merged.slice(-limit);
}

// Helper: batch operations in chunks of 450 (under Firestore 500 limit)
export async function batchChunked(
  docs: admin.firestore.QueryDocumentSnapshot[],
  operation: (batch: admin.firestore.WriteBatch, doc: admin.firestore.QueryDocumentSnapshot) => void
): Promise<void> {
  for (let i = 0; i < docs.length; i += FIRESTORE_BATCH_LIMIT) {
    const batch = db.batch();
    docs.slice(i, i + FIRESTORE_BATCH_LIMIT).forEach((d) => operation(batch, d));
    await batch.commit();
  }
}

export async function assertRateLimit(
  callerUid: string,
  action: string,
  options: { limit: number; windowMs: number } = RATE_LIMITS.write
): Promise<void> {
  const now = Date.now();
  const windowStartedAt = Math.floor(now / options.windowMs) * options.windowMs;
  const safeUid = callerUid.replace(/\//g, "_");
  const safeAction = action.replace(/[^A-Za-z0-9_-]/g, "_");
  const rateLimitRef = db.doc(`callableRateLimits/${safeUid}_${safeAction}`);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(rateLimitRef);
    const data = snapshot.exists ? snapshot.data() ?? {} : {};
    const storedWindow =
      typeof data.windowStartedAt === "number" ? data.windowStartedAt : Number.NaN;
    const currentCount =
      storedWindow === windowStartedAt && typeof data.count === "number"
        ? data.count
        : 0;

    if (currentCount >= options.limit) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many requests. Please wait a moment and try again."
      );
    }

    transaction.set(
      rateLimitRef,
      {
        userId: callerUid,
        action,
        windowStartedAt,
        windowMs: options.windowMs,
        count: currentCount + 1,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromMillis(
          windowStartedAt + options.windowMs * 2
        ),
      },
      { merge: true }
    );
  });
}

export async function processQueryInBatches(
  queryRef: admin.firestore.Query,
  operation: (batch: admin.firestore.WriteBatch, doc: admin.firestore.QueryDocumentSnapshot) => void
): Promise<void> {
  const orderedQuery: admin.firestore.Query = queryRef.orderBy(
    admin.firestore.FieldPath.documentId()
  );
  let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;

  while (true) {
    const pageQuery: admin.firestore.Query = lastDoc
      ? orderedQuery.startAfter(lastDoc).limit(FIRESTORE_BATCH_LIMIT)
      : orderedQuery.limit(FIRESTORE_BATCH_LIMIT);
    const snapshot: admin.firestore.QuerySnapshot = await pageQuery.get();
    if (snapshot.empty) return;

    await batchChunked(snapshot.docs, operation);
    lastDoc = snapshot.docs[snapshot.docs.length - 1];
    if (snapshot.size < FIRESTORE_BATCH_LIMIT) return;
  }
}

export async function forEachQueryDocumentInBatches(
  queryRef: admin.firestore.Query,
  operation: (doc: admin.firestore.QueryDocumentSnapshot) => Promise<void>
): Promise<void> {
  const orderedQuery: admin.firestore.Query = queryRef.orderBy(
    admin.firestore.FieldPath.documentId()
  );
  let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;

  while (true) {
    const pageQuery: admin.firestore.Query = lastDoc
      ? orderedQuery.startAfter(lastDoc).limit(FIRESTORE_BATCH_LIMIT)
      : orderedQuery.limit(FIRESTORE_BATCH_LIMIT);
    const snapshot: admin.firestore.QuerySnapshot = await pageQuery.get();
    if (snapshot.empty) return;

    for (const doc of snapshot.docs) {
      await operation(doc);
    }
    lastDoc = snapshot.docs[snapshot.docs.length - 1];
    if (snapshot.size < FIRESTORE_BATCH_LIMIT) return;
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
      update.photos = mergeCappedStrings(
        data.photos,
        delta.photosToAdd,
        LOCATION_PHOTO_PREVIEW_LIMIT
      );
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
