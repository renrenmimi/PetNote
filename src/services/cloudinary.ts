const cloudName = import.meta.env.VITE_CLOUDINARY_CLOUD_NAME;
const uploadPreset = "petnote_unsigned";

export async function uploadImage(file: File): Promise<string> {
  if (!cloudName) {
    throw new Error("Missing VITE_CLOUDINARY_CLOUD_NAME");
  }

  const formData = new FormData();
  formData.append("file", file);
  formData.append("upload_preset", uploadPreset);

  const response = await fetch(
    `https://api.cloudinary.com/v1_1/${cloudName}/image/upload`,
    {
      method: "POST",
      body: formData,
    }
  );

  if (!response.ok) {
    const message = await response.text();
    throw new Error(message || "Cloudinary upload failed");
  }

  const data = (await response.json()) as { secure_url?: string };
  if (!data.secure_url) {
    throw new Error("Cloudinary response missing secure_url");
  }

  return data.secure_url;
}

export async function uploadMedia(
  file: File
): Promise<{ url: string; type: "image" | "video"; thumbUrl?: string }> {
  if (!cloudName) {
    throw new Error("Missing VITE_CLOUDINARY_CLOUD_NAME");
  }

  const isVideo = file.type.startsWith("video/");
  const resourceType = isVideo ? "video" : "image";

  const formData = new FormData();
  formData.append("file", file);
  formData.append("upload_preset", uploadPreset);

  const response = await fetch(
    `https://api.cloudinary.com/v1_1/${cloudName}/${resourceType}/upload`,
    {
      method: "POST",
      body: formData,
    }
  );

  if (!response.ok) {
    const message = await response.text();
    throw new Error(message || "Cloudinary upload failed");
  }

  const data = (await response.json()) as { secure_url?: string };
  if (!data.secure_url) {
    throw new Error("Cloudinary response missing secure_url");
  }

  if (!isVideo) {
    return { url: data.secure_url, type: "image" };
  }

  const thumbUrl = data.secure_url
    .replace("/video/upload/", "/video/upload/so_0,w_400,h_400,c_fill/")
    .replace(/\.\w+$/, ".jpg");

  return { url: data.secure_url, type: "video", thumbUrl };
}
