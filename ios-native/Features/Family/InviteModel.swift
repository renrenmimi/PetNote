import Foundation
import Observation

/// The pet's invitation code: see it, make one, take it back.
///
/// Additive, so equal — any owner may invite and any owner may revoke,
/// including a code another owner made (`revokeInvitationCallable` checks
/// membership, not authorship).
///
/// **Two writes, both safe to settle by reading.** `createInvitationCallable`
/// hands back the live code if there is one instead of minting a second, and
/// `getActiveInvitationCallable` is a read — so when an answer is lost, asking
/// for the active code says what happened without risking a duplicate.
@MainActor
@Observable
final class InviteModel {
    enum State: Equatable {
        case loading
        /// No live code.
        case none
        case active(Invitation)
        /// The server says the viewer is not one of the pet's owners.
        case notPermitted
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var isGenerating = false
    private(set) var isRevoking = false
    /// The last failure of a generate or a revoke, as a sentence.
    private(set) var message: String?
    /// The last success worth saying out loud.
    private(set) var confirmation: String?

    let petID: String
    private let repository: any FamilyRepository
    private let now: @Sendable () -> Date

    init(
        petID: String,
        repository: any FamilyRepository,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.petID = petID
        self.repository = repository
        self.now = now
    }

    /// The code, if it is still live by this device's clock. A code that
    /// expired while the screen was open is not offered for sharing.
    var liveInvitation: Invitation? {
        guard case .active(let invitation) = state, invitation.expiresAt > now() else { return nil }
        return invitation
    }

    func load() async {
        if case .active = state {} else { state = .loading }
        do {
            state = try await repository.activeInvitation(petID: petID).map(State.active) ?? .none
        } catch let error as FamilyError where error == .notAnOwner {
            state = .notPermitted
        } catch {
            state = .failed("Could not load the invitation code.")
        }
    }

    func generate() async {
        guard !isGenerating, liveInvitation == nil else { return }
        isGenerating = true
        message = nil
        confirmation = nil
        defer { isGenerating = false }
        do {
            state = .active(try await repository.createInvitation(petID: petID))
            confirmation = "Invitation code ready."
        } catch {
            let error = (error as? FamilyError) ?? .outcomeUnknown
            switch error {
            case .notAnOwner:
                state = .notPermitted
            case .outcomeUnknown:
                await load()
                if liveInvitation == nil {
                    message = "We could not tell whether a code was made. Try again."
                }
            case .couldNotGenerate:
                message = "Could not make a code just now. Try again."
            default:
                message = Self.wording(for: error)
            }
        }
    }

    func revoke() async {
        guard !isRevoking, case .active(let invitation) = state else { return }
        isRevoking = true
        message = nil
        confirmation = nil
        defer { isRevoking = false }
        do {
            _ = try await repository.revokeInvitation(petID: petID, code: invitation.code)
            // Already used, revoked or expired is also "this code no longer
            // works", which is what was asked for.
            state = .none
            confirmation = "Invitation code revoked."
        } catch {
            let error = (error as? FamilyError) ?? .outcomeUnknown
            switch error {
            case .notAnOwner:
                state = .notPermitted
            case .invitationNotFound, .outcomeUnknown:
                await load()
                if case .active(let current) = state, current.code == invitation.code {
                    message = "We could not tell whether the code was revoked. Try again."
                } else {
                    confirmation = "That code no longer works."
                }
            default:
                message = Self.wording(for: error)
            }
        }
    }

    static func shareMessage(for invitation: Invitation, petName: String) -> String {
        "Join \(petName)'s family on PetNote with this invitation code: \(invitation.formattedCode)"
    }

    /// "Expires in 47h 59m", the web modal's wording.
    static func expiresLabel(_ expiresAt: Date, now: Date) -> String {
        let minutes = max(0, Int(expiresAt.timeIntervalSince(now) / 60))
        return "Expires in \(minutes / 60)h \(minutes % 60)m"
    }

    static func wording(for error: FamilyError) -> String {
        switch error {
        case .banned: return "This account cannot create invitations."
        case .accountDeleted: return "This account has been deleted."
        case .notSignedIn: return "Sign in again to do that."
        case .petNotFound: return "This pet no longer exists."
        case .rateLimited: return "Too many requests just now. Wait a moment and try again."
        case .offline: return "No connection. Check your network and try again."
        case .callablesUnavailable: return "This build cannot reach PetNote's server."
        default: return "That did not work. Try again."
        }
    }
}
