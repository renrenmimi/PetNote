import Foundation
import Observation
import OSLog

/// Somebody's profile, as another person sees it: who they are, the pets they
/// are an owner of, and a follow control on each.
///
/// Mirrors `UserProfile.tsx`, which has no list of posts — a person's posts
/// are reached through their pets, whose pages list them.
///
/// **The profile and the pets fail separately.** The web page loads both in
/// one `Promise.all`, so a failed pet read turned a readable profile into
/// "Could not load this profile". Here the header survives and the pets
/// section offers its own retry.
@MainActor
@Observable
final class UserProfileModel {
    enum State: Equatable {
        case loading
        case loaded(PublicProfile)
        /// Read successfully; there is no such account.
        case missing
        /// The viewer has blocked this person. Nothing of theirs is shown
        /// until they are unblocked, as on the web page.
        case blocked
        /// The rules refused the read.
        case denied
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var pets: [ProfilePet] = []
    private(set) var petsState: SocialListState = .loading
    private(set) var followModels: [String: FollowModel] = [:]
    private(set) var isUnblocking = false
    private(set) var unblockMessage: String?

    let userID: String
    let viewerID: String?
    private let social: any SocialRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "social")

    init(userID: String, viewerID: String?, social: any SocialRepository) {
        self.userID = userID
        self.viewerID = viewerID
        self.social = social
    }

    var isSelf: Bool { viewerID == userID }

    var profile: PublicProfile? {
        if case .loaded(let profile) = state { return profile }
        return nil
    }

    /// "PetNote User" in place of a missing name, as on the web page.
    var displayName: String {
        guard let profile, !profile.displayName.isEmpty else { return "PetNote User" }
        return profile.displayName
    }

    var locationLine: String? {
        guard let profile, !profile.city.isEmpty else { return nil }
        return profile.state.isEmpty ? profile.city : "\(profile.city), \(profile.state)"
    }

    var joinedLine: String {
        guard let createdAt = profile?.createdAt else { return "Joined: unknown" }
        return "Joined \(createdAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// The pets count is only a number once the pets have been read.
    var petCountText: String {
        petsState == .loaded ? "\(pets.count)" : "—"
    }

    var followingCount: Int { profile?.followingPetsCount ?? 0 }

    // MARK: - Loading

    func load() async {
        if let viewerID, !isSelf {
            do {
                if try await social.blockedUserIDs(viewerID: viewerID).contains(userID) {
                    state = .blocked
                    pets = []
                    followModels = [:]
                    return
                }
            } catch {
                // Not knowing is not the same as having blocked them. The
                // profile is public; the block is the viewer's own preference.
                log.error("blocked users read failed: \(String(describing: error), privacy: .public)")
            }
        }

        async let petsLoaded: Void = loadPets()
        do {
            if let profile = try await social.profile(userID: userID) {
                state = .loaded(profile)
            } else {
                state = .missing
            }
        } catch let error as SocialError where error == .denied {
            state = .denied
        } catch {
            state = .failed(Self.wording(for: error))
        }
        await petsLoaded
    }

    func retryPets() async { await loadPets() }

    private func loadPets() async {
        if pets.isEmpty { petsState = .loading }
        do {
            let pets = try await social.pets(ofUser: userID)
            self.pets = pets
            petsState = .loaded
            followModels = await FollowModel.models(
                for: pets.map(\.pet), viewerID: viewerID, repository: social,
                viewerOwnsAll: isSelf
            )
        } catch {
            petsState = .failed("Could not load their pets.")
        }
    }

    // MARK: - Unblocking

    func unblock() async {
        guard let viewerID, !isUnblocking, state == .blocked else { return }
        isUnblocking = true
        unblockMessage = nil
        defer { isUnblocking = false }
        do {
            try await social.unblock(userID: userID, viewerID: viewerID)
            state = .loading
            await load()
        } catch {
            unblockMessage = "Could not unblock this person. Try again."
        }
    }

    static func wording(for error: Error) -> String {
        switch error as? SocialError {
        case .offline: return "No connection. Check your network and try again."
        default: return "Could not load this profile."
        }
    }
}
