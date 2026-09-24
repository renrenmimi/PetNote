import FirebaseFirestore
import Foundation
import Observation
import OSLog

// The three things the web feed draws around its posts (src/pages/Feed.tsx):
// the birthday banner (`BirthdayCelebration`), the "⭐ Popular Pets" row
// (`PetSpotlight`), and the 🎂 on a card whose pet has its birthday today
// (`batchCheckPetBirthdays` → `PostCard.initialBirthday`).
//
// All three are decoration. The web client says so in both components — a
// failed read shows nothing, or the spotlight's empty line — and nothing here
// is allowed to turn a failure of theirs into a failure of the feed.

// MARK: - Readers

/// Posts created since a cutoff, newest first — the candidate read of
/// `getPopularPosts` (src/services/posts.ts), before it sorts.
///
/// Not a new query. `SearchRepository.posts(since:limit:)` already is exactly
/// this read, for the search page's trending section (`getTrendingPosts` has
/// the same shape), so the live value is the search repository itself. The
/// protocol is this narrow so the spotlight's fakes do not have to answer
/// eleven search reads they are never asked.
protocol PopularPostsReading: Sendable {
    func posts(since date: Date, limit: Int) async throws -> [Post]
}

extension FirestoreSearchRepository: PopularPostsReading {}

/// Pets by id, for the birthday mark on feed cards — the read half of
/// `batchCheckPetBirthdays` (src/services/pets.ts).
///
/// Only the read. Whether a pet's birthday is today stays `Pet.isBirthday`,
/// the rule the pet page already uses, so the card and the page cannot
/// disagree about the same pet.
protocol PetBirthdayReading: Sendable {
    /// The caller chunks (see `FeedExtras.birthdayBatchSize`), so that a test
    /// can see the chunks. More ids than one chunk are still read correctly.
    func pets(ids: [String]) async throws -> [Pet]
}

/// `documentId() in` reads of `pets`, thirty ids at a time.
///
/// Thirty rather than the web client's ten: Firestore has accepted thirty
/// values in an `in` filter since the SDK this project pins, and
/// `FirestoreLikeRepository` already batches at thirty. A feed page of twenty
/// posts is then one read, not two.
actor FirestorePetBirthdaySource: PetBirthdayReading {
    private let db: Firestore

    init(db: Firestore = .firestore()) {
        self.db = db
    }

    func pets(ids: [String]) async throws -> [Pet] {
        let valid = ids.compactMap(DeepLink.validDocumentID)
        var found: [Pet] = []
        for batch in IDBatches.make(valid, size: FeedExtras.birthdayBatchSize) {
            let snapshot = try await db.collection("pets")
                .whereField(FieldPath.documentID(), in: batch)
                .getDocuments()
            for document in snapshot.documents {
                // The shared decoder, so a pet here is the pet its own page
                // draws — including the canonical month/day `isBirthday` reads.
                if let pet = PetDecoder.pet(id: document.documentID, from: document.data()) {
                    found.append(pet)
                }
            }
        }
        return found
    }
}

/// Who the viewer has blocked, from the same place the feed's own filter gets
/// it.
///
/// `BlockFilteringFeed` is that place: it holds the one cached copy of the
/// list, it is told when a block or an unblock happens (`invalidate`), and it
/// is told when the account changes (`switchAccount`). Reading the list a
/// second way here would be a second cache with a second way to go stale.
protocol BlockedAuthorsProviding: Sendable {
    /// Unreadable means empty, as on the web: not knowing who is blocked
    /// filters nothing rather than hiding everything.
    func blockedIDs() async -> Set<String>
}

extension BlockFilteringFeed: BlockedAuthorsProviding {}

// MARK: - Seen spotlight posts

/// Which spotlight posts this account has opened — the web client's
/// `petnote_seen_spotlights` (src/components/PetSpotlight.tsx).
protocol SpotlightSeenStoring: Sendable {
    /// Oldest first, as the web client keeps it.
    func seen(uid: String) -> [String]
    func save(_ ids: [String], uid: String)
    func clear(uid: String)
}

