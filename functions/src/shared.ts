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

// Normalize callable `request.data` into a plain object so handler code can
// safely use `"key" in data` and indexed access without crashing on undefined
// or array payloads. Always prefer this over `request.data as { ... }`.
export function requestData(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, unknown>;
}

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

// Validate any caller-supplied string used as a Firestore document id /
// path segment. Without this guard a value like "abc/likes/xyz" silently
// reroutes db.doc("posts/${value}") into a different collection because
// "/" is the path separator. Firestore SDK accepts the resulting path
// when the segment count happens to land even, so the write or read
// goes to the wrong place rather than failing loudly.
//
// The character class matches Firestore's auto-generated ids and our
// own derived ones (auth uids, generated nanoid-style codes); reject
// "." or ".." which Firestore rejects anyway, and slashes which it
// silently accepts.
export function validateDocId(value: string): boolean {
  if (!value || value.length > 200) return false;
  if (value === "." || value === "..") return false;
  return /^[A-Za-z0-9_\-:.@+|=]+$/.test(value);
}

export function requiredDocId(value: unknown, fieldName: string): string {
  if (typeof value !== "string" || !validateDocId(value.trim())) {
    throw new HttpsError("invalid-argument", `Invalid ${fieldName}.`);
  }
  return value.trim();
}

