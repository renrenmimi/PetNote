import { createHash } from "node:crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  CLOUDINARY_API_KEY,
  CLOUDINARY_API_SECRET,
  CLOUDINARY_CLOUD_NAME,
  CLOUDINARY_FOLDER,
} from "./platform";
import { assertActorNotDeleting, getNotificationActor } from "./notifications";
import { assertRateLimit, RATE_LIMITS, requestData } from "./shared";

function signCloudinaryParams(params: Record<string, string>, apiSecret: string): string {
  const paramsToSign = Object.entries(params)
    .filter(([, value]) => value.length > 0)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}=${value}`)
    .join("&");

  return createHash("sha1")
    .update(`${paramsToSign}${apiSecret}`)
    .digest("hex");
}

// Enforced on the signature itself so a leaked signature can't be reused to
// upload a bigger file than we allow. Matches the limits surfaced to the
// client so size checks stay in sync.
const CLOUDINARY_MAX_IMAGE_BYTES = 10 * 1024 * 1024; // 10 MB
const CLOUDINARY_MAX_VIDEO_BYTES = 80 * 1024 * 1024; // 80 MB

export const getCloudinaryUploadSignature = onCall(
  {
    secrets: [CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET],
  },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Must be logged in.");
    }

    const caller = await getNotificationActor(callerUid);
    if (caller.banned === true) {
      throw new HttpsError("permission-denied", "Banned users cannot upload media.");
    }
    assertActorNotDeleting(caller);
    await assertRateLimit(
      callerUid,
      "getCloudinaryUploadSignature",
      RATE_LIMITS.uploadSignature
    );

    const { resourceType } = requestData(request.data) as {
      resourceType?: string;
    };
    if (resourceType !== "image" && resourceType !== "video") {
      throw new HttpsError("invalid-argument", "resourceType must be 'image' or 'video'.");
    }

    const cloudName = CLOUDINARY_CLOUD_NAME.value();
    const apiKey = CLOUDINARY_API_KEY.value();
    const apiSecret = CLOUDINARY_API_SECRET.value();

    if (!cloudName || !apiKey || !apiSecret) {
      throw new HttpsError("failed-precondition", "Cloudinary secrets are not configured.");
    }

    const uploadPreset = resourceType === "video" ? "petnote_video_signed" : "petnote_image_signed";
    const maxFileSize =
      resourceType === "video" ? CLOUDINARY_MAX_VIDEO_BYTES : CLOUDINARY_MAX_IMAGE_BYTES;
    const timestamp = Math.floor(Date.now() / 1000);
    const signature = signCloudinaryParams(
      {
        folder: CLOUDINARY_FOLDER,
        max_file_size: String(maxFileSize),
        timestamp: String(timestamp),
        upload_preset: uploadPreset,
      },
      apiSecret
    );

    return {
      cloudName,
      apiKey,
      timestamp,
      signature,
      uploadPreset,
      folder: CLOUDINARY_FOLDER,
      maxFileSize,
    };
  }
);
