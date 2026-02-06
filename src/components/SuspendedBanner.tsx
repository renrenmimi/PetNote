import { useAuth } from "../hooks/useAuth";

export function SuspendedBanner() {
  const { isBanned } = useAuth();

  if (!isBanned) return null;

  return (
    <div className="fixed inset-x-0 top-0 z-50 bg-red-500 px-4 py-2 text-center text-xs font-semibold text-white shadow-lg">
      Your account has been suspended.
    </div>
  );
}
