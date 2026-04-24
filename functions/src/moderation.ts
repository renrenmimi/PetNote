import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { getNotificationActor } from "./notifications";
import { getDefaultAvatar } from "./shared";

export const reportContentCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot submit reports.");
  }

  const data = request.data as {
    targetType?: "post" | "comment" | "user";
    targetId?: string;
    reason?: string;
    description?: string;
  };
  if (!data.targetType || !["post", "comment", "user"].includes(data.targetType)) {
    throw new HttpsError("invalid-argument", "Invalid targetType.");
  }
  if (!data.targetId || typeof data.targetId !== "string") {
    throw new HttpsError("invalid-argument", "Missing targetId.");
  }
  if (!data.reason || typeof data.reason !== "string" || data.reason.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Missing report reason.");
  }

  // Deterministic id == one report per (reporter, targetType, target). Any
  // replay or button-mash is silently deduped by Firestore rejecting the
  // second .create() with ALREADY_EXISTS. This also gives admins a stable
  // identifier per reporter/target pair.
  const reportId = `${callerUid}_${data.targetType}_${data.targetId}`;
  const reportRef = db.doc(`reports/${reportId}`);

  try {
    await reportRef.create({
      reporterId: callerUid,
      reporterName: caller.fromUserName,
      reporterAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      targetType: data.targetType,
      targetId: data.targetId,
      reason: data.reason.trim(),
      description: typeof data.description === "string" ? data.description.trim() : "",
      status: "pending",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      (error as { code?: number | string }).code === 6
    ) {
      throw new HttpsError(
        "already-exists",
        "You have already reported this content."
      );
    }
    throw error;
  }

  return { id: reportId };
});

export const submitFeedbackCallable = onCall(async (request) => {
  const callerAuth = request.auth;
  const callerUid = callerAuth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const data = request.data as {
    type?: "bug" | "feature" | "complaint" | "other";
    subject?: string;
    message?: string;
  };
  if (!data.type || !["bug", "feature", "complaint", "other"].includes(data.type)) {
    throw new HttpsError("invalid-argument", "Invalid feedback type.");
  }
  if (!data.subject || typeof data.subject !== "string" || data.subject.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Missing subject.");
  }
  if (!data.message || typeof data.message !== "string" || data.message.trim().length === 0) {
    throw new HttpsError("invalid-argument", "Missing feedback message.");
  }

  const caller = await getNotificationActor(callerUid);
  const result = await db.collection("feedback").add({
    userId: callerUid,
    userName: caller.fromUserName,
    userEmail: typeof callerAuth.token.email === "string" ? callerAuth.token.email : "",
    type: data.type,
    subject: data.subject.trim(),
    message: data.message.trim(),
    status: "new",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: result.id };
});
