import { useState } from "react";
import { createPortal } from "react-dom";
import Avatar from "./Avatar";
import { useToast } from "../contexts/ToastContext";
import {
  getRelationshipLabel,
  removeFamilyMember,
  transferPetPrimary,
  type FamilyMember,
} from "../services/pets";

/**
 * The family-management surface a shared pet never had.
 *
 * `removeFamilyMember` existed as a client service with no caller anywhere in
 * the app: there was no way to remove a co-owner, no way to leave a pet you
 * had joined, and no way to move the primary role. The only exit was deleting
 * your whole account — which, before the ownership fix, also deleted the pet
 * out from under everybody else.
 *
 * Each action states its consequence before it happens, because all three are
 * hard to undo: rejoining needs a fresh invitation from someone still inside.
 */

type PendingAction =
  | { kind: "remove"; member: FamilyMember }
  | { kind: "transfer"; member: FamilyMember }
  | { kind: "leave" }
  | null;

type FamilyManageModalProps = {
  open: boolean;
  petId: string;
  petName: string;
  viewerUid: string;
  viewerIsPrimary: boolean;
  members: FamilyMember[];
  onClose: () => void;
  /** Called after any change, so the caller can refetch the family. */
  onChanged: () => void;
  /** Called after the viewer leaves, since the pet page is no longer theirs. */
  onLeft: () => void;
};

export function FamilyManageModal({
  open,
  petId,
  petName,
  viewerUid,
  viewerIsPrimary,
  members,
  onClose,
  onChanged,
  onLeft,
}: FamilyManageModalProps) {
  const { showToast } = useToast();
  const [pending, setPending] = useState<PendingAction>(null);
  const [busy, setBusy] = useState(false);

  const isOnlyOwner = members.length <= 1;

  const run = async (action: NonNullable<PendingAction>) => {
    setBusy(true);
    try {
      if (action.kind === "remove") {
        await removeFamilyMember(petId, action.member.userId);
        showToast(`${action.member.userName} is no longer an owner.`, "success");
        onChanged();
      } else if (action.kind === "transfer") {
        await transferPetPrimary(petId, action.member.userId);
        showToast(
          `${action.member.userName} is now ${petName}'s primary owner.`,
          "success"
        );
        onChanged();
      } else {
        await removeFamilyMember(petId, viewerUid);
        showToast(`You left ${petName}'s family.`, "success");
        onLeft();
        return;
      }
      setPending(null);
    } catch (error) {
      // The server refuses two things this UI cannot fully predict: leaving as
      // the only owner, and removing whoever holds the primary role. Its
      // message says which, so show it rather than a generic failure.
      showToast(
        error instanceof Error ? error.message : "That didn't work.",
        "error"
      );
    } finally {
      setBusy(false);
    }
  };

  if (!open) return null;

  const confirmCopy = (action: NonNullable<PendingAction>): string => {
    if (action.kind === "remove") {
      return `${action.member.userName} will lose access to ${petName}. Anything they already posted stays. They can only come back through a new invitation.`;
    }
    if (action.kind === "transfer") {
      return `${action.member.userName} becomes ${petName}'s primary owner. You stay an owner and can still edit and post — but they, not you, will be the one who can remove other owners.`;
    }
    return `You will lose access to ${petName}. Your posts about ${petName} stay, and you can only come back through a new invitation.`;
  };

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-[0_20px_60px_-30px_rgba(15,23,42,0.5)] dark:bg-slate-800">
        {pending ? (
          <>
            <h3 className="text-base font-semibold text-slate-900 dark:text-white">
              {pending.kind === "remove"
                ? `Remove ${pending.member.userName}?`
                : pending.kind === "transfer"
                ? `Make ${pending.member.userName} primary owner?`
                : `Leave ${petName}'s family?`}
            </h3>
            <p className="mt-2 text-sm text-slate-600 dark:text-slate-300">
              {confirmCopy(pending)}
            </p>
            <div className="mt-5 flex items-center justify-end gap-3">
              <button
                type="button"
                onClick={() => setPending(null)}
                disabled={busy}
                className="rounded-full px-4 py-2 text-sm font-semibold text-slate-600 disabled:opacity-60 dark:text-slate-300"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => void run(pending)}
                disabled={busy}
                className="rounded-full bg-rose-500 px-4 py-2 text-sm font-semibold text-white disabled:opacity-60"
              >
                {busy ? "Working..." : "Confirm"}
              </button>
            </div>
          </>
        ) : (
          <>
            <div className="flex items-start justify-between gap-3">
              <div>
                <h3 className="text-base font-semibold text-slate-900 dark:text-white">
                  {petName}&apos;s owners
                </h3>
                <p className="mt-1 text-xs text-slate-500 dark:text-slate-300">
                  Every owner can edit {petName}, post, and invite. The primary
                  owner is the one who can remove someone.
                </p>
              </div>
              <button
                type="button"
                onClick={onClose}
                className="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-300"
              >
                Close
              </button>
            </div>

            <ul className="mt-4 space-y-2">
              {members.map((member) => {
                const isSelf = member.userId === viewerUid;
                const isPrimary = member.role === "primary";
                return (
                  <li
                    key={member.userId}
                    className="flex items-center gap-3 rounded-2xl border border-slate-200 p-3 dark:border-slate-700"
                  >
                    <Avatar
                      src={member.userAvatar}
                      alt={member.userName}
                      userId={member.userId}
                      size={36}
                      className="h-9 w-9"
                    />
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-semibold text-slate-900 dark:text-white">
                        {member.userName}
                        {isSelf ? " (you)" : ""}
                      </p>
                      <p className="text-xs text-slate-500 dark:text-slate-300">
                        {isPrimary ? "Primary owner · " : ""}
                        {getRelationshipLabel(
                          member.relationship,
                          member.customRelationship
                        )}
                      </p>
                    </div>
                    {viewerIsPrimary && !isSelf ? (
                      <div className="flex shrink-0 flex-col gap-1">
                        <button
                          type="button"
                          onClick={() => setPending({ kind: "transfer", member })}
                          className="rounded-full border border-slate-200 px-3 py-1 text-[11px] font-semibold text-slate-600 dark:border-slate-600 dark:text-slate-300"
                        >
                          Make primary
                        </button>
                        <button
                          type="button"
                          onClick={() => setPending({ kind: "remove", member })}
                          className="rounded-full border border-rose-200 px-3 py-1 text-[11px] font-semibold text-rose-600 dark:border-rose-500/40 dark:text-rose-300"
                        >
                          Remove
                        </button>
                      </div>
                    ) : null}
                  </li>
                );
              })}
            </ul>

            {isOnlyOwner ? (
              <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-xs text-slate-500 dark:bg-slate-900 dark:text-slate-300">
                You are {petName}&apos;s only owner, so there is no one to hand
                them to. Invite someone before you leave, or delete {petName}{" "}
                from the profile page.
              </p>
            ) : (
              <button
                type="button"
                onClick={() => setPending({ kind: "leave" })}
                className="mt-4 w-full rounded-full border border-rose-200 px-4 py-2 text-sm font-semibold text-rose-600 transition-all duration-200 hover:bg-rose-50 dark:border-rose-500/40 dark:text-rose-300 dark:hover:bg-rose-500/10"
              >
                Leave {petName}&apos;s family
              </button>
            )}
          </>
        )}
      </div>
    </div>,
    document.body
  );
}
