import Foundation

/// The feed's two lists: the web client's `activeTab` (src/pages/Feed.tsx),
/// "For You" for every post and "Following" for the pets this person follows.
enum FeedTab: String, CaseIterable, Sendable {
    case forYou
    case following
}

/// The "Following" tab as a `FeedRepository`, so `FeedViewModel` pages it,
/// likes on it and gets over its failures exactly as it does the main feed —
/// `PetPostsFeed` does the same for a pet's page.
///
/// Which pets: the ones this person follows, newest follow first, up to the
/// two hundred `getFollowingPets` reads by default. The web reads them inside
/// every `getFollowingPosts` call; here once per first page, so a follow that
/// lands while the list is being paged cannot change which pets page two is
/// merged from. A refresh picks it up.
///
/// Wrapped in its own `BlockFilteringFeed` by the shell, as the main feed is:
/// the web filters blocked authors out of whichever tab is showing.
actor FollowingFeed: FeedRepository {
    /// `getFollowingPets`' default `limitCount`.
    static let petLimit = 200

    private var viewerID: String
    private let social: any SocialRepository
    private let reader: any FollowingPostsReading
    /// For `post(id:)`, which is not about following at all.
    private let lookup: any FeedRepository
    /// Read by the last first page; the pets later pages are merged from.
    private var petIDs: [String] = []

    init(
        viewerID: String,
        social: any SocialRepository,
        reader: any FollowingPostsReading,
        lookup: any FeedRepository
    ) {
        self.viewerID = viewerID
        self.social = social
        self.reader = reader
        self.lookup = lookup
    }

    /// Another person signed in. What was read for the last one is theirs.
    func switchAccount(to viewerID: String) {
        guard viewerID != self.viewerID else { return }
        self.viewerID = viewerID
        petIDs = []
    }

    func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        if cursor == nil {
            petIDs = try await social.followedPets(viewerID: viewerID, limit: Self.petLimit).map(\.id)
        }
        guard !petIDs.isEmpty else { return .empty }
        return try await reader.posts(ofPets: petIDs, after: cursor, limit: limit)
    }

    func post(id: String) async throws -> Post? {
        try await lookup.post(id: id)
    }
}
