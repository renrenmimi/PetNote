import { useNavigate } from "react-router-dom";
import PawIcon from "../components/PawIcon";

export function NotFound() {
  const navigate = useNavigate();

  return (
    <main className="flex min-h-screen items-center justify-center bg-white px-4 dark:bg-slate-900">
      <div className="w-full max-w-md text-center">
        <div className="flex justify-center">
          <div className="-rotate-6 text-gray-400 dark:text-gray-500">
            <PawIcon size={64} />
          </div>
        </div>
        <h1 className="mt-4 text-2xl font-semibold text-slate-900 dark:text-white">
          Page not found
        </h1>
        <p className="mt-2 text-sm text-slate-500 dark:text-slate-400">
          This page doesn&apos;t exist or has been removed.
        </p>
        <button
          type="button"
          onClick={() => navigate("/")}
          className="mt-6 rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-5 py-2.5 text-sm font-semibold text-white transition-all duration-200 hover:brightness-110"
        >
          Go Home
        </button>
      </div>
    </main>
  );
}
