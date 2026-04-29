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

async function uploadToCloudinary(
  file: File,
  resourceType: CloudinaryResourceType
): Promise<string> {
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

  const payload = (await response.json()) as { secure_url?: string };
  if (!payload.secure_url) {
    throw new Error("Cloudinary response missing secure_url");
  }

  return payload.secure_url;
}

export async function uploadImage(file: File): Promise<string> {
  return uploadToCloudinary(await prepareImageForUpload(file), "image");
}

export async function uploadMedia(
  file: File
): Promise<{ url: string; type: "image" | "video"; thumbUrl?: string }> {
  const isVideo = file.type.startsWith("video/");
  const resourceType: CloudinaryResourceType = isVideo ? "video" : "image";
  const uploadFile = isVideo ? file : await prepareImageForUpload(file);
  const secureUrl = await uploadToCloudinary(uploadFile, resourceType);

  if (!isVideo) {
    return { url: secureUrl, type: "image" };
  }

  const thumbUrl = secureUrl
    .replace("/video/upload/", "/video/upload/so_0,w_400,h_400,c_fill/")
    .replace(/\.\w+$/, ".jpg");

  return { url: secureUrl, type: "video", thumbUrl };
}
