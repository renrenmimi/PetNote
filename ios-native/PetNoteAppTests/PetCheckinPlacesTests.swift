import Foundation
import Testing
@testable import PetNote

/// A pet's check-ins name their places, as the web's pet page does
/// (`PetProfile.tsx`): each place read once, Apple's name for one from Apple
/// Maps, the web's "Unknown location" for one that is gone, and no names at
/// all when the read failed — a name that is not known is not said.
@MainActor
@Suite struct PetCheckinPlacesTests {
    final class FakePlaces: PlacesByID, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [[String]] = []
        var answer: Result<[String: Place], Error> = .success([:])
        var questions: [[String]] { lock.withLock { asked } }

        func places(ids: [String]) async throws -> [String: Place] {
            lock.withLock { asked.append(ids) }
            return try answer.get()
        }
    }

    /// Apple Maps as a table.
    private struct AppleMaps: PlaceDirectory {
        let table: [String: PlaceDetails]
        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { table[id] }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] { [] }
        func forget() async {}
    }

    private func checkin(_ id: String, at place: String) -> PetCheckin {
        PetCheckin(id: id, locationID: place, petID: "pet-1", petName: "Mochi", photoURL: nil, caption: "", createdAt: nil)
    }

    private func model(
        _ checkins: [PetCheckin], places: FakePlaces, apple: [String: PlaceDetails] = [:]
    ) -> PetProfileViewModel {
        let repository = FakePetRepository()
        repository.pet = PetFixture.pet()
        repository.family = [PetFixture.member("alice", role: .primary)]
        repository.checkins = checkins
        return PetProfileViewModel(
            petID: "pet-1", repository: repository, likes: FeedViewModelTests.FakeLikes(),
            postLookup: FeedViewModelTests.FakeFeed(), viewerID: "alice",
            places: places, lookups: PlaceLookups(directory: AppleMaps(table: apple))
        )
    }

    @Test func eachCheckinNamesItsPlaceAndEachPlaceIsReadOnce() async {
        let places = FakePlaces()
        places.answer = .success([
            "park": Place.decode(id: "park", ["name": "Riverside Dog Park", "category": "dog_park"]),
            "cafe": Place.decode(id: "cafe", ["name": "Harbor Café", "category": "cafe"]),
        ])
        let checkins = [checkin("c1", at: "park"), checkin("c2", at: "cafe"), checkin("c3", at: "park")]
        let model = model(checkins, places: places)

        await model.load()

        #expect(checkins.map { model.placeName(for: $0) } == ["Riverside Dog Park", "Harbor Café", "Riverside Dog Park"])
        #expect(places.questions == [["park", "cafe"]])
    }

    @Test func aPlaceThatIsGoneIsAnUnknownLocation() async {
        let places = FakePlaces()
        let gone = checkin("c1", at: "gone")
        let model = model([gone], places: places)

        await model.load()

        #expect(model.placeName(for: gone) == "Unknown location")
    }

    @Test func aPlaceFromAppleMapsIsNamedByApple() async {
        let places = FakePlaces()
        places.answer = .success(["apple_I1": Place.decode(id: "apple_I1", ["applePlaceId": "I1", "category": "dog_park"])])
        let run = checkin("c1", at: "apple_I1")
        let model = model([run], places: places, apple: [
            "I1": PlaceDetails(name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095),
        ])

        await model.load()

        #expect(model.placeName(for: run) == "Fenway Dog Run")
    }

    @Test func aFailedReadLeavesTheCheckinsWithoutNames() async {
        let places = FakePlaces()
        places.answer = .failure(URLError(.notConnectedToInternet))
        let first = checkin("c1", at: "park")
        let model = model([first], places: places)

        await model.load()

        #expect(model.checkinsState == .loaded)
        #expect(model.checkins.map(\.id) == ["c1"])
        #expect(model.placeName(for: first) == nil, "a name not known is said as if the place were gone")
    }

    @Test func checkinsWithoutAPlaceAskForNone() async {
        let places = FakePlaces()
        let nowhere = checkin("c1", at: "")
        let model = model([nowhere], places: places)

        await model.load()

        #expect(places.questions.isEmpty)
        #expect(model.placeName(for: nowhere) == "Unknown location")
    }
}
