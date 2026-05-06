import { createHash, randomInt } from "node:crypto";
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
import {
  assertRateLimit,
  batchChunked,
  forEachQueryDocumentInBatches,
  FIRESTORE_BATCH_LIMIT,
  getDefaultAvatar,
  requestData,
  stripUndefined,
  optionalTrustedHttpsUrl,
  RATE_LIMITS,
  TRUSTED_AVATAR_URL_HOSTS,
  VALIDATION_LIMITS,
} from "./shared";

function normalizeDisplayName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length < 2 || trimmed.length > VALIDATION_LIMITS.displayName) {
    throw new HttpsError("invalid-argument", "Display name must be 2-30 characters.");
  }
  return trimmed;
}

function normalizeBio(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", "Bio must be a string.");
  }
  const trimmed = value.trim();
  if (trimmed.length > VALIDATION_LIMITS.bio) {
    throw new HttpsError("invalid-argument", "Bio must be 150 characters or fewer.");
  }
  return trimmed;
}

function normalizeAvatarUrl(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  return (
    optionalTrustedHttpsUrl(
      value,
      VALIDATION_LIMITS.url,
      "Avatar URL",
      TRUSTED_AVATAR_URL_HOSTS
    ) || undefined
  );
}

function usernameKey(displayNameLower: string): string {
  return createHash("sha256").update(displayNameLower).digest("hex");
}

function usernameRef(displayNameLower: string): admin.firestore.DocumentReference {
  return db.doc(`usernames/${usernameKey(displayNameLower)}`);
}

async function assertDisplayNameAvailable(
  transaction: admin.firestore.Transaction,
  displayNameLower: string,
  callerUid: string
): Promise<admin.firestore.DocumentReference> {
  const reservationRef = usernameRef(displayNameLower);
  const reservationSnap = await transaction.get(reservationRef);
  if (
    reservationSnap.exists &&
    reservationSnap.data()?.userId !== callerUid
  ) {
    throw new HttpsError("already-exists", "Display name is already taken.");
  }

  // Backward-compatible guard for users created before /usernames reservations.
  const existingUsersSnap = await transaction.get(
    db.collection("users").where("displayNameLower", "==", displayNameLower).limit(2)
  );
  const conflictingUser = existingUsersSnap.docs.find((docSnap) => docSnap.id !== callerUid);
  if (conflictingUser) {
    throw new HttpsError("already-exists", "Display name is already taken.");
  }

  return reservationRef;
}

function defaultDisplayName(userId: string): string {
  return `petnote_${userId.slice(0, 8)}`;
}

function withNumericSuffix(base: string): string {
  const suffix = String(randomInt(1000, 10000));
  return `${base.slice(0, VALIDATION_LIMITS.displayName - suffix.length)}${suffix}`;
}

export const onUserUpdated = onDocumentWritten(
  {
    document: "users/{userId}",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async (event) => {
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
      if (Object.keys(fields).length === 0) return;
      const orderedQuery: admin.firestore.Query = collectionQuery.orderBy(
        admin.firestore.FieldPath.documentId()
      );
      let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;
      while (true) {
        const pageQuery: admin.firestore.Query = lastDoc
          ? orderedQuery.startAfter(lastDoc).limit(FIRESTORE_BATCH_LIMIT)
          : orderedQuery.limit(FIRESTORE_BATCH_LIMIT);
        const snap: admin.firestore.QuerySnapshot = await pageQuery.get();
        if (snap.empty) return;
        await batchChunked(snap.docs, (batch, doc) => {
          batch.update(doc.ref, fields);
        });
        lastDoc = snap.docs[snap.docs.length - 1];
        if (snap.size < FIRESTORE_BATCH_LIMIT) return;
      }
    };

    const postFields: Record<string, string> = {};
    if (nameChanged) postFields.authorName = after.displayName;
    if (avatarChanged) postFields.authorAvatar = after.avatarUrl;

    const commentFields: Record<string, string> = {};
    if (nameChanged) commentFields.authorName = after.displayName;
    if (avatarChanged) commentFields.authorAvatar = after.avatarUrl;

    const notifFields: Record<string, string> = {};
    if (nameChanged) notifFields.fromUserName = after.displayName;
    if (avatarChanged) notifFields.fromUserAvatar = after.avatarUrl;

    const partFields: Record<string, string> = {};
    if (nameChanged) partFields.userName = after.displayName;
    if (avatarChanged) partFields.userAvatar = after.avatarUrl;

    const reviewFields: Record<string, string> = {};
    if (nameChanged) reviewFields.userName = after.displayName;
    if (avatarChanged) reviewFields.userAvatar = after.avatarUrl;

    const familyFields: Record<string, string> = {};
    if (nameChanged) familyFields.userName = after.displayName;
    if (avatarChanged) familyFields.userAvatar = after.avatarUrl;

    const syncTasks: Array<[string, () => Promise<void>]> = [
      ["posts", () => syncCollection(db.collection("posts").where("authorId", "==", userId), postFields)],
      ["comments", () => syncCollection(db.collectionGroup("comments").where("authorId", "==", userId), commentFields)],
      ["notifications", () => syncCollection(db.collection("notifications").where("fromUserId", "==", userId), notifFields)],
      ["participants", () => syncCollection(db.collectionGroup("participants").where("userId", "==", userId), partFields)],
      ["reviews", () => syncCollection(db.collectionGroup("reviews").where("userId", "==", userId), reviewFields)],
      ["family", () => syncCollection(db.collectionGroup("family").where("userId", "==", userId), familyFields)],
    ];

    const syncFailures = await Promise.all(
      syncTasks.map(async ([label, task]) => {
        try {
          await task();
          return null;
        } catch (error) {
          console.error(`onUserUpdated sync failed for ${label}`, error);
          return label;
        }
      })
    );
    const failedLabels = syncFailures.filter(
      (label): label is string => typeof label === "string"
    );
    if (failedLabels.length > 0) {
      throw new Error(`onUserUpdated sync failed for: ${failedLabels.join(", ")}`);
    }
  }
);

