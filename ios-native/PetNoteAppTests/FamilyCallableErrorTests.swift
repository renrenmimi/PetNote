import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// The family and invitation callables overload three status codes across
/// meanings a person has to be told apart. Every message below is copied from
/// functions/src/family.ts and invitations.ts.
struct FamilyCallableErrorTests {
    private func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
        NSError(
            domain: FunctionsErrorDomain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func map(
        _ code: FunctionsErrorCode, _ message: String,
        _ operation: FirestoreFamilyRepository.Operation
    ) -> FamilyError {
        FirestoreFamilyRepository.map(functionsError(code, message), for: operation)
    }

    // MARK: - removeFamilyMemberCallable

    @Test func removingSomebodyElseAsAMemberIsNotPrimary() {
        #expect(map(.permissionDenied,
                    "Only the pet's primary owner can remove another family member.",
                    .remove) == .notPrimary)
        #expect(map(.permissionDenied, "Cannot remove this family member.", .remove) == .notAnOwner)
        #expect(map(.permissionDenied, "Banned users cannot remove family members.", .remove) == .banned)
    }

    /// Both are `failed-precondition` and need opposite advice: hand the role
    /// on first, versus invite someone first or delete the pet.
    @Test func thePrimaryAndTheLastOwnerAreToldApart() {
        #expect(map(.failedPrecondition,
                    "Transfer the primary owner role before removing this person.",
                    .remove) == .targetIsPrimary)
        #expect(map(.failedPrecondition,
                    "You are this pet's only owner. Invite someone else first, or delete the pet.",
                    .remove) == .lastOwner)
        #expect(map(.failedPrecondition, "This account has been deleted.", .remove) == .accountDeleted)
    }

    @Test func theRemovalsActionIsRead() {
        #expect(FamilyRemoval(action: "member_removed") == .memberRemoved)
        #expect(FamilyRemoval(action: "handed_over") == .handedOver)
        #expect(FamilyRemoval(action: "not_a_member") == .wasNotAMember)
        #expect(FamilyRemoval(action: "pet_deleted") == .other("pet_deleted"))
    }

    // MARK: - transferPetPrimaryCallable

    @Test func transferRefusalsKeepTheirMeaning() {
        #expect(map(.permissionDenied,
                    "Only the pet's primary owner can transfer the role.",
                    .transfer) == .notPrimary)
        #expect(map(.permissionDenied, "Banned users cannot transfer pets.", .transfer) == .banned)
        #expect(map(.failedPrecondition,
                    "That person is not part of this pet's family.",
                    .transfer) == .targetNotInFamily)
        #expect(map(.notFound, "Pet not found.", .transfer) == .petNotFound)
    }

    // MARK: - redeemInvitationCallable

    /// "Not part of this pet's family" appears in both the inviter-left and
    /// the transfer refusal; the inviter case has to win on a redeem.
    @Test func anInviterWhoLeftIsNotConfusedWithATransferTarget() {
        #expect(map(.failedPrecondition,
                    "The person who sent this invitation is no longer part of this pet's family.",
                    .redeem) == .inviterLeft)
    }

    @Test func redeemRefusalsKeepTheirMeaning() {
        #expect(map(.failedPrecondition, "This invitation was revoked.", .redeem) == .invitationRevoked)
        #expect(map(.failedPrecondition, "Invitation is no longer valid.", .redeem) == .invitationInvalid)
        #expect(map(.notFound, "Invalid or expired invitation code.", .redeem) == .invitationInvalid)
        #expect(map(.notFound, "Invitation no longer exists.", .redeem) == .invitationInvalid)
        #expect(map(.notFound, "Associated pet not found.", .redeem) == .petNotFound)
        #expect(map(.alreadyExists, "You are already a family member of this pet.", .redeem) == .alreadyMember)
        #expect(map(.invalidArgument, "Invitation code must be 8 characters.", .redeem) == .malformedCode)
        #expect(map(.invalidArgument, "Invalid relationship.", .redeem) == .rejected)
    }

    // MARK: - Invitations

    @Test func invitationRefusalsKeepTheirMeaning() {
        #expect(map(.permissionDenied,
                    "Only family members can access invitations.",
                    .createInvitation) == .notAnOwner)
        #expect(map(.resourceExhausted,
                    "Could not generate an invitation code.",
                    .createInvitation) == .couldNotGenerate)
        #expect(map(.resourceExhausted,
                    "Too many requests. Please wait a moment and try again.",
                    .createInvitation) == .rateLimited)
        #expect(map(.notFound, "Invitation not found for this pet.", .revokeInvitation) == .invitationNotFound)
    }

    @Test func aLostAnswerIsUnknownAndANeverSentOneIsOffline() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(FirestoreFamilyRepository.map(timedOut, for: .redeem) == .outcomeUnknown)
        #expect(FirestoreFamilyRepository.map(offline, for: .redeem) == .offline)
        #expect(map(.unavailable, "unavailable", .remove) == .outcomeUnknown)
    }

    // MARK: - Decoding

    @Test func anInvitationIsDecodedFromTheCallablesShape() {
        let invitation = FirestoreFamilyRepository.invitation(
            from: [
                "code": "ABCD2345", "createdBy": "alice", "createdByName": "Alice",
                "expiresAtMillis": 1_700_000_000_000, "used": false, "petId": "pet-1",
            ],
            petID: "pet-1"
        )
        #expect(invitation?.code == "ABCD2345")
        #expect(invitation?.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(FirestoreFamilyRepository.invitation(from: ["code": "short"], petID: "p") == nil)
        #expect(FirestoreFamilyRepository.invitation(from: ["code": "abcd2345"], petID: "p") == nil)
    }

    @Test func aValidationAnswerIsDecoded() {
        #expect(FirestoreFamilyRepository.check(from: ["valid": true, "petId": "p1", "petName": "Mochi"])
                == .valid(petID: "p1", petName: "Mochi"))
        #expect(FirestoreFamilyRepository.check(from: ["valid": false, "error": "Invalid or expired invitation code."])
                == .invalid)
        #expect(FirestoreFamilyRepository.check(from: ["valid": false, "error": "Pet not found."]) == .petGone)
        #expect(FirestoreFamilyRepository.check(from: ["valid": true]) == .invalid)
    }
}
