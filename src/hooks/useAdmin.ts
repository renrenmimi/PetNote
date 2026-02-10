import { doc, getDoc } from "firebase/firestore";
import { useEffect, useState } from "react";
import { db } from "../services/firebase";
import { useAuth } from "./useAuth";

type UseAdminResult = {
  isAdmin: boolean;
  loading: boolean;
};

export function useAdmin(): UseAdminResult {
  const { user, loading: authLoading } = useAuth();
  const [isAdmin, setIsAdmin] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (authLoading) {
      setLoading(true);
      return;
    }

    if (!user) {
      setIsAdmin(false);
      setLoading(false);
      return;
    }

    let active = true;

    const checkAdmin = async () => {
      setLoading(true);
      try {
        const userDoc = await getDoc(doc(db, "users", user.uid));
        const role = userDoc.exists() ? userDoc.data().role : undefined;
        if (active) {
          setIsAdmin(role === "admin");
        }
      } catch (error) {
        console.warn("Failed to check admin role:", error);
        if (active) {
          setIsAdmin(false);
        }
      } finally {
        if (active) {
          setLoading(false);
        }
      }
    };

    void checkAdmin();

    return () => {
      active = false;
    };
  }, [authLoading, user]);

  return { isAdmin, loading };
}
