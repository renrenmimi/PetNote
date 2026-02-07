import { useCallback, useEffect, useState } from "react";
import {
  createUserWithEmailAndPassword,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signOut as firebaseSignOut,
  updateProfile,
  type User,
} from "firebase/auth";
import { doc, onSnapshot } from "firebase/firestore";
import { auth, db } from "../services/firebase";
import { createUserProfile, type UserProfile } from "../services/users";
import { generateRandomUsername } from "../utils/randomName";

type UseAuthResult = {
  user: User | null;
  loading: boolean;
  profile: UserProfile | null;
  profileLoading: boolean;
  isBanned: boolean;
  signIn: (email: string, password: string) => Promise<User>;
  signUp: (email: string, password: string) => Promise<User>;
  signOut: () => Promise<void>;
};

export function useAuth(): UseAuthResult {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [profileLoading, setProfileLoading] = useState(true);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, (nextUser) => {
      setUser(nextUser);
      setLoading(false);
    });

    return () => unsubscribe();
  }, []);

  useEffect(() => {
    if (!user) {
      setProfile(null);
      setProfileLoading(false);
      return;
    }
    setProfileLoading(true);
    const userRef = doc(db, "users", user.uid);
    const unsubscribe = onSnapshot(userRef, (snapshot) => {
      if (!snapshot.exists()) {
        setProfile(null);
        setProfileLoading(false);
        return;
      }
      setProfile({
        id: snapshot.id,
        ...(snapshot.data() as Omit<UserProfile, "id">),
      });
      setProfileLoading(false);
    });
    return () => unsubscribe();
  }, [user]);

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
      onboardingComplete: false,
    });
    return result.user;
  }, []);

  const signOut = useCallback(async () => {
    await firebaseSignOut(auth);
  }, []);

  return {
    user,
    loading,
    profile,
    profileLoading,
    isBanned: !!profile?.banned,
    signIn,
    signUp,
    signOut,
  };
}
