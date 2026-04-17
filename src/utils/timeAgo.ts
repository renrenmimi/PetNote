import {
  getDocumentLanguage,
  getLanguageLocale,
  isChineseLanguage,
} from "../i18n/config";

type FirestoreTimestamp = {
  toDate: () => Date;
};

const isTimestamp = (value: unknown): value is FirestoreTimestamp =>
  typeof value === "object" &&
  value !== null &&
  "toDate" in value &&
  typeof (value as { toDate: () => Date }).toDate === "function";

const toDate = (value: Date | FirestoreTimestamp | undefined | null) => {
  if (!value) return new Date();
  if (value instanceof Date) return value;
  if (isTimestamp(value)) return value.toDate();
  return new Date();
};

export function timeAgo(value: Date | FirestoreTimestamp): string {
  const date = toDate(value);
  const diffSeconds = Math.floor((Date.now() - date.getTime()) / 1000);
  const language = getDocumentLanguage();

  if (isChineseLanguage(language)) {
    if (diffSeconds < 5) return "刚刚";
    if (diffSeconds < 60) return `${diffSeconds}秒前`;

    const minutes = Math.floor(diffSeconds / 60);
    if (minutes < 60) return `${minutes}分钟前`;

    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}小时前`;

    const days = Math.floor(hours / 24);
    if (days < 7) return `${days}天前`;

    const weeks = Math.floor(days / 7);
    if (weeks < 4) return `${weeks}周前`;

    const now = new Date();
    const sameYear = date.getFullYear() === now.getFullYear();
    return date.toLocaleDateString(getLanguageLocale(language), {
      month: "numeric",
      day: "numeric",
      ...(sameYear ? {} : { year: "numeric" }),
    });
  }

  if (diffSeconds < 5) return "just now";
  if (diffSeconds < 60) return `${diffSeconds}s`;

  const minutes = Math.floor(diffSeconds / 60);
  if (minutes < 60) return `${minutes}m`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;

  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d`;

  const weeks = Math.floor(days / 7);
  if (weeks < 4) return `${weeks}w`;

  const now = new Date();
  const sameYear = date.getFullYear() === now.getFullYear();
  return date.toLocaleDateString(getLanguageLocale(language), {
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  });
}
