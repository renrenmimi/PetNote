import { createHash } from "node:crypto";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { assertNoBlockBetween } from "./blocking";
import { cascadeDeletePost, deleteQueryDocs } from "./cleanup";
import { assertCallerAccountActive, getNotificationActor } from "./notifications";
import {
  assertRateLimit,
  getDefaultAvatar,
  optionalTrimmedString,
  optionalTrustedHttpsUrl,
  RATE_LIMITS,
  requestData,
  requiredDocId,
  runEventOnce,
  stripUndefined,
  TRUSTED_MEDIA_URL_HOSTS,
  VALIDATION_LIMITS,
} from "./shared";
import { getAccessiblePet } from "./pets";

/**
 * Characters a hashtag cannot contain, because the tag *is* a document id.
 *
 * `onPostWritten` writes aggregates to `hashtags/{tag}`. A tag containing "/"
 * makes that an odd-component path, and the Admin SDK throws out of the whole
 * aggregation transaction — so a post tagged `dogs/cats` committed fine and
 * then silently took its pet's postCount down with it. "." splits field paths,
 * and `* ~ [ ]` are rejected by the Admin SDK's path parser.
 *
 * The same set is already rejected for place-review tags in ./places.ts. Post
 * tags went through a different validator that checked only length, which is
 * how the two drifted apart.
 */
const TAG_FORBIDDEN_CHARACTERS = /[.*~/[\]]/;

/** True when this tag can safely be used as a `hashtags/{id}` document id. */
function isUsableTag(tag: string): boolean {
  return (
    tag.length > 0 &&
    tag.length <= VALIDATION_LIMITS.tag &&
    !TAG_FORBIDDEN_CHARACTERS.test(tag) &&
    // "." alone is also a relative path segment; the character class above
    // already covers it, but __.*__ is reserved by Firestore separately.
    !/^__.*__$/.test(tag)
  );
}

function normalizeTagText(tag: string): string {
  return tag.trim().toLowerCase().replace(/^#/, "");
}

/**
 * Tags as stored on a post, for the aggregation trigger.
 *
 * Unusable tags are **dropped rather than thrown on**. The trigger reads data
 * that is already committed — including posts written before the validator
 * below existed — and a tag it cannot turn into a document id must not be
 * allowed to fail the transaction that also carries the pet's postCount.
 */
function normalizeTags(tags: unknown): string[] {
  if (!Array.isArray(tags)) return [];
  return Array.from(
    new Set(
      tags
        .slice(0, VALIDATION_LIMITS.maxTags)
        .filter((tag): tag is string => typeof tag === "string")
        .map(normalizeTagText)
        .filter(isUsableTag)
    )
  );
}

/**
 * Tags on the way in, for a callable. Rejects rather than silently dropping:
 * a person who typed `dogs/cats` should be told, not have it disappear.
 */
function validateIncomingTags(tags: unknown): string[] {
  if (!Array.isArray(tags)) return [];
  const normalized = tags
    .slice(0, VALIDATION_LIMITS.maxTags)
    .filter((tag): tag is string => typeof tag === "string")
    .map(normalizeTagText)
    .filter((tag) => tag.length > 0);
  for (const tag of normalized) {
    if (tag.length > VALIDATION_LIMITS.tag) {
      throw new HttpsError(
        "invalid-argument",
        `Tags must be ${VALIDATION_LIMITS.tag} characters or fewer.`
      );
    }
    if (!isUsableTag(tag)) {
      throw new HttpsError(
        "invalid-argument",
        "Tags cannot contain . * ~ / [ ] characters."
      );
    }
  }
  return Array.from(new Set(normalized));
}

/**
 * Turns a client-supplied operation id into the post's document id.
 *
 * Publishing was not idempotent: the callable did `collection.add()`, which
 * mints a fresh random id per call. If the response to a successful call was
 * lost — a dropped connection on a phone, the tab suspended mid-request — the
 * client saw a failure, and a retry created a *second* post. Worse, the
 * client's catch also deleted the uploaded media, so the first post survived
 * pointing at assets that no longer existed.
 *
 * Deriving the document id from (caller, operation) makes the write itself the
 * idempotency record: `.create()` either writes the post or fails with
 * ALREADY_EXISTS, in which case the earlier attempt is the answer and its id
 * gets returned. No extra document, no query, no composite index, and no
 * window where two attempts can both succeed.
 *
 * The caller's uid is in the hash so one person's operation id cannot collide
 * with — or be used to squat on — another's.
 */
function postIdForOperation(callerUid: string, operationId: string): string {
  return createHash("sha256")
    .update(`${callerUid}:${operationId}`)
    .digest("hex")
    .slice(0, 24);
}

/**
 * An operation id is opaque to the server; it only has to be stable across a
 * client's retries and long enough not to collide by accident. A client that
 * sends nothing gets the old non-idempotent behaviour, so a stale tab loaded
 * before this shipped keeps working.
 */
function optionalOperationId(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", "operationId must be a string.");
  }
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length < 8 || trimmed.length > 64 || !/^[A-Za-z0-9_-]+$/.test(trimmed)) {
    throw new HttpsError(
      "invalid-argument",
      "operationId must be 8-64 characters of A-Z, a-z, 0-9, - or _."
    );
  }
  return trimmed;
}

