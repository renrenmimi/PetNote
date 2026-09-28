import Foundation
import Observation

/// The state every list on the social screens can be in.
///
/// `failed` is kept apart from an empty `loaded` on purpose: "nobody follows
/// this pet" and "we could not find out who does" are different sentences,
/// and only one of them deserves a retry button.
enum SocialListState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

/// Who follows a pet — the web page's followers sheet, opened from the count.
@MainActor
@Observable
final class PetFollowersModel {
    private(set) var state: SocialListState = .loading
    private(set) var followers: [PetFollower] = []
    private(set) var hasMore = false
    /// A later page failed. The rows already shown stay; only the tail says so.
    private(set) var pageFailure: String?

    let petID: String
    let petName: String
    private let repository: any SocialRepository
    private let pageSize: Int
    private var next: PageCursor?
    private var loadingMore = false

    init(petID: String, petName: String, repository: any SocialRepository, pageSize: Int = 50) {
        self.petID = petID
        self.petName = petName
        self.repository = repository
        self.pageSize = pageSize
    }

    func load() async {
        if followers.isEmpty { state = .loading }
        pageFailure = nil
        do {
            let page = try await repository.followers(petID: petID, after: nil, limit: pageSize)
            followers = page.items
            next = page.next
            hasMore = page.hasMore
            state = .loaded
        } catch {
            // Rows from an earlier load are not discarded: a refresh that
            // fails should not make the list look empty.
            state = .failed(Self.wording(error, fallback: String(localized: "Could not load this pet's followers.")))
        }
    }

    func loadMoreIfNeeded(after follower: PetFollower) async {
        guard follower.id == followers.last?.id, let cursor = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await repository.followers(petID: petID, after: cursor, limit: pageSize)
            // A follower who appears on two pages (they re-followed between
            // reads) is shown once.
            let known = Set(followers.map(\.id))
            followers += page.items.filter { !known.contains($0.id) }
            next = page.next
            hasMore = page.hasMore
            pageFailure = nil
        } catch {
            pageFailure = Self.wording(error, fallback: String(localized: "Could not load more followers."))
        }
    }

    func retryMore() async {
        guard let last = followers.last else { return }
        pageFailure = nil
        await loadMoreIfNeeded(after: last)
    }

    static func wording(_ error: Error, fallback: String) -> String {
        switch error as? SocialError {
        case .offline: return String(localized: "No connection. Check your network and try again.")
        case .denied: return String(localized: "This list is not visible to you.")
        default: return fallback
        }
    }
}

/// The pets the signed-in person follows — the web profile's "Following Pets"
/// sheet, which only its owner can open (`followingPets` is owner-only by
/// rule, so for anyone else it would always read empty).
@MainActor
@Observable
final class FollowingPetsModel {
    private(set) var state: SocialListState = .loading
    private(set) var pets: [FollowedPet] = []

    private let viewerID: String
    private let repository: any SocialRepository
    /// The web client's first page, and the only one it shows.
    static let limit = 200

    init(viewerID: String, repository: any SocialRepository) {
        self.viewerID = viewerID
        self.repository = repository
    }

    func load() async {
        if pets.isEmpty { state = .loading }
        do {
            pets = try await repository.followedPets(viewerID: viewerID, limit: Self.limit)
            state = .loaded
        } catch {
            state = .failed(PetFollowersModel.wording(error, fallback: String(localized: "Could not load the pets you follow.")))
        }
    }
}
