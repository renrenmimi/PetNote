import { httpsCallable } from "firebase/functions";
import { functions } from "./firebase";

type CloudinaryResourceType = "image" | "video";

type SignedUploadSignatureRequest = {
  resourceType: CloudinaryResourceType;
};

type SignedUploadSignatureResponse = {
  cloudName: string;
  apiKey: string;
  timestamp: number;
  signature: string;
  uploadPreset: string;
  folder: string;
  maxFileSize: number;
};

function formatMegabytes(bytes: number): string {
  return `${Math.round(bytes / (1024 * 1024))}MB`;
}

async function prepareImageForUpload(file: File): Promise<File> {
  const { compressImage, convertHeicToJpeg, isHeicImage } = await import(
    "../utils/imageCompressor"
  );
  const imageFile = isHeicImage(file) ? await convertHeicToJpeg(file) : file;
  return compressImage(imageFile, {
    maxWidth: 1920,
    maxHeight: 1920,
    quality: 0.8,
    maxSizeMB: 2,
  });
}

// Asset metadata returned by every upload. publicId / resourceType are the
// inputs deleteCloudinaryAssets needs to clean up the asset on the server
// when a downstream Firestore write fails.
export type UploadedAsset = {
  url: string;
  publicId: string;
  resourceType: CloudinaryResourceType;
  type: "image" | "video";
  thumbUrl?: string;
};

async function uploadToCloudinary(
  file: File,
  resourceType: CloudinaryResourceType
): Promise<{ url: string; publicId: string }> {
  const getCloudinaryUploadSignature = httpsCallable<
    SignedUploadSignatureRequest,
    SignedUploadSignatureResponse
  >(functions, "getCloudinaryUploadSignature");

  const { data } = await getCloudinaryUploadSignature({ resourceType });

  if (data.maxFileSize && file.size > data.maxFileSize) {
    throw new Error(
      `${resourceType === "video" ? "Video" : "Image"} exceeds ${formatMegabytes(data.maxFileSize)} limit.`
    );
  }

  const formData = new FormData();
  formData.append("file", file);
  formData.append("api_key", data.apiKey);
  formData.append("timestamp", String(data.timestamp));
  formData.append("signature", data.signature);
  formData.append("upload_preset", data.uploadPreset);
  formData.append("folder", data.folder);
  if (data.maxFileSize) {
    formData.append("max_file_size", String(data.maxFileSize));
  }

  const response = await fetch(
    `https://api.cloudinary.com/v1_1/${data.cloudName}/${resourceType}/upload`,
    {
      method: "POST",
      body: formData,
    }
  );

  if (!response.ok) {
    const message = await response.text();
    throw new Error(message || "Cloudinary upload failed");
  }

  const payload = (await response.json()) as {
    secure_url?: string;
    public_id?: string;
  };
  if (!payload.secure_url || !payload.public_id) {
    throw new Error("Cloudinary response missing secure_url or public_id");
  }

  return { url: payload.secure_url, publicId: payload.public_id };
}

export async function uploadImage(file: File): Promise<UploadedAsset> {
  const prepared = await prepareImageForUpload(file);
  const { url, publicId } = await uploadToCloudinary(prepared, "image");
  return { url, publicId, resourceType: "image", type: "image" };
}

export async function uploadMedia(file: File): Promise<UploadedAsset> {
  const isVideo = file.type.startsWith("video/");
  const resourceType: CloudinaryResourceType = isVideo ? "video" : "image";
  const uploadFile = isVideo ? file : await prepareImageForUpload(file);
  const { url, publicId } = await uploadToCloudinary(uploadFile, resourceType);

  if (!isVideo) {
    return { url, publicId, resourceType: "image", type: "image" };
  }

  const thumbUrl = url
    .replace("/video/upload/", "/video/upload/so_0,w_400,h_400,c_fill/")
    .replace(/\.\w+$/, ".jpg");

  return { url, publicId, resourceType: "video", type: "video", thumbUrl };
}

// Best-effort cleanup of assets the user just uploaded but failed to
// reference (e.g. createPost rejected after media upload). Never throws —
// the caller's original error toast must always win.
export async function deleteCloudinaryAssets(
  assets: UploadedAsset[]
): Promise<void> {
  if (assets.length === 0) return;
  const payload = assets.map((asset) => ({
    publicId: asset.publicId,
    resourceType: asset.resourceType,
  }));
  try {
    await httpsCallable<
      { assets: typeof payload },
      { deleted: number }
    >(functions, "deleteCloudinaryAssetsCallable")({ assets: payload });
  } catch (error) {
    console.warn("Failed to clean up orphan Cloudinary assets:", error);
  }
}
