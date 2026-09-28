import Foundation
import Observation

/// What the search screen shows before anything is typed.
///
/// Four modules, loaded together and failing **one at a time**. The web page
/// used to load them with `Promise.all` and no catch, so any one rejection
/// emptied all of them; it moved to `allSettled` so "trending tags could not
/// load" stops reading as "search is broken". Each module here has its own
/// failure and its own retry.
///
/// The web page's other two modules — top-rated places and upcoming meetups —
/// read collections that belong to other lines and are not reinvented here.
@MainActor
@Observable
final class ExploreModel {
    enum Module: Hashable, Sendable {
        case tags
        case trendingPosts
        case discoverPets
        case popularPets
    }

    private(set) var tags: [Hashtag] = []
    private(set) var trendingPosts: [Post] = []
    private(set) var discoverPets: [Pet] = []
    private(set) var popularPets: [RankedPet] = []
    private(set) var failed: Set<Module> = []
    private(set) var loading: Set<Module> = []
    private(set) var followModels: [String: FollowModel] = [:]

    let viewerID: String?
    let blockList: BlockList
    private let search: any SearchRepository
    private let social: any SocialRepository
    private let now: @Sendable () -> Date

    static let tagLimit = 12
    static let trendingLimit = 9
    static let trendingWindow: TimeInterval = 7 * 24 * 60 * 60
    static let discoverLimit = 8
    static let discoverCandidates = 50
    static let popularLimit = 8
    static let popularFallbackPosts = 120
    /// `getFollowingPets`' first page, which is what suggestions exclude.
    static let followedLimit = 200

    init(
        viewerID: String?,
        search: any SearchRepository,
        social: any SocialRepository,
        blockList: BlockList,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.viewerID = viewerID
        self.search = search
        self.social = social
        self.blockList = blockList
        self.now = now
    }

    var tagHeading: String { SearchLogic.tagHeading(tags) }

    var visibleTrendingPosts: [Post] {
        SearchLogic.withoutBlocked(trendingPosts, blocked: blockList.ids)
    }

    var alsoActivePets: [RankedPet] { SearchLogic.alsoActive(popularPets, excluding: discoverPets) }
    var showsAlsoActive: Bool { alsoActivePets.count >= SearchLogic.alsoActiveMinimum }

    // MARK: - Loading

    func load() async {
        async let blocks: Void = blockList.loadIfNeeded()
        async let tags: Void = loadTags()
        async let trending: Void = loadTrending()
        async let discover: Void = loadDiscover()
        async let popular: Void = loadPopular()
        _ = await (blocks, tags, trending, discover, popular)
    }

    func retry(_ module: Module) async {
        switch module {
        case .tags: await loadTags()
        case .trendingPosts: await loadTrending()
        case .discoverPets: await loadDiscover()
        case .popularPets: await loadPopular()
        }
    }

    private func begin(_ module: Module) {
        loading.insert(module)
        failed.remove(module)
    }

    private func finish(_ module: Module, failed didFail: Bool) {
        loading.remove(module)
        if didFail { failed.insert(module) }
    }

    private func loadTags() async {
        begin(.tags)
        do {
            tags = try await search.popularTags(limit: Self.tagLimit)
            finish(.tags, failed: false)
        } catch {
            finish(.tags, failed: true)
        }
    }

    private func loadTrending() async {
        begin(.trendingPosts)
        do {
            let since = now().addingTimeInterval(-Self.trendingWindow)
            let candidates = try await search.posts(
                since: since, limit: SearchLogic.trendingCandidateCount(for: Self.trendingLimit)
            )
            trendingPosts = SearchLogic.trending(candidates, limit: Self.trendingLimit)
            finish(.trendingPosts, failed: false)
        } catch {
            finish(.trendingPosts, failed: true)
        }
    }

    /// `getSuggestedPets`: the fifty most followed, minus the ones the viewer
    /// follows, first eight. Then one batched read for the follow buttons.
    private func loadDiscover() async {
        begin(.discoverPets)
        do {
            async let candidates = search.petsByFollowers(limit: Self.discoverCandidates)
            async let followed = followedIDs()
            let followedSet = await followed
            let pets = SearchLogic.discover(
                try await candidates, followed: followedSet ?? [], limit: Self.discoverLimit
            )
            discoverPets = pets
            finish(.discoverPets, failed: false)
            await makeFollowModels(for: pets)
        } catch {
            finish(.discoverPets, failed: true)
        }
    }

    /// Nil when the read failed. The web page fails the whole module then; a
    /// list that may include pets already followed is still worth showing,
    /// and each card's button settles its own state.
    private func followedIDs() async -> Set<String>? {
        guard let viewerID else { return [] }
        do {
            return Set(try await social.followedPets(viewerID: viewerID, limit: Self.followedLimit).map(\.id))
        } catch {
            return nil
        }
    }

    private func makeFollowModels(for pets: [Pet]) async {
        followModels = await FollowModel.models(for: pets, viewerID: viewerID, repository: social)
    }

    /// `getPopularPets`: stored `postCount` first; when fewer than eight pets
    /// have one, count the newest 120 posts per pet to fill the rest.
    private func loadPopular() async {
        begin(.popularPets)
        do {
            let stored = SearchLogic.rankedByStoredCount(
                try await search.petsByPostCount(limit: Self.popularLimit)
            )
            guard stored.count < Self.popularLimit else {
                popularPets = Array(stored.prefix(Self.popularLimit))
                finish(.popularPets, failed: false)
                return
            }
            let recent = try await search.latestPosts(limit: Self.popularFallbackPosts)
            let fallback = SearchLogic.fallbackCounts(
                from: recent,
                excluding: Set(stored.map(\.id)),
                needed: Self.popularLimit - stored.count
            )
            let pets = try await search.pets(ids: fallback.map(\.petID))
            let byID = Dictionary(pets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let filled = fallback.compactMap { entry in
                byID[entry.petID].map { RankedPet(pet: $0, postCount: entry.count) }
            }
            popularPets = Array((stored + filled).prefix(Self.popularLimit))
            finish(.popularPets, failed: false)
        } catch {
            finish(.popularPets, failed: true)
        }
    }

}
