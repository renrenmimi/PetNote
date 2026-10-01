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

    /// Apple Maps as a table, counting what it is asked, under a lock: the
    /// lookups ask from their own tasks.
    private final class Directory: PlaceDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        private let table: [String: PlaceDetails]
        private var failing: Set<String>

        init(_ table: [String: PlaceDetails] = [:], failing: Set<String> = []) {
            self.table = table
            self.failing = failing
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
        func forget() async {}
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

    /// The list's source, answering with a fixed page.
    private struct Places: PlacesReading {
        let places: [Place]
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { places }
        func search(prefix: String) async throws -> [Place] { [] }
        func place(id: String) async throws -> Place? { places.first { $0.id == id } }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }
}
