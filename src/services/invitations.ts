import {
  Timestamp,
  collection,
  collectionGroup,
  doc,
  getDoc,
  getDocs,
  limit,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
} from "firebase/firestore";
import { db } from "./firebase";
import type { PetFamilyRelationship } from "./pets";
import { removeUndefined } from "../utils/removeUndefined";

export type Invitation = {
  code: string;
  createdBy: string;
  createdByName: string;
  expiresAt: unknown;
  used: boolean;
  usedBy?: string;
  usedByName?: string;
  createdAt?: unknown;
  petId?: string;
};

type UseInvitationResult = {
  success: boolean;
  petId?: string;
  petName?: string;
  error?: string;
};

const INVITE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

const normalizeCode = (code: string): string =>
  code.replace(/[^a-zA-Z0-9]/g, "").toUpperCase();

const withCustomRelationship = (
  relationship: PetFamilyRelationship,
  customRelationship?: string
) => {
  if (relationship !== "other") {
    return {};
  }
  const normalized = customRelationship?.trim();
  return normalized ? { customRelationship: normalized } : {};
};

export function generateInviteCode(): string {
  let code = "";
  for (let index = 0; index < 8; index += 1) {
    code += INVITE_CHARS[Math.floor(Math.random() * INVITE_CHARS.length)];
  }
  return code;
}

export async function createInvitation(
  petId: string,
  userId: string,
  userName: string
): Promise<string> {
  const memberRef = doc(db, `pets/${petId}/family/${userId}`);
  const memberSnap = await getDoc(memberRef);
  if (!memberSnap.exists()) {
    throw new Error("Only family members can create invitation codes.");
  }

  let code = generateInviteCode();
  let attempts = 0;
  while (attempts < 10) {
    const inviteRef = doc(db, `pets/${petId}/invitations/${code}`);
    const inviteSnap = await getDoc(inviteRef);
    if (!inviteSnap.exists()) {
      const expiresAt = new Date(Date.now() + 48 * 60 * 60 * 1000);
      await setDoc(inviteRef, {
        code,
        createdBy: userId,
        createdByName: userName,
        expiresAt: Timestamp.fromDate(expiresAt),
        used: false,
        createdAt: serverTimestamp(),
      });
      return code;
    }
    code = generateInviteCode();
    attempts += 1;
  }

  throw new Error("Could not generate an invitation code. Please try again.");
}

export async function validateInvitationCode(code: string): Promise<{
  valid: boolean;
  petId?: string;
  petName?: string;
  invitationRefPath?: string;
  error?: string;
}> {
  try {
    const normalized = normalizeCode(code);
    if (normalized.length !== 8) {
      return { valid: false, error: "Invitation code must be 8 characters." };
    }

    // Keep this query on a single field to avoid requiring a composite index.
    const invitationQuery = query(
      collectionGroup(db, "invitations"),
      where("code", "==", normalized),
      limit(5)
    );
    const invitationSnapshot = await getDocs(invitationQuery);
    if (invitationSnapshot.empty) {
      return { valid: false, error: "Invalid or expired invitation code." };
    }

    const candidate = invitationSnapshot.docs
      .map((docSnap) => ({
        docSnap,
        data: docSnap.data() as Invitation,
      }))
      .find((item) => {
        if (item.data.used) return false;
        const expiresDate =
          item.data.expiresAt &&
          typeof item.data.expiresAt === "object" &&
          "toDate" in item.data.expiresAt &&
          typeof (item.data.expiresAt as { toDate: () => Date }).toDate ===
            "function"
            ? (item.data.expiresAt as { toDate: () => Date }).toDate()
            : null;
        if (!expiresDate) return false;
        return expiresDate.getTime() >= Date.now();
      });

    if (!candidate) {
      return { valid: false, error: "Invalid or expired invitation code." };
    }

    const petId = candidate.docSnap.ref.parent.parent?.id;
    if (!petId) {
      return { valid: false, error: "Could not find the associated pet." };
    }

    const petSnap = await getDoc(doc(db, "pets", petId));
    if (!petSnap.exists()) {
      return { valid: false, error: "Could not find the associated pet." };
    }

    return {
      valid: true,
      petId,
      petName: (petSnap.data() as { name?: string }).name || "Pet",
      invitationRefPath: candidate.docSnap.ref.path,
    };
  } catch (error) {
    console.error("Error validating invitation code:", error);
    return {
      valid: false,
      error: "Failed to validate code. Please try again.",
    };
  }
}

export async function useInvitation(
  code: string,
  userId: string,
  userName: string,
  userAvatar: string,
  relationship: PetFamilyRelationship,
  customRelationship?: string
): Promise<UseInvitationResult> {
  const normalized = normalizeCode(code);
  const preview = await validateInvitationCode(normalized);
  if (!preview.valid || !preview.petId) {
    return {
      success: false,
      error: preview.error || "Invalid or expired invitation code.",
    };
  }

  const familyRef = doc(db, `pets/${preview.petId}/family/${userId}`);
  const existingFamilySnap = await getDoc(familyRef);
  if (existingFamilySnap.exists()) {
    return {
      success: false,
      error: "You are already a family member of this pet.",
    };
  }

  const invitationRef = doc(
    db,
    preview.invitationRefPath || `pets/${preview.petId}/invitations/${normalized}`
  );

  await setDoc(
    familyRef,
    removeUndefined({
      userId,
      userName,
      userAvatar:
        userAvatar || `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`,
      relationship,
      role: "member",
      invitationCode: normalized,
      ...withCustomRelationship(relationship, customRelationship),
      joinedAt: serverTimestamp(),
    })
  );

  await updateDoc(invitationRef, {
    used: true,
    usedBy: userId,
    usedByName: userName,
  });

  return { success: true, petId: preview.petId, petName: preview.petName };
}

export async function getActiveInvitations(
  petId: string
): Promise<Invitation[]> {
  const invitationsRef = collection(db, `pets/${petId}/invitations`);
  const snapshot = await getDocs(invitationsRef);
  return snapshot.docs
    .map((docSnap) => ({
      ...(docSnap.data() as Invitation),
      code: docSnap.id,
      petId,
    }))
    .filter((invitation) => {
      if (invitation.used) {
        return false;
      }
      if (
        invitation.expiresAt &&
        typeof invitation.expiresAt === "object" &&
        "toDate" in invitation.expiresAt &&
        typeof (invitation.expiresAt as { toDate: () => Date }).toDate ===
          "function"
      ) {
        const expiresAt = (invitation.expiresAt as { toDate: () => Date }).toDate();
        return expiresAt.getTime() > Date.now();
      }
      return false;
    })
    .sort((left, right) => {
      const leftDate =
        left.createdAt &&
        typeof left.createdAt === "object" &&
        "toDate" in left.createdAt &&
        typeof (left.createdAt as { toDate: () => Date }).toDate === "function"
          ? (left.createdAt as { toDate: () => Date }).toDate().getTime()
          : 0;
      const rightDate =
        right.createdAt &&
        typeof right.createdAt === "object" &&
        "toDate" in right.createdAt &&
        typeof (right.createdAt as { toDate: () => Date }).toDate === "function"
          ? (right.createdAt as { toDate: () => Date }).toDate().getTime()
          : 0;
      return rightDate - leftDate;
    });
}
