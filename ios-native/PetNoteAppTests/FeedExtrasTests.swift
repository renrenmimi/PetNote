import Foundation
import Testing

@testable import PetNote

/// The feed's birthday banner, its "⭐ Popular Pets" row and the cards'
/// birthday marks, against fakes — the web client's `BirthdayCelebration`,
/// `PetSpotlight` and `batchCheckPetBirthdays`.
///
/// The blocked list comes through a real `BlockFilteringFeed` over the social
/// fake, so "the same block source the feed uses" is checked as a fact and
/// not assumed from a protocol conformance.
@MainActor
struct FeedExtrasTests {
    // MARK: - Fakes

    /// One call's own behaviour, for the fakes below that can be told how
    /// each read goes: held until a gate opens, or failed. Taken in order,
    /// one per call; once they run out the fake answers from its inputs.
    struct Step {
        var gate: SocialGate?
        var error: Error?
    }

    /// Answers the way the Firestore query does: at or after the cutoff,
    /// newest first, at most `limit`.
    final class FakePopularPosts: PopularPostsReading, @unchecked Sendable {
        /// Every input and record below is taken under this lock. The model's
        /// reads run with `async let`, so calls arrive on several threads at
        /// once, and some tests change an input while a read is still out;
        /// an unlocked append crashed a CI run (SIGSEGV in
        /// `posts(since:limit:)`, run 35905119437, 2026-09-23).
        private let lock = NSLock()
        private var storedPosts: [Post] = []
        private var storedError: Error?
        private var steps: [Step] = []
        private var cutoffs: [Date] = []
        private var limits: [Int] = []

        var stored: [Post] {
            get { lock.withLock { storedPosts } }
            set { lock.withLock { storedPosts = newValue } }
        }
        var error: Error? {
            get { lock.withLock { storedError } }
            set { lock.withLock { storedError = newValue } }
        }
        var script: [Step] {
            get { lock.withLock { steps } }
            set { lock.withLock { steps = newValue } }
        }
        var recordedCutoffs: [Date] { lock.withLock { cutoffs } }
        var recordedLimits: [Int] { lock.withLock { limits } }

