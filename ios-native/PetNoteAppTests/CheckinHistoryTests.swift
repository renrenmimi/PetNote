import FirebaseFirestore
import Foundation
import Testing

@testable import PetNote

/// The profile's check-ins, by the web client's `getUserCheckins` and
/// `batchGetLocations`: newest first, each place looked up once, a place that
/// is gone shown as "Unknown location", and a refused read shown as no
/// check-ins, as `Profile.tsx` does.
@MainActor
struct CheckinHistoryTests {
    // MARK: - Fakes

    /// Holds a fake read until the test lets it go, so "a second load while
    /// the first is reading" is arranged rather than hoped for.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let resumed = waiting
            waiting = []
            lock.unlock()
            resumed.forEach { $0.resume() }
        }
    }

    /// Every answer and every record is taken under the lock: a second load
    /// can start while the first is still reading, so two calls overlap.
    final class FakeHistory: CheckinHistoryReading, @unchecked Sendable {
        private struct CheckinAnswer {
            let result: Result<[CheckinHistoryEntry], Error>
            let gate: Gate?
        }

        private let lock = NSLock()
        private var checkinAnswers: [CheckinAnswer] = []
        private var placeAnswers: [Result<[String: Place], Error>] = []
        private var _checkinCalls: [(uid: String, limit: Int)] = []
        private var _placeCalls: [[String]] = []

        var checkinCalls: [(uid: String, limit: Int)] { lock.withLock { _checkinCalls } }
        var placeCalls: [[String]] { lock.withLock { _placeCalls } }

        /// Answers the next `checkins` call; held until `gate` opens, if given.
        func answerCheckins(_ result: Result<[CheckinHistoryEntry], Error>, heldBy gate: Gate? = nil) {
            lock.withLock { checkinAnswers.append(CheckinAnswer(result: result, gate: gate)) }
        }

        func answerPlaces(_ result: Result<[String: Place], Error>) {
            lock.withLock { placeAnswers.append(result) }
        }

        func checkins(uid: String, limit: Int) async throws -> [CheckinHistoryEntry] {
            let answer = lock.withLock { () -> CheckinAnswer? in
                _checkinCalls.append((uid, limit))
                return checkinAnswers.isEmpty ? nil : checkinAnswers.removeFirst()
            }
            guard let answer else { return [] }
            if let gate = answer.gate { await gate.wait() }
            return try answer.result.get()
        }

        func places(ids: [String]) async throws -> [String: Place] {
            let answer = lock.withLock { () -> Result<[String: Place], Error>? in
                _placeCalls.append(ids)
                return placeAnswers.isEmpty ? nil : placeAnswers.removeFirst()
            }
            return try (answer ?? .success([:])).get()
        }
    }

    // MARK: - Sample data

    private static func entry(_ id: String, at placeID: String, caption: String = "", pet: String? = nil) -> CheckinHistoryEntry {
        var data: [String: Any] = ["userId": "me", "caption": "TEST CONTENT \(caption)"]
        if let pet { data["petName"] = pet }
        return CheckinHistoryEntry.decode(id: id, pathPlaceID: placeID, data)
    }

    private static func place(_ id: String, name: String, photo: String? = nil) -> Place {
        var data: [String: Any] = ["name": name, "category": "dog_park"]
        if let photo { data["photos"] = [photo] }
        return Place.decode(id: id, data)
    }

    private static var offline: NSError { NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet) }

    // MARK: - What a stored check-in becomes

    /// The web spreads the stored fields over the parent's id, so a stored
    /// `locationId` wins; without one the parent is the place.
    @Test func thePlaceIsTheStoredOneAndOtherwiseTheParent() {
        let stored = CheckinHistoryEntry.decode(id: "me_2026-09-23", pathPlaceID: "from-path", ["locationId": "from-field"])
        #expect(stored.placeID == "from-field")
        let unnamed = CheckinHistoryEntry.decode(id: "me_2026-09-23", pathPlaceID: "from-path", [:])
        #expect(unnamed.placeID == "from-path")
        let nowhere = CheckinHistoryEntry.decode(id: "me_2026-09-23", pathPlaceID: nil, [:])
        #expect(nowhere.placeID == "")
        // An id that cannot name a document never reaches a query.
        let malformed = CheckinHistoryEntry.decode(id: "me_2026-09-23", pathPlaceID: "from-path", ["locationId": "a/b"])
        #expect(malformed.placeID == "")
        #expect(CheckinHistoryModel.placeIDs(in: [malformed]).isEmpty)
    }

    /// `{uid}_{day}` is unique within one place only. Two places on one day
    /// must still be two rows, or the list would draw one of them twice.
    @Test func twoPlacesOnOneDayAreTwoRows() {
        let morning = Self.entry("me_2026-09-23", at: "park")
        let evening = Self.entry("me_2026-09-23", at: "cafe")
        #expect(morning.id != evening.id)
    }

    // MARK: - The lookup

    @Test func placesAreAskedForThirtyAtATime() {
        let ids = (1...65).map { "p\($0)" }
        let batches = FirestoreCheckinHistorySource.batches(of: ids, size: FirestoreCheckinHistorySource.placeBatchSize)
        #expect(batches.map(\.count) == [30, 30, 5])
        #expect(batches.flatMap { $0 } == ids, "an id was lost or repeated between batches")
        #expect(FirestoreCheckinHistorySource.batches(of: [], size: 30).isEmpty, "no places must mean no place query")
    }

    /// The query's order is the list's order. The places come back by id, in
    /// no order at all, and must not reorder anything; each is asked for once.
    @Test func rowsKeepTheQuerysOrderAndEachPlaceIsAskedForOnce() async {
        let source = FakeHistory()
        source.answerCheckins(.success([
            Self.entry("c3", at: "pB"), Self.entry("c2", at: "pA"), Self.entry("c1", at: "pB"),
        ]))
        source.answerPlaces(.success(["pA": Self.place("pA", name: "TEST CONTENT A"), "pB": Self.place("pB", name: "TEST CONTENT B")]))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()

        guard case .loaded(let rows) = model.state else {
            Issue.record("expected a list, got \(model.state)")
            return
        }
        #expect(rows.map(\.entry.checkin.id) == ["c3", "c2", "c1"])
        #expect(rows.map(\.placeName) == ["TEST CONTENT B", "TEST CONTENT A", "TEST CONTENT B"])
        #expect(source.placeCalls == [["pB", "pA"]])
        #expect(source.checkinCalls.map { $0.uid } == ["me"])
        #expect(source.checkinCalls.map { $0.limit } == [100], "the web asks for a hundred")
    }

    /// The row's picture is the place's, as on the web; the check-in's own
    /// photo, caption and pet ride along.
    @Test func aRowCarriesThePlacesPhotoAndTheCheckinsWords() async {
        let source = FakeHistory()
        source.answerCheckins(.success([Self.entry("c1", at: "park", caption: "First visit!", pet: "Mochi")]))
        source.answerPlaces(.success(["park": Self.place("park", name: "TEST CONTENT Park", photo: "https://example.test/park.jpg")]))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()

        guard case .loaded(let rows) = model.state, let row = rows.first else {
            Issue.record("expected a list, got \(model.state)")
            return
        }
        #expect(row.placePhoto == URL(string: "https://example.test/park.jpg"))
        #expect(row.entry.checkin.caption == "TEST CONTENT First visit!")
        #expect(row.entry.checkin.petName == "Mochi")
    }

    // MARK: - A place that is gone

    /// `location?.name || t("profile.unknownLocation")`: the row stays, says
    /// "Unknown location", has no place photo, and still knows which place to
    /// open — the web navigates to it either way.
    @Test func aPlaceThatIsGoneIsAnUnknownLocationThatStillOpens() async {
        let source = FakeHistory()
        source.answerCheckins(.success([Self.entry("c2", at: "gone"), Self.entry("c1", at: "here")]))
        source.answerPlaces(.success(["here": Self.place("here", name: "TEST CONTENT Here")]))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()

        guard case .loaded(let rows) = model.state else {
            Issue.record("expected a list, got \(model.state)")
            return
        }
        #expect(rows.map(\.placeName) == [String(localized: "Unknown location"), "TEST CONTENT Here"])
        #expect(rows[0].placePhoto == nil)
        #expect(rows[0].entry.placeID == "gone")
    }

    @Test func aPlaceWithNoNameIsAnUnknownLocationToo() {
        let row = CheckinHistoryRow(entry: Self.entry("c1", at: "p1"), place: Self.place("p1", name: ""))
        #expect(row.placeName == "Unknown location")
    }

    // MARK: - The screen's states

    @Test func noCheckinsIsTheEmptyStateAndLooksNothingUp() async {
        let source = FakeHistory()
        source.answerCheckins(.success([]))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()

        #expect(model.state == .empty)
        #expect(source.placeCalls.isEmpty, "no check-ins must mean no place query")
    }

    /// `Profile.tsx` catches the read, logs "Permission error while loading
    /// check-ins" and shows the empty state. A refusal is handled the same.
    @Test func aRefusedReadIsTheEmptyStateAsOnTheWeb() async {
        let source = FakeHistory()
        source.answerCheckins(.failure(NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()

        #expect(model.state == .empty)
    }

    /// Anything else is not "no check-ins": it says it could not load, and
    /// Try again loads.
    @Test func aFailedFirstLoadSaysSoAndTryingAgainLoads() async {
        let source = FakeHistory()
        source.answerCheckins(.failure(Self.offline))
        source.answerCheckins(.success([Self.entry("c1", at: "park")]))
        source.answerPlaces(.success(["park": Self.place("park", name: "TEST CONTENT Park")]))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()
        #expect(model.state == .failed(String(localized: "Couldn't load your check-ins.")))

        await model.load()
        guard case .loaded(let rows) = model.state else {
            Issue.record("the retry did not load, got \(model.state)")
            return
        }
        #expect(rows.map(\.placeName) == ["TEST CONTENT Park"])
        #expect(source.checkinCalls.count == 2)
    }

    /// A lookup that failed is not a list of unknown places: every place
    /// would read "Unknown location" when none of them is gone.
    @Test func aFailedPlaceLookupIsAFailureNotAListOfUnknownPlaces() async {
        let source = FakeHistory()
        source.answerCheckins(.success([Self.entry("c1", at: "park")]))
        source.answerPlaces(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()

        #expect(model.state == .failed(String(localized: "Couldn't load your check-ins.")))
    }

    /// Coming back to the list re-reads it. If that read fails, the list that
    /// was on screen stays and the screen says it may be out of date.
    @Test func aReloadThatFailsKeepsTheListAndSaysItMayBeStale() async {
        let source = FakeHistory()
        source.answerCheckins(.success([Self.entry("c1", at: "park")]))
        source.answerPlaces(.success(["park": Self.place("park", name: "TEST CONTENT Park")]))
        source.answerCheckins(.failure(Self.offline))
        let model = CheckinHistoryModel(uid: "me", source: source)

        await model.load()
        let shown = model.state
        await model.load()

        #expect(model.state == shown)
        #expect(model.refreshFailed)
    }

    /// A second load while the first is still reading — the screen appearing
    /// again, a pull to refresh — is the one that shows. The first, answering
    /// late, must not put its older list back, nor look up its places.
    @Test func aLoadStartedWhileAnotherIsReadingIsTheOneThatShows() async {
        let source = FakeHistory()
        let gate = Gate()
        source.answerCheckins(.success([Self.entry("old", at: "p1")]), heldBy: gate)
        source.answerCheckins(.success([Self.entry("new", at: "p2")]))
        source.answerPlaces(.success(["p2": Self.place("p2", name: "TEST CONTENT Two")]))
        let model = CheckinHistoryModel(uid: "me", source: source)

        let first = Task { await model.load() }
        #expect(await eventuallyTrueAnywhere { source.checkinCalls.count == 1 }, "the first load never reached the source")

        await model.load()
        let newer = model.state
        guard case .loaded(let rows) = newer else {
            Issue.record("the second load did not show its list, got \(newer)")
            gate.open()
            await first.value
            return
        }
        #expect(rows.map(\.entry.checkin.id) == ["new"])

        gate.open()
        await first.value

        #expect(model.state == newer, "the older read replaced the newer one")
        #expect(source.placeCalls == [["p2"]], "the superseded read still looked up its places")
    }
}
