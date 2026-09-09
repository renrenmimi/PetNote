import { createContext, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
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
import { doc, getDoc, onSnapshot, serverTimestamp } from "firebase/firestore";
import { auth, db } from "../services/firebase";
import { getUserLocation } from "../services/location";
import {
  subscribeAdminState,
  type AdminState,
} from "../services/adminState";
import {
  createUserProfile,
  clearUserProfileCache,
  generateUniqueUsername,
  isUsernameTaken,
  updateUserProfile,
  type UserProfile,
} from "../services/users";
import { clearPetCache } from "../services/pets";
import { clearCachedUsers } from "../hooks/useUserCache";
import { isAccountDeletionInProgress } from "../services/accountDeletion";

/**
 * What actually happened during sign-up.
 *
 * The account, the profile document and the verification email are three
 * separate operations against two different systems, and they fail
 * independently. Collapsing them into "threw or didn't" is what made a failed
 * verification send silent and a failed profile write look like "sign up
 * failed" — after which the person tried again and hit
 * `auth/email-already-in-use` on their own brand-new account.
 */
export type SignUpOutcome = {
  user: User;
  /** False when the account exists but its profile document write failed. */
  profileCreated: boolean;
  /** False when the account exists but no verification email went out. */
  verificationSent: boolean;
};

type AuthContextValue = {
  user: User | null;
  /**
   * Whether the signed-in account's email is verified, as React state.
   *
   * Not read off `user.emailVerified` by consumers, because `user.reload()`
   * mutates that same User instance in place — the value changes and nothing
   * re-renders. Every gate in the app reads this so that pressing "I verified
   * my email" unblocks the composer immediately, with the draft still in it,
   * instead of after a reload.
   */
  emailVerified: boolean;
  loading: boolean;
  profile: UserProfile | null;
  profileLoading: boolean;
  adminLoading: boolean;
  isAdmin: boolean;
  isBanned: boolean;
  signIn: (email: string, password: string) => Promise<User>;
  signUp: (email: string, password: string) => Promise<SignUpOutcome>;
  signInWithGoogle: () => Promise<User>;
  signOut: () => Promise<void>;
  /**
   * Re-reads the Auth user and forces an ID-token refresh, returning whether
   * the email is verified now.
   *
   * Needed because nothing tells this tab that the person followed the
   * verification link — possibly in a different browser. onAuthStateChanged
   * does not fire for it, and the callables that gate publishing check the
   * token's `email_verified` claim, so a stale token keeps refusing even after
   * verification actually happened.
   */
  refreshUser: () => Promise<boolean>;
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
  const [emailVerified, setEmailVerified] = useState(false);
  const profileRepairingRef = useRef<Set<string>>(new Set());
  // Set true once we've seen this user's doc carry deletionPending; if the
  // doc then disappears we treat it as a finalized deletion and refuse to
  // repair it (see the profile listener below).
  const sawDeletionPendingRef = useRef(false);
  const hasProfileLocation = Boolean(profile?.location);
  const profileLocationKey = profile?.location
    ? `${profile.location.city}|${profile.location.state}`
    : "";

  // Single auth state listener for the entire app
  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, (nextUser) => {
      setProfileLoading(!!nextUser);
      setUser(nextUser);
      setEmailVerified(!!nextUser?.emailVerified);
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
    sawDeletionPendingRef.current = false;
    const userRef = doc(db, "users", user.uid);
    const unsubscribe = onSnapshot(userRef, (snapshot) => {
      if (!snapshot.exists()) {
        // Account is mid-deletion: do NOT repair/recreate the profile, or
        // the listener resurrects the user doc + username reservation the
        // backend just removed. Sign out so the listener detaches instead.
        if (
          sawDeletionPendingRef.current ||
          isAccountDeletionInProgress(user.uid)
        ) {
          setProfile(null);
          setProfileLoading(false);
          // Mirror signOut()'s local cache clearing so a passive tab that
          // observes the deletion doesn't keep stale profile/pet/user caches.
          clearUserProfileCache();
          clearPetCache();
          clearCachedUsers();
          void firebaseSignOut(auth);
          return;
        }
        if (!profileRepairingRef.current.has(user.uid)) {
          profileRepairingRef.current.add(user.uid);
          void (async () => {
            const displayName =
              user.displayName?.trim() || (await generateUniqueUsername());
            await createUserProfile(user.uid, {
              displayName,
              avatarUrl:
                user.photoURL ||
                `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
              bio: "",
              onboardingComplete: false,
              createdAt: serverTimestamp(),
            });
          })()
            .catch(() => {
              setProfile(null);
              setProfileLoading(false);
            })
            .finally(() => {
              profileRepairingRef.current.delete(user.uid);
            });
        }
        return;
      }
      const data = snapshot.data() as Omit<UserProfile, "id"> & {
        deletionPending?: boolean;
      };
      if (data.deletionPending === true) {
        // Account is being torn down — show current data but never trigger a
        // profile repair (the !exists() branch will sign out shortly).
        sawDeletionPendingRef.current = true;
        setProfile({ id: snapshot.id, ...data });
        setProfileLoading(false);
        return;
      }
      const needsProfileRepair =
        !data.displayName?.trim() || !data.avatarUrl?.trim();
      if (needsProfileRepair && !profileRepairingRef.current.has(user.uid)) {
        profileRepairingRef.current.add(user.uid);
        void (async () => {
          await updateUserProfile(user.uid, {
            displayName:
              data.displayName?.trim() ||
              user.displayName?.trim() ||
              (await generateUniqueUsername()),
            avatarUrl:
              data.avatarUrl?.trim() ||
              user.photoURL ||
              `https://api.dicebear.com/7.x/thumbs/svg?seed=${user.uid}`,
          });
        })().finally(() => {
          profileRepairingRef.current.delete(user.uid);
        });
      }
      setProfile({
        id: snapshot.id,
        ...data,
      });
      setProfileLoading(false);
    },
    (error) => {
      // Without an error handler a denied/failed subscription silently
      // detached and left profileLoading stuck at true (which suppresses
      // onboarding gating in Feed forever).
      console.warn("Failed to subscribe to user profile:", error);
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

  const signUp = useCallback(
    async (email: string, password: string): Promise<SignUpOutcome> => {
      // Only this line can fail in a way that means "there is no account".
      // Everything after it runs against an account that already exists, so it
      // must not be allowed to present itself as a failed sign-up.
      const result = await createUserWithEmailAndPassword(auth, email, password);
      const createdUser = result.user;

      let profileCreated = false;
      try {
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
        profileCreated = true;
      } catch (error) {
        // The profile listener above repairs a missing profile document on its
        // own, so this is recoverable without the person doing anything. It is
        // still reported, because "finishing setup" is a different message
        // from "sign up failed".
        console.error("signUp: profile setup failed", error);
      }

      let verificationSent = false;
      try {
        await sendEmailVerification(createdUser);
        verificationSent = true;
      } catch (error) {
        // Was swallowed entirely, so a delivery failure looked exactly like a
        // delivered email that never arrived — and the person had no reason to
        // press Resend.
        console.error("signUp: verification email failed to send", error);
      }

      return { user: createdUser, profileCreated, verificationSent };
    },
    []
  );

  const refreshUser = useCallback(async (): Promise<boolean> => {
    const current = auth.currentUser;
    if (!current) return false;
    await current.reload();
    // Force a new ID token: the callables that gate publishing read
    // `email_verified` off the token's claims, and the cached token still says
    // false for up to an hour after the link is followed.
    await current.getIdToken(true);
    // reload() mutates the same User instance, so nothing about `user` changes
    // as far as React is concerned. This state is what re-renders the gates.
    setEmailVerified(current.emailVerified);
    return current.emailVerified;
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
        await updateUserProfile(googleUser.uid, {
          displayName,
          avatarUrl: needsAvatar ? avatarUrl : profileData?.avatarUrl || avatarUrl,
        });
      }
    }
    return googleUser;
  }, []);

  const signOut = useCallback(async () => {
    await firebaseSignOut(auth);
    clearUserProfileCache();
    clearPetCache();
    clearCachedUsers();
  }, []);

  const isAdmin = adminState?.role === "admin";
  const isBanned = adminState?.banned === true;

  const value = useMemo(
    () => ({
      user,
      emailVerified,
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
      refreshUser,
    }),
    [
      user,
      emailVerified,
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
      refreshUser,
    ]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
