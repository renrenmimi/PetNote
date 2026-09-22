import Foundation
import Observation
import OSLog

/// Following one pet: whether the viewer does, and the one control that
/// changes it.
///
/// **Not optimistic, on purpose.** The web hook (`useFollowPet`) flips the
/// state only after the callable answers, and so does this. A follow is not a
/// like: there is no count the person is watching tick, and a button that says
/// "Following" before the server has agreed is a claim, not a fact.
///
/// **An unknown outcome is settled by reading, not by guessing.** Both
/// callables are idempotent — `followPetCallable` returns early when the
/// follow document already exists, `unfollowPetCallable` deletes only if it is
/// there — so when an answer is lost, the follow document itself says what
/// happened.
@MainActor
@Observable
final class FollowModel {
    enum Status: Equatable, Sendable {
        /// Not determined yet.
        case unknown
        /// One of the pet's owners. The server refuses their follow, so no
        /// button is offered — the web page's `canEditPet ? … : <Follow>`.
        case ownPet
        case notFollowing
        case following
        /// The status read failed. Rendered as "Follow", which is safe
        /// *because* the callable is idempotent: tapping it on a pet already
        /// followed changes nothing on the server and settles the state.
        case checkFailed
    }

    private(set) var status: Status
    private(set) var isBusy = false
    /// The last failure, as a sentence. Cleared by the next attempt.
    private(set) var message: String?
    /// Local adjustment to the follower count this screen was loaded with,
    /// since `followerCount` is moved by a trigger some time after the call.
    private(set) var followerDelta = 0

