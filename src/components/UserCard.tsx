import { useNavigate } from "react-router-dom";
import { type UserProfile } from "../services/users";
import Avatar from "./Avatar";

type UserCardProps = {
  user: UserProfile;
  currentUid: string | null;
};

export function UserCard({ user, currentUid }: UserCardProps) {
  const navigate = useNavigate();
  const isSelf = currentUid === user.id;

  return (
    <div className="flex items-center justify-between rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700">
      <button
        type="button"
        onClick={() => navigate(`/profile/${user.id}`)}
        className="flex items-center gap-3"
      >
        <Avatar
          src={user.avatarUrl || undefined}
          alt={user.displayName || "User"}
          userId={user.id}
          size={48}
          className="h-12 w-12"
        />
        <div className="text-left">
          <p className="text-sm font-semibold text-slate-900 dark:text-white">
            {user.displayName || "PetNote User"}
          </p>
          <p className="text-xs text-slate-400 dark:text-slate-500">
            {user.bio || "Pet lover"}
          </p>
        </div>
      </button>

      <span
        className={`rounded-full px-4 py-1.5 text-xs font-semibold ${
          isSelf
            ? "text-slate-400 dark:text-slate-500"
            : "text-purple-600 dark:text-purple-300"
        }`}
      >
        {isSelf ? "You" : "View"}
      </span>
    </div>
  );
}
