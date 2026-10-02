import Foundation
import Testing
@testable import PetNote

/// The temporary cache in front of Apple Maps: what it keeps, what it shares,
/// and what it lets go. Driven through a counting stand-in for MapKit, so it
/// runs without a network and says exactly how often Apple would be asked.
@Suite struct PlaceDirectoryTests {
    private static let park = PlaceDetails(
        name: "Riverside Dog Park", address: "1 River St, Cambridge, MA", latitude: 42.3601, longitude: -71.0942
    )

    /// Every question the stand-in was asked, under a lock: the directory asks
    /// from its own tasks.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var questions: [String] = []
        func record(_ question: String) { lock.withLock { questions.append(question) } }
        var all: [String] { lock.withLock { questions } }
    }

    /// Holds a lookup until the test lets it finish.
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func pass() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private struct Unreachable: Error {}

    private func directory(
        asked: Asked,
        gate: Gate? = nil,
        searchGate: Gate? = nil,
        hits: [PlaceSearchHit] = [],
        streets: [PlaceDetails] = [],
        place: @escaping @Sendable (String) throws -> PlaceDetails? = { _ in park }
    ) -> MapKitPlaceDirectory {
        MapKitPlaceDirectory(lookups: .init(
            place: { id in
                asked.record("place \(id)")
                await gate?.pass()
                return try place(id)
            },
            address: { text in
                asked.record("address \(text)")
                return PlaceDetails(name: text, address: text, latitude: 42.39, longitude: -71.1)
            },
            search: { text in
                asked.record("search \(text)")
                await searchGate?.pass()
                return hits
            },
            searchAddresses: { text in
                asked.record("addresses \(text)")
                return streets
            }
        ))
    }

    @Test func aPlaceShownTwiceIsAskedForOnce() async throws {
        let asked = Asked()
        let directory = directory(asked: asked)

        #expect(try await directory.details(forApplePlaceID: "I1") == Self.park)
        #expect(try await directory.details(forApplePlaceID: "I1") == Self.park)
        #expect(asked.all == ["place I1"])
    }

    @Test func twoRowsAskingAtOnceMakeOneRequest() async throws {
        let asked = Asked()
        let gate = Gate()
        let directory = directory(asked: asked, gate: gate)

        async let first = directory.details(forApplePlaceID: "I1")
        #expect(await eventuallyTrueAnywhere { asked.all.count == 1 })
        async let second = directory.details(forApplePlaceID: "I1")
        await gate.open()

        #expect(try await first == Self.park)
        #expect(try await second == Self.park)
        #expect(asked.all == ["place I1"])
    }

    @Test func aPlaceAppleNoLongerKnowsIsRememberedAsGone() async throws {
        let asked = Asked()
        let directory = directory(asked: asked, place: { _ in nil })

        #expect(try await directory.details(forApplePlaceID: "I1") == nil)
        #expect(try await directory.details(forApplePlaceID: "I1") == nil)
        #expect(asked.all == ["place I1"], "a gone place should not be asked for on every row")
    }

    @Test func aFailureIsNotKeptAndTheNextLookTriesAgain() async throws {
        let asked = Asked()
        let directory = directory(asked: asked, place: { _ in
            if asked.all.count == 1 { throw Unreachable() }
            return Self.park
        })

        await #expect(throws: Unreachable.self) { try await directory.details(forApplePlaceID: "I1") }
        #expect(try await directory.details(forApplePlaceID: "I1") == Self.park)
        #expect(asked.all == ["place I1", "place I1"])
    }

    @Test func forgettingEmptiesTheCache() async throws {
        let asked = Asked()
        let directory = directory(asked: asked)

        _ = try await directory.details(forApplePlaceID: "I1")
        _ = try await directory.locate(address: "12 Elm St")
        await directory.forget()
        _ = try await directory.details(forApplePlaceID: "I1")
        _ = try await directory.locate(address: "12 Elm St")

        #expect(asked.all == ["place I1", "address 12 Elm St", "place I1", "address 12 Elm St"])
    }

    @Test func anAnswerOnItsWayWhenForgottenIsGivenButNotKept() async throws {
        let asked = Asked()
        let gate = Gate()
        let directory = directory(asked: asked, gate: gate)

        async let first = directory.details(forApplePlaceID: "I1")
        #expect(await eventuallyTrueAnywhere { asked.all.count == 1 })
        await directory.forget()
        await gate.open()

        #expect(try await first == Self.park, "the caller that asked still gets its answer")
        _ = try await directory.details(forApplePlaceID: "I1")
        #expect(asked.all == ["place I1", "place I1"], "an answer from before forget() must not be cached")
    }

    /// A search is asked each time; what it says about each place it finds
    /// is kept, so the place it turns into is not asked about again.
    @Test func aSearchKeepsWhatAppleSaidAboutEachPlaceItFound() async throws {
        let asked = Asked()
        let directory = directory(asked: asked, hits: [PlaceSearchHit(applePlaceID: "I1", details: Self.park)])

        #expect(try await directory.search("  dog park ").map(\.applePlaceID) == ["I1"])
        #expect(try await directory.details(forApplePlaceID: "I1") == Self.park)
        _ = try await directory.search("dog park")
        #expect(try await directory.search("   ").isEmpty)

        #expect(asked.all == ["search dog park", "search dog park"])
    }

    @Test func aSearchAnsweredWhenForgottenIsGivenButNotKept() async throws {
        let asked = Asked()
        let gate = Gate()
        let directory = directory(asked: asked, searchGate: gate, hits: [PlaceSearchHit(applePlaceID: "I1", details: Self.park)])

        async let found = directory.search("dog park")
        #expect(await eventuallyTrueAnywhere { asked.all.count == 1 })
        await directory.forget()
        await gate.open()

        #expect(try await found.map(\.applePlaceID) == ["I1"], "the caller that searched still gets its answer")
        _ = try await directory.details(forApplePlaceID: "I1")
        #expect(asked.all == ["search dog park", "place I1"], "a search answered after forget() must not be kept")
    }

    /// Asked each time, as a search for places is. Each address found is
    /// kept as the answer for its own words, so a meetup saved at one does
    /// not ask Apple again to show it; one Apple gave twice, or with no
    /// words, is shown once, or not at all.
    @Test func anAddressSearchKeepsEachAddressForItsOwnWords() async throws {
        let asked = Asked()
        let elm = PlaceDetails(name: "12 Elm St", address: "12 Elm St, Somerville, MA 02144", latitude: 42.39, longitude: -71.12)
        let blank = PlaceDetails(name: "Somewhere", address: "", latitude: 42.4, longitude: -71.1)
        let directory = directory(asked: asked, streets: [elm, blank, elm])

        #expect(try await directory.searchAddresses("  12 elm st ") == [elm])
        #expect(try await directory.locate(address: "12 Elm St, Somerville, MA 02144") == elm)
        _ = try await directory.searchAddresses("12 elm st")
        #expect(try await directory.searchAddresses("   ").isEmpty)

        #expect(asked.all == ["addresses 12 elm st", "addresses 12 elm st"])
    }

    #if PETNOTE_FAULT_INJECTION
    /// The emulator build's table, as UI tests search it: by the words of a
    /// place's name, whatever the case.
    @Test func theStandInFindsATablePlaceByTheWordsOfItsName() async throws {
        let standIn = StandInPlaceDirectory()

        #expect(try await standIn.search("fenway DOG").map(\.applePlaceID) == ["TESTAPPLEDOGRUN01"])
        #expect(try await standIn.search("dog fenway").map(\.applePlaceID) == ["TESTAPPLEDOGRUN01"], "words in any order")
        #expect(try await standIn.search("TEST CONTENT").map(\.applePlaceID) == ["TESTAPPLEDOGRUN01", "TESTAPPLEPETSHOP1"])
        #expect(try await standIn.search("TEST CONTENT Hi").isEmpty, "the web's search test would find it")
        #expect(try await standIn.search("  ").isEmpty)
    }

    /// Its addresses, as UI tests search for one: words with a street number
    /// are one, in the town they name or else in Medford; a place's name is
    /// not.
    @Test func theStandInFindsAStreetAddressForWordsWithANumber() async throws {
        let standIn = StandInPlaceDirectory()

        let elm = try await standIn.searchAddresses(" 12 Elm St ")
        #expect(elm.map(\.name) == ["12 Elm St"] && elm.map(\.address) == ["12 Elm St, Medford, MA 02155"])
        let oak = try await standIn.searchAddresses("5 Oak Ave, Medford, MA")
        #expect(oak.map(\.name) == ["5 Oak Ave"] && oak.map(\.address) == ["5 Oak Ave, Medford, MA"])
        #expect(try await standIn.searchAddresses("dog run").isEmpty)
    }
    #endif

    @Test func anAddressIsTrimmedAndAnEmptyOneIsNotAsked() async throws {
        let asked = Asked()
        let directory = directory(asked: asked)

        #expect(try await directory.locate(address: "   ") == nil)
        #expect(try await directory.locate(address: "  12 Elm St \n")?.name == "12 Elm St")
        #expect(try await directory.locate(address: "12 Elm St")?.name == "12 Elm St")
        #expect(asked.all == ["address 12 Elm St"])
    }
}
