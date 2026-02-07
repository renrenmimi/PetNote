import { useNavigate } from "react-router-dom";
import { useFollow } from "../hooks/useFollow";
import { type UserProfile } from "../services/users";

type UserCardProps = {
  user: UserProfile;
  currentUid: string | null;
};

export function UserCard({ user, currentUid }: UserCardProps) {
  const navigate = useNavigate();
  const { isFollowing, toggleFollow, loading } = useFollow(user.id);
  const isSelf = currentUid === user.id;

  return (
    <div className="flex items-center justify-between rounded-2xl bg-white px-4 py-3 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700">
      <button
        type="button"
        onClick={() => navigate(`/profile/${user.id}`)}
        className="flex items-center gap-3"
      >
        <img
          src={user.avatarUrl || "https://i.pravatar.cc/100?img=12"}
          alt={user.displayName || "User"}
          className="h-12 w-12 rounded-full object-cover"
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

      {!isSelf ? (
        <button
          type="button"
          onClick={toggleFollow}
          disabled={loading}
          className={`rounded-full px-4 py-1.5 text-xs font-semibold transition-all duration-200 hover:scale-105 ${
            isFollowing
              ? "border border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-300"
              : "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-[0_10px_25px_-15px_rgba(168,85,247,0.7)]"
          }`}
        >
          {isFollowing ? "Following" : "Follow"}
        </button>
      ) : null}
    </div>
  );
}
