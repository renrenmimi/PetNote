export interface CompressOptions {
  maxWidth?: number;
  maxHeight?: number;
  quality?: number;
  maxSizeMB?: number;
  /**
   * Hard guardrail: files this large are rejected before we try to decode
   * them to a canvas. Decoding a 100 MB+ image on mobile browsers can
   * crash the tab.
   */
  maxInputSizeMB?: number;
}

const DEFAULT_MAX_INPUT_MB = 50;
export const IMAGE_TOO_LARGE_CODE = "IMAGE_TOO_LARGE";

export function createImageTooLargeError(maxMB: number): Error {
  const err = new Error(`Image exceeds ${maxMB}MB upload limit.`);
  (err as Error & { code?: string }).code = IMAGE_TOO_LARGE_CODE;
  return err;
}

export function isHeicImage(file: File): boolean {
  return (
    file.type === "image/heic" ||
    file.type === "image/heif" ||
    /\.heic$/i.test(file.name) ||
    /\.heif$/i.test(file.name)
  );
}

export async function convertHeicToJpeg(
  file: File,
  quality = 0.85
): Promise<File> {
  const heic2any = (await import("heic2any")).default;
  const blob = await heic2any({
    blob: file,
    toType: "image/jpeg",
    quality,
  });
  const outputBlob = Array.isArray(blob) ? blob[0] : blob;
  return new File(
    [outputBlob as Blob],
    file.name.replace(/\.hei[cf]$/i, ".jpg"),
    { type: "image/jpeg", lastModified: file.lastModified }
  );
}

const loadImage = (file: File) =>
  new Promise<HTMLImageElement>((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Failed to load image"));
    };
    img.src = url;
  });

const canvasToBlob = (
  canvas: HTMLCanvasElement,
  type: string,
  quality: number
) =>
  new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (!blob) {
          reject(new Error("Failed to compress image"));
          return;
        }
        resolve(blob);
      },
      type,
      quality
    );
  });

export async function compressImage(
  file: File,
  options: CompressOptions = {}
): Promise<File> {
  const {
    maxWidth = 1920,
    maxHeight = 1920,
    quality = 0.8,
    maxSizeMB = 2,
    maxInputSizeMB = DEFAULT_MAX_INPUT_MB,
  } = options;

  const maxBytes = maxSizeMB * 1024 * 1024;
  const maxInputBytes = maxInputSizeMB * 1024 * 1024;

  // Reject absurdly large files before decoding. A 100 MB image decoded
  // to a Canvas can OOM mobile browsers long before Cloudinary would
  // notice the size.
  if (file.size > maxInputBytes) {
    throw createImageTooLargeError(maxInputSizeMB);
  }

  if (file.type === "image/gif") return file;
  if (file.size <= maxBytes) return file;

  const img = await loadImage(file);
  const ratio = Math.min(1, maxWidth / img.width, maxHeight / img.height);
  const width = Math.round(img.width * ratio);
  const height = Math.round(img.height * ratio);

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;

  const ctx = canvas.getContext("2d");
  if (!ctx) return file;
  ctx.drawImage(img, 0, 0, width, height);

  let outputType =
    file.type === "image/png" && file.size <= maxBytes
      ? "image/png"
      : "image/jpeg";

  if (file.type === "image/png" && file.size > maxBytes) {
    outputType = "image/jpeg";
  }

  let currentQuality = quality;
  let blob = await canvasToBlob(canvas, outputType, currentQuality);

  if (outputType === "image/png" && blob.size > maxBytes) {
    outputType = "image/jpeg";
    currentQuality = quality;
    blob = await canvasToBlob(canvas, outputType, currentQuality);
  }

  while (blob.size > maxBytes && currentQuality > 0.3) {
    currentQuality = Math.max(0.3, currentQuality - 0.1);
    blob = await canvasToBlob(canvas, outputType, currentQuality);
    if (currentQuality <= 0.3) break;
  }

  const extension = outputType === "image/png" ? "png" : "jpg";
  const name = file.name.replace(/\.[^/.]+$/, `.${extension}`);
  return new File([blob], name, {
    type: outputType,
    lastModified: file.lastModified,
  });
}
