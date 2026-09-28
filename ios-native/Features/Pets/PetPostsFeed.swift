import Foundation

/// A pet's posts, read the way the feed reads posts: newest first, a page at a
/// time.
///
/// So the pet page can list them with the feed's own model, and a heart on a
/// pet page behaves exactly as one in the feed — the optimistic fill, the
/// rollback on failure, a count the server has not caught up with, a tap while
/// one is still out — rather than through a third copy of that logic. The
/// page's heart used to be `onLike: {}`: drawn, tappable, and doing nothing.
struct PetPostsFeed: FeedRepository {
    let petID: String
    let pets: any PetRepository
    /// For a single post, which is not a pet's to answer.
    let lookup: any FeedRepository

    func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        try await pets.posts(petID: petID, after: cursor, limit: limit)
    }

    func post(id: String) async throws -> Post? {
        try await lookup.post(id: id)
    }
}
