import { useCallback, useEffect, useState } from "react";
import {
  createUserWithEmailAndPassword,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signOut as firebaseSignOut,
  updateProfile,
  type User,
} from "firebase/auth";
import { auth } from "../services/firebase";
import { createUserProfile } from "../services/users";
import { generateRandomUsername } from "../utils/randomName";

type UseAuthResult = {
  user: User | null;
  loading: boolean;
  signIn: (email: string, password: string) => Promise<User>;
  signUp: (email: string, password: string) => Promise<User>;
  signOut: () => Promise<void>;
};

export function useAuth(): UseAuthResult {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, (nextUser) => {
      setUser(nextUser);
      setLoading(false);
    });

    return () => unsubscribe();
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    const result = await signInWithEmailAndPassword(auth, email, password);
    return result.user;
  }, []);

  const signUp = useCallback(async (email: string, password: string) => {
    const result = await createUserWithEmailAndPassword(auth, email, password);
    const randomName = generateRandomUsername();
    const avatarUrl = `https://api.dicebear.com/7.x/thumbs/svg?seed=${result.user.uid}`;
    await updateProfile(result.user, {
      displayName: randomName,
      photoURL: avatarUrl,
    });
    await createUserProfile(result.user.uid, {
      displayName: randomName,
      avatarUrl,
      bio: "",
      email: result.user.email || email,
      followerCount: 0,
      followingCount: 0,
    });
    return result.user;
  }, []);

  const signOut = useCallback(async () => {
    await firebaseSignOut(auth);
  }, []);

  return { user, loading, signIn, signUp, signOut };
}
