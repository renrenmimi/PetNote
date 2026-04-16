import { createContext, useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  createUserWithEmailAndPassword,
  GoogleAuthProvider,
  onAuthStateChanged,
  sendEmailVerification,
  signInWithPopup,
  signInWithEmailAndPassword,
  signOut as firebaseSignOut,
  updateProfile,
  type User,
} from "firebase/auth";
import { doc, getDoc, onSnapshot, serverTimestamp, setDoc } from "firebase/firestore";
import { auth, db } from "../services/firebase";
import { getUserLocation } from "../services/location";
import {
  subscribeAdminState,
  type AdminState,
} from "../services/adminState";
import {
  createUserProfile,
  generateUniqueUsername,
  isUsernameTaken,
  type UserProfile,
} from "../services/users";

type AuthContextValue = {
  user: User | null;
  loading: boolean;
  profile: UserProfile | null;
  profileLoading: boolean;
  adminLoading: boolean;
  isAdmin: boolean;
  isBanned: boolean;
  signIn: (email: string, password: string) => Promise<User>;
  signUp: (email: string, password: string) => Promise<User>;
  signInWithGoogle: () => Promise<User>;
  signOut: () => Promise<void>;
};

// eslint-disable-next-line react-refresh/only-export-components
export const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [profileLoading, setProfileLoading] = useState(true);
  const [adminState, setAdminState] = useState<AdminState | null>(null);
  const [adminLoading, setAdminLoading] = useState(true);
  const hasProfileLocation = Boolean(profile?.location);
  const profileLocationKey = profile?.location
    ? `${profile.location.city}|${profile.location.state}`
    : "";

  // Single auth state listener for the entire app
  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, (nextUser) => {
      setProfileLoading(!!nextUser);
      setUser(nextUser);
      setLoading(false);
    });
    return () => unsubscribe();
  }, []);

  // Single profile listener for the entire app
  useEffect(() => {
    if (!user) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
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

  useEffect(() => {
    if (!user) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setAdminState(null);
      setAdminLoading(false);
      return;
    }

    setAdminLoading(true);
    const unsubscribe = subscribeAdminState(user.uid, (nextAdminState) => {
      setAdminState(nextAdminState);
      setAdminLoading(false);
    });
    return () => unsubscribe();
  }, [user]);

  useEffect(() => {
    if (!user || !hasProfileLocation) {
      return;
    }
    void getUserLocation(user.uid);
  }, [user, hasProfileLocation, profileLocationKey]);

  const signIn = useCallback(async (email: string, password: string) => {
    const result = await signInWithEmailAndPassword(auth, email, password);
    return result.user;
  }, []);

  const signUp = useCallback(async (email: string, password: string) => {
    const result = await createUserWithEmailAndPassword(auth, email, password);
    const createdUser = result.user;
    const randomName = await generateUniqueUsername();
    const avatarUrl = `https://api.dicebear.com/7.x/thumbs/svg?seed=${createdUser.uid}`;
    await updateProfile(createdUser, {
      displayName: randomName,
      photoURL: avatarUrl,
    });
    await createUserProfile(createdUser.uid, {
      displayName: randomName,
      avatarUrl,
      bio: "",
      onboardingComplete: false,
      createdAt: serverTimestamp(),
    });
    try {
      await sendEmailVerification(createdUser);
    } catch {
      // Ignore verification errors so sign-up can still finish.
    }
    return createdUser;
  }, []);

  const signInWithGoogle = useCallback(async () => {
    const provider = new GoogleAuthProvider();
    const result = await signInWithPopup(auth, provider);
    const googleUser = result.user;
    const userRef = doc(db, "users", googleUser.uid);
    const snapshot = await getDoc(userRef);
    const profileData = snapshot.exists()
      ? (snapshot.data() as Partial<UserProfile>)
      : null;
    const candidateName = profileData?.displayName || googleUser.displayName?.trim();
    let displayName =
      candidateName && candidateName.length > 0
        ? candidateName
        : await generateUniqueUsername();
    if (!snapshot.exists() && candidateName) {
      const taken = await isUsernameTaken(candidateName);
      if (taken) {
        displayName = await generateUniqueUsername();
      }
    }
    const avatarUrl = `https://api.dicebear.com/7.x/thumbs/svg?seed=${googleUser.uid}`;
    if (!snapshot.exists()) {
      await createUserProfile(googleUser.uid, {
        displayName,
        avatarUrl,
        bio: "",
        onboardingComplete: false,
        createdAt: serverTimestamp(),
      });
      await updateProfile(googleUser, {
        displayName,
        photoURL: avatarUrl,
      });
    } else {
      const needsAvatar =
        !profileData?.avatarUrl ||
        (profileData.avatarUrl ?? "").includes("googleusercontent");
      if (needsAvatar || !profileData?.displayName) {
        await setDoc(
          userRef,
          {
            displayName,
            avatarUrl: profileData?.avatarUrl || avatarUrl,
          },
          { merge: true }
        );
        await updateProfile(googleUser, {
          displayName,
          photoURL: profileData?.avatarUrl || avatarUrl,
        });
      }
    }
    return googleUser;
  }, []);

  const signOut = useCallback(async () => {
    await firebaseSignOut(auth);
  }, []);

  const isAdmin = adminState?.role === "admin";
  const isBanned = adminState?.banned === true;

  const value = useMemo(
    () => ({
      user,
      loading,
      profile,
      profileLoading,
      adminLoading,
      isAdmin,
      isBanned,
      signIn,
      signUp,
      signInWithGoogle,
      signOut,
    }),
    [
      user,
      loading,
      profile,
      profileLoading,
      adminLoading,
      isAdmin,
      isBanned,
      signIn,
      signUp,
      signInWithGoogle,
      signOut,
    ]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
