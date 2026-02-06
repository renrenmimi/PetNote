import { useMemo } from "react";
import { useAuth } from "./useAuth";

type UseAdminResult = {
  isAdmin: boolean;
  loading: boolean;
};

export function useAdmin(): UseAdminResult {
  const { user, loading, profile, profileLoading } = useAuth();
  const isAdmin = useMemo(
    () => !!user && profile?.role === "admin",
    [profile?.role, user]
  );

  return { isAdmin, loading: loading || profileLoading };
}
