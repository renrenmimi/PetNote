import Foundation
import Observation
import OSLog

/// Who the viewer has blocked, read once per screen and shared by the parts of
/// it that filter posts.
///
/// **Fails open, and says why here.** A failed read leaves the set empty, so
/// posts by a blocked person could appear in search. That is a preference not
/// being applied, not something being revealed — posts are world-readable —
/// and hiding every post because one owner-only read failed would be worse.
@MainActor
@Observable
final class BlockList {
    private(set) var ids: Set<String> = []
    private(set) var loaded = false

    private let viewerID: String?
    private let social: any SocialRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "search")

    init(viewerID: String?, social: any SocialRepository) {
        self.viewerID = viewerID
        self.social = social
    }

    func loadIfNeeded() async {
        guard !loaded, let viewerID else { return }
        do {
            ids = try await social.blockedUserIDs(viewerID: viewerID)
        } catch {
            log.error("blocked users read failed: \(String(describing: error), privacy: .public)")
        }
        loaded = true
    }
}

/// Searching: people, pets, tags and posts for what was typed.
///
/// Mirrors `Search.tsx`: a 300 ms pause after typing, four reads at once, a
/// query starting with `#` treated as a tag, and "no results" shown only after
/// a search actually finished — never in the pause before it starts.
@MainActor
@Observable
final class SearchModel {
    enum State: Equatable {
        /// Nothing typed. The screen shows discovery instead.
        case idle
        case searching
        case loaded(SearchResults)
        /// Distinct from an empty result: losing the connection must not read
        /// as "nothing matches".
        case failed
    }

    var query = ""
    private(set) var state: State = .idle
    /// The query the results on screen belong to.
    private(set) var searchedQuery = ""
    var showAllPeople = false
    var showAllPets = false
    /// Pets per person in the People results. Missing means not known, and
    /// the row then says nothing rather than a wrong "0 pets".
    private(set) var petCounts: [String: Int] = [:]

    let viewerID: String?
    let blockList: BlockList
    private let search: any SearchRepository
    private let debounce: Duration
    private var pending: Task<Void, Never>?
    /// Bumped by every search, so an older answer arriving late is dropped
    /// instead of replacing a newer one.
    private var generation = 0
    /// The query the latest search was started for, so an edit that lands on
    /// the same text — a tag chip setting the field, or typing back to where
    /// it was — does not ask the same question twice.
    private var startedQuery = ""

    /// The web page's `slice(0, 3)` before "See all".
    static let collapsedCount = 3
    static let peopleLimit = 10
    static let petLimit = 10
    static let tagLimit = 10
    /// A `#tag` query reads a page of 50 (`getPostsByTag`); a plain query 20
    /// (`searchByText`). Either way the results show five.
    static let tagPostLimit = 50
    static let textPostLimit = 20
    static let visiblePostCount = 5

    init(
        viewerID: String?,
        search: any SearchRepository,
        blockList: BlockList,
        initialTag: String? = nil,
        debounce: Duration = .milliseconds(300)
    ) {
        self.viewerID = viewerID
        self.search = search
        self.blockList = blockList
        self.debounce = debounce
        if let initialTag {
            let tag = SearchLogic.keyword(from: initialTag)
            if !tag.isEmpty { query = "#\(tag)" }
        }
    }

    var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasQuery: Bool { !normalizedQuery.isEmpty }
    var activeTag: String? { SearchLogic.activeTag(in: searchedQuery) }

    private var results: SearchResults {
        if case .loaded(let results) = state { return results }
        return .empty
    }

    var visiblePeople: [PublicProfile] {
        showAllPeople ? results.people : Array(results.people.prefix(Self.collapsedCount))
    }

    var visiblePets: [Pet] {
        showAllPets ? results.pets : Array(results.pets.prefix(Self.collapsedCount))
    }

    var canExpandPeople: Bool { results.people.count > Self.collapsedCount }
    var canExpandPets: Bool { results.pets.count > Self.collapsedCount }

    var visibleTags: [Hashtag] { SearchLogic.visibleTags(results.tags, activeTag: activeTag) }

    var visiblePosts: [Post] {
        Array(SearchLogic.withoutBlocked(results.posts, blocked: blockList.ids)
            .prefix(Self.visiblePostCount))
    }

    /// "No results" only counts what would actually be drawn.
    var hasAnyResult: Bool {
        !results.people.isEmpty || !results.pets.isEmpty || !visibleTags.isEmpty
            || !visiblePosts.isEmpty
    }

    // MARK: - Running

    /// Called on every edit. Waits for typing to pause.
    func queryChanged() {
        pending?.cancel()
        guard hasQuery else {
            generation += 1
            state = .idle
            searchedQuery = ""
            startedQuery = ""
            return
        }
        guard normalizedQuery != startedQuery || state == .failed else { return }
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.searchNow()
        }
    }

    /// Runs the search for what is typed now, without waiting.
    func searchNow() async {
        let current = normalizedQuery
        guard !current.isEmpty else {
            state = .idle
            return
        }
        generation += 1
        let mine = generation
        startedQuery = current
        state = .searching
        showAllPeople = false
        showAllPets = false
        petCounts = [:]

        let keyword = SearchLogic.keyword(from: current)
        guard !keyword.isEmpty else {
            // A lone "#". The web page asks every query with an empty string
            // and gets nothing back; this skips the round trips.
            searchedQuery = current
            state = .loaded(.empty)
            return
        }
        await blockList.loadIfNeeded()
        let postLimit = SearchLogic.isTagQuery(current) ? Self.tagPostLimit : Self.textPostLimit

        do {
            async let people = search.people(prefix: keyword, limit: Self.peopleLimit)
            async let pets = search.pets(prefix: keyword, limit: Self.petLimit)
            async let tags = search.tags(prefix: keyword, limit: Self.tagLimit)
            async let posts = search.posts(taggedWith: keyword, limit: postLimit)
            let results = SearchResults(
                people: try await people,
                pets: try await pets,
                tags: SearchLogic.sortTags(try await tags),
                posts: try await posts
            )
            guard mine == generation else { return }
            searchedQuery = current
            state = .loaded(results)
            await loadPetCounts(for: results.people, generation: mine)
        } catch {
            guard mine == generation else { return }
            searchedQuery = current
            state = .failed
        }
    }

    /// For tests: waits for the debounced search, if one is scheduled.
    func settle() async {
        await pending?.value
    }

    private func loadPetCounts(for people: [PublicProfile], generation mine: Int) async {
        guard !people.isEmpty else { return }
        do {
            let counts = try await search.petCounts(forUsers: people.map(\.id))
            guard mine == generation else { return }
            petCounts = counts
        } catch {
            // Decorative. The rows simply do not say how many pets.
        }
    }

    /// A tag chip, or a tag in the results.
    func select(tag: String) async {
        let next = "#\(tag)"
        // Re-selecting the tag already on screen is a no-op; the web page had
        // to guard this or it stranded itself on "No results".
        guard normalizedQuery != next || state == .failed else { return }
        pending?.cancel()
        query = next
        await searchNow()
    }

    func clear() {
        pending?.cancel()
        generation += 1
        query = ""
        searchedQuery = ""
        startedQuery = ""
        state = .idle
    }
}
