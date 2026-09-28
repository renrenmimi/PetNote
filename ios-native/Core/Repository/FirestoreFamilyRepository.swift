import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// Shared ownership: invitations, joining, leaving, removing, handing on.
///
/// **Every change goes through a callable.** `firestore.rules` refuses every
/// client create, update and delete under `pets/{id}/family` and
/// `pets/{id}/invitations`, and refuses even *reads* of invitations and of
/// `invitationCodes`. That is not a hurdle to route around: the callables are
/// where the rights split lives — "adding is equal, taking away converges" —
/// and where it is decided inside a transaction against what is true at that
/// moment rather than against what this screen last read.
///
/// The single direct read, `isMember`, is the family document itself, which is
/// world-readable and is what every unknown outcome is settled against.
actor FirestoreFamilyRepository: FamilyRepository {
    private let db: Firestore
    private let functions: Functions
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "family")

    init(
        db: Firestore = .firestore(),
        functions: Functions = .functions(),
        environment: AppEnvironment = .current
    ) {
        self.db = db
        self.functions = functions
        self.environment = environment
    }

    // MARK: - Invitations

    func activeInvitation(petID: String) async throws -> Invitation? {
        guard let pet = DeepLink.validDocumentID(petID) else { throw FamilyError.petNotFound }
        let data = try await call(Callables.getActiveInvitation, ["petId": pet], as: .readInvitation)
        guard let raw = data["invitation"] as? [String: Any] else { return nil }
        return Self.invitation(from: raw, petID: pet)
    }

    func createInvitation(petID: String) async throws -> Invitation {
        guard let pet = DeepLink.validDocumentID(petID) else { throw FamilyError.petNotFound }
        let data = try await call(Callables.createInvitation, ["petId": pet], as: .createInvitation)
        guard let invitation = Self.invitation(from: data, petID: pet) else {
            // A code may exist now; the screen reads the active one back
            // rather than showing a code it cannot vouch for.
            log.error("createInvitationCallable returned an unexpected shape")
            throw FamilyError.outcomeUnknown
        }
        return invitation
    }

    func revokeInvitation(petID: String, code: String) async throws -> Bool {
        guard let pet = DeepLink.validDocumentID(petID) else { throw FamilyError.petNotFound }
        let normalized = InvitationCode.normalize(code)
        guard normalized.count == InvitationCode.length else { throw FamilyError.malformedCode }
        let data = try await call(
            Callables.revokeInvitation, ["petId": pet, "code": normalized], as: .revokeInvitation
        )
        return (data["alreadyInactive"] as? Bool) ?? false
    }

    func validateInvitation(code: String) async throws -> InvitationCheck {
        let normalized = InvitationCode.normalize(code)
        guard normalized.count == InvitationCode.length else { throw FamilyError.malformedCode }
        let data = try await call(Callables.validateInvitation, ["code": normalized], as: .validate)
        return Self.check(from: data)
    }

    func redeemInvitation(
        code: String, relationship: PetFamilyRelationship, customRelationship: String?
    ) async throws -> JoinedPet {
        let normalized = InvitationCode.normalize(code)
        guard normalized.count == InvitationCode.length else { throw FamilyError.malformedCode }
        let custom = Self.customRelationship(relationship, customRelationship)
        let data: [String: Any]
        if let custom {
            data = try await call(
                Callables.redeemInvitation,
                ["code": normalized, "relationship": relationship.rawValue, "customRelationship": custom],
                as: .redeem
            )
        } else {
            data = try await call(
                Callables.redeemInvitation,
                ["code": normalized, "relationship": relationship.rawValue],
                as: .redeem
            )
        }
        guard let petID = data["petId"] as? String, !petID.isEmpty else {
            log.error("redeemInvitationCallable returned an unexpected shape")
            throw FamilyError.outcomeUnknown
        }
        return JoinedPet(petID: petID, petName: SocialDecoder.nonEmpty(data["petName"]) ?? String(localized: "Pet", comment: "Stand-in name for a pet whose name is missing"))
    }

    // MARK: - Membership changes

    func removeMember(petID: String, userID: String) async throws -> FamilyRemoval {
        guard let pet = DeepLink.validDocumentID(petID),
              let user = DeepLink.validDocumentID(userID) else { throw FamilyError.petNotFound }
        let data = try await call(
            Callables.removeFamilyMember, ["petId": pet, "targetUserId": user], as: .remove
        )
        return FamilyRemoval(action: (data["action"] as? String) ?? "")
    }

    func transferPrimary(petID: String, to userID: String) async throws -> Bool {
        guard let pet = DeepLink.validDocumentID(petID),
              let user = DeepLink.validDocumentID(userID) else { throw FamilyError.petNotFound }
        let data = try await call(
            Callables.transferPetPrimary, ["petId": pet, "targetUserId": user], as: .transfer
        )
        return (data["alreadyPrimary"] as? Bool) ?? false
    }

    func isMember(petID: String, userID: String) async throws -> Bool {
        guard let pet = DeepLink.validDocumentID(petID),
              let user = DeepLink.validDocumentID(userID) else { return false }
        do {
            return try await db.collection("pets").document(pet)
                .collection("family").document(user)
                .getDocument().exists
        } catch {
            log.error("family membership read failed: \(String(describing: error), privacy: .public)")
            let nsError = error as NSError
            if nsError.domain == FirestoreErrorDomain,
               nsError.code == FirestoreErrorCode.Code.unavailable.rawValue {
                throw FamilyError.offline
            }
            throw FamilyError.transport("firestore/\(nsError.code)")
        }
    }

    // MARK: - Decoding

    static func invitation(from raw: [String: Any], petID: String) -> Invitation? {
        guard let code = raw["code"] as? String,
              InvitationCode.normalize(code) == code,
              code.count == InvitationCode.length else { return nil }
        let millis = number(raw["expiresAtMillis"]) ?? 0
        return Invitation(
            code: code,
            createdBy: (raw["createdBy"] as? String) ?? "",
            createdByName: SocialDecoder.nonEmpty(raw["createdByName"]) ?? String(localized: "PetNote User"),
            expiresAt: Date(timeIntervalSince1970: millis / 1000),
            petID: SocialDecoder.nonEmpty(raw["petId"]) ?? petID
        )
    }

    static func check(from data: [String: Any]) -> InvitationCheck {
        if (data["valid"] as? Bool) == true,
           let petID = SocialDecoder.nonEmpty(data["petId"]) {
            return .valid(petID: petID, petName: SocialDecoder.nonEmpty(data["petName"]) ?? String(localized: "Pet", comment: "Stand-in name for a pet whose name is missing"))
        }
        let error = ((data["error"] as? String) ?? "").lowercased()
        return error.contains("pet not found") ? .petGone : .invalid
    }

    /// Only `other` carries a custom label, trimmed and capped at the server's
    /// limit (`VALIDATION_LIMITS.petCustomRelationship`) — sending more would
    /// be refused outright rather than truncated.
    static func customRelationship(
        _ relationship: PetFamilyRelationship, _ raw: String?
    ) -> String? {
        guard relationship == .other,
              let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(PetValidation.customRelationshipLimit))
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let int as Int: return Double(int)
        case let int64 as Int64: return Double(int64)
        case let double as Double where double.isFinite: return double
        default: return nil
        }
    }

    // MARK: - Calling

    enum Operation: Sendable {
        case readInvitation
        case createInvitation
        case revokeInvitation
        case validate
        case redeem
        case remove
        case transfer
    }

    private func call(
        _ name: String, _ payload: sending [String: Any], as operation: Operation
    ) async throws -> [String: Any] {
        guard environment.supportsCallables else {
            log.error("callables are unreachable from this build; refusing to send \(name, privacy: .public)")
            throw FamilyError.callablesUnavailable
        }
        do {
            return try await CallableClient.call(name, payload, functions: functions)
        } catch {
            let nsError = error as NSError
            log.error("""
                \(name, privacy: .public) failed: \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code) \
                desc=\(nsError.localizedDescription, privacy: .public)
                """)
            throw Self.map(error, for: operation)
        }
    }

    /// Maps a callable failure onto functions/src/family.ts and invitations.ts.
    ///
    /// The server overloads `failed-precondition`, `permission-denied` and
    /// `not-found` across meanings whose recovery differs — "you are the only
    /// owner" and "transfer the role first" are both the first, and a person
    /// has to be told which. The message is matched only to separate those,
    /// and every branch has an operation-specific fallback so a rewording on
    /// the server degrades to a sensible case rather than a wrong one.
    static func map(_ error: Error, for operation: Operation) -> FamilyError {
        if let already = error as? FamilyError { return already }
        switch CallableFailure.classify(error) {
        case .neverSent: return .offline
        case .unavailable: return .callablesUnavailable
        case .unknownOutcome: return .outcomeUnknown
        case .server(let code, let message):
            return map(code: code, message: message, for: operation)
        }
    }

    private static func map(
        code: FunctionsErrorCode, message: String, for operation: Operation
    ) -> FamilyError {
        switch code {
        case .unauthenticated:
            return .notSignedIn

        case .permissionDenied:
            if message.contains("banned") { return .banned }
            if message.contains("primary owner") { return .notPrimary }
            return .notAnOwner

        case .failedPrecondition:
            if CallableFailure.isAccountDeletion(message) { return .accountDeleted }
            if message.contains("revoked") { return .invitationRevoked }
            // Before the transfer wording below, which shares "part of this
            // pet's family".
            if message.contains("sent this invitation") { return .inviterLeft }
            if message.contains("transfer the primary") { return .targetIsPrimary }
            if message.contains("only owner") { return .lastOwner }
            if message.contains("not part of this pet's family") { return .targetNotInFamily }
            if message.contains("no longer valid") { return .invitationInvalid }
            switch operation {
            case .redeem, .validate: return .invitationInvalid
            case .transfer: return .targetNotInFamily
            default: return .rejected
            }

        case .notFound:
            switch operation {
            case .redeem, .validate:
                return message.contains("pet not found") ? .petNotFound : .invitationInvalid
            case .revokeInvitation:
                return message.contains("invitation not found") ? .invitationNotFound : .petNotFound
            default:
                return .petNotFound
            }

        case .alreadyExists:
            return .alreadyMember

        case .invalidArgument, .outOfRange:
            if message.contains("8 characters") { return .malformedCode }
            return .rejected

        case .resourceExhausted:
            return message.contains("could not generate") ? .couldNotGenerate : .rateLimited

        default:
            return .transport("functions/\(code.rawValue)")
        }
    }
}
