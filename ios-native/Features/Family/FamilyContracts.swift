import Foundation

// MARK: - TEMPORARY LOCATION
//
// `FamilyRepository` and the value types below belong with the shared
// repository protocols and models, which are the coordinator's. Listed in the
// batch report.

/// A live invitation code, as `createInvitationCallable` and
/// `getActiveInvitationCallable` return it.
///
/// A code is a standing grant of write access to somebody else's pet for 48
/// hours, single-use, and dies early if it is revoked or if the person who
/// made it stops being an owner.
struct Invitation: Sendable, Equatable {
    /// Eight characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
    let code: String
    let createdBy: String
    let createdByName: String
    let expiresAt: Date
    let petID: String

    /// "ABCD EFGH", as the web modal shows it.
    var formattedCode: String { InvitationCode.format(code) }
}

/// What `validateInvitationCallable` said about a typed code.
enum InvitationCheck: Sendable, Equatable {
    case valid(petID: String, petName: String)
    /// `{ valid: false, error: "Invalid or expired invitation code." }`
    case invalid
    /// `{ valid: false, error: "Pet not found." }`
    case petGone
}

/// A successful redemption.
struct JoinedPet: Sendable, Equatable {
    let petID: String
    let petName: String
}

/// What `removeFamilyMemberCallable` reports it did. `action` on the wire.
enum FamilyRemoval: Sendable, Equatable {
    /// An ordinary member left or was removed.
    case memberRemoved
    /// The primary left, and the role went to whoever has been in the family
    /// longest (`pickSuccessor`).
    case handedOver
    /// The target was not in the family by the time the transaction ran — a
    /// removal that raced another. Nothing left to do.
    case wasNotAMember
    /// An `action` this client does not know.
    case other(String)

    init(action: String) {
        switch action {
        case "member_removed": self = .memberRemoved
        case "handed_over": self = .handedOver
        case "not_a_member": self = .wasNotAMember
        default: self = .other(action)
        }
    }
}

/// One case per refusal the family and invitation callables raise, in words
/// the recovery needs to distinguish.
enum FamilyError: Error, Sendable, Equatable {
    case notSignedIn
    case banned
    case accountDeleted
    case petNotFound
    /// `permission-denied` from the membership check: the caller is not one
    /// of this pet's owners (any more).
    case notAnOwner
    /// `permission-denied` "Only the pet's primary owner can …". Removing
    /// *another* owner and handing the role on are the primary's alone.
    case notPrimary
    /// `failed-precondition` "Transfer the primary owner role before removing
    /// this person." The primary can leave, but cannot be pushed out.
    case targetIsPrimary
    /// `failed-precondition` "You are this pet's only owner. …" A leave never
    /// destroys the pet; the last owner has to delete it deliberately.
    case lastOwner
    /// `failed-precondition` on a transfer: the target is not in the family.
    case targetNotInFamily
    /// `not-found` / `failed-precondition` "no longer valid": mistyped, used,
    /// or expired. The server does not say which, and neither does this.
    case invitationInvalid
    /// `failed-precondition` "This invitation was revoked."
    case invitationRevoked
    /// `failed-precondition`: whoever made the code is no longer an owner.
    case inviterLeft
    /// `already-exists` on a redeem.
    case alreadyMember
    /// `invalid-argument`: not eight characters after normalising.
    case malformedCode
    /// `not-found` on a revoke: no such code on this pet.
    case invitationNotFound
    /// `resource-exhausted` "Could not generate an invitation code." Ten
    /// collisions in a row; a second try is expected to work.
    case couldNotGenerate
    case rateLimited
    /// Any other content refusal. Never retryable as-is.
    case rejected
    case offline
    case callablesUnavailable
    /// Sent, and no answer. The screen settles it by reading — see each
    /// model's recovery — rather than by repeating a write.
    case outcomeUnknown
    case transport(String)
}

protocol FamilyRepository: Sendable {
    func activeInvitation(petID: String) async throws -> Invitation?
    /// Hands back the existing live code when there is one, so calling it
    /// twice does not mint two.
    func createInvitation(petID: String) async throws -> Invitation
    /// - Returns: true when the code was already dead (used, revoked, expired).
    func revokeInvitation(petID: String, code: String) async throws -> Bool
    func validateInvitation(code: String) async throws -> InvitationCheck
    func redeemInvitation(
        code: String, relationship: PetFamilyRelationship, customRelationship: String?
    ) async throws -> JoinedPet
    /// Removes `userID` from the family. With the caller's own uid, this is
    /// *leaving* — the web client's only way out, and the server's.
    func removeMember(petID: String, userID: String) async throws -> FamilyRemoval
    /// - Returns: true when the target already held the role.
    func transferPrimary(petID: String, to userID: String) async throws -> Bool
    /// `pets/{petId}/family/{uid}` exists. World-readable, and the ground
    /// truth any unknown outcome is settled against.
    func isMember(petID: String, userID: String) async throws -> Bool
}

/// Invitation-code text handling, mirroring `normalizeInvitationCode` on the
/// server and `formatCode` in the web modal.
enum InvitationCode {
    static let length = 8

    /// Letters and digits only, upper-cased, at most eight — what the server
    /// does to whatever it is sent, so a pasted "abcd-efgh" works.
    static func normalize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars
        where scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
            if scalars.count == length { break }
        }
        return String(scalars).uppercased()
    }

    static func format(_ code: String) -> String {
        let normalized = normalize(code)
        guard normalized.count > 4 else { return normalized }
        let split = normalized.index(normalized.startIndex, offsetBy: 4)
        return "\(normalized[..<split]) \(normalized[split...])"
    }

    static func isComplete(_ code: String) -> Bool { normalize(code).count == length }
}