/// The seen list in `UserDefaults`, one per account.
///
/// **Per account, where the web client's key is global.** Its key is one
/// string for the whole browser, so a second person signing in on the same
/// machine inherits the first person's dimmed tiles. The compose draft made
/// the same mistake and was fixed the same way (`UserDefaultsComposeDraftStore`).
///
/// `@unchecked Sendable` for the reason the draft store gives: `UserDefaults`
/// is documented as thread-safe but not marked `Sendable`, and the only stored
/// property here is that `let`.
final class UserDefaultsSpotlightSeenStore: SpotlightSeenStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(uid: String) -> String { "petnote_seen_spotlights:\(uid)" }

    func seen(uid: String) -> [String] {
        defaults.stringArray(forKey: Self.key(uid: uid)) ?? []
    }

    func save(_ ids: [String], uid: String) {
        defaults.set(ids, forKey: Self.key(uid: uid))
    }

    func clear(uid: String) {
        defaults.removeObject(forKey: Self.key(uid: uid))
    }
}

// MARK: - Values

/// One tile in the spotlight row.
struct SpotlightItem: Equatable, Identifiable {
    let post: Post
    let isSeen: Bool

    var id: String { post.id }

    /// Who the tile is about. The row is "Popular Pets", so the pet leads;
    /// a post with no pet falls back to its author, and one with neither to
    /// "Pet" — the web client's `post.petName || post.authorName || "Pet"`.
    var name: String {
        if let petName = post.petName { return petName }
        if !post.authorName.isEmpty { return post.authorName }
        return String(localized: "Pet", comment: "Stand-in name for a pet whose name is missing")
    }

    /// The name under the picture, cut the way the web client cuts it.
    var label: String { FeedExtras.truncated(name) }
}

/// What the birthday banner says.
struct BirthdayBanner: Equatable {
    let petID: String
    let title: String
    /// Nil when the pet's birth year is not known.
    let ageLine: String?
    let avatarURL: URL?
    let species: PetSpecies
}

/// The spotlight row's three states. The web client has the same three —
/// skeleton, "Share your pet to get featured!", and the tiles — and draws a
/// failure as the second, which is kept.
enum SpotlightPhase: Equatable {
    case loading
    case empty
    case items([SpotlightItem])
}

// MARK: - Rules

/// The decisions the two web components make, as pure functions so each can
/// be checked on its own.
enum FeedExtras {
    /// `PetSpotlight`'s `limitCount`.
    static let spotlightLimit = 10
    /// `markAsSeen` keeps the last hundred.
    static let seenCap = 100
    /// `truncate(value, max = 8)`.
    static let nameLength = 8
    /// See `FirestorePetBirthdaySource`.
    static let birthdayBatchSize = 30
    /// `getPopularPosts(limitCount, 24)`, then `24 * 7` when that is short.
    static let recentWindow: TimeInterval = 24 * 60 * 60
    static let fallbackWindow: TimeInterval = 7 * 24 * 60 * 60
    /// The mark a card carries on its pet's birthday. Not words, so not a
    /// catalog entry; the card gives it a spoken label.
    static let birthdayMark = "🎂"

    /// `value.length > max ? value.slice(0, max) + "…" : value`.
    ///
    /// Counted in characters, where the web counts UTF-16 units: an emoji in
    /// a name is one character to a reader, and cutting it in half draws a
    /// broken glyph.
    static func truncated(_ value: String, max: Int = FeedExtras.nameLength) -> String {
        value.count > max ? String(value.prefix(max)) + "…" : value
    }

    /// Unseen first, seen after, and the likes order kept inside each group —
    /// the web client's comparator returns 0 within a group, and `Array.sort`
    /// is stable.
    static func seenLast(_ posts: [Post], seen: Set<String>) -> [SpotlightItem] {
        let items = posts.map { SpotlightItem(post: $0, isSeen: seen.contains($0.id)) }
        return items.filter { !$0.isSeen } + items.filter(\.isSeen)
    }

