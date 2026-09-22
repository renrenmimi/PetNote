import Foundation
import Observation

/// Joining a pet's family with a code somebody inside gave you.
///
/// Two steps, as on the web's "Join existing" tab: check the code, which says
/// whose family it is for, then say who you are to the pet and join.
///
/// **A lost answer is settled by reading the family document.** The code is
/// single-use, so repeating a redemption that did go through does not say
/// "already joined" — the used code is not found, and the second attempt reads
/// "invalid or expired" to somebody who is in fact now an owner. The web
/// client's automatic retry has exactly that flaw. Whether
/// `pets/{petId}/family/{uid}` exists is the answer that cannot mislead.
@MainActor
@Observable
final class JoinFamilyModel {
    enum Step: Equatable {
        case entering
        case checking
        /// The code is good; the viewer is choosing a relationship.
        case choosing(petID: String, petName: String)
        case joining(petID: String, petName: String)
        case joined(JoinedPet, alreadyMember: Bool)
    }

    private(set) var code = ""
    private(set) var step: Step = .entering
    var relationship: PetFamilyRelationship?
    private(set) var customRelationship = ""
    private(set) var message: String?

    let viewerID: String
    private let repository: any FamilyRepository
    /// Set when a redemption's answer was lost, so a later "invalid code" is
    /// checked against the family before it is believed.
    private var outcomeWasUnknown = false

    init(viewerID: String, repository: any FamilyRepository) {
        self.viewerID = viewerID
        self.repository = repository
    }

    var canCheck: Bool { step == .entering && InvitationCode.isComplete(code) }

    var canJoin: Bool {
        guard case .choosing = step else { return false }
        return relationship != nil
    }

    var formattedCode: String { InvitationCode.format(code) }

    func updateCode(_ raw: String) {
        guard step == .entering else { return }
        code = InvitationCode.normalize(raw)
        message = nil
    }

    func updateCustomRelationship(_ raw: String) {
        customRelationship = String(raw.prefix(PetValidation.customRelationshipLimit))
    }

    /// Back to the code field, keeping what was typed.
    func startOver() {
        guard step != .checking else { return }
        if case .joining = step { return }
        step = .entering
        relationship = nil
        customRelationship = ""
        message = nil
        outcomeWasUnknown = false
    }

    func check() async {
        guard canCheck else { return }
        step = .checking
        message = nil
        do {
            switch try await repository.validateInvitation(code: code) {
            case .valid(let petID, let petName):
                step = .choosing(petID: petID, petName: petName)
            case .invalid:
                step = .entering
                message = "That code is not valid, or it has expired. Ask one of the pet's owners for a new one."
            case .petGone:
                step = .entering
                message = "The pet this code was for no longer exists."
            }
        } catch {
            step = .entering
            let error = (error as? FamilyError) ?? .outcomeUnknown
            switch error {
            case .malformedCode:
                message = "An invitation code is \(InvitationCode.length) letters and numbers."
            case .outcomeUnknown, .transport:
                // A read: nothing happened, and trying again is safe.
                message = "Could not check the code. Try again."
            default:
                message = Self.wording(for: error)
            }
        }
    }

    func join() async {
        guard canJoin, case .choosing(let petID, let petName) = step,
              let relationship else { return }
        step = .joining(petID: petID, petName: petName)
        message = nil
        do {
            let joined = try await repository.redeemInvitation(
                code: code,
                relationship: relationship,
                customRelationship: relationship == .other ? customRelationship : nil
            )
            step = .joined(joined, alreadyMember: false)
        } catch {
            await recover(
                from: (error as? FamilyError) ?? .outcomeUnknown,
                petID: petID, petName: petName
            )
        }
    }

    private func recover(from error: FamilyError, petID: String, petName: String) async {
        let pet = JoinedPet(petID: petID, petName: petName)
        switch error {
        case .alreadyMember:
            step = .joined(pet, alreadyMember: true)

        case .outcomeUnknown:
            outcomeWasUnknown = true
            await settleByReading(pet, otherwise: "We could not tell whether you joined. Try again.")

        case .invitationInvalid where outcomeWasUnknown, .invitationRevoked where outcomeWasUnknown:
            // The code may be "used" because the earlier attempt used it.
            await settleByReading(pet, otherwise: Self.wording(for: error))

        case .invitationInvalid, .invitationRevoked, .inviterLeft, .petNotFound, .malformedCode:
            // The code itself will not work again. Back to the field.
            step = .entering
            relationship = nil
            message = Self.wording(for: error)

        default:
            // The code may still be good: stay on the choice and say why.
            step = .choosing(petID: petID, petName: petName)
            message = Self.wording(for: error)
        }
    }

    private func settleByReading(_ pet: JoinedPet, otherwise failure: String) async {
        do {
            if try await repository.isMember(petID: pet.petID, userID: viewerID) {
                step = .joined(pet, alreadyMember: false)
                outcomeWasUnknown = false
                return
            }
            step = .choosing(petID: pet.petID, petName: pet.petName)
            message = failure
        } catch {
            step = .choosing(petID: pet.petID, petName: pet.petName)
            message = "We could not tell whether you joined. Check your pets, or try again."
        }
    }

    static func wording(for error: FamilyError) -> String {
        switch error {
        case .invitationInvalid:
            return "That code no longer works. It may have been used already, or it expired."
        case .invitationRevoked:
            return "This invitation was revoked. Ask one of the pet's owners for a new one."
        case .inviterLeft:
            return """
                The person who sent this code is no longer one of the pet's owners, so it no \
                longer works. Ask a current owner for a new one.
                """
        case .petNotFound: return "The pet this code was for no longer exists."
        case .malformedCode: return "An invitation code is \(InvitationCode.length) letters and numbers."
        case .rejected: return "That relationship was not accepted. Choose another, or shorten it."
        case .banned: return "This account cannot join a pet's family."
        case .accountDeleted: return "This account has been deleted."
        case .notSignedIn: return "Sign in again to do that."
        case .rateLimited: return "Too many requests just now. Wait a moment and try again."
        case .offline: return "No connection. Nothing was changed. Try again."
        case .callablesUnavailable: return "This build cannot reach PetNote's server."
        default: return "That did not work. Try again."
        }
    }
}
