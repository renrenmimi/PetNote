import { createHash } from "node:crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  CLOUDINARY_API_KEY,
  CLOUDINARY_API_SECRET,
  CLOUDINARY_CLOUD_NAME,
  CLOUDINARY_FOLDER,
} from "./platform";
import { getNotificationActor } from "./notifications";

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

    const { resourceType } = request.data as { resourceType?: string };
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
    const timestamp = Math.floor(Date.now() / 1000);
    const signature = signCloudinaryParams(
      {
        folder: CLOUDINARY_FOLDER,
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
    };
  }
);