    /// `markAsSeen`: appended once, and the oldest dropped past the cap.
    static func markingSeen(_ id: String, in seen: [String], cap: Int = FeedExtras.seenCap) -> [String] {
        guard !seen.contains(id) else { return seen }
        var next = seen + [id]
        if next.count > cap { next.removeFirst(next.count - cap) }
        return next
    }

    /// The banner for the pets whose birthday it is, or nil when there are
    /// none. The first pet is named; the rest are counted, as the web does.
    static func banner(for birthdayPets: [Pet], on date: Date, calendar: Calendar) -> BirthdayBanner? {
        guard let first = birthdayPets.first else { return nil }
        let greeting = String(localized: "🎂🎉 Happy Birthday, \(first.name)! 🎉🎂")
        let others = birthdayPets.count - 1
        return BirthdayBanner(
            petID: first.id,
            title: others > 0 ? "\(greeting) +\(others)" : greeting,
            ageLine: ageLine(for: first, on: date, calendar: calendar),
            avatarURL: first.avatarURL,
            species: first.species
        )
    }

    /// "Turning N years old today!", when the year is known.
    ///
    /// The birth year is read from the legacy timestamp's **UTC** fields, for
    /// the reason `Pet.isBirthday` reads its month and day that way: the
    /// server derives the canonical pair from UTC, and a pet born on 1 January
    /// must not come out a year older west of Greenwich.
    ///
    /// One deliberate difference from the web client, which prints whatever
    /// the subtraction gives: a pet born this year gets no line, rather than
    /// "Turning 0 years old today!".
    static func ageLine(for pet: Pet, on date: Date, calendar: Calendar) -> String? {
        guard let birthday = pet.birthday else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let years = calendar.component(.year, from: date) - utc.component(.year, from: birthday)
        guard years >= 1 else { return nil }
        return years == 1
            ? String(localized: "Turning 1 year old today!")
            : String(localized: "Turning \(years) years old today!")
    }
}

// MARK: - Model

/// Drives the banner, the spotlight row and the cards' birthday marks for one
/// signed-in account.
///
/// Owned by `SignedInView` with the feed's own model, and reset the same way
/// on an account switch (`prepare(for:)`): the view keeps its identity across
/// a switch, so everything in here would otherwise be the previous person's —
/// their pets' birthdays, and which spotlight posts *they* have opened.
@MainActor
@Observable
final class FeedExtrasModel {
    /// Nil while there is nothing to say — no birthday today, not loaded yet,
    /// or a first read that failed.
    private(set) var banner: BirthdayBanner?
    /// Closed for this session. Survives a refresh; does not survive signing
    /// out or switching account.
    private(set) var isBannerDismissed = false
    /// Nil until the first answer; empty after an answer with nothing in it or
    /// a failed read.
    private(set) var spotlightPosts: [Post]?
    /// Oldest first, as stored.
    private(set) var seenPostIDs: [String] = []
    /// Pets on screen whose birthday is today.
    private(set) var birthdayPetIDs: Set<String> = []

