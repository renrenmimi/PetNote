import { httpsCallable } from "firebase/functions";
import { functions } from "./firebase";
import type { PetFamilyRelationship } from "./pets";

export type Invitation = {
  code: string;
  createdBy: string;
  createdByName: string;
  expiresAtMillis: number;
  used: boolean;
  usedBy?: string;
  usedByName?: string;
  petId?: string;
};

type UseInvitationResult = {
  success: boolean;
  petId?: string;
  petName?: string;
  error?: string;
};

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

export async function createInvitation(
  petId: string,
  _userId: string,
  _userName: string
): Promise<Invitation> {
  void _userId;
  void _userName;
  const result = await httpsCallable<
    { petId: string },
    Invitation
  >(functions, "createInvitationCallable")({ petId });
  return result.data;
}

export async function validateInvitationCode(code: string): Promise<{
  valid: boolean;
  petId?: string;
  petName?: string;
  error?: string;
}> {
  try {
    const normalized = normalizeCode(code);
    if (normalized.length !== 8) {
      return { valid: false, error: "Invitation code must be 8 characters." };
    }
    const result = await httpsCallable<
      { code: string },
      { valid: boolean; petId?: string; petName?: string; error?: string }
    >(functions, "validateInvitationCallable")({ code: normalized });
    return result.data;
  } catch (error) {
    console.error("Error validating invitation code:", error);
    return {
      valid: false,
      error: "Failed to validate code. Please try again.",
    };
  }
}

export async function getActiveInvitation(
  petId: string
): Promise<Invitation | null> {
  const result = await httpsCallable<
    { petId: string },
    { invitation: Invitation | null }
  >(functions, "getActiveInvitationCallable")({ petId });
  return result.data.invitation;
}

export async function redeemInvitation(
  code: string,
  _userId: string,
  _userName: string,
  _userAvatar: string,
  relationship: PetFamilyRelationship,
  customRelationship?: string
): Promise<UseInvitationResult> {
  const normalized = normalizeCode(code);
  try {
    const result = await httpsCallable<
      { code: string; relationship: PetFamilyRelationship; customRelationship?: string },
      { success: boolean; petId: string; petName: string }
    >(functions, "redeemInvitationCallable")({
      code: normalized,
      relationship,
      ...withCustomRelationship(relationship, customRelationship),
    });
    return {
      success: result.data.success,
      petId: result.data.petId,
      petName: result.data.petName,
    };
  } catch (error) {
    const message =
      typeof error === "object" &&
      error !== null &&
      "message" in error &&
      typeof (error as { message?: unknown }).message === "string"
        ? (error as { message: string }).message
        : "Failed to redeem invitation.";
    return {
      success: false,
      error: message,
    };
  }
}
