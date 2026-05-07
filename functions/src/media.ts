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

// User-isolated upload folder. Every uploaded asset lands under
// petnote/users/{uid}/... so the delete callable can verify ownership by
// public_id prefix without trusting any client-supplied owner field.
function userFolder(callerUid: string): string {
  return `${CLOUDINARY_FOLDER}/users/${callerUid}`;
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
    const folder = userFolder(callerUid);
    const signature = signCloudinaryParams(
      {
        folder,
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
      folder,
      maxFileSize,
    };
  }
);

// Best-effort cleanup for orphaned uploads. Frontend flows call this from
// their error path when an upload succeeded but the subsequent Firestore
// write (createPost, addPlace, etc.) failed.
//
// IMPORTANT: this callable does NOT check banned / deletionPending. A user
// who just got banned mid-flow still needs to clean up the assets they
// uploaded a moment earlier — otherwise we leak storage.
//
// Authorization is purely public_id prefix: assets must live under
// petnote/users/{callerUid}/... which only the signed-upload flow places
// them in. A leaked or guessed publicId for another user's asset can't be
// destroyed because the prefix won't match.
export const deleteCloudinaryAssetsCallable = onCall(
  {
    secrets: [CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY, CLOUDINARY_API_SECRET],
  },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Must be logged in.");
    }
    await assertRateLimit(
      callerUid,
      "deleteCloudinaryAssets",
      RATE_LIMITS.write
    );

    const { assets } = requestData(request.data) as {
      assets?: unknown;
    };
    if (!Array.isArray(assets) || assets.length === 0) {
      return { deleted: 0 };
    }
    if (assets.length > 30) {
      throw new HttpsError(
        "invalid-argument",
        "Cannot delete more than 30 assets in a single call."
      );
    }

    const ownedPrefix = `${userFolder(callerUid)}/`;
    const validated: Array<{ publicId: string; resourceType: "image" | "video" }> = [];
    for (const raw of assets) {
      if (!raw || typeof raw !== "object") {
        throw new HttpsError("invalid-argument", "Invalid asset entry.");
      }
      const entry = raw as { publicId?: unknown; resourceType?: unknown };
      const publicId =
        typeof entry.publicId === "string" ? entry.publicId : "";
      const resourceType = entry.resourceType;
      if (!publicId || !publicId.startsWith(ownedPrefix)) {
        throw new HttpsError(
          "permission-denied",
          "Asset does not belong to this user."
        );
      }
      if (resourceType !== "image" && resourceType !== "video") {
        throw new HttpsError(
          "invalid-argument",
          "resourceType must be 'image' or 'video'."
        );
      }
      validated.push({ publicId, resourceType });
    }

    const cloudName = CLOUDINARY_CLOUD_NAME.value();
    const apiKey = CLOUDINARY_API_KEY.value();
    const apiSecret = CLOUDINARY_API_SECRET.value();
    if (!cloudName || !apiKey || !apiSecret) {
      throw new HttpsError("failed-precondition", "Cloudinary secrets are not configured.");
    }

    let deleted = 0;
    for (const asset of validated) {
      const timestamp = Math.floor(Date.now() / 1000);
      const signature = signCloudinaryParams(
        {
          public_id: asset.publicId,
          timestamp: String(timestamp),
        },
        apiSecret
      );
      const form = new URLSearchParams();
      form.set("public_id", asset.publicId);
      form.set("timestamp", String(timestamp));
      form.set("signature", signature);
      form.set("api_key", apiKey);

      const url = `https://api.cloudinary.com/v1_1/${cloudName}/${asset.resourceType}/destroy`;
      // 8s per-asset timeout. Cloudinary destroy normally responds well
      // under 1s; anything past 8s is a network problem we don't want to
      // sit on inside a function instance, especially when the caller is
      // already waiting to surface the original error.
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 8_000);
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: form.toString(),
          signal: controller.signal,
        });
        if (response.ok) {
          const payload = (await response.json()) as { result?: string };
          if (payload.result === "ok" || payload.result === "not found") {
            deleted += 1;
          }
        }
      } catch {
        // Best-effort. Leaked asset will be picked up by a future scheduled
        // cleanup job; we don't want orphan-cleanup failures to mask the
        // original error the caller is reporting.
      } finally {
        clearTimeout(timeoutId);
      }
    }

    return { deleted };
  }
);
