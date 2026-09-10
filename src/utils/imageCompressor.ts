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

/**
 * The worker that does the downscale + re-encode, created once and reused.
 *
 * Lazily, because most sessions never upload a photo and a worker costs a
 * thread. Set to "unsupported" after the worker tells us it cannot do the job,
 * so a browser without OffscreenCanvas.convertToBlob pays the probe once and
 * then goes straight to the DOM path.
 */
let compressWorker: Worker | null | "unsupported" = null;
let compressRequestId = 0;

function getCompressWorker(): Worker | null {
  if (compressWorker === "unsupported") return null;
  if (compressWorker) return compressWorker;
  if (typeof Worker === "undefined") {
    compressWorker = "unsupported";
    return null;
  }
  try {
    compressWorker = new Worker(
      new URL("./imageCompressor.worker.ts", import.meta.url),
      { type: "module" }
    );
    return compressWorker;
  } catch {
    compressWorker = "unsupported";
    return null;
  }
}

type WorkerResult =
  | { ok: true; blob: Blob; type: string }
  | { ok: false; reason: "unsupported" | "failed"; message?: string };

function compressInWorker(
  worker: Worker,
  payload: {
    blob: Blob;
    maxWidth: number;
    maxHeight: number;
    quality: number;
    maxBytes: number;
    outputType: string;
  }
): Promise<WorkerResult> {
  const id = ++compressRequestId;
  return new Promise<WorkerResult>((resolve) => {
    const onMessage = (event: MessageEvent) => {
      const data = event.data as { id?: number } & WorkerResult;
      if (data?.id !== id) return;
      cleanup();
      resolve(data);
    };
    const onError = () => {
      cleanup();
      resolve({ ok: false, reason: "failed", message: "worker error" });
    };
    const cleanup = () => {
      worker.removeEventListener("message", onMessage);
      worker.removeEventListener("error", onError);
    };
    worker.addEventListener("message", onMessage);
    worker.addEventListener("error", onError);
    worker.postMessage({ id, ...payload });
  });
}

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

  // Which container to write. Decided before the worker call so both paths
  // produce identical output.
  const desiredOutputType =
    file.type === "image/png" && file.size <= maxBytes
      ? "image/png"
      : "image/jpeg";

  // Try the worker first. The DOM path below stays as the fallback: it is not
  // dead code, it is what runs when OffscreenCanvas.convertToBlob is missing.
  const worker = getCompressWorker();
  if (worker) {
    const result = await compressInWorker(worker, {
      blob: file,
      maxWidth,
      maxHeight,
      quality,
      maxBytes,
      outputType: desiredOutputType,
    });
    if (result.ok) {
      const extension = result.type === "image/png" ? "png" : "jpg";
      return new File(
        [result.blob],
        file.name.replace(/\.[^/.]+$/, `.${extension}`),
        { type: result.type, lastModified: file.lastModified }
      );
    }
    if (result.reason === "unsupported") {
      // Remember, so every subsequent photo skips the round trip.
      worker.terminate();
      compressWorker = "unsupported";
    }
    // A "failed" result falls through to the DOM path for this photo without
    // disabling the worker: one undecodable image should not change the
    // strategy for the rest of the session.
  }

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

  let outputType = desiredOutputType;

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
