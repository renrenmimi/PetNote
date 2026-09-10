/// <reference lib="webworker" />

/**
 * Image downscale + re-encode, off the main thread.
 *
 * The measured cost this exists for: a 4032×3024 / 9.86 MB JPEG going to
 * 1920×1440 / 0.50 MB produced main-thread long tasks of 111–127 ms at 1× CPU
 * and 449–524 ms at 4×. That is the composer freezing mid-upload on a phone,
 * per photo. HEIC decoding is already off-thread (heic2any creates its own
 * worker); this is the other half, and the part the benchmark actually caught.
 *
 * `createImageBitmap` + `OffscreenCanvas.convertToBlob` are the worker-safe
 * equivalents of `<img>` + `canvas.toBlob`. Neither is universally available —
 * `convertToBlob` in particular arrived late in Safari — so the worker reports
 * `unsupported` and the caller falls back to the DOM path rather than failing
 * the upload. Feature-detecting here rather than on the main thread is
 * deliberate: `OffscreenCanvas` existing in a window says nothing about the
 * worker scope.
 */

type CompressRequest = {
  id: number;
  blob: Blob;
  maxWidth: number;
  maxHeight: number;
  quality: number;
  maxBytes: number;
  outputType: string;
};

type CompressResponse =
  | { id: number; ok: true; blob: Blob; type: string }
  | { id: number; ok: false; reason: "unsupported" | "failed"; message?: string };

const supported = () =>
  typeof createImageBitmap === "function" &&
  typeof OffscreenCanvas === "function" &&
  typeof new OffscreenCanvas(1, 1).convertToBlob === "function";

self.onmessage = async (event: MessageEvent<CompressRequest>) => {
  const request = event.data;
  const reply = (response: CompressResponse) =>
    (self as unknown as Worker).postMessage(response);

  if (!supported()) {
    reply({ id: request.id, ok: false, reason: "unsupported" });
    return;
  }

  let bitmap: ImageBitmap | null = null;
  try {
    bitmap = await createImageBitmap(request.blob);
    const ratio = Math.min(
      1,
      request.maxWidth / bitmap.width,
      request.maxHeight / bitmap.height
    );
    const width = Math.round(bitmap.width * ratio);
    const height = Math.round(bitmap.height * ratio);

    const canvas = new OffscreenCanvas(width, height);
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      reply({ id: request.id, ok: false, reason: "unsupported" });
      return;
    }
    ctx.drawImage(bitmap, 0, 0, width, height);

    // Same quality ladder as the DOM path, so switching between them cannot
    // change the size of what gets uploaded.
    let type = request.outputType;
    let quality = request.quality;
    let blob = await canvas.convertToBlob({ type, quality });

    if (type === "image/png" && blob.size > request.maxBytes) {
      type = "image/jpeg";
      quality = request.quality;
      blob = await canvas.convertToBlob({ type, quality });
    }
    while (blob.size > request.maxBytes && quality > 0.3) {
      quality = Math.max(0.3, quality - 0.1);
      blob = await canvas.convertToBlob({ type, quality });
      if (quality <= 0.3) break;
    }

    reply({ id: request.id, ok: true, blob, type });
  } catch (error) {
    reply({
      id: request.id,
      ok: false,
      reason: "failed",
      message: error instanceof Error ? error.message : String(error),
    });
  } finally {
    bitmap?.close();
  }
};

export {};