// Sync admin/banned to Auth custom claims so firestore.rules can short-
// circuit cheap token-claim checks (admin == true, banned == true) ahead
// of the existing get(/admin/state) reads. Custom claims are eventually
// consistent — they only land on the user's NEXT id token, up to 1h
// later — so callables continue to read Firestore directly via
// getNotificationActor for time-critical authorization. Rules combine
// both: positive token claim trusted, negative/missing falls back to
// Firestore.
export const onAdminStateWritten = onDocumentWritten(
  "users/{userId}/admin/state",
  async (event) => {
    const userId = event.params.userId;
    const after = event.data?.after?.data();

    const isAdmin = after?.role === "admin";
    const isBanned = after?.banned === true;

    // setCustomUserClaims overwrites the entire claims object, so any
    // future per-user claims must be merged in here too. Keep this list
    // exhaustive — silently dropping a claim is a security regression.
    const claims: Record<string, unknown> = {};
    if (isAdmin) claims.admin = true;
    if (isBanned) claims.banned = true;

    try {
      await admin
        .auth()
        .setCustomUserClaims(userId, Object.keys(claims).length > 0 ? claims : null);
    } catch (error) {
      // Auth user might not exist yet (admin/state created before Auth
      // record) or might already have been deleted. Don't fail the trigger
      // — Firestore read fallback in rules still enforces the policy.
      console.warn("Failed to sync admin custom claims", { userId, error });
    }
  }
);

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

export const ensureUserProfileCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  await assertRateLimit(callerUid, "ensureUserProfile", RATE_LIMITS.strictWrite);

  const data = requestData(request.data);
  const requestedName = normalizeDisplayName(data.displayName);
  const baseName = requestedName ?? defaultDisplayName(callerUid);
  const avatarUrl = normalizeAvatarUrl(data.avatarUrl) ?? getDefaultAvatar(callerUid);
  const bio = normalizeBio(data.bio) ?? "";
  const onboardingComplete =
    typeof data.onboardingComplete === "boolean" ? data.onboardingComplete : false;

  for (let attempt = 0; attempt < 6; attempt += 1) {
    const displayName = attempt === 0 ? baseName : withNumericSuffix(baseName);
    const displayNameLower = displayName.toLowerCase();
    try {
      const result = await db.runTransaction(async (transaction) => {
        const userRef = db.doc(`users/${callerUid}`);
        const userSnap = await transaction.get(userRef);
        if (userSnap.exists) {
          const existing = userSnap.data() ?? {};
          return {
            displayName:
              typeof existing.displayName === "string" && existing.displayName.trim()
                ? existing.displayName
                : displayName,
            avatarUrl:
              typeof existing.avatarUrl === "string" && existing.avatarUrl.trim()
                ? existing.avatarUrl
                : avatarUrl,
          };
        }

        const reservationRef = await assertDisplayNameAvailable(
          transaction,
          displayNameLower,
          callerUid
        );

        transaction.set(reservationRef, {
          userId: callerUid,
          displayName,
          displayNameLower,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        transaction.set(userRef, {
          displayName,
          displayNameLower,
          avatarUrl,
          bio,
          onboardingComplete,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { displayName, avatarUrl };
      });

      await admin.auth().updateUser(callerUid, {
        displayName: result.displayName,
        photoURL: result.avatarUrl,
      });
      return result;
    } catch (error) {
      if (error instanceof HttpsError && error.code === "already-exists") {
        if (attempt === 5) {
          throw error;
        }
        continue;
      }
      throw error;
    }
  }

  throw new HttpsError("resource-exhausted", "Could not create a unique profile.");
});

export const checkDisplayNameAvailabilityCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  await assertRateLimit(
    callerUid,
    "checkDisplayNameAvailability",
    RATE_LIMITS.read
  );

  const data = requestData(request.data);
  const displayName = normalizeDisplayName(data.displayName);
  if (!displayName) {
    throw new HttpsError("invalid-argument", "Display name is required.");
  }

  const displayNameLower = displayName.toLowerCase();
  const [reservationSnap, existingUsersSnap] = await Promise.all([
    usernameRef(displayNameLower).get(),
    db.collection("users").where("displayNameLower", "==", displayNameLower).limit(2).get(),
  ]);
  const reservedByOther =
    reservationSnap.exists && reservationSnap.data()?.userId !== callerUid;
  const usedByOther = existingUsersSnap.docs.some((docSnap) => docSnap.id !== callerUid);
  const taken = reservedByOther || usedByOther;

  return { available: !taken, taken };
});

