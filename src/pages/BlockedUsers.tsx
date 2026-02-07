import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { getBlockedUsers, unblockUser } from "../services/block";
import { getUsersByIds, type UserProfile } from "../services/users";

export function BlockedUsers() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const [users, setUsers] = useState<UserProfile[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let ignore = false;
    if (!user) return;
    const load = async () => {
      setLoading(true);
      const ids = await getBlockedUsers(user.uid);
      const profiles = await getUsersByIds(ids);
      if (!ignore) {
        setUsers(profiles);
        setLoading(false);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [user]);

  if (!user) return null;

  return (
    <div className="min-h-screen bg-white pb-10 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Blocked Users
          </h1>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-6">
        {loading ? (
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            Loading blocked users...
          </div>
        ) : users.length === 0 ? (
          <div className="rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500 dark:bg-slate-800 dark:text-slate-300">
            No blocked users
          </div>
        ) : (
          users.map((profile) => (
            <div
              key={profile.id}
              className="flex items-center justify-between rounded-2xl border border-slate-200 bg-white px-4 py-3 dark:border-slate-700 dark:bg-slate-800"
            >
              <div className="flex items-center gap-3">
                <img
                  src={profile.avatarUrl || "https://i.pravatar.cc/100?img=12"}
                  alt={profile.displayName || "User"}
                  className="h-10 w-10 rounded-full object-cover"
                />
                <div>
                  <p className="text-sm font-semibold text-slate-900 dark:text-white">
                    {profile.displayName || "User"}
                  </p>
                  <p className="text-xs text-slate-400 dark:text-slate-500">
                    {profile.email}
                  </p>
                </div>
              </div>
              <button
                type="button"
                onClick={async () => {
                  await unblockUser(user.uid, profile.id);
                  setUsers((prev) =>
                    prev.filter((item) => item.id !== profile.id)
                  );
                }}
                className="rounded-full border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-600 transition-all duration-200 hover:border-purple-300 hover:text-purple-600 dark:border-slate-700 dark:text-slate-300"
              >
                Unblock
              </button>
            </div>
          ))
        )}
      </main>
    </div>
  );
}
