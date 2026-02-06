import { Navigate } from "react-router-dom";
import { useAdmin } from "../hooks/useAdmin";
import { useAuth } from "../hooks/useAuth";

type RequireAdminProps = {
  children: React.ReactNode;
};

export function RequireAdmin({ children }: RequireAdminProps) {
  const { user, loading } = useAuth();
  const { isAdmin, loading: adminLoading } = useAdmin();

  if (loading || adminLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-white">
        <span className="text-sm text-slate-500">Checking admin access...</span>
      </div>
    );
  }

  if (!user || !isAdmin) {
    return <Navigate to="/" replace />;
  }

  return <>{children}</>;
}