    let petID: String
    let petName: String
    private let viewerID: String?
    private let knownOwnerIDs: Set<String>
    private let repository: any SocialRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "social")

    /// - Parameters:
    ///   - knownOwnerIDs: `ownerId` and `primaryOwnerId` from the pet
    ///     document. The callable refuses a follow from either as well as from
    ///     a family member, so the client refuses to offer one too.
    ///   - initial: a status already known from a batched read, so each row
    ///     does not make its own.
    init(
        petID: String,
        petName: String,
        viewerID: String?,
        repository: any SocialRepository,
        knownOwnerIDs: [String] = [],
        initial: Status = .unknown
    ) {
        self.petID = petID
        self.petName = petName
        self.viewerID = viewerID
        self.repository = repository
        self.knownOwnerIDs = Set(knownOwnerIDs.filter { !$0.isEmpty })
        if let viewerID, self.knownOwnerIDs.contains(viewerID) {
            status = .ownPet
        } else {
            status = initial
        }
    }

    /// Whether there is a control to draw at all.
    var offersControl: Bool {
        guard viewerID != nil else { return false }
        return status != .ownPet
    }

    func displayedFollowerCount(base: Int) -> Int { max(0, base + followerDelta) }

    /// Reads both halves of the status: the follow document, and whether the
    /// viewer is one of the pet's owners.
    func load() async {
        guard let viewerID, status == .unknown || status == .checkFailed else { return }
        async let following = repository.isFollowing(petID: petID, viewerID: viewerID)
        async let member = repository.isFamilyMember(petID: petID, userID: viewerID)
        do {
            // Membership first: an owner has no follow control whatever the
            // follow document says.
            if try await member {
                status = .ownPet
                _ = try? await following
                return
            }
        } catch {
            // Not knowing is not the same as being an owner. The callable
            // still refuses an owner, and `toggle` handles that answer.
            log.error("family membership read failed: \(String(describing: error), privacy: .public)")
        }
        do {
            status = try await following ? .following : .notFollowing
        } catch {
            status = .checkFailed
        }
    }

    func toggle() async {
        guard viewerID != nil, !isBusy else { return }
        let wantsFollowing: Bool
        switch status {
        case .following: wantsFollowing = false
        case .notFollowing, .checkFailed: wantsFollowing = true
        case .unknown, .ownPet: return
        }
        let wasCheckFailed = status == .checkFailed
        isBusy = true
        message = nil
        defer { isBusy = false }

        do {
            if wantsFollowing {
                try await repository.follow(petID: petID)
            } else {
                try await repository.unfollow(petID: petID)
            }
            settle(following: wantsFollowing, countChanged: !wasCheckFailed)
        } catch let error as SocialError {
            await recover(from: error, wantedFollowing: wantsFollowing, wasCheckFailed: wasCheckFailed)
        } catch {
            await recover(from: .outcomeUnknown, wantedFollowing: wantsFollowing, wasCheckFailed: wasCheckFailed)
        }
    }

    private func settle(following: Bool, countChanged: Bool) {
        let previous = status
        status = following ? .following : .notFollowing
        // Only a real change moves the count. From `checkFailed` it is not
        // known whether the server had to do anything.
        guard countChanged, previous != status else { return }
        followerDelta += following ? 1 : -1
    }

    private func recover(from error: SocialError, wantedFollowing: Bool, wasCheckFailed: Bool) async {
        switch error {
        case .ownPet:
            status = .ownPet
            message = Self.wording(for: error)
        case .outcomeUnknown:
            guard let viewerID else { return }
            do {
                let isFollowing = try await repository.isFollowing(petID: petID, viewerID: viewerID)
                if isFollowing == wantedFollowing {
                    settle(following: isFollowing, countChanged: !wasCheckFailed)
                } else {
                    status = isFollowing ? .following : .notFollowing
                    message = wantedFollowing
                        ? "Could not follow \(petName). Try again."
                        : "Could not unfollow \(petName). Try again."
                }
            } catch {
                message = "We could not tell whether that went through. Reload to check."
            }
        default:
            message = Self.wording(for: error)
        }
    }

    /// One sentence per failure. Static so a test can check the words without
    /// driving a screen.
    static func wording(for error: SocialError) -> String {
        switch error {
        case .notSignedIn: return "Sign in again to do that."
        case .banned: return "This account cannot follow pets."
        case .accountDeleted: return "This account has been deleted."
        case .petNotFound: return "This pet no longer exists."
        case .ownPet: return "You are one of this pet's owners, so you cannot follow it."
        case .rateLimited: return "Too many requests just now. Wait a moment and try again."
        case .denied: return "That was not allowed."
        case .offline: return "No connection. Check your network and try again."
        case .callablesUnavailable: return "This build cannot reach PetNote's server."
        case .outcomeUnknown: return "We could not tell whether that went through. Reload to check."
        case .transport: return "Something went wrong reaching PetNote. Try again."
        }
    }

    /// What a batched status read resolves to for one pet.
    ///
    /// - Parameters:
    ///   - memberPetIDs: nil when that read failed. Not knowing is treated as
    ///     "not an owner": the callable still refuses an owner, and that
    ///     answer is handled.
    ///   - followedPetIDs: nil when that read failed.
    static func status(
        for pet: Pet,
        viewerID: String?,
        memberPetIDs: Set<String>?,
        followedPetIDs: Set<String>?
    ) -> Status {
        guard let viewerID else { return .unknown }
        if pet.ownerID == viewerID || pet.primaryOwnerID == viewerID { return .ownPet }
        if memberPetIDs?.contains(pet.id) == true { return .ownPet }
        guard let followedPetIDs else { return .checkFailed }
        return followedPetIDs.contains(pet.id) ? .following : .notFollowing
    }

    // MARK: - Batches

    /// Follow controls for a list of pets from two batched reads — the
    /// viewer's family memberships and their follow documents — instead of two
    /// reads per row (`batchCheckFollowingPets`).
    ///
    /// - Parameter viewerOwnsAll: the viewer's own profile. Every pet on it is
    ///   theirs, so neither read is made.
    static func models(
        for pets: [Pet],
        viewerID: String?,
        repository: any SocialRepository,
        viewerOwnsAll: Bool = false
    ) async -> [String: FollowModel] {
        guard let viewerID else { return [:] }
        let ids = pets.map(\.id)
        let memberIDs: Set<String>?
        let followedIDs: Set<String>?
        if viewerOwnsAll {
            memberIDs = Set(ids)
            followedIDs = []
        } else {
            async let members = memberPetIDs(viewerID, repository)
            async let followed = followedPetIDs(ids, viewerID, repository)
            memberIDs = await members
            followedIDs = await followed
        }
        var models: [String: FollowModel] = [:]
        for pet in pets {
            models[pet.id] = FollowModel(
                petID: pet.id,
                petName: pet.name,
                viewerID: viewerID,
                repository: repository,
                knownOwnerIDs: [pet.ownerID, pet.primaryOwnerID],
                initial: status(
                    for: pet, viewerID: viewerID,
                    memberPetIDs: memberIDs, followedPetIDs: followedIDs
                )
            )
        }
        return models
    }

    private nonisolated static func memberPetIDs(
        _ viewerID: String, _ repository: any SocialRepository
    ) async -> Set<String>? {
        try? await repository.memberPetIDs(userID: viewerID)
    }

    private nonisolated static func followedPetIDs(
        _ ids: [String], _ viewerID: String, _ repository: any SocialRepository
    ) async -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        return try? await repository.followedPetIDs(among: ids, viewerID: viewerID)
    }
}
