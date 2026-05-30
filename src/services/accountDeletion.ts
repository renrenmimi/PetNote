// Module-level guard shared between the account-deletion flow (Settings) and
// the auth profile listener (AuthContext). While a uid is marked
// in-progress, AuthContext must NOT recreate ("repair") the user profile
// document when it observes the doc disappear mid-deletion — otherwise the
// listener resurrects the account (and its username reservation) that the
// backend just deleted. The server-side tombstone is the authoritative
// guard; this flag closes the same-tab window without an extra read.
const deletingUids = new Set<string>();

export function markAccountDeletionInProgress(uid: string): void {
  if (uid) deletingUids.add(uid);
}

export function isAccountDeletionInProgress(uid: string): boolean {
  return !!uid && deletingUids.has(uid);
}

export function clearAccountDeletionInProgress(uid: string): void {
  deletingUids.delete(uid);
}