    private let pets: any PetChoiceProviding
    private let popular: any PopularPostsReading
    private let birthdays: any PetBirthdayReading
    private let blocked: any BlockedAuthorsProviding
    private let seenStore: any SpotlightSeenStoring
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "feed")

    private var accountID: String
    private var didLoad = false
    /// Bumped by `prepare(for:)`. An answer carrying an older one was asked
    /// for somebody else.
    private var generation = 0
    /// Per read, so a slow first answer cannot land on top of a newer one.
    private var bannerRequest = 0
    private var spotlightRequest = 0

    /// Pets already asked about, and pets being asked about now. The second
    /// is what keeps two overlapping checks — a page arriving while the last
    /// one's read is still out — from reading the same ids twice.
    private var checkedPetIDs: Set<String> = []
    private var pendingPetIDs: Set<String> = []
    /// The day the marks were worked out for. A session that runs past
    /// midnight asks again instead of showing yesterday's birthdays.
    private var markedDay: DateComponents?

    init(
        accountID: String,
        pets: any PetChoiceProviding,
        popular: any PopularPostsReading,
        birthdays: any PetBirthdayReading,
        blocked: any BlockedAuthorsProviding,
        seenStore: any SpotlightSeenStoring = UserDefaultsSpotlightSeenStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.accountID = accountID
        self.pets = pets
        self.popular = popular
        self.birthdays = birthdays
        self.blocked = blocked
        self.seenStore = seenStore
        self.now = now
        self.calendar = calendar
    }

    // MARK: Reading

    /// The banner to draw, if any.
    var visibleBanner: BirthdayBanner? {
        isBannerDismissed ? nil : banner
    }

    /// The spotlight row as it should be drawn now. Worked out on each read
    /// rather than stored, so marking a post seen reorders it without a second
    /// copy of the list to keep in step.
    var spotlight: SpotlightPhase {
        guard let spotlightPosts else { return .loading }
        guard !spotlightPosts.isEmpty else { return .empty }
        return .items(FeedExtras.seenLast(spotlightPosts, seen: Set(seenPostIDs)))
    }

    func hasBirthday(petID: String?) -> Bool {
        guard let petID else { return false }
        return birthdayPetIDs.contains(petID)
    }

    // MARK: Account

    /// Binds this model to a signed-in account, discarding everything it holds
    /// for a different one. See `FeedViewModel.prepare(for:)` for why a switch
    /// needs this and signing out does not.
    func prepare(for accountID: String) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        generation += 1
        didLoad = false
        banner = nil
        isBannerDismissed = false
        spotlightPosts = nil
        seenPostIDs = []
        birthdayPetIDs = []
        checkedPetIDs = []
        pendingPetIDs = []
        markedDay = nil
    }

    // MARK: Loading

    /// Once per session; the feed's appearance calls this every time it comes
    /// back into view, and that is not a reason to read again.
    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await reload()
    }

    /// Pull-to-refresh. Both at once — they are unrelated reads, and waiting
    /// for one before asking for the other only makes the row late.
    func reload() async {
        didLoad = true
        // `async let` and not a task group, for the reason
        // `PetProfileViewModel.load()` gives: both reads mutate this object,
        // so they run on the main actor and interleave only at their awaits.
        async let bannerRead: Void = reloadBanner()
        async let spotlightRead: Void = reloadSpotlight()
        _ = await (bannerRead, spotlightRead)
    }

    /// A pet was added, edited or removed. Only once something has been
    /// shown: before that, `loadIfNeeded` is about to ask anyway.
    func petsChanged() async {
        guard didLoad else { return }
        await reloadBanner()
    }

    /// A block or an unblock. The feed's filter has been told already; this
    /// asks it again.
    func blocksChanged() async {
        guard didLoad else { return }
        await reloadSpotlight()
    }

    /// `getBirthdayPets`: the person's pets, less the ones whose birthday is
    /// not today.
    private func reloadBanner() async {
        bannerRequest += 1
        let request = bannerRequest
        let account = accountID
        let generation = self.generation
        do {
            let owned = try await pets.pets(ownedBy: account)
            guard generation == self.generation, request == bannerRequest else { return }
            let today = now()
            banner = FeedExtras.banner(
                for: owned.filter { $0.isBirthday(on: today, calendar: calendar) },
                on: today,
                calendar: calendar
            )
        } catch {
            // Decorative, as the web client says: never an error on screen.
            // And a read that fails decides nothing — a first load that fails
            // leaves no banner, a refresh that fails leaves the one that was
            // true a moment ago rather than taking it away.
            log.error("birthday pets read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `PetSpotlight`'s load: the last day, and the last week when the day
    /// has fewer than ten.
    ///
    /// What is on screen stays on screen while a refresh is out; only the
    /// first load shows the placeholders.
    private func reloadSpotlight() async {
        spotlightRequest += 1
        let request = spotlightRequest
        let account = accountID
        let generation = self.generation
        do {
            let blockedIDs = await blocked.blockedIDs()
            let asked = now()
            var posts = try await popularPosts(
                since: asked.addingTimeInterval(-FeedExtras.recentWindow), excluding: blockedIDs
            )
            if posts.count < FeedExtras.spotlightLimit {
                posts = try await popularPosts(
                    since: asked.addingTimeInterval(-FeedExtras.fallbackWindow), excluding: blockedIDs
                )
            }
            guard generation == self.generation, request == spotlightRequest else { return }
            seenPostIDs = seenStore.seen(uid: account)
            spotlightPosts = posts
        } catch {
            guard generation == self.generation, request == spotlightRequest else { return }
            log.error("spotlight read failed: \(error.localizedDescription, privacy: .public)")
            // The web client's choice for a load that fails: the empty line,
            // not a skeleton left pulsing and not an error. A refresh that
            // fails over tiles already drawn keeps them.
            if spotlightPosts == nil {
                seenPostIDs = seenStore.seen(uid: account)
                spotlightPosts = []
            }
        }
    }

    /// `getPopularPosts`: the newest `max(limit × 10, 50)` since the cutoff,
    /// most liked first and newest first on a tie, ten of them.
    ///
    /// Blocked authors come out before the ten are chosen, not after, so a
    /// block costs the row a tile only when there is nothing to replace it
    /// with. The web spotlight does not filter blocked authors at all; the
    /// web feed does, and a person who blocked somebody does not expect to
    /// find them featured at the top of it.
    private func popularPosts(since cutoff: Date, excluding blockedIDs: Set<String>) async throws -> [Post] {
        let candidates = try await popular.posts(
            since: cutoff, limit: SearchLogic.trendingCandidateCount(for: FeedExtras.spotlightLimit)
        )
        return SearchLogic.trending(
            SearchLogic.withoutBlocked(candidates, blocked: blockedIDs), limit: FeedExtras.spotlightLimit
        )
    }

    // MARK: Acting

    /// The ✕. Hidden until this session ends, as on the web.
    func dismissBanner() {
        isBannerDismissed = true
    }

    /// Opened from the spotlight: dimmed and moved to the end from now on.
    ///
    /// Added to what is stored, not to the copy held here — the web client's
    /// `markAsSeen` reads `localStorage` afresh for the same reason: the copy
    /// is only as new as the last load, and saving from it could drop a mark.
    func markSeen(_ postID: String) {
        let stored = seenStore.seen(uid: accountID)
        let next = FeedExtras.markingSeen(postID, in: stored)
        if next != stored { seenStore.save(next, uid: accountID) }
        seenPostIDs = next
    }

    // MARK: Birthday marks

    /// `batchCheckPetBirthdays` for the pets on these cards that have not been
    /// asked about yet, thirty to a read.
    ///
    /// A chunk that fails is left unasked, so the next check — the next page,
    /// or a refresh — tries it again. The web client marks it checked and
    /// never asks again; the mark is decoration, but so is the retry's cost.
    func checkBirthdays(for posts: [Post]) async {
        rollOverIfTheDayChanged()
        var seen: Set<String> = []
        let unasked = posts.compactMap(\.petID).filter {
            seen.insert($0).inserted && !checkedPetIDs.contains($0) && !pendingPetIDs.contains($0)
        }
        guard !unasked.isEmpty else { return }
        pendingPetIDs.formUnion(unasked)
        let generation = self.generation

        for chunk in IDBatches.make(unasked, size: FeedExtras.birthdayBatchSize) {
            let found: [Pet]
            do {
                found = try await birthdays.pets(ids: chunk)
            } catch {
                guard generation == self.generation else { return }
                pendingPetIDs.subtract(chunk)
                log.error("birthday marks read failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard generation == self.generation else { return }
            pendingPetIDs.subtract(chunk)
            checkedPetIDs.formUnion(chunk)
            let today = now()
            for pet in found where pet.isBirthday(on: today, calendar: calendar) {
                birthdayPetIDs.insert(pet.id)
            }
        }
    }

    private func rollOverIfTheDayChanged() {
        let today = calendar.dateComponents([.year, .month, .day], from: now())
        guard today != markedDay else { return }
        if markedDay != nil {
            checkedPetIDs = []
            birthdayPetIDs = []
        }
        markedDay = today
    }
}