/** How many times a repair re-reads before leaving the counter to the triggers. */
const REPAIR_ATTEMPTS = 3;

function countFieldOf(
  data: admin.firestore.DocumentData | undefined,
  field: string
): number {
  const value = data?.[field];
  return typeof value === "number" ? value : 0;
}

function getPostPetId(data: admin.firestore.DocumentData | undefined): string | null {
  return typeof data?.petId === "string" && data.petId.trim().length > 0
    ? data.petId
    : null;
}

// Applies a pet's post-count change to an already-read snapshot. Firestore
// forbids reads after writes inside a transaction, so the caller reads every
// pet up front and only then stages the updates; doing the read inside this
// helper broke as soon as a post moved between two pets.
//
// The clamp keeps the count off negative numbers. It never made the change
// idempotent, which is why the caller wraps the whole thing in runEventOnce.
function stagePetPostCountDelta(
  t: admin.firestore.Transaction,
  petSnap: admin.firestore.DocumentSnapshot,
  delta: number
): void {
  if (delta === 0 || !petSnap.exists) return;
  const current = petSnap.data()?.postCount;
  const currentCount = typeof current === "number" ? current : 0;
  t.update(petSnap.ref, {
    postCount: Math.max(0, currentCount + delta),
  });
}

/**
 * What this post has already contributed to the aggregates.
 *
 * This is the fix for out-of-order delivery. The handler used to compute a
 * delta from the *event* (before → after) and clamp the result at zero, so
 * delivering a post's delete before its create left the aggregates holding a
 * post that never existed: the early decrement clamped to 0, losing the
 * inverse, and the later increment then applied for real. Event-id
 * deduplication cannot help — those are two different events.
 *
 * Recording what was applied, on the post itself, makes the handler converge
 * instead of accumulate: each delivery moves the aggregates from "what this
 * post has contributed" to "what it should contribute", in any order, any
 * number of times.
 */
type PostContribution = {
  petId: string | null;
  tags: string[];
};

const NO_CONTRIBUTION: PostContribution = { petId: null, tags: [] };

function readContribution(
  data: admin.firestore.DocumentData | undefined
): PostContribution | null {
  const raw = data?.countedContribution;
  if (!raw || typeof raw !== "object") return null;
  const value = raw as { petId?: unknown; tags?: unknown };
  return {
    petId: typeof value.petId === "string" && value.petId ? value.petId : null,
    tags: Array.isArray(value.tags)
      ? value.tags.filter((tag): tag is string => typeof tag === "string")
      : [],
  };
}

/**
 * Applied state for a post that has no `countedContribution` field.
 *
 * Only posts written before this protocol shipped are in that position —
 * createPostCallable stamps an explicit empty contribution, so a *new* post
 * that is missing the field has genuinely not been counted yet. That
 * distinction is what makes delete-overtaking-create separable from a legacy
 * post being deleted:
 *
 * - legacy delete: no field, `before` had tags/pet, and its create ran long
 *   ago under the old handler → undo `before`, which is what the old handler
 *   would have done.
 * - new post, delete before create: the field is present and empty → undo
 *   nothing, because nothing was ever applied.
 */
function legacyContribution(
  before: admin.firestore.DocumentData | undefined
): PostContribution {
  if (!before) return NO_CONTRIBUTION;
  return { petId: getPostPetId(before), tags: normalizeTags(before.tags) };
}

function contributionOf(data: admin.firestore.DocumentData | undefined): PostContribution {
  return readContribution(data) ?? legacyContribution(data);
}

