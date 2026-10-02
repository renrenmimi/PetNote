import Foundation
import MapKit
import Testing
@testable import PetNote

/// On a real iPhone, the two things the Mac run could not settle
/// (`docs/apple-maps-places-plan.md`): that Apple Maps gives a search's places
/// an identifier there too — a developer reported none on iOS 18 devices —
/// and that a page's worth of them can be looked up at once without being
/// throttled. Through the app's own MapKit calls, in the app's own process.
/// Only counts and times are printed; nothing Apple says about a place is
/// kept.
@Suite(.enabled(if: RealIPhone.isThisOne, "on a real iPhone only"), .serialized)
struct AppleMapsDeviceProbeTests {
    /// Ordinary searches, so the answers are ordinary public places.
    private static let queries = ["dog park Boston", "pet store Boston", "park Cambridge MA", "cafe Somerville MA"]

    @Test func searchesGiveTheirPlacesIdentifiersAndTheSameOnesAgain() async throws {
        var withIdentifier = 0
        var without = 0
        var first: [String: Set<String>] = [:]
        for query in Self.queries {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            let items = try await MKLocalSearch(request: request).start().mapItems
            withIdentifier += items.filter { $0.identifier != nil }.count
            without += items.filter { $0.identifier == nil }.count
            first[query] = Set(items.compactMap { $0.identifier?.rawValue })
        }
        print("MEASURED apple search: \(withIdentifier) places with an identifier, \(without) without, in \(Self.queries.count) searches")
        #expect(withIdentifier > 0, "no identifiers on this device")

        var again = 0
        var same = 0
        for query in Self.queries {
            let ids = try await MapKitPlaceDirectory.Lookups.mapKit.search(query).map(\.applePlaceID)
            again += ids.count
            same += ids.filter { first[query]?.contains($0) == true }.count
        }
        print("MEASURED apple search again: \(same) of \(again) identifiers the same as the first time")
        #expect(again > 0)
        #expect(Double(same) >= Double(again) * 0.8, "the same places came back under other identifiers")
    }

    @Test func aPageOfPlacesIsLookedUpAtOnce() async throws {
        var ids: [String] = []
        for query in Self.queries where ids.count < 26 {
            for id in try await MapKitPlaceDirectory.Lookups.mapKit.search(query).map(\.applePlaceID) where !ids.contains(id) {
                ids.append(id)
            }
        }
        ids = Array(ids.prefix(26))
        let started = Date()
        let answered = try await withThrowingTaskGroup(of: Bool.self) { group in
            for id in ids {
                group.addTask { try await MapKitPlaceDirectory.Lookups.mapKit.place(id) != nil }
            }
            var found = 0
            for try await isFound in group where isFound { found += 1 }
            return found
        }
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "MEASURED apple lookups: %d of %d answered at once in %.2f s", answered, ids.count, seconds))
        #expect(ids.count >= 20, "too few places found to make a page")
        #expect(answered == ids.count, "not every place was answered: throttled, or gone")
    }
}

/// Its own type: the suite's condition cannot be on the suite itself.
private enum RealIPhone {
    static var isThisOne: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
