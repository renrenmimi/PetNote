import type { Post } from "../services/posts";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";

const loadImage = (src?: string): Promise<HTMLImageElement | null> => {
  if (!src) return Promise.resolve(null);
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = src;
  });
};

const drawWrappedText = (
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  maxWidth: number,
  lineHeight: number,
  maxLines = 3
) => {
  const words = text.split(/\s+/);
  let line = "";
  let lines = 0;

  for (let i = 0; i < words.length; i += 1) {
    const testLine = line ? `${line} ${words[i]}` : words[i];
    const { width } = ctx.measureText(testLine);
    if (width > maxWidth && line) {
      ctx.fillText(line, x, y);
      line = words[i];
      y += lineHeight;
      lines += 1;
      if (lines >= maxLines - 1) break;
    } else {
      line = testLine;
    }
  }
  if (line && lines < maxLines) {
    ctx.fillText(line, x, y);
  }
};

export async function generateShareCard(post: Post): Promise<Blob> {
  const canvas = document.createElement("canvas");
  const width = 400;
  const height = 560;
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Canvas not supported");

  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, width, height);

  const mediaUrl = optimizeCloudinaryUrl(
    post.media?.[0]?.url || post.mediaUrl || "",
    "medium"
  );
  const heroImage = await loadImage(mediaUrl);
  if (heroImage) {
    ctx.drawImage(heroImage, 0, 0, 400, 400);
  } else {
    ctx.fillStyle = "#f1f5f9";
    ctx.fillRect(0, 0, 400, 400);
  }

  ctx.fillStyle = "#1f2937";
  ctx.font = "bold 16px sans-serif";
  ctx.fillText(post.authorName || "PetNote User", 16, 430);

  ctx.fillStyle = "#6b7280";
  ctx.font = "14px sans-serif";
  const caption = post.text ? post.text.slice(0, 100) : "";
  drawWrappedText(ctx, caption, 16, 455, 368, 18);

  const tags = (post.tags || []).slice(0, 3).map((tag) => `#${tag}`).join(" ");
  if (tags) {
    ctx.fillStyle = "#8b5cf6";
    ctx.font = "12px sans-serif";
    ctx.fillText(tags, 16, 510);
  }

  ctx.fillStyle = "#8b5cf6";
  ctx.font = "bold 12px sans-serif";
  ctx.fillText("🐾 Shared from PetNote", 16, 540);

  const gradient = ctx.createLinearGradient(0, 552, 400, 552);
  gradient.addColorStop(0, "#8b5cf6");
  gradient.addColorStop(1, "#ec4899");
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 552, 400, 8);

  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error("Unable to generate share card"));
        return;
      }
      resolve(blob);
    }, "image/png");
  });
}