export const onPostWritten = onDocumentWritten("posts/{postId}", async (event) => {
  const postId = event.params.postId;
  const postRef = db.doc(`posts/${postId}`);
  const eventBefore = event.data?.before?.data();
  // A delete event is the one case where the live document cannot be read, so
  // its snapshot is the only record of what had been applied.
  const isDelete = event.data?.after?.exists !== true;

  await runEventOnce(event.id, async (t) => {
    // Read the *live* post, not the event snapshot. Two events for the same
    // post can arrive in either order, and the live document is the only
    // thing that says what should be true now.
    const liveSnap = isDelete ? null : await t.get(postRef);
    const live = liveSnap?.exists ? liveSnap.data() : undefined;

    // A non-delete event for a post that no longer exists has nothing to do.
    //
    // The delete event owns the undo, and it is the only event that can do it
    // correctly, because its `before` snapshot is the only record of what the
    // post had contributed. An update or create that arrives afterwards must
    // not derive a second copy of that contribution from its own stale
    // `before` and subtract it again — which is exactly what happened: two
    // counted posts, one edited then deleted, delete processed first taking
    // the count 2 → 1, then the delayed update taking it 1 → 0 with a post
    // still standing. Event-id deduplication cannot help; those are two
    // different events.
    //
    // Returning before the legacy fallback below is deliberate. That fallback
    // exists to reconstruct "what was already applied" for a post with no
    // marker, and it is right for a live document and for a delete. For an
    // event about a document that is gone it manufactures work out of
    // history.
    if (!isDelete && !live) return false;

    // The legacy fallback has to read the event's *before* snapshot, not the
    // live document: for a post with no marker, "what was already applied" is
    // its previous state, which is exactly the delta the old handler used.
    // Reading live here would make applied === desired for every legacy post
    // and silently stop counting them altogether.
    const applied = isDelete
      ? contributionOf(eventBefore)
      : readContribution(live) ?? legacyContribution(eventBefore);

    // A deleted post contributes nothing. `live` is always present on the
    // non-delete path by the guard above, so this only resolves to
    // NO_CONTRIBUTION for a delete event.
    const desired: PostContribution = live
      ? { petId: getPostPetId(live), tags: normalizeTags(live.tags) }
      : NO_CONTRIBUTION;

    const added = desired.tags.filter((tag) => !applied.tags.includes(tag));
    const removed = applied.tags.filter((tag) => !desired.tags.includes(tag));

    const petDeltas = new Map<string, number>();
    if (applied.petId) {
      petDeltas.set(applied.petId, (petDeltas.get(applied.petId) ?? 0) - 1);
    }
    if (desired.petId) {
      petDeltas.set(desired.petId, (petDeltas.get(desired.petId) ?? 0) + 1);
    }
    const petIds = [...petDeltas.keys()].filter((id) => petDeltas.get(id) !== 0);

    const contributionUnchanged =
      added.length === 0 && removed.length === 0 && petIds.length === 0;
    // Still stamp the contribution on a live post that has none: that is what
    // moves a legacy post onto this protocol without a separate write.
    if (contributionUnchanged && (isDelete || readContribution(live) !== null)) {
      return false;
    }

    // Every read first — Firestore rejects a read that follows a write in the
    // same transaction, and a post moving from one pet to another needs two.
    const [removedSnaps, petSnaps] = await Promise.all([
      Promise.all(removed.map((tag) => t.get(db.doc(`hashtags/${tag}`)))),
      Promise.all(petIds.map((petId) => t.get(db.doc(`pets/${petId}`)))),
    ]);

    petSnaps.forEach((petSnap, i) => {
      stagePetPostCountDelta(t, petSnap, petDeltas.get(petIds[i]) ?? 0);
    });

    for (const tag of added) {
      t.set(
        db.doc(`hashtags/${tag}`),
        {
          name: tag,
          postCount: admin.firestore.FieldValue.increment(1),
          lastUsed: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }

    // Decrements stay clamped reads rather than increment(-1): the old
    // merge-set with increment(-1) resurrected already-deleted tag docs as
    // nameless {postCount: -1} stubs.
    removedSnaps.forEach((snap) => {
      if (!snap.exists) return;
      const current =
        typeof snap.data()?.postCount === "number"
          ? (snap.data() as { postCount: number }).postCount
          : 0;
      const next = current - 1;
      if (next <= 0) {
        // Drop the doc entirely so trending/search never surface a
        // zero-post tag.
        t.delete(snap.ref);
      } else {
        t.update(snap.ref, {
          postCount: next,
          lastUsed: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    });

    // Record the new applied state in the same transaction as the aggregates,
    // so the two can never disagree. Nothing to record for a deleted post.
    if (live) {
      t.update(postRef, { countedContribution: desired });
    }

    return true;
  });
});

/**
 * Brings one post's aggregate contribution up to date, outside the trigger.
 *
 * Used by the admin repair callables. It is the *same* protocol the trigger
 * runs — read the applied state, apply the difference, record the new state —
 * which is the point: a repair that bypassed the contribution markers is what
 * made recompute double-count posts whose trigger had not fired yet.
 */
export async function settlePostContribution(postId: string): Promise<boolean> {
  const postRef = db.doc(`posts/${postId}`);
  return db.runTransaction(async (t) => {
    const snap = await t.get(postRef);
    if (!snap.exists) return false;
    const live = snap.data() ?? {};
    const applied = contributionOf(live);
    const desired: PostContribution = {
      petId: getPostPetId(live),
      tags: normalizeTags(live.tags),
    };

    const added = desired.tags.filter((tag) => !applied.tags.includes(tag));
    const removed = applied.tags.filter((tag) => !desired.tags.includes(tag));
    const petDeltas = new Map<string, number>();
    if (applied.petId) {
      petDeltas.set(applied.petId, (petDeltas.get(applied.petId) ?? 0) - 1);
    }
    if (desired.petId) {
      petDeltas.set(desired.petId, (petDeltas.get(desired.petId) ?? 0) + 1);
    }
    const petIds = [...petDeltas.keys()].filter((id) => petDeltas.get(id) !== 0);

    if (
      added.length === 0 &&
      removed.length === 0 &&
      petIds.length === 0 &&
      readContribution(live) !== null
    ) {
      return false;
    }

    const [removedSnaps, petSnaps] = await Promise.all([
      Promise.all(removed.map((tag) => t.get(db.doc(`hashtags/${tag}`)))),
      Promise.all(petIds.map((petId) => t.get(db.doc(`pets/${petId}`)))),
    ]);
    petSnaps.forEach((petSnap, i) => {
      stagePetPostCountDelta(t, petSnap, petDeltas.get(petIds[i]) ?? 0);
    });
    for (const tag of added) {
      t.set(
        db.doc(`hashtags/${tag}`),
        {
          name: tag,
          postCount: admin.firestore.FieldValue.increment(1),
          lastUsed: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }
    removedSnaps.forEach((snap2) => {
      if (!snap2.exists) return;
      const current =
        typeof snap2.data()?.postCount === "number"
          ? (snap2.data() as { postCount: number }).postCount
          : 0;
      const next = current - 1;
      if (next <= 0) {
        t.delete(snap2.ref);
      } else {
        t.update(snap2.ref, {
          postCount: next,
          lastUsed: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    });
    t.update(postRef, { countedContribution: desired });
    return true;
  });
}

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
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "createPost", RATE_LIMITS.write);

  const data = requestData(request.data) as {
    text?: string;
    tags?: unknown;
    media?: Array<{ url?: string; type?: "image" | "video"; thumbUrl?: string }>;
    petId?: string;
    operationId?: unknown;
  };

  const operationId = optionalOperationId(data.operationId);
  const petId = requiredDocId(data.petId, "petId");

  const petData = await getAccessiblePet(petId, callerUid);
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
        .map((item) => {
          const mediaItem: {
            url: string;
            type: "image" | "video";
            thumbUrl?: string;
          } = {
            url: optionalTrustedHttpsUrl(
              item.url,
              VALIDATION_LIMITS.url,
              "Media URL",
              TRUSTED_MEDIA_URL_HOSTS
            ),
            type: item.type,
          };
          if (item.thumbUrl) {
            mediaItem.thumbUrl = optionalTrustedHttpsUrl(
              item.thumbUrl,
              VALIDATION_LIMITS.url,
              "Media thumbnail URL",
              TRUSTED_MEDIA_URL_HOSTS
            );
          }
          return mediaItem;
        })
    : [];
  const firstMedia = media[0];
  const text = optionalTrimmedString(
    data.text,
    VALIDATION_LIMITS.postText,
    "Post text"
  );

  // stripUndefined keeps text-only posts working: when no media is attached
  // firstMedia is undefined and Firestore Admin SDK rejects undefined fields
  // unless ignoreUndefinedProperties is enabled (we don't enable it globally).
  const payload = stripUndefined({
    authorId: callerUid,
    authorName: caller.fromUserName,
    authorAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    text,
    media,
    mediaUrl: firstMedia?.url,
    mediaType: firstMedia?.type,
    petId,
    petName:
      typeof petData.name === "string" && petData.name.trim().length > 0
        ? petData.name
        : "Pet",
    petAvatarUrl:
      typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
        ? petData.avatarUrl
        : getDefaultAvatar(petId),
    tags: validateIncomingTags(data.tags),
    // Explicit "nothing counted yet". onPostWritten needs to tell a brand
    // new post apart from one written before the contribution protocol
    // existed: a missing field means legacy (already counted the old way),
    // an empty one means the aggregation trigger has not run. Without that
    // distinction a delete event overtaking the create would undo a
    // contribution that was never applied.
    countedContribution: { petId: null, tags: [] },
    likeCount: 0,
    commentCount: 0,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(operationId ? { operationId } : {}),
  });

  if (!operationId) {
    // No operation id: a client from before idempotency shipped. Keep the old
    // behaviour rather than refusing to publish for it.
    const result = await db.collection("posts").add(payload);
    return { id: result.id, deduplicated: false };
  }

  const postRef = db.doc(`posts/${postIdForOperation(callerUid, operationId)}`);
  try {
    await postRef.create(payload);
    return { id: postRef.id, deduplicated: false };
  } catch (error) {
    if ((error as { code?: number | string } | null)?.code !== 6 /* ALREADY_EXISTS */) {
      throw error;
    }
  }

  // This operation already published. Returning the existing post — rather
  // than an error — is what makes a retry after a lost response safe: the
  // client gets the same answer it missed, and its media stays referenced.
  const existing = await postRef.get();
  if (existing.data()?.authorId !== callerUid) {
    // Cannot happen while the id is derived from the caller's own uid, and is
    // checked anyway: returning somebody else's post here would be a leak.
    throw new HttpsError("already-exists", "That operation id is already in use.");
  }
  return { id: postRef.id, deduplicated: true };
});

/**
 * Did this operation id produce a post?
 *
 * The composer needs a truthful answer before it reclaims uploaded media. A
 * publish that commits and then loses its response is indistinguishable, from
 * the client's side, from one that never happened — and the client used to
 * resolve that ambiguity by deleting the assets, which is the one choice that
 * cannot be undone if it guessed wrong.
 *
 * Read-only, and scoped to the caller by construction: the document id is
 * derived from their own uid, so this cannot be used to probe anybody else's
 * posts. The authorId is checked anyway.
 */
export const getPublishStatusCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  await assertRateLimit(callerUid, "getPublishStatus", RATE_LIMITS.read);

  const data = requestData(request.data) as { operationId?: unknown };
  const operationId = optionalOperationId(data.operationId);
  if (!operationId) {
    throw new HttpsError("invalid-argument", "operationId is required.");
  }

  const postId = postIdForOperation(callerUid, operationId);
  const snap = await db.doc(`posts/${postId}`).get();
  const published = snap.exists && snap.data()?.authorId === callerUid;
  return published ? { published: true, postId } : { published: false };
});

export const updatePostCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot edit posts.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "updatePost", RATE_LIMITS.write);
  const data = requestData(request.data) as {
    postId?: string;
    text?: string;
    tags?: unknown;
    petId?: string | null;
  };

  const postId = requiredDocId(data.postId, "postId");

  const postRef = db.doc(`posts/${postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) {
    throw new HttpsError("not-found", "Post not found.");
  }

  const postData = postSnap.data() ?? {};
  if (postData.authorId !== callerUid && caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Cannot edit this post.");
  }

  // Field-preserving update: only overwrite a field when the request explicitly
  // includes it. Previously we always wrote text and tags, which clobbered
  // existing values whenever the caller wanted to change petId only.
  const updates: Record<string, unknown> = {};

  if ("text" in data) {
    updates.text = optionalTrimmedString(
      data.text,
      VALIDATION_LIMITS.postText,
      "Post text"
    );
  }
  if ("tags" in data) {
    updates.tags = validateIncomingTags(data.tags);
  }

  if ("petId" in data) {
    if (data.petId === null || data.petId === "") {
      // Posts must stay linked to a pet — reject clearing the association.
      throw new HttpsError("invalid-argument", "Posts must be linked to a pet.");
    } else if (typeof data.petId === "string") {
      const newPetId = requiredDocId(data.petId, "petId");
      const petData = await getAccessiblePet(newPetId, callerUid);
      if (!petData) {
        throw new HttpsError("permission-denied", "You do not have access to this pet.");
      }
      updates.petId = newPetId;
      updates.petName =
        typeof petData.name === "string" && petData.name.trim().length > 0
          ? petData.name
          : "Pet";
      updates.petAvatarUrl =
        typeof petData.avatarUrl === "string" && petData.avatarUrl.trim().length > 0
          ? petData.avatarUrl
          : getDefaultAvatar(newPetId);
    } else {
      throw new HttpsError("invalid-argument", "Invalid petId.");
    }
  }

  if (Object.keys(updates).length === 0) {
    throw new HttpsError("invalid-argument", "No supported fields to update.");
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
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "setPinnedPost", RATE_LIMITS.write);

  const { postId } = requestData(request.data) as { postId?: string | null };
  const userRef = db.doc(`users/${callerUid}`);

  // postId === null or missing means "unpin"
  if (postId === null || postId === undefined || postId === "") {
    await userRef.set(
      { pinnedPostId: admin.firestore.FieldValue.delete() },
      { merge: true }
    );
    return { success: true };
  }

  const validatedPostId = requiredDocId(postId, "postId");

  const postSnap = await db.doc(`posts/${validatedPostId}`).get();
  if (!postSnap.exists) {
    throw new HttpsError("not-found", "Post not found.");
  }
  const postData = postSnap.data() ?? {};
  if (postData.authorId !== callerUid) {
    throw new HttpsError("permission-denied", "You can only pin your own posts.");
  }

  await userRef.set({ pinnedPostId: validatedPostId }, { merge: true });
  return { success: true };
});

export const deletePostCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot delete posts.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "deletePost", RATE_LIMITS.write);

  const { postId: rawDeletePostId } = requestData(request.data) as {
    postId?: string;
  };
  const postId = requiredDocId(rawDeletePostId, "postId");

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
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "createComment", RATE_LIMITS.write);

  const data = requestData(request.data) as {
    postId?: string;
    text?: string;
    replyToCommentId?: string;
  };

  const postId = requiredDocId(data.postId, "postId");

  const postRef = db.doc(`posts/${postId}`);
  const postSnap = await postRef.get();
  if (!postSnap.exists) {
    throw new HttpsError("not-found", "Post not found.");
  }

  // Commenting is an interaction with the post's author, so a block between
  // the two of them stops it here rather than only in the reader's own feed
  // filter. See ./blocking.ts for why the pair is the two humans and not the
  // pet's whole family.
  const postAuthorId = postSnap.data()?.authorId;
  if (typeof postAuthorId === "string" && postAuthorId) {
    await assertNoBlockBetween(callerUid, postAuthorId, "Commenting");
  }

  let replyTo:
    | {
        commentId: string;
        authorName: string;
      }
    | undefined;

  if (data.replyToCommentId) {
    const replyToCommentId = requiredDocId(
      data.replyToCommentId,
      "replyToCommentId"
    );
    const replyRef = db.doc(`posts/${postId}/comments/${replyToCommentId}`);
    const replySnap = await replyRef.get();
    if (!replySnap.exists) {
      throw new HttpsError("not-found", "Reply target not found.");
    }
    const replyData = replySnap.data() ?? {};
    // A reply notifies the comment's author directly, which makes it the same
    // kind of interaction as commenting on their post.
    if (typeof replyData.authorId === "string" && replyData.authorId) {
      await assertNoBlockBetween(callerUid, replyData.authorId, "Replying");
    }
    replyTo = {
      commentId: replyToCommentId,
      authorName:
        typeof replyData.authorName === "string" && replyData.authorName.trim().length > 0
          ? replyData.authorName
          : "PetNote User",
    };
  }

  const commentRef = db.collection(`posts/${postId}/comments`).doc();
  const text = requiredCommentText(data.text);
  await commentRef.set({
    authorId: callerUid,
    authorName: caller.fromUserName,
    authorAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
    text,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    // onCommentCreated flips this to true in the same transaction as the
    // commentCount increment. Until then the comment is not counted, so a
    // delete that overtakes the create knows to leave the count alone.
    counted: false,
    ...(replyTo ? { replyTo } : {}),
  });

  return { id: commentRef.id };
});

function requiredCommentText(value: unknown): string {
  const text = optionalTrimmedString(
    value,
    VALIDATION_LIMITS.commentText,
    "Comment text"
  );
  if (!text) {
    throw new HttpsError("invalid-argument", "Comment text is required.");
  }
  return text;
}

export const deleteCommentCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot delete comments.");
  }
  await assertCallerAccountActive(callerUid, caller);
  await assertRateLimit(callerUid, "deleteComment", RATE_LIMITS.write);

  const { postId: rawCommentPostId, commentId: rawCommentId } = requestData(
    request.data
  ) as {
    postId?: string;
    commentId?: string;
  };
  const postId = requiredDocId(rawCommentPostId, "postId");
  const commentId = requiredDocId(rawCommentId, "commentId");

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

// Admin-only: recompute pet.postCount from posts.where(petId == petId)
// using a server-side count() aggregate. Use to repair drift after a
// missed onPostWritten increment (the trigger swallows certain errors
// to keep post creation flowing — see applyPetPostCountDelta).
export const recomputePetPostCountCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  const caller = await getNotificationActor(callerUid);
  if (caller.role !== "admin") {
    throw new HttpsError("permission-denied", "Only admins can recompute pet post counts.");
  }
  await assertRateLimit(callerUid, "recomputePetPostCount", RATE_LIMITS.write);

  const { petId: rawRecomputePetId } = requestData(request.data) as {
    petId?: string;
  };
  const petId = requiredDocId(rawRecomputePetId, "petId");

  const petRef = db.doc(`pets/${petId}`);
  const petSnap = await petRef.get();
  if (!petSnap.exists) {
    throw new HttpsError("not-found", "Pet not found.");
  }

  // Settle every one of this pet's posts through the contribution protocol
  // *before* taking an absolute count.
  //
  // This is the ordering the previous version got wrong. It went straight to
  // count(), which counts posts whose aggregation trigger has not run yet — so
  // the repair wrote a total that already included them, and then their
  // pending trigger incremented on top of it. One pending post meant a count
  // one too high, permanently. Settling first means every post's marker says
  // "counted", so a later (re)delivery is a no-op and the absolute count is
  // the truth rather than a race.
  //
  // Bounded by the pet's own post count, which is what a per-pet repair costs
  // by nature. Paged so a prolific pet does not load in one go.
  let settled = 0;
  let cursor: admin.firestore.QueryDocumentSnapshot | null = null;
  for (;;) {
    let page: admin.firestore.Query = db
      .collection("posts")
      .where("petId", "==", petId)
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(200);
    if (cursor) page = page.startAfter(cursor);
    const snap = await page.get();
    if (snap.empty) break;
    for (const docSnap of snap.docs) {
      if (await settlePostContribution(docSnap.id)) settled += 1;
    }
    if (snap.size < 200) break;
    cursor = snap.docs[snap.docs.length - 1];
  }

  // Compare-and-set, same reason as the interaction repair above: settling the
  // contributions is transactional per post, but the absolute count that
  // follows is not, so a post whose trigger lands in between would have its
  // increment overwritten.
  for (let attempt = 0; attempt < REPAIR_ATTEMPTS; attempt += 1) {
    const observed = await petRef.get();
    if (!observed.exists) {
      throw new HttpsError("not-found", "Pet not found.");
    }
    const observedCount = countFieldOf(observed.data(), "postCount");

    const aggSnap = await db
      .collection("posts")
      .where("petId", "==", petId)
      .count()
      .get();
    const postCount = aggSnap.data().count;

    const applied = await db.runTransaction(async (t) => {
      const snap = await t.get(petRef);
      if (!snap.exists) return "gone" as const;
      if (countFieldOf(snap.data(), "postCount") !== observedCount) {
        return "changed" as const;
      }
      t.update(petRef, { postCount });
      return "written" as const;
    });

    if (applied === "gone") {
      throw new HttpsError("not-found", "Pet not found.");
    }
    if (applied === "written") {
      return { success: true, postCount, settled, converged: true };
    }
  }

  const current = await petRef.get();
  return {
    success: true,
    postCount: countFieldOf(current.data(), "postCount"),
    settled,
    converged: false,
  };
});

// Admin-only: recompute likeCount and commentCount on a single post from
// its subcollection sizes. Repairs drift from missed onLikeCreated /
// onCommentCreated triggers (e.g. event delivery failures), and backfills
// posts that never had those fields written in the first place.
export const recomputePostInteractionCountsCallable = onCall(
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Must be logged in.");
    }
    const caller = await getNotificationActor(callerUid);
    if (caller.role !== "admin") {
      throw new HttpsError(
        "permission-denied",
        "Only admins can recompute post interaction counts."
      );
    }
    await assertRateLimit(
      callerUid,
      "recomputePostInteractionCounts",
      RATE_LIMITS.write
    );

    const { postId: rawInteractPostId } = requestData(request.data) as {
      postId?: string;
    };
    const postId = requiredDocId(rawInteractPostId, "postId");

    const postRef = db.doc(`posts/${postId}`);
    const postSnap = await postRef.get();
    if (!postSnap.exists) {
      throw new HttpsError("not-found", "Post not found.");
    }

    // Subtract the documents whose contribution has not been applied yet, and
    // only write if the stored value has not moved since it was observed.
    //
    // The counter's meaning is "how many likes/comments have been folded in",
    // and the create triggers are what fold them in — each flips its own
    // `counted` marker in the same transaction as the increment. A plain
    // count() therefore over-reports: it includes documents still waiting for
    // their trigger, whose increment is still to come.
    //
    // Subtracting the pending set fixes that, but an *absolute* write still
    // loses any increment that lands between the aggregates and the write.
    // Measured in the emulator: two counted likes plus one pending, the
    // trigger commits 2 → 3, the repair then writes its observed 2, and the
    // post is permanently one short. So the write is a compare-and-set against
    // the value read before the aggregates; if a trigger moved it, the repair
    // starts over with fresh counts. Aggregate queries cannot run inside a
    // transaction, which is why this is a retry loop rather than one.
    //
    // Giving up after a few attempts is safe: not writing leaves whatever the
    // triggers produced, and the triggers are the only other writer.
    for (let attempt = 0; attempt < REPAIR_ATTEMPTS; attempt += 1) {
      const observed = await postRef.get();
      if (!observed.exists) {
        throw new HttpsError("not-found", "Post not found.");
      }
      const observedLike = countFieldOf(observed.data(), "likeCount");
      const observedComment = countFieldOf(observed.data(), "commentCount");

      const [likeAgg, commentAgg, pendingLikeAgg, pendingCommentAgg] =
        await Promise.all([
          db.collection(`posts/${postId}/likes`).count().get(),
          db.collection(`posts/${postId}/comments`).count().get(),
          // `counted == false` is the pending set. A document with no
          // `counted` field predates the marker and counts as already
          // applied — the same reading as wasCountedAtCreate in ./shared.ts.
          db
            .collection(`posts/${postId}/likes`)
            .where("counted", "==", false)
            .count()
            .get(),
          db
            .collection(`posts/${postId}/comments`)
            .where("counted", "==", false)
            .count()
            .get(),
        ]);
      const pendingLikes = pendingLikeAgg.data().count;
      const pendingComments = pendingCommentAgg.data().count;
      const likeCount = Math.max(0, likeAgg.data().count - pendingLikes);
      const commentCount = Math.max(
        0,
        commentAgg.data().count - pendingComments
      );

      const applied = await db.runTransaction(async (t) => {
        const snap = await t.get(postRef);
        if (!snap.exists) return "gone" as const;
        if (
          countFieldOf(snap.data(), "likeCount") !== observedLike ||
          countFieldOf(snap.data(), "commentCount") !== observedComment
        ) {
          return "changed" as const;
        }
        t.update(postRef, { likeCount, commentCount });
        return "written" as const;
      });

      if (applied === "gone") {
        throw new HttpsError("not-found", "Post not found.");
      }
      if (applied === "written") {
        return {
          success: true,
          likeCount,
          commentCount,
          pendingLikes,
          pendingComments,
          converged: true,
        };
      }
    }

    // Still moving after several attempts. Reporting it rather than forcing a
    // value keeps the counter under the triggers' control, which is where it
    // belongs while they are active.
    const current = await postRef.get();
    return {
      success: true,
      likeCount: countFieldOf(current.data(), "likeCount"),
      commentCount: countFieldOf(current.data(), "commentCount"),
      pendingLikes: 0,
      pendingComments: 0,
      converged: false,
    };
  }
);
