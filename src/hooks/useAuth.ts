import { useCallback, useEffect, useState } from "react";
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
import {
  createUserProfile,
  generateUniqueUsername,
  isUsernameTaken,
  type UserProfile,
} from "../services/users";

type UseAuthResult = {
  user: User | null;
  loading: boolean;
  profile: UserProfile | null;
  profileLoading: boolean;
  isBanned: boolean;
  signIn: (email: string, password: string) => Promise<User>;
  signUp: (email: string, password: string) => Promise<User>;
  signInWithGoogle: () => Promise<User>;
  signOut: () => Promise<void>;
};

export function useAuth(): UseAuthResult {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [profileLoading, setProfileLoading] = useState(true);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, (nextUser) => {
      setProfileLoading(!!nextUser);
      setUser(nextUser);
      setLoading(false);
    });

    return () => unsubscribe();
  }, []);

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
      email: createdUser.email || email,
      followerCount: 0,
      followingCount: 0,
      followingPetsCount: 0,
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
        email: googleUser.email ?? "",
        followingCount: 0,
        followerCount: 0,
        followingPetsCount: 0,
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

  return {
    user,
    loading,
    profile,
    profileLoading,
    isBanned: !!profile?.banned,
    signIn,
    signUp,
    signInWithGoogle,
    signOut,
  };
}
