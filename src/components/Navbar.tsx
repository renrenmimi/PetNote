import { Link } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";

export function Navbar() {
  const { user } = useAuth();

  return (
    <header className="sticky top-0 z-20 border-b border-slate-200 bg-white/95 backdrop-blur">
      <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
        <Link to="/" className="text-lg font-semibold text-slate-900">
          🐾 PetNote
        </Link>

        <div className="flex items-center gap-3">
          {!user ? (
            <Link
              to="/login"
              className="rounded-full border border-purple-200 px-3 py-1.5 text-sm font-semibold text-purple-600 transition hover:border-purple-300 hover:bg-purple-50"
            >
              Login
            </Link>
          ) : (
            <>
              <Link
                to="/create"
                className="flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-md transition hover:brightness-110"
                aria-label="Create post"
              >
                +
              </Link>
              <Link to="/profile" aria-label="Profile">
                <img
                  src={
                    user.photoURL ||
                    "https://i.pravatar.cc/100?img=12"
                  }
                  alt={user.displayName || "User"}
                  className="h-9 w-9 rounded-full object-cover"
                />
              </Link>
            </>
          )}
        </div>
      </div>
    </header>
  );
}
