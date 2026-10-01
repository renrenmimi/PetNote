import Foundation
import Testing
@testable import PetNote

/// A place from Apple Maps stores its identifier only, and a screen looks the
/// rest up each time it shows it. These pin what a screen shows for each
/// answer, and that a place from the web is shown as it stores itself without
/// asking anyone.
@MainActor
@Suite struct PlaceLookupsTests {
    private static let dogRun = PlaceDetails(
        name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095
    )
    private static let petShop = PlaceDetails(
        name: "Corner Pet Shop", address: "20 Elm St, Somerville, MA", latitude: 42.3967, longitude: -71.122
    )

    /// Apple Maps as a table, counting what it is asked, under a lock: the
    /// lookups ask from their own tasks.
    private final class Directory: PlaceDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        private let table: [String: PlaceDetails]
        private var failing: Set<String>
        private let hits: [PlaceSearchHit]
        private let searchFails: Bool

        init(
            _ table: [String: PlaceDetails] = [:], failing: Set<String> = [],
            hits: [PlaceSearchHit] = [], searchFails: Bool = false
        ) {
            self.table = table
            self.failing = failing
            self.hits = hits
            self.searchFails = searchFails
        }

        var questions: [String] { lock.withLock { asked } }
        func stopFailing() { lock.withLock { failing = [] } }