        func posts(since date: Date, limit: Int) async throws -> [Post] {
            let (stored, error, step) = lock.withLock { () -> ([Post], Error?, Step?) in
                cutoffs.append(date)
                limits.append(limit)
                return (storedPosts, storedError, steps.isEmpty ? nil : steps.removeFirst())
            }
            if let gate = step?.gate { await gate.wait() }
            if let failure = step?.error ?? error { throw failure }
            return stored
                .filter { $0.createdAt >= date }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// Pets by id. A chunk holding any id in `failing` fails whole, as a
    /// Firestore read does.
    final class FakeBirthdayPets: PetBirthdayReading, @unchecked Sendable {
        /// Inputs and records under the lock, for the reason
        /// `FakePopularPosts` gives.
        private let lock = NSLock()
        private var petsByID: [String: Pet] = [:]
        private var failingIDs: Set<String> = []
        private var heldBy: SocialGate?
        private var asked: [[String]] = []

        var byID: [String: Pet] {
            get { lock.withLock { petsByID } }
            set { lock.withLock { petsByID = newValue } }
        }
        var failing: Set<String> {
            get { lock.withLock { failingIDs } }
            set { lock.withLock { failingIDs = newValue } }
        }
        /// When set, every read waits for it before answering.
        var gate: SocialGate? {
            get { lock.withLock { heldBy } }
            set { lock.withLock { heldBy = newValue } }
        }
        var requests: [[String]] { lock.withLock { asked } }

        func pets(ids: [String]) async throws -> [Pet] {
            let (byID, failing, gate) = lock.withLock { () -> ([String: Pet], Set<String>, SocialGate?) in
                asked.append(ids)
                return (petsByID, failingIDs, heldBy)
            }
            if let gate { await gate.wait() }
            if !failing.isDisjoint(with: ids) { throw SocialFixture.readFailure }
            return ids.compactMap { byID[$0] }
        }
    }

    /// The signed-in person's pets, per account.
    final class FakeOwnedPets: PetChoiceProviding, @unchecked Sendable {
        /// Inputs and records under the lock, for the reason
        /// `FakePopularPosts` gives.
        private let lock = NSLock()
        private var petsByOwner: [String: [Pet]] = [:]
        private var storedError: Error?
        private var steps: [Step] = []
        private var asked: [String] = []

        var byOwner: [String: [Pet]] {
            get { lock.withLock { petsByOwner } }
            set { lock.withLock { petsByOwner = newValue } }
        }
        var error: Error? {
            get { lock.withLock { storedError } }
            set { lock.withLock { storedError = newValue } }
        }
        var script: [Step] {
            get { lock.withLock { steps } }
            set { lock.withLock { steps = newValue } }
        }
        var reads: [String] { lock.withLock { asked } }

        func pets(ownedBy uid: String) async throws -> [Pet] {
            let (pets, error, step) = lock.withLock { () -> ([Pet], Error?, Step?) in
                asked.append(uid)
                return (petsByOwner[uid] ?? [], storedError, steps.isEmpty ? nil : steps.removeFirst())
            }
            if let gate = step?.gate { await gate.wait() }
            if let failure = step?.error ?? error { throw failure }
            return pets
        }
    }

    /// A clock a test can move.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ date: Date) { current = date }

        var now: Date { lock.withLock { current } }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    private struct NoDrafts: ComposeDraftStoring {
        func load(uid: String) -> ComposeDraft? { nil }
        func save(_ draft: ComposeDraft, uid: String) {}
        func clear(uid: String) {}
    }

    // MARK: - Fixtures

    /// 2026-09-23, noon in New York.
    private static func clock() throws -> (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12)))
        return (now, calendar)
    }

    /// A defaults domain of the test's own, so nothing leaks between tests or
    /// into the app's.
    private static func defaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "FeedExtrasTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    /// Where both clients put a picked birthday: midnight, in the calendar
    /// of the person who picked it (AddPet.tsx:290-306,
    /// `FirestorePetRepository.birthdayFields`).
    private static func localMidnight(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    /// The legacy timestamp as the server's month/day derivation reads it,
    /// for the pet page's own `isBirthday` fallback.
    private static func utcMidnight(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return try #require(utc.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private static func post(
        _ id: String,
        likes: Int = 0,
        hoursAgo: Double = 1,
        from now: Date = Date(timeIntervalSince1970: 1_790_000_000),
        author: String = "alice",
        pet: String? = "Mochi",
        petID: String? = nil
    ) -> Post {
        Post(
            id: id, authorID: author, authorName: author.capitalized, authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: petID, petName: pet,
            petAvatarURL: nil, createdAt: now.addingTimeInterval(-hoursAgo * 3600),
            likeCount: likes, commentCount: 0, tags: []
        )
    }

    private func makeModel(
        uid: String = "me",
        pets: FakeOwnedPets = FakeOwnedPets(),
        popular: FakePopularPosts = FakePopularPosts(),
        birthdays: FakeBirthdayPets = FakeBirthdayPets(),
        social: FakeSocialRepository = FakeSocialRepository(),
        seen: any SpotlightSeenStoring,
        now: Date,
        calendar: Calendar
    ) -> FeedExtrasModel {
        FeedExtrasModel(
            accountID: uid,
            pets: pets,
            popular: popular,
            birthdays: birthdays,
            blocked: BlockFilteringFeed(base: FeedViewModelTests.FakeFeed(), social: social, viewerID: uid),
            seenStore: seen,
            now: { now },
            calendar: calendar
        )
    }

    private static func items(_ phase: SpotlightPhase) -> [SpotlightItem] {
        guard case .items(let items) = phase else { return [] }
        return items
    }

    private static func ids(_ phase: SpotlightPhase) -> [String] {
        items(phase).map(\.id)
    }

    // MARK: - Spotlight: what is featured

    /// `getPopularPosts`: the most liked first, and the newer first on a tie,
    /// ten of them.
    @Test func theSpotlightIsTheMostLikedThenTheNewest() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let popular = FakePopularPosts()
        popular.stored = [
            Self.post("a", likes: 5, hoursAgo: 3, from: now),
            Self.post("b", likes: 9, hoursAgo: 20, from: now),
            Self.post("c", likes: 5, hoursAgo: 1, from: now),   // ties a, and is newer
            Self.post("d", likes: 0, hoursAgo: 2, from: now),
            Self.post("e", likes: 7, hoursAgo: 5, from: now),
            Self.post("f", likes: 1, hoursAgo: 6, from: now),
            Self.post("g", likes: 2, hoursAgo: 7, from: now),
            Self.post("h", likes: 3, hoursAgo: 8, from: now),
            Self.post("i", likes: 4, hoursAgo: 9, from: now),
            Self.post("j", likes: 6, hoursAgo: 10, from: now),
            Self.post("k", likes: 8, hoursAgo: 11, from: now),
            Self.post("l", likes: 0, hoursAgo: 12, from: now),
        ]
        let model = makeModel(
            popular: popular, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        #expect(model.spotlight == .loading, "nothing has been asked yet")
        await model.loadIfNeeded()

        #expect(Self.ids(model.spotlight) == ["b", "k", "e", "j", "c", "a", "i", "h", "g", "f"])
        #expect(popular.recordedCutoffs == [now.addingTimeInterval(-24 * 3600)],
                "ten in the last day is enough; the week was not asked for")
        #expect(popular.recordedLimits == [100], "max(limit × 10, 50) candidates, as the web reads")
    }

    /// Fewer than ten in a day: the web asks again for the week.
    @Test func fewerThanTenInADayWidensToTheWeek() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let popular = FakePopularPosts()
        popular.stored = [
            Self.post("today", likes: 1, hoursAgo: 2, from: now),
            Self.post("late-last-night", likes: 0, hoursAgo: 23, from: now),
            Self.post("yesterday", likes: 4, hoursAgo: 30, from: now),
            Self.post("last-week", likes: 9, hoursAgo: 24 * 6, from: now),
            Self.post("too-old", likes: 50, hoursAgo: 24 * 8, from: now),
        ]
        let model = makeModel(
            popular: popular, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        await model.loadIfNeeded()

        #expect(popular.recordedCutoffs == [
            now.addingTimeInterval(-24 * 3600),
            now.addingTimeInterval(-7 * 24 * 3600),
        ])
        #expect(Self.ids(model.spotlight) == ["last-week", "yesterday", "today", "late-last-night"],
                "the week's posts, ranked; nothing older than the week")
    }

    /// Somebody the viewer blocked is not featured — through the feed's own
    /// filter, and a block made later takes effect once the filter is told.
    @Test func peopleTheViewerBlockedAreNotFeatured() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let popular = FakePopularPosts()
        popular.stored = (1...10).map { Self.post("alice-\($0)", likes: $0, hoursAgo: 1, from: now) }
            + [
                Self.post("bob-1", likes: 100, hoursAgo: 1, from: now, author: "bob"),
                Self.post("bob-2", likes: 90, hoursAgo: 2, from: now, author: "bob"),
            ]
        let social = FakeSocialRepository()
        social.blocked = ["bob"]
        let filter = BlockFilteringFeed(base: FeedViewModelTests.FakeFeed(), social: social, viewerID: "me")
        let model = FeedExtrasModel(
            accountID: "me", pets: FakeOwnedPets(), popular: popular, birthdays: FakeBirthdayPets(),
            blocked: filter, seenStore: UserDefaultsSpotlightSeenStore(defaults: defaults),
            now: { now }, calendar: calendar
        )

        await model.loadIfNeeded()

        let shown = Self.items(model.spotlight)
        #expect(!shown.contains { $0.post.authorID == "bob" }, "a blocked author is featured")
        #expect(shown.count == 10, "the blocked author's tiles were replaced, not left empty")
        #expect(social.blockedReads == 1, "the list came through the feed's filter, once")

        social.blocked = ["bob", "alice"]
        await model.blocksChanged()
        #expect(Self.items(model.spotlight).count == 10, "the filter's cache holds until it is told")

        await filter.invalidate()
        await model.blocksChanged()
        #expect(model.spotlight == .empty)
    }

    /// The web client's choice for a load that fails: the empty line. A
    /// refresh that fails over tiles already drawn keeps them.
    @Test func aSpotlightThatCannotBeReadShowsTheEmptyLine() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let popular = FakePopularPosts()
        popular.error = SocialFixture.readFailure
        let model = makeModel(
            popular: popular, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        await model.loadIfNeeded()
        #expect(model.spotlight == .empty)

        popular.error = nil
        popular.stored = [Self.post("a", likes: 1, hoursAgo: 1, from: now)]
        await model.reload()
        #expect(Self.ids(model.spotlight) == ["a"])

        popular.error = SocialFixture.readFailure
        await model.reload()
        #expect(Self.ids(model.spotlight) == ["a"], "a failed refresh took the tiles away")
    }

    // MARK: - Spotlight: seen

    /// Opened ones go after the rest, keeping the likes order inside each
    /// group, and say so to VoiceOver as well as by being dimmed.
    @Test func postsAlreadyOpenedGoLast() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSpotlightSeenStore(defaults: defaults)
        store.save(["top"], uid: "me")
        let popular = FakePopularPosts()
        popular.stored = [
            Self.post("top", likes: 9, hoursAgo: 1, from: now),
            Self.post("second", likes: 5, hoursAgo: 1, from: now),
            Self.post("third", likes: 1, hoursAgo: 1, from: now),
        ]
        let model = makeModel(popular: popular, seen: store, now: now, calendar: calendar)

        await model.loadIfNeeded()
        #expect(Self.ids(model.spotlight) == ["second", "third", "top"])
        #expect(Self.items(model.spotlight).map(\.isSeen) == [false, false, true])

        model.markSeen("second")
        #expect(Self.ids(model.spotlight) == ["third", "top", "second"],
                "the likes order holds inside the seen group too")
        #expect(store.seen(uid: "me") == ["top", "second"], "the tap was not stored")
    }

    /// `markAsSeen`: at most a hundred, the oldest dropped first, and marking
    /// one already seen changes nothing.
    @Test func theSeenListKeepsTheLatestHundred() async throws {
        let hundred = (0..<100).map { "p\($0)" }
        let next = FeedExtras.markingSeen("new", in: hundred)
        #expect(next.count == 100)
        #expect(next.first == "p1")
        #expect(next.last == "new")
        #expect(FeedExtras.markingSeen("p5", in: hundred) == hundred)

        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSpotlightSeenStore(defaults: defaults)
        let model = makeModel(seen: store, now: now, calendar: calendar)
        for index in 0...100 { model.markSeen("p\(index)") }
        let stored = store.seen(uid: "me")
        #expect(stored.count == 100)
        #expect(!stored.contains("p0"))
        #expect(stored.last == "p100")
    }

    /// Per account: what one person opened is not dimmed for the next person
    /// on the same phone — the web client's single global key is the mistake
    /// this does not repeat.
    @Test func whatOneAccountOpenedIsNotDimmedForAnother() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSpotlightSeenStore(defaults: defaults)
        let popular = FakePopularPosts()
        popular.stored = [
            Self.post("shared", likes: 3, hoursAgo: 1, from: now),
            Self.post("other", likes: 1, hoursAgo: 1, from: now),
        ]
        let model = makeModel(uid: "alice-uid", popular: popular, seen: store, now: now, calendar: calendar)
        await model.loadIfNeeded()
        model.markSeen("shared")
        #expect(Self.ids(model.spotlight) == ["other", "shared"])

        model.prepare(for: "bob-uid")
        #expect(model.spotlight == .loading, "the previous account's row was still drawn")
        await model.loadIfNeeded()
        #expect(Self.ids(model.spotlight) == ["shared", "other"])
        #expect(Self.items(model.spotlight).allSatisfy { !$0.isSeen })

        #expect(store.seen(uid: "alice-uid") == ["shared"])
        #expect(store.seen(uid: "bob-uid").isEmpty)
        #expect(UserDefaultsSpotlightSeenStore.key(uid: "alice-uid") != UserDefaultsSpotlightSeenStore.key(uid: "bob-uid"))
    }

    /// A deleted account's list goes with it, and nobody else's does.
    @Test func forgettingADeletedAccountForgetsWhatItOpened() async throws {
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSpotlightSeenStore(defaults: defaults)
        store.save(["p1"], uid: "deleted")
        store.save(["p2"], uid: "someone-else")

        await AccountLocalData.forget(
            uid: "deleted", drafts: NoDrafts(),
            images: ImageLoader(session: URLSession(configuration: .ephemeral)),
            seenSpotlights: store
        )

        #expect(store.seen(uid: "deleted").isEmpty)
        #expect(store.seen(uid: "someone-else") == ["p2"])
    }

    // MARK: - Spotlight: names

    /// `truncate(value, 8)`, counted as JavaScript counts: UTF-16 units.
    @Test func namesAreCutAtEightUnitsAsTheWebCutsThem() {
        #expect(FeedExtras.truncated("Biscuit") == "Biscuit")
        #expect(FeedExtras.truncated("Mochiko!") == "Mochiko!", "eight is not more than eight")
        #expect(FeedExtras.truncated("Mochi the Great") == "Mochi th…")
        // The seed's long CJK name: one unit a character.
        #expect(FeedExtras.truncated("麻薯团子小豆泥花生酱") == "麻薯团子小豆泥花…")
        // An emoji is two units, so four of them are eight and are not cut...
        #expect(FeedExtras.truncated("🐶🐶🐶🐶") == "🐶🐶🐶🐶")
        // ...and nine are cut after four, where the web cuts them.
        #expect(FeedExtras.truncated("🐶🐶🐶🐶🐶🐶🐶🐶🐶") == "🐶🐶🐶🐶…")
        // A cut through the middle of one leaves half of it, as the web's
        // `slice` does; the half is drawn as the replacement mark.
        #expect(FeedExtras.truncated("Mochi🐶🐶") == "Mochi🐶\u{FFFD}…")
    }

    /// The pet, then the author, then "Pet" — and the whole name is what is
    /// read aloud.
    @Test func aTileIsNamedForThePetThenTheAuthor() {
        let withPet = SpotlightItem(post: Self.post("a", pet: "Sir Pounce-a-lot"), isSeen: false)
        #expect(withPet.label == "Sir Poun…")
        #expect(withPet.name == "Sir Pounce-a-lot")

        let noPet = SpotlightItem(post: Self.post("b", author: "alice", pet: nil), isSeen: false)
        #expect(noPet.label == "Alice")

        let nobody = SpotlightItem(post: Self.post("c", author: "", pet: nil), isSeen: false)
        #expect(nobody.label == "Pet")
    }

    // MARK: - Birthday banner

    /// Which pets count is the pet page's rule, asked the same way: the
    /// canonical month and day, or the legacy timestamp's UTC fields.
    @Test func theBannerCountsThePetsThePetPageWould() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let legacyBirthday = try Self.utcMidnight(2020, 9, 23)
        let canonical = PetFixture.pet(id: "canonical", name: "Mochi", birthdayMonth: 9, birthdayDay: 23)
        let tomorrow = PetFixture.pet(id: "tomorrow", name: "Tomorrow", birthdayMonth: 9, birthdayDay: 24)
        let legacy = PetFixture.pet(id: "legacy", name: "Old Timer", birthday: legacyBirthday)
        let none = PetFixture.pet(id: "none", name: "Nobody")
        let pets = FakeOwnedPets()
        pets.byOwner["me"] = [canonical, tomorrow, legacy, none]
        let model = makeModel(
            pets: pets, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        await model.loadIfNeeded()

        let counted = [canonical, tomorrow, legacy, none]
            .filter { $0.isBirthday(on: now, calendar: calendar) }
            .map(\.id)
        #expect(counted == ["canonical", "legacy"], "the control: the rule itself answers this way")
        let banner = try #require(model.visibleBanner, "two birthdays today and no banner")
        #expect(banner.petID == "canonical")
        #expect(banner.title == "🎂🎉 Happy Birthday, Mochi! 🎉🎂 +1")
        #expect(pets.reads == ["me"])
        #expect(model.bannerReadsSettled == 1, "the probe's count did not see the read come back")
    }

    @Test func oneBirthdayIsNamedAndTheRestAreCounted() throws {
        let (now, calendar) = try Self.clock()
        let one = FeedExtras.banner(for: [PetFixture.pet(id: "a", name: "Mochi")], on: now, calendar: calendar)
        #expect(one?.title == "🎂🎉 Happy Birthday, Mochi! 🎉🎂")

        let three = FeedExtras.banner(
            for: [
                PetFixture.pet(id: "a", name: "Mochi"),
                PetFixture.pet(id: "b", name: "Bean"),
                PetFixture.pet(id: "c", name: "Tofu"),
            ],
            on: now, calendar: calendar
        )
        #expect(three?.title == "🎂🎉 Happy Birthday, Mochi! 🎉🎂 +2")
        #expect(three?.petID == "a", "the first pet is the one the banner opens")
        #expect(FeedExtras.banner(for: [], on: now, calendar: calendar) == nil)
    }

    /// "Turning N years old today!": this year less the birth year, both
    /// read on the viewer's local clock, whatever that gives — as the web's
    /// `getFullYear()` subtraction does.
    @Test func theAgeLineIsTheLocalYearsBetween() throws {
        let (now, calendar) = try Self.clock()
        let three = PetFixture.pet(
            birthday: try Self.localMidnight(2023, 9, 23, in: calendar), birthdayMonth: 9, birthdayDay: 23
        )
        #expect(FeedExtras.ageLine(for: three, on: now, calendar: calendar) == "Turning 3 years old today!")

        let one = PetFixture.pet(birthday: try Self.localMidnight(2025, 9, 23, in: calendar))
        #expect(FeedExtras.ageLine(for: one, on: now, calendar: calendar) == "Turning 1 year old today!")

        let noYear = PetFixture.pet(birthdayMonth: 9, birthdayDay: 23)
        #expect(FeedExtras.ageLine(for: noYear, on: now, calendar: calendar) == nil,
                "a month and a day say nothing about an age")

        let newborn = PetFixture.pet(birthday: try Self.localMidnight(2026, 9, 23, in: calendar))
        #expect(FeedExtras.ageLine(for: newborn, on: now, calendar: calendar) == "Turning 0 years old today!",
                "the web says it, so this does")

        // Born on New Year's Day in Tokyo and stored as both clients store it,
        // at local midnight — which in UTC is still 31 December of the year
        // before. Read in UTC, the pet would come out a year older than it is.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let newYear = try #require(tokyo.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12)))
        let born = try Self.localMidnight(2024, 1, 1, in: tokyo)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(utc.component(.year, from: born) == 2023, "the control: in UTC this birthday is in 2023")
        let janFirst = PetFixture.pet(birthday: born, birthdayMonth: 1, birthdayDay: 1)
        #expect(FeedExtras.ageLine(for: janFirst, on: newYear, calendar: tokyo) == "Turning 3 years old today!")
    }

    /// Gregorian years whatever calendar the viewer has chosen, as the web's
    /// `getFullYear()` always is. With Settings › Calendar set to Japanese,
    /// the calendar's `.year` is the year of the era, and subtracting those
    /// said "Turning -19 years old today!" for a pet born in 2015.
    @Test func theAgeLineCountsGregorianYearsInAJapaneseCalendar() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = zone
        // The dates are made in the Gregorian calendar: the Japanese one would
        // read "2015" as a year of the current era.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = zone

        let now = try #require(tokyo.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12)))
        let born = try Self.localMidnight(2015, 9, 23, in: tokyo)
        #expect(japanese.component(.year, from: now) - japanese.component(.year, from: born) == -19,
                "the control: in the Japanese calendar this is Reiwa 8 less Heisei 27")
        let eleven = PetFixture.pet(birthday: born, birthdayMonth: 9, birthdayDay: 23)
        #expect(eleven.isBirthday(on: now, calendar: japanese),
                "the control: the Japanese calendar's months and days are the Gregorian ones, so the banner is up")
        #expect(FeedExtras.ageLine(for: eleven, on: now, calendar: japanese) == "Turning 11 years old today!")
        #expect(FeedExtras.banner(for: [eleven], on: now, calendar: japanese)?.ageLine == "Turning 11 years old today!")

        // Still on the viewer's clock: the Gregorian years are read in the
        // viewer calendar's time zone, not in the Gregorian calendar's
        // default one. Late on New Year's Day in Tokyo it is 1 January in UTC
        // too, but a birthday stored at Tokyo midnight is 31 December 2023
        // there — so read anywhere west of Tokyo, this pet would be four.
        let newYear = try #require(tokyo.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 23)))
        let janFirst = PetFixture.pet(
            birthday: try Self.localMidnight(2024, 1, 1, in: tokyo), birthdayMonth: 1, birthdayDay: 1
        )
        #expect(FeedExtras.ageLine(for: janFirst, on: newYear, calendar: japanese) == "Turning 3 years old today!")
    }

    /// Closed for the session: not back on a refresh or a pet edit, back for
    /// another account and for the next launch.
    @Test func dismissingTheBannerLastsForThisSessionOnly() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pets = FakeOwnedPets()
        pets.byOwner["me"] = [PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 9, birthdayDay: 23)]
        pets.byOwner["you"] = [PetFixture.pet(id: "bean", name: "Bean", birthdayMonth: 9, birthdayDay: 23)]
        let store = UserDefaultsSpotlightSeenStore(defaults: defaults)
        let model = makeModel(pets: pets, seen: store, now: now, calendar: calendar)

        await model.loadIfNeeded()
        #expect(model.visibleBanner?.petID == "mochi")

        model.dismissBanner()
        #expect(model.visibleBanner == nil)
        await model.reload()
        #expect(model.visibleBanner == nil, "a refresh brought it back")
        await model.petsChanged()
        #expect(model.visibleBanner == nil, "a pet edit brought it back")

        model.prepare(for: "you")
        #expect(model.visibleBanner == nil, "the previous account's banner was still up")
        await model.loadIfNeeded()
        #expect(model.visibleBanner?.petID == "bean", "another account is another session")

        let nextLaunch = makeModel(pets: pets, seen: store, now: now, calendar: calendar)
        await nextLaunch.loadIfNeeded()
        #expect(nextLaunch.visibleBanner?.petID == "mochi", "a dismissal outlived the session")
    }

    /// Decorative, as the web says: a failed read shows nothing, and does not
    /// hold up the spotlight.
    @Test func petsThatCannotBeReadShowNoBanner() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pets = FakeOwnedPets()
        pets.error = SocialFixture.readFailure
        let model = makeModel(
            pets: pets, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        await model.loadIfNeeded()

        #expect(model.visibleBanner == nil)
        #expect(model.spotlight == .empty, "the banner's failure stopped the spotlight answering")
        #expect(model.bannerReadsSettled == 1, "a read that failed is still a read that came back")
    }

    /// A pet added with today's birthday shows up without a pull.
    @Test func aPetChangeReadsTheBirthdaysAgain() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pets = FakeOwnedPets()
        let model = makeModel(
            pets: pets, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )
        await model.petsChanged()
        #expect(pets.reads.isEmpty, "read before the feed had asked for anything")

        await model.loadIfNeeded()
        #expect(model.visibleBanner == nil)
        pets.byOwner["me"] = [PetFixture.pet(id: "new", name: "Newcomer", birthdayMonth: 9, birthdayDay: 23)]
        await model.petsChanged()
        #expect(model.visibleBanner?.petID == "new")
    }

    // MARK: - Birthday marks on cards

    /// `batchCheckPetBirthdays`, at thirty to a read: each pet once, however
    /// many of its posts are on screen.
    @Test func birthdayMarksAreReadThirtyPetsAtATime() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let birthdays = FakeBirthdayPets()
        let petIDs = (0..<65).map { "pet-\($0)" }
        for id in petIDs {
            birthdays.byID[id] = PetFixture.pet(id: id, birthdayMonth: 9, birthdayDay: id == "pet-7" ? 23 : 1)
        }
        let posts = petIDs.flatMap { [Self.post("\($0)-a", petID: $0), Self.post("\($0)-b", petID: $0)] }
            + [Self.post("no-pet", petID: nil)]
        let model = makeModel(
            birthdays: birthdays, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        await model.checkBirthdays(for: posts)

        let requests = birthdays.requests
        #expect(requests.map(\.count) == [30, 30, 5])
        #expect(requests.flatMap { $0 } == petIDs, "a pet was asked about twice, or not at all")
        #expect(model.hasBirthday(petID: "pet-7"))
        #expect(!model.hasBirthday(petID: "pet-8"))
        #expect(!model.hasBirthday(petID: nil))
    }

    /// The cache: a pet already asked about is not asked about again.
    @Test func petsAlreadyAskedAboutAreNotAskedAgain() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let birthdays = FakeBirthdayPets()
        let model = makeModel(
            birthdays: birthdays, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )
        let page = (1...5).map { Self.post("post-\($0)", petID: "pet-\($0)") }

        await model.checkBirthdays(for: Array(page.prefix(3)))
        await model.checkBirthdays(for: page)
        await model.checkBirthdays(for: [page[4], page[0]])

        #expect(birthdays.requests == [["pet-1", "pet-2", "pet-3"], ["pet-4", "pet-5"]])
    }

    /// Two checks at once — a page arriving while the last one's read is
    /// still out — ask about each pet once between them.
    @Test func twoChecksAtOnceAskAboutEachPetOnce() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let birthdays = FakeBirthdayPets()
        let model = makeModel(
            birthdays: birthdays, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )
        let page = (1...4).map { Self.post("post-\($0)", petID: "pet-\($0)") }

        async let first: Void = model.checkBirthdays(for: page)
        async let second: Void = model.checkBirthdays(for: page)
        _ = await (first, second)

        #expect(birthdays.requests.flatMap { $0 }.sorted() == ["pet-1", "pet-2", "pet-3", "pet-4"])
    }

    /// A chunk that fails is not recorded as asked, so the next check tries
    /// it again.
    @Test func aChunkThatFailsIsAskedAgainNextTime() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let birthdays = FakeBirthdayPets()
        birthdays.byID["pet-1"] = PetFixture.pet(id: "pet-1", birthdayMonth: 9, birthdayDay: 23)
        birthdays.failing = ["pet-1"]
        let model = makeModel(
            birthdays: birthdays, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )
        let card = Self.post("post-1", petID: "pet-1")

        await model.checkBirthdays(for: [card])
        #expect(!model.hasBirthday(petID: "pet-1"))

        birthdays.failing = []
        await model.checkBirthdays(for: [card])
        #expect(birthdays.requests == [["pet-1"], ["pet-1"]])
        #expect(model.hasBirthday(petID: "pet-1"))
    }

    /// A session that runs past midnight asks again rather than keeping
    /// yesterday's cake on the card.
    @Test func theMarksAreWorkedOutAgainTheNextDay() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock(now)
        let birthdays = FakeBirthdayPets()
        birthdays.byID["pet-1"] = PetFixture.pet(id: "pet-1", birthdayMonth: 9, birthdayDay: 23)
        let model = FeedExtrasModel(
            accountID: "me", pets: FakeOwnedPets(), popular: FakePopularPosts(), birthdays: birthdays,
            blocked: BlockFilteringFeed(base: FeedViewModelTests.FakeFeed(), social: FakeSocialRepository(), viewerID: "me"),
            seenStore: UserDefaultsSpotlightSeenStore(defaults: defaults),
            now: { clock.now }, calendar: calendar
        )
        let card = Self.post("post-1", petID: "pet-1")

        await model.checkBirthdays(for: [card])
        #expect(model.hasBirthday(petID: "pet-1"))

        clock.advance(by: 24 * 3600)
        await model.checkBirthdays(for: [card])
        #expect(birthdays.requests.count == 2, "the next day did not ask again")
        #expect(!model.hasBirthday(petID: "pet-1"), "yesterday's birthday is still marked")
    }

    /// Another account on the same shell starts with no marks and asks again.
    @Test func anAccountSwitchForgetsTheMarks() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let birthdays = FakeBirthdayPets()
        birthdays.byID["pet-1"] = PetFixture.pet(id: "pet-1", birthdayMonth: 9, birthdayDay: 23)
        let model = makeModel(
            birthdays: birthdays, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )
        let card = Self.post("post-1", petID: "pet-1")

        await model.checkBirthdays(for: [card])
        #expect(model.hasBirthday(petID: "pet-1"))

        model.prepare(for: "someone-else")
        #expect(!model.hasBirthday(petID: "pet-1"))
        await model.checkBirthdays(for: [card])
        #expect(birthdays.requests.count == 2)
        #expect(model.hasBirthday(petID: "pet-1"))
    }

    // MARK: - Birthday marks: the day, and this person's own pets

    /// A refresh that brings back the same posts changes no ids, so the view
    /// does not ask about their pets again; the refresh itself does, and on a
    /// new day that is what takes yesterday's pills off and puts today's on.
    @Test func aRefreshThatBringsBackTheSamePostsAsksAgainTheNextDay() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock(now)
        let birthdays = FakeBirthdayPets()
        birthdays.byID["pet-1"] = PetFixture.pet(id: "pet-1", birthdayMonth: 9, birthdayDay: 23)
        birthdays.byID["pet-2"] = PetFixture.pet(id: "pet-2", birthdayMonth: 9, birthdayDay: 24)
        let model = FeedExtrasModel(
            accountID: "me", pets: FakeOwnedPets(), popular: FakePopularPosts(), birthdays: birthdays,
            blocked: BlockFilteringFeed(base: FeedViewModelTests.FakeFeed(), social: FakeSocialRepository(), viewerID: "me"),
            seenStore: UserDefaultsSpotlightSeenStore(defaults: defaults),
            now: { clock.now }, calendar: calendar
        )
        let cards = [Self.post("post-1", petID: "pet-1"), Self.post("post-2", petID: "pet-2")]
        await model.loadIfNeeded()
        await model.checkBirthdays(for: cards)
        #expect(model.hasBirthday(petID: "pet-1"))
        #expect(!model.hasBirthday(petID: "pet-2"))

        clock.advance(by: 24 * 3600)
        // The pull, and nothing else: the posts that come back are the same.
        await model.reload()

        #expect(birthdays.requests.count == 2, "a refresh on the next day did not ask about the same cards again")
        #expect(!model.hasBirthday(petID: "pet-1"), "yesterday's pill survived the refresh")
        #expect(model.hasBirthday(petID: "pet-2"), "today's birthday did not get its pill")
    }

    /// Past midnight, yesterday's pill is not shown even before anything has
    /// asked again — the next page or pull may be a while.
    @Test func yesterdaysPillIsNotShownPastMidnight() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock(now)
        let birthdays = FakeBirthdayPets()
        birthdays.byID["pet-1"] = PetFixture.pet(id: "pet-1", birthdayMonth: 9, birthdayDay: 23)
        let model = FeedExtrasModel(
            accountID: "me", pets: FakeOwnedPets(), popular: FakePopularPosts(), birthdays: birthdays,
            blocked: BlockFilteringFeed(base: FeedViewModelTests.FakeFeed(), social: FakeSocialRepository(), viewerID: "me"),
            seenStore: UserDefaultsSpotlightSeenStore(defaults: defaults),
            now: { clock.now }, calendar: calendar
        )
        await model.checkBirthdays(for: [Self.post("post-1", petID: "pet-1")])
        #expect(model.hasBirthday(petID: "pet-1"))

        clock.advance(by: 12 * 3600 + 60)

        #expect(birthdays.requests.count == 1, "the control: nothing has asked again")
        #expect(!model.hasBirthday(petID: "pet-1"), "yesterday's pill is still shown after midnight")
    }

    /// A pet edited to or away from today's birthday moves the pill on its
    /// own cards — through the banner's read of this person's pets, with no
    /// read of its own. Before, the pet stayed "already asked about" for the
    /// rest of the session and its cards never changed.
    @Test func aPetEditMovesThePillOnItsCards() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pets = FakeOwnedPets()
        pets.byOwner["me"] = [PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 3, birthdayDay: 1)]
        let birthdays = FakeBirthdayPets()
        birthdays.byID["mochi"] = PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 3, birthdayDay: 1)
        let model = makeModel(
            pets: pets, birthdays: birthdays, seen: UserDefaultsSpotlightSeenStore(defaults: defaults),
            now: now, calendar: calendar
        )
        await model.loadIfNeeded()
        await model.checkBirthdays(for: [Self.post("mochis-post", petID: "mochi")])
        #expect(!model.hasBirthday(petID: "mochi"))

        pets.byOwner["me"] = [PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 9, birthdayDay: 23)]
        await model.petsChanged()
        #expect(model.hasBirthday(petID: "mochi"), "a pet edited to today's birthday did not reach its cards")
        #expect(model.visibleBanner?.petID == "mochi", "the control: the banner read saw the edit")

        pets.byOwner["me"] = [PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 3, birthdayDay: 1)]
        await model.petsChanged()
        #expect(!model.hasBirthday(petID: "mochi"), "a birthday edited away from today kept its pill")
        #expect(birthdays.requests.isEmpty, "this person's own pet cost a read of its own")
    }

    // MARK: - Reads that overlap

    /// A newer spotlight read that fails decides nothing: an older one still
    /// out that then answers is what is shown. Before, the failure — the
    /// newest request — was allowed to stand and the answer was thrown away.
    @Test func aNewerSpotlightReadThatFailsDoesNotBeatAnOlderOneThatAnswered() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let popular = FakePopularPosts()
        popular.stored = (1...10).map { Self.post("p\($0)", likes: $0, hoursAgo: 1, from: now) }
        let older = SocialGate()
        popular.script = [Step(gate: older), Step(error: SocialFixture.readFailure)]
        let model = makeModel(
            popular: popular, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        let first = Task { await model.reload() }
        let firstIsOut = await eventuallyTrueAnywhere { popular.recordedCutoffs.count == 1 }
        await model.reload()
        let afterTheFailure = model.spotlight
        older.open()
        await first.value

        #expect(firstIsOut, "the first read never went out")
        #expect(afterTheFailure == .empty, "the control: with nothing arrived yet, the failure shows the empty line")
        #expect(Self.ids(model.spotlight).count == 10, "a newer read's failure threw away tiles that did arrive")
    }

    /// And the other way round: an older answer that lands after a newer one
    /// does not replace it.
    @Test func anOlderSpotlightAnswerLandingLateDoesNotReplaceANewerOne() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let popular = FakePopularPosts()
        popular.stored = (1...10).map { Self.post("old-\($0)", likes: $0, hoursAgo: 1, from: now) }
        let older = SocialGate()
        popular.script = [Step(gate: older)]
        let model = makeModel(
            popular: popular, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        let first = Task { await model.reload() }
        let firstIsOut = await eventuallyTrueAnywhere { popular.recordedCutoffs.count == 1 }
        popular.stored = (1...10).map { Self.post("new-\($0)", likes: $0, hoursAgo: 1, from: now) }
        await model.reload()
        older.open()
        await first.value

        #expect(firstIsOut)
        #expect(Self.ids(model.spotlight).allSatisfy { $0.hasPrefix("new-") },
                "an older answer landed over a newer one: \(Self.ids(model.spotlight))")
    }

    /// The banner keeps the same rule: a newer read that fails does not hide
    /// the answer an older read brings.
    @Test func aNewerBannerReadThatFailsDoesNotHideAnOlderAnswer() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pets = FakeOwnedPets()
        pets.byOwner["me"] = [PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 9, birthdayDay: 23)]
        let older = SocialGate()
        pets.script = [Step(gate: older), Step(error: SocialFixture.readFailure)]
        let model = makeModel(
            pets: pets, seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        let first = Task { await model.loadIfNeeded() }
        let firstIsOut = await eventuallyTrueAnywhere { pets.reads.count == 1 }
        await model.petsChanged()
        let afterTheFailure = model.visibleBanner
        older.open()
        await first.value

        #expect(firstIsOut)
        #expect(afterTheFailure == nil, "the control: nothing had arrived when the newer read failed")
        #expect(model.visibleBanner?.petID == "mochi", "a newer read's failure hid the banner an older read brought")
        #expect(model.bannerReadsSettled == 2)
    }

    /// All three reads out for one account, then a switch to another, then
    /// the answers: none of them lands on the account that is signed in now.
    @Test func readsStillOutWhenTheAccountChangesLandNowhere() async throws {
        let (now, calendar) = try Self.clock()
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = SocialGate()
        let pets = FakeOwnedPets()
        pets.byOwner["alice-uid"] = [PetFixture.pet(id: "mochi", name: "Mochi", birthdayMonth: 9, birthdayDay: 23)]
        pets.script = [Step(gate: gate)]
        let popular = FakePopularPosts()
        popular.stored = [Self.post("alices-pick", likes: 5, hoursAgo: 1, from: now)]
        popular.script = [Step(gate: gate)]
        let birthdays = FakeBirthdayPets()
        birthdays.byID["mochi"] = PetFixture.pet(id: "mochi", birthdayMonth: 9, birthdayDay: 23)
        birthdays.gate = gate
        let model = makeModel(
            uid: "alice-uid", pets: pets, popular: popular, birthdays: birthdays,
            seen: UserDefaultsSpotlightSeenStore(defaults: defaults), now: now, calendar: calendar
        )

        let load = Task { await model.loadIfNeeded() }
        let marks = Task { await model.checkBirthdays(for: [Self.post("mochis-post", petID: "mochi")]) }
        let allOut = await eventuallyTrueAnywhere {
            pets.reads.count == 1 && popular.recordedCutoffs.count == 1 && birthdays.requests.count == 1
        }
        model.prepare(for: "bob-uid")
        gate.open()
        await load.value
        await marks.value

        #expect(allOut, "not every read went out before the switch")
        #expect(model.visibleBanner == nil, "alice's birthday banner landed on bob")
        #expect(model.spotlight == .loading, "alice's spotlight landed on bob")
        #expect(!model.hasBirthday(petID: "mochi"), "alice's marks landed on bob")
        #expect(model.bannerReadsSettled == 0, "alice's read was counted as bob's")
    }

    // MARK: - The spotlight's pictures

    /// The picture a tile asks for is the web tile's — the stored `thumbUrl`
    /// before anything derived — so the two clients share one CDN rendition.
    @Test func aVideoTileAsksForTheStoredThumbnailAsTheWebDoes() throws {
        let clip = try #require(URL(string: "https://res.cloudinary.com/demo/video/upload/v1/clip.mp4"))
        let stored = try #require(URL(string: "https://res.cloudinary.com/demo/video/upload/so_0,w_400,h_400,c_fill/v1/clip.jpg"))
        let video = MediaItem(url: clip, kind: .video, thumbnailURL: stored)
        let chosen = try #require(FeedExtras.spotlightPictureURL(for: video))
        #expect(chosen == stored, "the tile derived its own poster instead of using the stored thumbUrl")
        #expect(CloudinaryURL.optimized(chosen, size: .spotlight) == stored,
                "the size step changed a /video/upload/ address, which the web's leaves alone")

        let photoURL = try #require(URL(string: "https://res.cloudinary.com/demo/image/upload/v1/cat.jpg"))
        let photo = try #require(FeedExtras.spotlightPictureURL(for: MediaItem(url: photoURL, kind: .image, thumbnailURL: nil)))
        #expect(CloudinaryURL.optimized(photo, size: .spotlight).absoluteString
                == "https://res.cloudinary.com/demo/image/upload/w_200,h_200,c_fill,q_auto,f_auto/v1/cat.jpg")

        // No stored thumbnail: the web hands the video file to an <img> and
        // draws nothing; this derives the frame-0 poster at the tile's size.
        let bare = MediaItem(url: clip, kind: .video, thumbnailURL: nil)
        #expect(FeedExtras.spotlightPictureURL(for: bare)?.absoluteString
                == "https://res.cloudinary.com/demo/video/upload/so_0,w_200,h_200,c_fill,q_auto,f_auto/v1/clip.jpg")
        #expect(FeedExtras.spotlightPictureURL(for: nil) == nil)
    }

    // MARK: - Share a birthday post

    /// The banner's "Share a birthday post" opens the composer for its pet —
    /// the web's `/create?petId=` — and only a pet that is theirs is chosen.
    @Test func theComposerOpenedForAPetStartsOnIt() async {
        let owned = [PetFixture.pet(id: "bean", name: "Bean"), PetFixture.pet(id: "mochi", name: "Mochi")]
        func composer(for petID: String?) -> ComposeViewModel {
            ComposeViewModel(
                uid: "me", isEmailVerified: true, uploader: FakeUploader(), writes: FakePostWrites(),
                pets: FixedPets(pets: owned), preferredPetID: petID, drafts: InMemoryDraftStore()
            )
        }

        let plain = composer(for: nil)
        await plain.start()
        #expect(plain.selectedPetID == nil, "the control: with two pets, nothing is chosen for them")

        let forMochi = composer(for: "mochi")
        await forMochi.start()
        #expect(forMochi.selectedPetID == "mochi", "the composer did not start on the birthday pet")

        let forSomeoneElse = composer(for: "not-theirs")
        await forSomeoneElse.start()
        #expect(forSomeoneElse.selectedPetID == nil, "a pet that is not theirs was chosen")
    }
}
