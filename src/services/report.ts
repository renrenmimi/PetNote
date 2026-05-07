import { httpsCallable } from "firebase/functions";
import { functions } from "./firebase";

export type ReportTargetType = "post" | "comment" | "user";

export type ReportInput = {
  reporterId: string;
  reporterName: string;
  reporterAvatar?: string;
  targetType: ReportTargetType;
  targetId: string;
  reason: string;
  description?: string;
};

export type ReportItem = ReportInput & {
  id: string;
  status: "pending" | "reviewed" | "resolved";
  createdAt?: unknown;
  postId?: string;
};

export async function reportContent(data: ReportInput): Promise<void> {
  await httpsCallable<
    {
      targetType: ReportTargetType;
      targetId: string;
      reason: string;
      description?: string;
    },
    { id: string }
  >(functions, "reportContentCallable")({
    targetType: data.targetType,
    targetId: data.targetId,
    reason: data.reason,
    description: data.description,
  });
}

// `getReportsByUser` was removed — it had no callers and was unbounded.
// If a "my reports" surface is ever added, build it through a paginated
// callable so admin reads and reporter reads stay separated.
