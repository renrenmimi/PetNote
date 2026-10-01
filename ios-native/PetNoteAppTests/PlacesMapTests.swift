import Foundation
import Testing
@testable import PetNote

/// The map over the places list: which places it marks, and where.
@MainActor
@Suite struct PlacesMapTests {
    private nonisolated static let run = PlaceDetails(
        name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095
    )

    private struct Directory: PlaceDirectory {
        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { id == "I1" ? PlacesMapTests.run : nil }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] { [] }
        func forget() async {}
    }

    private func place(_ id: String, apple: String? = nil, name: String = "", lat: Double = 0, lng: Double = 0) -> Place {
        Place(
            id: id, name: name, address: "", city: "", state: "", latitude: lat, longitude: lng,
            category: .dogPark, description: "", features: [], photos: [],
            averageRating: 0, totalRatings: 0, totalCheckins: 0, verifiedByCheckins: false,
            applePlaceID: apple
        )
    }

    @Test func aPlaceFromTheWebIsMarkedWhereItSaysItIs() {
        let lookups = PlaceLookups(directory: Directory())
        let cafe = place("web-cafe", name: "Harbor Cafe", lat: 42.3551, lng: -71.0489)
        let nowhere = place("web-nowhere", name: "No Position Park")

        #expect(PlacesMap.pins(for: [cafe, nowhere], lookups: lookups) == [
            PlacesMap.Pin(id: "web-cafe", name: "Harbor Cafe", latitude: 42.3551, longitude: -71.0489),
        ])
    }

    @Test func aPlaceFromAppleMapsIsMarkedOnceAppleHasSaidWhere() async {
        let lookups = PlaceLookups(directory: Directory())
        let found = place("apple_I1", apple: "I1")
        let gone = place("apple_I9", apple: "I9")

        #expect(PlacesMap.pins(for: [found, gone], lookups: lookups).isEmpty, "marked before Apple answered")
        await lookups.lookUp([found, gone])

        #expect(PlacesMap.pins(for: [found, gone], lookups: lookups) == [
            PlacesMap.Pin(id: "apple_I1", name: "Fenway Dog Run", latitude: 42.3434, longitude: -71.095),
        ], "one Apple no longer knows has nowhere to be")
    }

    @Test func theMapSaysHowManyPlacesItShows() {
        #expect(PlacesMap.label(count: 1) == "Map of 1 place")
        #expect(PlacesMap.label(count: 4) == "Map of 4 places")
    }
}
