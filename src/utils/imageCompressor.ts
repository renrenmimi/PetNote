export interface CompressOptions {
  maxWidth?: number;
  maxHeight?: number;
  quality?: number;
  maxSizeMB?: number;
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
  } = options;

  const maxBytes = maxSizeMB * 1024 * 1024;

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
