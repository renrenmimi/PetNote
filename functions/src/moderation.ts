import { onCall, HttpsError } from "firebase-functions/v2/https";
import { admin, db } from "./platform";
import { assertActorNotDeleting, getNotificationActor } from "./notifications";
import {
  assertRateLimit,
  getDefaultAvatar,
  optionalTrimmedString,
  RATE_LIMITS,
  requestData,
  requiredDocId,
  requiredTrimmedString,
  VALIDATION_LIMITS,
} from "./shared";

export const reportContentCallable = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Must be logged in.");

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot submit reports.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "reportContent", RATE_LIMITS.strictWrite);

  const data = requestData(request.data) as {
    targetType?: "post" | "comment" | "user";
    targetId?: string;
    postId?: string;
    reason?: string;
    description?: string;
  };
  if (!data.targetType || !["post", "comment", "user"].includes(data.targetType)) {
    throw new HttpsError("invalid-argument", "Invalid targetType.");
  }
  // requiredDocId rejects "/" and other characters that would let a
  // crafted targetId silently retarget the report doc to a sibling
  // collection — Firestore's path parser splits on slash, so
  // "abc/likes/xyz" would write to reports/abc/likes/xyz instead of
  // reports/{callerUid}_{type}_abc/likes/xyz.
  const targetId = requiredDocId(data.targetId, "targetId");

  // Comment reports must carry their parent postId: every admin resolution
  // path (preview, delete-and-warn, target-user lookup) locates the comment
  // at posts/{postId}/comments/{targetId}. Verify the comment actually
  // exists there so a forged postId can't point moderation at unrelated
  // content.
  let commentPostId: string | undefined;
  if (data.targetType === "comment") {
    if (data.postId === undefined) {
      throw new HttpsError(
        "invalid-argument",
        "Comment reports require the parent postId."
      );
    }
    commentPostId = requiredDocId(data.postId, "postId");
    const commentSnap = await db
      .doc(`posts/${commentPostId}/comments/${targetId}`)
      .get();
    if (!commentSnap.exists) {
      throw new HttpsError("not-found", "Reported comment not found.");
    }
  }
  const reason = requiredTrimmedString(
    data.reason,
    VALIDATION_LIMITS.reportReason,
    "Report reason"
  );
  const description = optionalTrimmedString(
    data.description,
    VALIDATION_LIMITS.reportDescription,
    "Report description"
  );

  // Deterministic id == one report per (reporter, targetType, target). Any
  // replay or button-mash is silently deduped by Firestore rejecting the
  // second .create() with ALREADY_EXISTS. This also gives admins a stable
  // identifier per reporter/target pair.
  const reportId = `${callerUid}_${data.targetType}_${targetId}`;
  const reportRef = db.doc(`reports/${reportId}`);

  try {
    await reportRef.create({
      reporterId: callerUid,
      reporterName: caller.fromUserName,
      reporterAvatar: caller.fromUserAvatar || getDefaultAvatar(callerUid),
      targetType: data.targetType,
      targetId,
      ...(commentPostId ? { postId: commentPostId } : {}),
      reason,
      description,
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

  const caller = await getNotificationActor(callerUid);
  if (caller.banned === true) {
    throw new HttpsError("permission-denied", "Banned users cannot submit feedback.");
  }
  assertActorNotDeleting(caller);
  await assertRateLimit(callerUid, "submitFeedback", RATE_LIMITS.strictWrite);

  const data = requestData(request.data) as {
    type?: "bug" | "feature" | "complaint" | "other";
    subject?: string;
    message?: string;
  };
  if (!data.type || !["bug", "feature", "complaint", "other"].includes(data.type)) {
    throw new HttpsError("invalid-argument", "Invalid feedback type.");
  }
  const subject = requiredTrimmedString(
    data.subject,
    VALIDATION_LIMITS.feedbackSubject,
    "Feedback subject"
  );
  const message = requiredTrimmedString(
    data.message,
    VALIDATION_LIMITS.feedbackMessage,
    "Feedback message"
  );

  const result = await db.collection("feedback").add({
    userId: callerUid,
    userName: caller.fromUserName,
    userEmail: typeof callerAuth.token.email === "string" ? callerAuth.token.email : "",
    type: data.type,
    subject,
    message,
    status: "new",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { id: result.id };
});
