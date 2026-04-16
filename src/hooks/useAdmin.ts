import { useAuth } from "./useAuth";

type UseAdminResult = {
  isAdmin: boolean;
  loading: boolean;
};

export function useAdmin(): UseAdminResult {
  const { isAdmin, loading, adminLoading } = useAuth();
  return { isAdmin, loading: loading || adminLoading };
}