// 1-5 finite check shared by rating + petFriendly subscores. The bare
// "typeof === number" guard let NaN/Infinity/out-of-range values slip
// through, which then poisoned the location aggregate sums.
export function validateRatingScore(
  value: unknown,
  fieldName: string
): number {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < 1 ||
    value > 5
  ) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must be a finite number between 1 and 5.`
    );
  }
  return value;
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

// How long a processed-event marker is kept. Firestore retries a failed
// trigger for up to 7 days, so the ledger has to outlive that window or a very
// late redelivery slips through and double-counts. 30 days leaves room for TTL
// deletion to lag, which it is allowed to do by up to 24 hours.
export const PROCESSED_EVENT_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;


/**
 * Firestore document ids may not contain "/" and may not be "." or "..".
 * CloudEvent ids are normally safe, but the ledger key must never be able to
 * escape the collection it is written to.
 */
function eventLedgerId(eventId: string): string {
  const safe = eventId.replace(/[/.]/g, "_").slice(0, 400);
  return safe.length > 0 ? safe : "unknown";
}

/**
 * Runs `body` at most once per trigger event.
 *
 * Firestore delivers events at least once and out of order, so a handler that
 * blind-increments a counter double-counts on redelivery. `body` stages its
 * writes on the transaction it is handed, and the event id is written into
 * processedEvents/{eventId} in that same transaction — so the count and the
 * record of having counted either both land or neither does. A redelivery
 * finds the marker and does nothing.
 *
 * `body` returns whether it actually applied anything. When it declines (the
 * source document is gone, the target document is gone, the event was already
 * accounted for) nothing is recorded, so a later redelivery is free to try
 * again and reach the same conclusion.
 *
 * The ledger is read before `body` runs because Firestore forbids reads after
 * writes inside a transaction and `body` writes.
 *
 * Requires a TTL policy on processedEvents.expiresAt, or the collection grows
 * without bound.
 */
export async function runEventOnce(
  eventId: string | undefined,
  body: (t: admin.firestore.Transaction) => Promise<boolean>
): Promise<boolean> {
  if (!eventId) {
    // v2 triggers always carry an id, so this is a should-not-happen path.
    // Applying the effect beats dropping it: at-least-once is the contract we
    // are already living with, never-once is a new failure.
    console.warn("runEventOnce: no event id, deduplication skipped");
    return db.runTransaction((t) => body(t));
  }

  const ledgerRef = db.doc(`processedEvents/${eventLedgerId(eventId)}`);
  return db.runTransaction(async (t) => {
    const seen = await t.get(ledgerRef);
    if (seen.exists) return false;

    const applied = await body(t);
    if (!applied) return false;

    t.set(ledgerRef, {
      eventId,
      processedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromMillis(
        Date.now() + PROCESSED_EVENT_RETENTION_MS
      ),
    });
    return true;
  });
}

/**
 * Whether a deleted document's count had already been applied, read from the
 * snapshot the delete event carries.
 *
 * A delete must not undo a count that was never applied — Firestore can
 * deliver a delete before the create it undoes, and subtracting anyway drives
 * the aggregate below the truth. Clamping at zero hides that rather than
 * fixing it. So every document that feeds a counter is written with
 * `counted: false` and flipped to `true` by the counting transaction, giving
 * three unambiguous states:
 *
 *   true      the count was applied; undo it
 *   false     the document exists but its create trigger has not counted it
 *             yet, so there is nothing to undo
 *   absent    written before this scheme shipped, by code that counted
 *             unconditionally, so it was counted; undo it
 *
 * The absent case is what makes this safe to deploy without a backfill: it
 * needs no date and nothing reconfigured at deploy time.
 *
 * It is also, on its own, a way to forge "already counted" — so nothing may
 * be able to write a counter-feeding document without the field. Every
 * collection here but one is written by a callable that stamps `counted:
 * false` server-side. The exception is `likes`, the only collection a client
 * writes to Firestore directly, and firestore.rules therefore REQUIRES
 * `counted == false` on a like create. It used to merely permit absence, for
 * the sake of clients running pre-`counted` JS, and that combined with the
 * reading below into a live exploit: create a like with no `counted`, delete
 * it before onLikeCreated runs, and onLikeDeleted subtracts a like that was
 * never added. See the comment on that rule.
 *
 * Do not relax `counted` to optional in any client-writable path without
 * changing this function too.
 */
export function wasCountedAtCreate(
  data: admin.firestore.DocumentData | undefined
): boolean {
  if (!data) return false;
  if (typeof data.counted === "boolean") return data.counted;
  return true;
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

/**
 * Applies one batched write page at a time, using document-id cursors so the
 * operation does not rely on mutated documents disappearing from the query.
 * Queries that combine filters with this helper's document-id ordering may
 * need matching composite indexes in firestore.indexes.json.
 */
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

/**
 * Iterates one query page at a time, using the same document-id cursor pattern
 * as processQueryInBatches for long-running per-document operations.
 */
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

export type PetFriendlySubscores = {
  space: number;
  safety: number;
  cleanliness: number;
};

export type ReviewAggregationDelta = {
  ratingSum: number;
  count: number;
  tagsToAdd?: string[];
  photosToAdd?: string[];
  // Per-dimension sum delta (positive on create, negative on delete). The
  // location doc maintains both petFriendlySum (raw) and petFriendlyAvg
  // (sum / totalRatings) so the UI can render the subscores without
  // pulling every review.
  petFriendlySumDelta?: PetFriendlySubscores;
  // Tag histogram delta: { puppy: 1, friendly: 1 } on create, the same
  // tags with -1 on delete. Keys whose count goes <= 0 are removed from
  // tagCounts via FieldValue.delete so the map doesn't accumulate dead
  // entries forever.
  tagCountsDelta?: Record<string, number>;
};

const TOP_TAGS_LIMIT = 10;

function divideSubscores(
  sum: PetFriendlySubscores,
  count: number
): PetFriendlySubscores {
  if (count <= 0) {
    return { space: 0, safety: 0, cleanliness: 0 };
  }
  return {
    space: Number((sum.space / count).toFixed(2)),
    safety: Number((sum.safety / count).toFixed(2)),
    cleanliness: Number((sum.cleanliness / count).toFixed(2)),
  };
}

function readSubscores(value: unknown): PetFriendlySubscores {
  if (!value || typeof value !== "object") {
    return { space: 0, safety: 0, cleanliness: 0 };
  }
  const record = value as Record<string, unknown>;
  return {
    space: typeof record.space === "number" ? record.space : 0,
    safety: typeof record.safety === "number" ? record.safety : 0,
    cleanliness: typeof record.cleanliness === "number" ? record.cleanliness : 0,
  };
}

function readTagCounts(value: unknown): Record<string, number> {
  if (!value || typeof value !== "object") return {};
  const out: Record<string, number> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (typeof raw === "number" && raw > 0) {
      out[key] = raw;
    }
  }
  return out;
}

// Apply a per-review delta to location aggregation counters in a single
// transaction. Avoids re-reading every review on the location on every
// write, which previously scaled O(totalReviews) per create/delete.
/**
 * Stages one review's contribution to a location's aggregates on a caller-
 * supplied transaction. The transaction belongs to the caller so the review
 * counter and the processed-event marker commit together — a delta that lands
 * without its marker would be reapplied on the next redelivery.
 *
 * Returns false when the location is gone and nothing was staged.
 */
export async function applyReviewAggregationDelta(
  t: admin.firestore.Transaction,
  locationId: string,
  delta: ReviewAggregationDelta
): Promise<boolean> {
  const locationRef = db.doc(`locations/${locationId}`);
  const snap = await t.get(locationRef);
  if (!snap.exists) return false;
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

  if (delta.petFriendlySumDelta) {
    const prevPfSum = readSubscores(data.petFriendlySum);
    const newPfSum: PetFriendlySubscores = {
      space: Math.max(0, prevPfSum.space + delta.petFriendlySumDelta.space),
      safety: Math.max(0, prevPfSum.safety + delta.petFriendlySumDelta.safety),
      cleanliness: Math.max(
        0,
        prevPfSum.cleanliness + delta.petFriendlySumDelta.cleanliness
      ),
    };
    update.petFriendlySum = newPfSum;
    update.petFriendlyAvg = divideSubscores(newPfSum, newCount);
  }

  if (delta.tagCountsDelta && Object.keys(delta.tagCountsDelta).length > 0) {
    const prevCounts = readTagCounts(data.tagCounts);
    for (const [tag, change] of Object.entries(delta.tagCountsDelta)) {
      const next = (prevCounts[tag] ?? 0) + change;
      if (next <= 0) {
        // Drop the key entirely so the map doesn't accumulate dead tags.
        delete prevCounts[tag];
        update[`tagCounts.${tag}`] = admin.firestore.FieldValue.delete();
      } else {
        prevCounts[tag] = next;
        update[`tagCounts.${tag}`] = next;
      }
    }
    // topTags: highest-count tags up to TOP_TAGS_LIMIT, alphabetical
    // tiebreak. Pre-computed so the UI doesn't need the full histogram
    // for the common chips display.
    const topTags = Object.entries(prevCounts)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, TOP_TAGS_LIMIT)
      .map(([tag]) => tag);
    update.topTags = topTags;
  }

  t.update(locationRef, update);
  return true;
}

// Recompute every aggregate field from the location's review subcollection.
// Used by the admin recompute callable to backfill petFriendly* / tagCounts
// for locations whose reviews predate the trigger that maintains them.
export async function recomputeLocationReviewAggregates(
  locationId: string
): Promise<{
  totalRatings: number;
  averageRating: number;
  petFriendlyAvg: PetFriendlySubscores;
  tagCount: number;
}> {
  const locationRef = db.doc(`locations/${locationId}`);
  const reviewsRef = db.collection(`locations/${locationId}/reviews`);
  const reviewsSnap = await reviewsRef.get();

  let sumRating = 0;
  const pfSum: PetFriendlySubscores = { space: 0, safety: 0, cleanliness: 0 };
  const tagCounts: Record<string, number> = {};
  const distinctTags = new Set<string>();

  for (const docSnap of reviewsSnap.docs) {
    const data = docSnap.data() ?? {};
    const rating = typeof data.rating === "number" ? data.rating : 0;
    sumRating += rating;
    const pf = readSubscores(data.petFriendly);
    pfSum.space += pf.space || rating;
    pfSum.safety += pf.safety || rating;
    pfSum.cleanliness += pf.cleanliness || rating;
    if (Array.isArray(data.tags)) {
      for (const raw of data.tags as unknown[]) {
        if (typeof raw === "string" && raw.length > 0) {
          tagCounts[raw] = (tagCounts[raw] ?? 0) + 1;
          distinctTags.add(raw);
        }
      }
    }
  }

  const count = reviewsSnap.size;
  const averageRating = count === 0 ? 0 : Number((sumRating / count).toFixed(2));
  const petFriendlyAvg = divideSubscores(pfSum, count);
  const topTags = Object.entries(tagCounts)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, TOP_TAGS_LIMIT)
    .map(([tag]) => tag);

  await locationRef.set(
    {
      sumRating,
      totalRatings: count,
      averageRating,
      petFriendlySum: pfSum,
      petFriendlyAvg,
      tagCounts,
      topTags,
      tags: Array.from(distinctTags),
    },
    { merge: true }
  );

  return {
    totalRatings: count,
    averageRating,
    petFriendlyAvg,
    tagCount: Object.keys(tagCounts).length,
  };
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
