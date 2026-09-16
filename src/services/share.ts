import { Capacitor } from "@capacitor/core";
import { Share } from "@capacitor/share";
import { Directory, Filesystem } from "@capacitor/filesystem";

/**
 * Sharing, across the two runtimes this app has.
 *
 * `navigator.share` is the reason the Share button was dead on the phone: it
 * *exists* in a WKWebView, so the feature-detect said yes, and then every
 * call rejected. The app logged `console.warn("Share failed")` and showed the
 * person nothing at all.
 *
 * So the detect is "are we native?" rather than "is the API defined", and the
 * native path goes through Capacitor's Share plugin, which opens the real iOS
 * share sheet.
 *
 * Cancelling is not failing. Dismissing the sheet rejects on both paths, and
 * reporting that as an error would be worse than the silence it replaces —
 * every outcome below is distinguished so the caller can stay quiet for a
 * deliberate dismissal and speak up for a real failure.
 */

export type ShareOutcome = "shared" | "cancelled" | "unsupported" | "failed";

const isNative = () => Capacitor.isNativePlatform();

/** Both runtimes signal a user dismissal by rejecting; only the text differs. */
function isCancellation(error: unknown): boolean {
  if (error instanceof DOMException && error.name === "AbortError") return true;
  const message =
    error && typeof error === "object" && "message" in error
      ? String((error as { message?: unknown }).message ?? "")
      : String(error ?? "");
  return /cancel/i.test(message) || /abort/i.test(message);
}

export function canShare(): boolean {
  if (isNative()) return true;
  return typeof navigator !== "undefined" && typeof navigator.share === "function";
}

export async function shareLink(args: {
  title?: string;
  text?: string;
  url: string;
}): Promise<ShareOutcome> {
  if (isNative()) {
    try {
      await Share.share({
        title: args.title,
        text: args.text,
        url: args.url,
        dialogTitle: args.title,
      });
      return "shared";
    } catch (error) {
      return isCancellation(error) ? "cancelled" : "failed";
    }
  }

  if (typeof navigator === "undefined" || typeof navigator.share !== "function") {
    return "unsupported";
  }
  try {
    await navigator.share({ title: args.title, text: args.text, url: args.url });
    return "shared";
  } catch (error) {
    return isCancellation(error) ? "cancelled" : "failed";
  }
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("read failed"));
    reader.onload = () => {
      const result = String(reader.result ?? "");
      // Strip the "data:image/png;base64," prefix the plugin does not want.
      const comma = result.indexOf(",");
      resolve(comma >= 0 ? result.slice(comma + 1) : result);
    };
    reader.readAsDataURL(blob);
  });
}

/**
 * Shares a generated image.
 *
 * On the phone the file has to exist somewhere the share sheet can reach, so
 * it is written to the cache directory first — iOS clears that on its own
 * terms, which is the right lifetime for something handed to another app.
 * The old fallback was a synthetic `<a download>` click, which in a WKWebView
 * goes nowhere at all.
 */
export async function shareImage(args: {
  blob: Blob;
  fileName: string;
  title?: string;
  text?: string;
}): Promise<ShareOutcome> {
  if (isNative()) {
    let uri: string;
    try {
      const data = await blobToBase64(args.blob);
      const written = await Filesystem.writeFile({
        path: args.fileName,
        data,
        directory: Directory.Cache,
      });
      uri = written.uri;
    } catch {
      return "failed";
    }
    try {
      await Share.share({
        title: args.title,
        text: args.text,
        files: [uri],
        dialogTitle: args.title,
      });
      return "shared";
    } catch (error) {
      return isCancellation(error) ? "cancelled" : "failed";
    }
  }

  const file = new File([args.blob], args.fileName, { type: args.blob.type });
  if (
    typeof navigator !== "undefined" &&
    typeof navigator.share === "function" &&
    navigator.canShare?.({ files: [file] })
  ) {
    try {
      await navigator.share({ files: [file], title: args.title, text: args.text });
      return "shared";
    } catch (error) {
      return isCancellation(error) ? "cancelled" : "failed";
    }
  }

  // Desktop browsers: a real download is a real outcome.
  try {
    const url = URL.createObjectURL(args.blob);
    try {
      const link = document.createElement("a");
      link.href = url;
      link.download = args.fileName;
      document.body.appendChild(link);
      link.click();
      link.remove();
    } finally {
      URL.revokeObjectURL(url);
    }
    return "shared";
  } catch {
    return "failed";
  }
}