        func details(forApplePlaceID id: String) async throws -> PlaceDetails? {
            let fails = lock.withLock { () -> Bool in
                asked.append(id)
                return failing.contains(id)
            }
            if fails { throw URLError(.notConnectedToInternet) }
            return table[id]
        }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] {
            if searchFails { throw URLError(.notConnectedToInternet) }
            return hits
        }
        func forget() async {}
    }

    /// Apple Maps taking its time: every question waits until `answer()`.
    final class SlowDirectory: PlaceDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var answered = false
        private let table: [String: PlaceDetails]

        init(_ table: [String: PlaceDetails]) { self.table = table }

        var isAsked: Bool { lock.withLock { !waiting.isEmpty } }

        func details(forApplePlaceID id: String) async throws -> PlaceDetails? {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if answered { return true }
                    waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
            return table[id]
        }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] { [] }
        func forget() async {}

        func answer() {
            let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                answered = true
                defer { waiting = [] }
                return waiting
            }
            held.forEach { $0.resume() }
        }
    }

    private func place(_ id: String, apple: String? = nil, name: String = "") -> Place {
        Place(
            id: id, name: name, address: apple == nil ? "2 Harbor Way" : "", city: "", state: "",
            latitude: apple == nil ? 42.35 : 0, longitude: apple == nil ? -71.05 : 0,
            category: .dogPark, description: "", features: [], photos: [],
            averageRating: 0, totalRatings: 0, totalCheckins: 0, verifiedByCheckins: false,
            applePlaceID: apple
        )
    }

    @Test func aPlaceFromTheWebIsShownAsItStoresItselfAndNobodyIsAsked() async {
        let directory = Directory()
        let lookups = PlaceLookups(directory: directory)
        let cafe = place("web-cafe", name: "Harbor Cafe")

        await lookups.lookUp([cafe])

        #expect(lookups.name(of: cafe) == "Harbor Cafe")
        #expect(lookups.shown(cafe) == .found(cafe.storedDetails))
        #expect(directory.questions.isEmpty)
    }

    @Test func aPlaceFromAppleMapsIsLoadingUntilAppleAnswers() async {
        let lookups = PlaceLookups(directory: Directory(["I1": Self.dogRun]))
        let run = place("apple_I1", apple: "I1")

        #expect(lookups.shown(run) == .looking)
        #expect(lookups.name(of: run) == String(localized: "Loading…"))
        await lookups.lookUp([run])

        #expect(lookups.shown(run) == .found(Self.dogRun))
        #expect(lookups.name(of: run) == "Fenway Dog Run")
    }

    @Test func aPlaceAppleNoLongerKnowsSaysSo() async {
        let lookups = PlaceLookups(directory: Directory())
        let gone = place("apple_I9", apple: "I9")

        await lookups.lookUp([gone])

        #expect(lookups.shown(gone) == .gone)
        #expect(lookups.name(of: gone) == String(localized: "No longer on Apple Maps"))
    }

    @Test func aFailedLookupSaysSoAndIsAskedAgainNextTime() async {
        let directory = Directory(["I1": Self.dogRun], failing: ["I1"])
        let lookups = PlaceLookups(directory: directory)
        let run = place("apple_I1", apple: "I1")

        await lookups.lookUp([run])
        #expect(lookups.shown(run) == .failed)
        #expect(lookups.name(of: run) == String(localized: "Couldn't load this place"))

        directory.stopFailing()
        await lookups.lookUp([run])
        #expect(lookups.shown(run) == .found(Self.dogRun))
        #expect(directory.questions == ["I1", "I1"])
    }

    @Test func aListAsksForEachPlaceFromAppleMapsOnceAndNotAgain() async {
        let directory = Directory(["I1": Self.dogRun, "I2": Self.dogRun])
        let lookups = PlaceLookups(directory: directory)
        let list = [
            place("apple_I1", apple: "I1"), place("apple_I2", apple: "I2"),
            place("web-cafe", name: "Harbor Cafe"), place("apple_I1-again", apple: "I1"),
        ]

        await lookups.lookUp(list)
        await lookups.lookUp(list)

        #expect(directory.questions.sorted() == ["I1", "I2"])
    }

    @Test func aStoredPlaceWithAnAppleIdentifierIsReadAsOne() {
        let apple = Place.decode(id: "apple_I1", [
            "applePlaceId": "I1", "category": "dog_park", "totalRatings": 2,
        ])
        let web = Place.decode(id: "web", ["name": "Harbor Cafe", "lat": 42.35, "lng": -71.05])

        #expect(apple.applePlaceID == "I1")
        #expect(apple.name.isEmpty && apple.address.isEmpty)
        #expect(apple.directionsURL == nil, "a place from Apple Maps has no stored position to link")
        #expect(web.applePlaceID == nil)
        #expect(web.directionsURL != nil)
    }

    @Test func thePlacesListAsksForTheNamesOfItsPlacesFromAppleMaps() async {
        let directory = Directory(["I1": Self.dogRun])
        let model = PlacesModel(source: Places(places: [place("apple_I1", apple: "I1")]), lookups: PlaceLookups(directory: directory))

        await model.load()

        #expect(model.items.map(\.id) == ["apple_I1"])
        #expect(model.lookups.name(of: model.items[0]) == "Fenway Dog Run")
    }

    /// While Apple is being asked about a place, the rest of its page comes
    /// in: Apple's answer is for the name, address and map only.
    @Test func aSlowAppleHoldsUpOnlyWhatAppleIsAskedFor() async {
        let directory = SlowDirectory(["I1": Self.dogRun, "I2": Self.petShop])
        let run = place("apple_I1", apple: "I1")
        let review = PlaceReview.decode(id: "r1", ["userId": "u1", "rating": 4, "comment": "Shady"])
        let meetups = PlacesMeetupsTests.FakeMeetups()
        meetups.atPlaceList = [Meetup.decode(id: "m1", [
            "title": "Morning walk", "organizerId": "o1", "status": "upcoming",
            "location": ["applePlaceId": "I2"], "locationVisibility": "everyone", "locationId": run.id,
        ])]
        let model = PlaceDetailModel(
            placeID: run.id, viewerID: "me", places: Places(places: [run], reviews: [review]),
            reviewer: PlacesMeetupsTests.FakeReviews(), checker: FakeCheckins(), meetups: meetups,
            lookups: PlaceLookups(directory: directory)
        )

        let loading = Task { await model.load() }
        #expect(await eventuallyTrue { directory.isAsked })
        #expect(await eventuallyTrue { model.reviews.map(\.id) == ["r1"] && model.hasReviewed == false },
                "the reviews, or the review button, waited for Apple")
        #expect(model.meetups.map(\.id) == ["m1"])
        #expect(model.lookups.shown(run) == .looking)

        directory.answer()
        await loading.value
        #expect(model.lookups.name(of: run) == "Fenway Dog Run")
        #expect(model.meetups.first.map { model.lookups.name(of: $0.place) } == "Corner Pet Shop")
    }

    @Test func theNextPageNeedNotWaitForAppleToNameThisOne() async {
        let directory = SlowDirectory(["I1": Self.dogRun])
        let source = PlacesMeetupsTests.FakePlaces()
        source.pages = [
            (0..<PlacesModel.pageSize).map { place("web-\($0)", name: "Cafe \($0)") },
            [place("apple_I1", apple: "I1")],
        ]
        let model = PlacesModel(source: source, lookups: PlaceLookups(directory: directory))
        await model.load()

        let loading = Task { await model.loadMore() }
        #expect(await eventuallyTrue { directory.isAsked })
        #expect(model.items.count == PlacesModel.pageSize + 1)
        #expect(!model.isLoadingMore, "the list still said it was loading while Apple was asked")

        directory.answer()
        await loading.value
        #expect(model.items.last.map { model.lookups.name(of: $0) } == "Fenway Dog Run")
    }

    /// A name search shows the places Apple finds that are ours, in Apple's
    /// order, then the web's places whose names start with the text, each
    /// once. A place Apple finds that nobody has added is not shown, and what
    /// Apple said about each place names its row without asking again.
    @Test func aSearchListsOurPlacesFromAppleMapsInApplesOrderThenTheWebs() async {
        let directory = Directory(hits: [
            PlaceSearchHit(applePlaceID: "I2", details: Self.petShop),
            PlaceSearchHit(applePlaceID: "I9", details: Self.dogRun),
            PlaceSearchHit(applePlaceID: "I1", details: Self.dogRun),
        ])
        let cafe = place("web-cafe", name: "Harbor Cafe")
        let run = place("apple_I1", apple: "I1", name: "Harbor Dog Run")
        // The run has a name of its own as well, so the web's search finds it
        // too.
        let source = Places(places: [run, place("apple_I2", apple: "I2"), cafe], named: [cafe, run])
        let model = PlacesModel(source: source, lookups: PlaceLookups(directory: directory))

        model.search("Harbor")

        #expect(await eventuallyTrue { model.items.count == 3 })
        #expect(model.items.map(\.id) == ["apple_I2", "apple_I1", "web-cafe"])
        #expect(model.items.map { model.lookups.name(of: $0) } == ["Corner Pet Shop", "Fenway Dog Run", "Harbor Cafe"])
        #expect(directory.questions.isEmpty, "a place the search named was asked about again")
    }

    @Test func aSearchAppleCannotAnswerStillListsTheWebsMatches() async {
        let cafe = place("web-cafe", name: "Harbor Cafe")
        let model = PlacesModel(
            source: Places(places: [cafe], named: [cafe]),
            lookups: PlaceLookups(directory: Directory(searchFails: true))
        )

        model.search("Harbor")

        #expect(await eventuallyTrue { model.items.map(\.id) == ["web-cafe"] })
        #expect(model.state == .loaded)
    }

    /// The list's source, answering with a fixed page.
    private struct Places: PlacesReading {
        let places: [Place]
        var reviews: [PlaceReview] = []
        /// What the web's search finds.
        var named: [Place] = []
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { places }
        func search(prefix: String) async throws -> [Place] { named }
        func places(applePlaceIDs ids: [String]) async throws -> [Place] {
            places.filter { $0.applePlaceID.map(ids.contains) ?? false }
        }
        func place(id: String) async throws -> Place? { places.first { $0.id == id } }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { reviews }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }
}
