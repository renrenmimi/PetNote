import Foundation
import Observation
import OSLog

/// A pet's owners, and the three things that change who they are: removing
/// someone, handing on the primary role, and leaving.
///
/// **The rights split this screen expresses and does not decide.** From
/// functions/src/pets.ts `getPetFamilyAuthority`: everything additive is equal
/// — every owner edits, posts, invites and revokes — and the two destructive
/// acts converge. Removing *another* owner, and moving the primary role, are
/// the primary's alone; leaving is every owner's own decision; and the last
/// owner cannot leave at all, because a leave must never be a way to destroy a
/// pet by accident. Deleting it is a separate, deliberate act on the pet page.
///
/// **Showing a button is not permission.** Controls are drawn from
/// `PetOwnership`, which mirrors the server's reading of the family — but the
/// server decides again inside a transaction, against what is true *then*.
/// Another owner may have handed the role on, or removed this viewer, since
/// the roster was read. So every refusal is expected, reported in words, and
/// followed by a re-read so the screen stops offering what is no longer true.
@MainActor
@Observable
final class FamilyModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        /// Read successfully; the pet does not exist.
        case missing
        case failed(String)
    }

    enum Action: Equatable {
        case remove(PetFamilyMember)
        case transfer(PetFamilyMember)
        case leave
    }

    enum Notice: Equatable {
        case success(String)
        case failure(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var pet: Pet?
    private(set) var members: [PetFamilyMember] = []
    /// Nil until the family has been read. Stays nil if that read fails, so a
    /// failure can never be mistaken for "no family" — the empty-family legacy
    /// fallback would otherwise hand a stale `ownerId` the primary's controls.
    private(set) var ownership: PetOwnership?
    /// The action awaiting confirmation.
    private(set) var pending: Action?
    private(set) var isWorking = false
    private(set) var notice: Notice?
    /// The viewer has left. The screen they are on is no longer theirs.
    private(set) var didLeave = false

    let petID: String
    let viewerID: String
    private let viewerIsAdmin: Bool
    private let pets: any PetRepository
    private let family: any FamilyRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "family")

    init(
        petID: String,
        viewerID: String,
        viewerIsAdmin: Bool = false,
        pets: any PetRepository,
        family: any FamilyRepository
    ) {
        self.petID = petID
        self.viewerID = viewerID
        self.viewerIsAdmin = viewerIsAdmin
        self.pets = pets
        self.family = family
    }

    var permissions: PetOwnership { ownership ?? .none }
    var petName: String { pet?.name ?? "this pet" }
    /// The web modal's `members.length <= 1`.
    var isOnlyOwner: Bool { permissions.memberCount <= 1 }
    /// Leaving is offered to any owner who is not the last one.
    var canLeave: Bool { permissions.isMember && !isOnlyOwner }

    func isViewer(_ member: PetFamilyMember) -> Bool { member.id == viewerID }

    /// Remove and Make primary, on somebody else's row, for the primary.
    func canManage(_ member: PetFamilyMember) -> Bool {
        permissions.canManageOtherOwners && !isViewer(member)
    }

    // MARK: - Loading

    func load() async {
        if state != .loaded { state = .loading }
        do {
            guard let pet = try await pets.pet(id: petID) else {
                self.pet = nil
                members = []
                ownership = nil
                state = .missing
                return
            }
            self.pet = pet
            do {
                let members = try await pets.family(petID: petID)
                self.members = members
                ownership = PetOwnership.resolve(
                    pet: pet, family: members, viewerID: viewerID, isAdmin: viewerIsAdmin
                )
                state = .loaded
            } catch {
                ownership = nil
                state = .failed("Could not load \(pet.name)'s owners.")
            }
        } catch {
            log.error("family screen pet read failed: \(String(describing: error), privacy: .public)")
            ownership = nil
            state = .failed("Could not load this pet.")
        }
    }

    // MARK: - Acting

    /// Asks for confirmation. Refuses to ask for something the viewer is not
    /// shown a control for, so a stale tap cannot reach the server either.
    func ask(_ action: Action) {
        switch action {
        case .remove(let member), .transfer(let member):
            guard canManage(member) else { return }
        case .leave:
            guard canLeave else { return }
        }
        notice = nil
        pending = action
    }

    func cancel() {
        guard !isWorking else { return }
        pending = nil
    }

    func dismissNotice() { notice = nil }

    /// Performs what was asked for.
    func confirm() async {
        guard let action = pending else { return }
        await perform(action)
    }

    /// Takes the action as a value rather than reading `pending`, because the
    /// confirmation alert clears its own binding as it closes — possibly
    /// before the task running this has started.
    func perform(_ action: Action) async {
        guard !isWorking else { return }
        switch action {
        case .remove(let member), .transfer(let member):
            guard canManage(member) else { return }
        case .leave:
            guard canLeave else { return }
        }
        isWorking = true
        pending = nil
        notice = nil
        defer { isWorking = false }

        do {
            switch action {
            case .remove(let member):
                let outcome = try await family.removeMember(petID: petID, userID: member.id)
                pending = nil
                notice = .success(outcome == .wasNotAMember
                    ? "\(Self.name(member)) was already no longer an owner."
                    : "\(Self.name(member)) is no longer an owner.")
                await load()
            case .transfer(let member):
                _ = try await family.transferPrimary(petID: petID, to: member.id)
                pending = nil
                notice = .success("\(Self.name(member)) is now \(petName)'s primary owner.")
                await load()
            case .leave:
                _ = try await family.removeMember(petID: petID, userID: viewerID)
                pending = nil
                didLeave = true
            }
        } catch {
            pending = nil
            await recover(from: (error as? FamilyError) ?? .outcomeUnknown, during: action)
        }
    }

    private func recover(from error: FamilyError, during action: Action) async {
        switch error {
        case .outcomeUnknown:
            // Settled by reading the family, which is what the transaction
            // changes. Nothing is sent a second time.
            await load()
            guard state == .loaded else {
                notice = .failure(Self.unknownOutcome)
                return
            }
            switch action {
            case .remove(let member):
                if members.contains(where: { $0.id == member.id }) {
                    notice = .failure(Self.unknownOutcome)
                } else {
                    notice = .success("\(Self.name(member)) is no longer an owner.")
                }
            case .transfer(let member):
                if members.first(where: { $0.id == member.id })?.role == .primary {
                    notice = .success("\(Self.name(member)) is now \(petName)'s primary owner.")
                } else {
                    notice = .failure(Self.unknownOutcome)
                }
            case .leave:
                if members.contains(where: { $0.id == viewerID }) {
                    notice = .failure(Self.unknownOutcome)
                } else {
                    didLeave = true
                }
            }

        case .notPrimary, .notAnOwner, .targetIsPrimary, .targetNotInFamily, .petNotFound:
            // The roster this screen drew from is out of date. Say what the
            // server said, then show what is true now.
            notice = .failure(Self.wording(for: error, petName: petName))
            await load()

        default:
            notice = .failure(Self.wording(for: error, petName: petName))
        }
    }

    // MARK: - Words

    static let unknownOutcome =
        "We could not tell whether that went through. The list below is what is true now."

    static func name(_ member: PetFamilyMember) -> String {
        member.userName.isEmpty ? "PetNote user" : member.userName
    }

    func title(for action: Action) -> String {
        switch action {
        case .remove(let member): return "Remove \(Self.name(member))?"
        case .transfer(let member): return "Make \(Self.name(member)) primary owner?"
        case .leave: return "Leave \(petName)'s family?"
        }
    }

    /// Each consequence stated before it happens, because none of the three is
    /// easy to undo: coming back takes a new invitation from someone inside.
    /// The web modal's wording, plus the one fact it left out — where the
    /// primary role goes when the primary leaves (`pickSuccessor`).
    func consequence(of action: Action) -> String {
        switch action {
        case .remove(let member):
            return """
                \(Self.name(member)) will lose access to \(petName). Anything they already \
                posted stays. They can only come back through a new invitation.
                """
        case .transfer(let member):
            return """
                \(Self.name(member)) becomes \(petName)'s primary owner. You stay an owner and \
                can still edit and post — but they, not you, will be the one who can remove \
                other owners.
                """
        case .leave:
            let handover = permissions.isPrimary
                ? " The primary owner role passes to whoever has been an owner the longest."
                : ""
            return """
                You will lose access to \(petName). Your posts about \(petName) stay, and you \
                can only come back through a new invitation.\(handover)
                """
        }
    }

    static func wording(for error: FamilyError, petName: String) -> String {
        switch error {
        case .notSignedIn: return "Sign in again to do that."
        case .banned: return "This account cannot make changes."
        case .accountDeleted: return "This account has been deleted."
        case .petNotFound: return "\(petName) no longer exists."
        case .notAnOwner: return "You are no longer one of \(petName)'s owners."
        case .notPrimary:
            return "Only the primary owner can do that. The roles may have changed — the list has been refreshed."
        case .targetIsPrimary:
            return "They hold the primary owner role. It has to be handed to someone else before they can be removed."
        case .lastOwner:
            return "You are \(petName)'s only owner. Invite someone else first, or delete \(petName) from its page."
        case .targetNotInFamily:
            return "That person is no longer one of \(petName)'s owners."
        case .rateLimited: return "Too many requests just now. Wait a moment and try again."
        case .offline: return "No connection. Nothing was changed. Try again."
        case .callablesUnavailable: return "This build cannot reach PetNote's server."
        case .outcomeUnknown: return unknownOutcome
        case .invitationInvalid, .invitationRevoked, .inviterLeft, .alreadyMember,
             .malformedCode, .invitationNotFound, .couldNotGenerate, .rejected, .transport:
            return "That did not work. Try again."
        }
    }
}
