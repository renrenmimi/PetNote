import Foundation

// MARK: - TEMPORARY LOCATION
//
// `SearchRepository` and the value types belong with the shared repository
// protocols and models, which are the coordinator's. Listed in the batch
// report.

/// A hashtag aggregate, `hashtags/{tag}`, maintained by `onPostWritten`.
///
/// `postCount` is a **lifetime** total, not a window — the web client's own
/// comment on `getTrendingTags` says so, and the heading on screen is derived
/// from the counts rather than calling the list "trending".
struct Hashtag: Sendable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let postCount: Int
}

/// A pet with the post count a ranking was made on.
///
/// Separate from `Pet.postCount` because the fallback ranking counts recent
/// posts itself, and the number shown has to be the one that was ranked on.
struct RankedPet: Sendable, Equatable, Identifiable {
    var id: String { pet.id }
    let pet: Pet
    let postCount: Int
}

struct SearchResults: Sendable, Equatable {
    var people: [PublicProfile] = []
    var pets: [Pet] = []
    var tags: [Hashtag] = []
    var posts: [Post] = []

    static let empty = SearchResults()
}

/// The reads behind the search screen. All of them are public reads; nothing
/// here writes.
protocol SearchRepository: Sendable {
    /// `displayNameLower` prefix, as `searchUsers` does.
    func people(prefix: String, limit: Int) async throws -> [PublicProfile]
    /// `nameLower` prefix and `name` prefix, merged — `searchPets`.
    func pets(prefix: String, limit: Int) async throws -> [Pet]
    /// `hashtags` by name prefix — `searchTags`.
    func tags(prefix: String, limit: Int) async throws -> [Hashtag]
    /// `tags array-contains`, newest first — `getPostsByTag` / `searchByText`.
    func posts(taggedWith tag: String, limit: Int) async throws -> [Post]
    /// How many pets each person is in the family of — `getUserPetCounts`.
    func petCounts(forUsers userIDs: [String]) async throws -> [String: Int]

    /// Most-used tags, lifetime — `getTrendingTags`.
    func popularTags(limit: Int) async throws -> [Hashtag]
    /// Posts created since `date`, newest first — the candidate set
    /// `getTrendingPosts` ranks.
    func posts(since date: Date, limit: Int) async throws -> [Post]
    /// `orderBy("followerCount","desc")` — `getSuggestedPets`' candidates.
    func petsByFollowers(limit: Int) async throws -> [Pet]
    /// `orderBy("postCount","desc")` — `getPopularPets`.
    func petsByPostCount(limit: Int) async throws -> [Pet]
    /// The newest posts, for `getPopularPets`' fallback count.
    func latestPosts(limit: Int) async throws -> [Post]
    func pets(ids: [String]) async throws -> [Pet]
}

/// The decisions the web search page makes, as pure functions so each can be
/// checked on its own.
enum SearchLogic {
    /// `normalizedQuery.replace(/^#/, "").toLowerCase()`, trimmed.
    static func keyword(from query: String) -> String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isTagQuery(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }

    /// The tag a `#tag` query is showing the posts of, if it is one.
    static func activeTag(in query: String) -> String? {
        guard isTagQuery(query) else { return nil }
        let keyword = keyword(from: query)
        return keyword.isEmpty ? nil : keyword
    }

    /// `searchPets`: the lower-cased match first, then the exact-case match,
    /// each pet once, at most `limit`.
    static func mergePets(lower: [Pet], exact: [Pet], limit: Int) -> [Pet] {
        var seen: Set<String> = []
        return (lower + exact).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// `searchTags` sorts what it got by count, highest first. Stable on ties
    /// so the order does not shuffle between identical reads.
    static func sortTags(_ tags: [Hashtag]) -> [Hashtag] {
        tags.enumerated()
            .sorted { lhs, rhs in
                lhs.element.postCount != rhs.element.postCount
                    ? lhs.element.postCount > rhs.element.postCount
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The tags row under a `#tag` search leaves out the tag already being
    /// shown — listing it again was redundant and re-tapping it did nothing.
    static func visibleTags(_ tags: [Hashtag], activeTag: String?, limit: Int = 5) -> [Hashtag] {
        tags.filter { $0.name != activeTag }.prefix(limit).map { $0 }
    }

    /// `getTrendingPosts`: most liked first, newest first on a tie.
    static func trending(_ posts: [Post], limit: Int) -> [Post] {
        posts.sorted { lhs, rhs in
            lhs.likeCount != rhs.likeCount
                ? lhs.likeCount > rhs.likeCount
                : lhs.createdAt > rhs.createdAt
        }
        .prefix(limit).map { $0 }
    }

    /// `getTrendingPosts` reads ten candidates per slot, at least fifty.
    static func trendingCandidateCount(for limit: Int) -> Int { max(limit * 10, 50) }

    /// `getSuggestedPets`: the most followed, minus the ones already followed.
    static func discover(_ candidates: [Pet], followed: Set<String>, limit: Int) -> [Pet] {
        candidates.filter { !followed.contains($0.id) }.prefix(limit).map { $0 }
    }

    /// `getPopularPets`' first half: stored counts, zero dropped.
    static func rankedByStoredCount(_ pets: [Pet]) -> [RankedPet] {
        pets.filter { $0.postCount > 0 }.map { RankedPet(pet: $0, postCount: $0.postCount) }
    }

    /// `getPopularPets`' fallback: count recent posts per pet, skipping pets
    /// already ranked, most first, only as many as are still needed. Ties keep
    /// the order the pets first appeared in, so the result is deterministic.
    static func fallbackCounts(
        from posts: [Post], excluding: Set<String>, needed: Int
    ) -> [(petID: String, count: Int)] {
        guard needed > 0 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for post in posts {
            guard let petID = post.petID, !excluding.contains(petID) else { continue }
            if counts[petID] == nil { order.append(petID) }
            counts[petID, default: 0] += 1
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let left = counts[lhs.element] ?? 0
                let right = counts[rhs.element] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .prefix(needed)
            .map { (petID: $0.element, count: counts[$0.element] ?? 0) }
    }

    /// "Most posts" is a second section only when it has at least three pets
    /// that "Discover pets" does not already show. With a small catalogue both
    /// rankings resolve to the same animals.
    static func alsoActive(_ popular: [RankedPet], excluding discover: [Pet]) -> [RankedPet] {
        let shown = Set(discover.map(\.id))
        return popular.filter { !shown.contains($0.id) }
    }

    static let alsoActiveMinimum = 3

    /// How many posts the most-used tag needs before "Popular" is a fair
    /// word. The web page's `POPULAR_TAG_THRESHOLD` — a judgement, named.
    static let popularTagThreshold = 5

    static func tagHeading(_ tags: [Hashtag]) -> String {
        (tags.first?.postCount ?? 0) >= popularTagThreshold ? "Popular Tags" : "Tags in use"
    }

    static func postCountLabel(_ count: Int) -> String {
        count == 1 ? "1 post" : "\(count) posts"
    }

    /// Posts by people the viewer blocked are not shown, as on the web page.
    static func withoutBlocked(_ posts: [Post], blocked: Set<String>) -> [Post] {
        guard !blocked.isEmpty else { return posts }
        return posts.filter { !blocked.contains($0.authorID) }
    }
}