export const updateUserProfileCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot update profiles.");
  }
  await assertRateLimit(callerUid, "updateUserProfile", RATE_LIMITS.write);

  const data = requestData(request.data);
  const displayName =
    "displayName" in data ? normalizeDisplayName(data.displayName) : undefined;
  const avatarUrl =
    "avatarUrl" in data ? normalizeAvatarUrl(data.avatarUrl) : undefined;
  const bio = "bio" in data ? normalizeBio(data.bio) : undefined;
  if (displayName === undefined && avatarUrl === undefined && bio === undefined) {
    throw new HttpsError("invalid-argument", "No profile fields to update.");
  }

  await db.runTransaction(async (transaction) => {
    const userRef = db.doc(`users/${callerUid}`);
    const userSnap = await transaction.get(userRef);
    const current = userSnap.exists ? userSnap.data() ?? {} : {};
    const update: Record<string, unknown> = {};

    if (displayName !== undefined) {
      const displayNameLower = displayName.toLowerCase();
      const nextReservationRef = await assertDisplayNameAvailable(
        transaction,
        displayNameLower,
        callerUid
      );

      const previousLower =
        typeof current.displayNameLower === "string" ? current.displayNameLower : "";
      if (previousLower && previousLower !== displayNameLower) {
        transaction.delete(usernameRef(previousLower));
      }

      transaction.set(nextReservationRef, {
        userId: callerUid,
        displayName,
        displayNameLower,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      update.displayName = displayName;
      update.displayNameLower = displayNameLower;
    }
    if (avatarUrl !== undefined) update.avatarUrl = avatarUrl;
    if (bio !== undefined) update.bio = bio;

    transaction.set(
      userRef,
      stripUndefined({
        ...update,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(userSnap.exists ? {} : { createdAt: admin.firestore.FieldValue.serverTimestamp() }),
      }),
      { merge: true }
    );
  });

  // Only hit Auth when something Auth-visible actually changed. Bio-only
  // edits don't need to touch Auth, and updateUser({}) is a wasted RPC.
  if (displayName !== undefined || avatarUrl !== undefined) {
    await admin.auth().updateUser(
      callerUid,
      stripUndefined({
        displayName,
        photoURL: avatarUrl,
      })
    );
  }

  return { success: true };
});

// Account deletion can take a while for heavy accounts. Allow up to nine
// minutes so large cascades finish in a single run; the function is still
// idempotent and safe to retry if it times out.
export const deleteUserAccount = onCall({ timeoutSeconds: 540 }, async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }

  const { userId } = requestData(request.data) as { userId?: string };
  if (!userId || typeof userId !== "string") {
    throw new HttpsError("invalid-argument", "Missing userId.");
  }
  if (callerUid !== userId) {
    throw new HttpsError("permission-denied", "Can only delete your own account.");
  }
  await assertRateLimit(callerUid, "deleteUserAccount", RATE_LIMITS.accountDeletion);

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
    await forEachQueryDocumentInBatches(
      db.collection("posts").where("authorId", "==", userId),
      async (docSnap) => {
        await cascadeDeletePost(docSnap.id);
      }
    );
  });

  await runStep("pets", async () => {
    await forEachQueryDocumentInBatches(
      db.collection("pets").where("ownerId", "==", userId),
      async (docSnap) => {
        await cascadeDeletePet(docSnap.id);
      }
    );
  });

  await runStep("meetups", async () => {
    await forEachQueryDocumentInBatches(
      db.collection("meetups").where("organizerId", "==", userId),
      async (docSnap) => {
        await cascadeDeleteMeetup(docSnap.id);
      }
    );
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

  await db.runTransaction(async (transaction) => {
    const userSnap = await transaction.get(userRef);
    const displayNameLower =
      typeof userSnap.data()?.displayNameLower === "string"
        ? (userSnap.data() as { displayNameLower: string }).displayNameLower
        : "";

    if (displayNameLower) {
      const reservationRef = usernameRef(displayNameLower);
      const reservationSnap = await transaction.get(reservationRef);
      if (reservationSnap.exists && reservationSnap.data()?.userId === userId) {
        transaction.delete(reservationRef);
      }
    }
    transaction.delete(userRef);
  }).catch((error) => {
    console.error("deleteUserAccount: final user cleanup failed", error);
    throw new HttpsError("internal", "Failed to finalize account deletion; please retry.");
  });

  return { success: true };
});
