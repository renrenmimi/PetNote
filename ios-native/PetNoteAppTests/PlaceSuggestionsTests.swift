import Foundation
import Testing
@testable import PetNote

/// Suggestions while someone types, before Return: asked about once the words
/// rest, none for nothing typed or for words already searched for, an answer
/// for older words never shown over newer ones; and a suggestion chosen is
/// searched for, and what that finds is what is chosen.
@MainActor
@Suite struct PlaceSuggestionsTests {
    private nonisolated static let run = PlaceSearchHit(
        applePlaceID: "I1",
        details: PlaceDetails(name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA 02215", latitude: 42.34, longitude: -71.09)
    )
    private nonisolated static let shop = PlaceSearchHit(
        applePlaceID: "I2",
        details: PlaceDetails(name: "Corner Pet Shop", address: "20 Elm St, Somerville, MA 02144", latitude: 42.39, longitude: -71.12)
    )
    private nonisolated static let elm = PlaceDetails(
        name: "12 Elm St", address: "12 Elm St, Somerville, MA 02144", latitude: 42.39, longitude: -71.12
    )
    private static let runSuggestion = PlaceSuggestion(kind: .place, title: "Fenway Dog Run", subtitle: "1 Park Dr, Boston, MA 02215")
    private static let elmSuggestion = PlaceSuggestion(kind: .address, title: "12 Elm St", subtitle: "Somerville, MA")

    /// Apple's suggestions, as set, with every question asked. A question can
    /// be held until it is let go, to answer after a newer one.
    @MainActor
    private final class Suggester: PlaceSuggesting {
        var answers: [String: [PlaceSuggestion]] = [:]
        private(set) var asked: [String] = []
        /// Those answered, in the order they were.
        private(set) var answered: [String] = []
        var holds: Set<String> = []
        private var held: [String: CheckedContinuation<Void, Never>] = [:]

        func suggestions(for fragment: String, addresses: Bool) async -> [PlaceSuggestion] {
            asked.append(addresses ? "\(fragment) and addresses" : fragment)
            if holds.contains(fragment) {
                await withCheckedContinuation { held[fragment] = $0 }
            }
            answered.append(fragment)
            return answers[fragment] ?? []
        }

        var isHolding: Bool { !held.isEmpty }

        func release(_ fragment: String) {
            held.removeValue(forKey: fragment)?.resume()
        }
    }

    /// Apple Maps: every search kept, each answered as set.
    private final class Directory: PlaceDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private var searches: [String] = []
        private let hits: [PlaceSearchHit]
        private let streets: [PlaceDetails]
        private let fails: Bool

        init(hits: [PlaceSearchHit] = [PlaceSuggestionsTests.shop, PlaceSuggestionsTests.run],
             streets: [PlaceDetails] = [PlaceSuggestionsTests.elm], fails: Bool = false) {
            self.hits = hits
            self.streets = streets
            self.fails = fails
        }

        var asked: [String] { lock.withLock { searches } }

        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { nil }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] {
            lock.withLock { searches.append("places \(text)") }
            if fails { throw URLError(.notConnectedToInternet) }
            return hits
        }
        func searchAddresses(_ text: String) async throws -> [PlaceDetails] {
            lock.withLock { searches.append("addresses \(text)") }
            if fails { throw URLError(.notConnectedToInternet) }
            return streets
        }
        func forget() async {}
    }

    /// Ours: the dog run has been added.
    private struct Places: PlacesReading {
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { [] }
        func search(prefix: String) async throws -> [Place] { [] }
        func places(applePlaceIDs ids: [String]) async throws -> [Place] {
            ids.contains("I1") ? [Place.decode(id: "apple_I1", ["applePlaceId": "I1", "category": "dog_park"])] : []
        }
        func place(id: String) async throws -> Place? { nil }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }

    private func finder(
        suggester: Suggester, directory: Directory = Directory(), marksAdded: Bool = false, findsAddresses: Bool = false
    ) -> ApplePlaceFinder {
        ApplePlaceFinder(
            places: Places(), marksAdded: marksAdded, findsAddresses: findsAddresses,
            directory: directory, suggester: suggester, typingPause: .zero
        )
    }

    private func type(_ text: String, into finder: ApplePlaceFinder) {
        finder.query = text
        finder.wordsChanged()
    }

    @Test func theWordsSoFarAreSuggestedForAndShownUntilReturn() async {
        let suggester = Suggester()
        suggester.answers["fenway"] = [Self.runSuggestion]
        let finder = finder(suggester: suggester)

        type("  fenway ", into: finder)

        #expect(await eventuallyTrue { finder.suggestions == [Self.runSuggestion] })
        #expect(suggester.asked == ["fenway"], "a place's search asks for places only")
        #expect(!finder.showsResults)
        await finder.search()
        #expect(finder.suggestions.isEmpty, "Return searches, and its results show instead")
        #expect(finder.showsResults)
    }

    @Test func aMeetupsSearchAsksForAddressesToo() async {
        let suggester = Suggester()
        let finder = finder(suggester: suggester, findsAddresses: true)

        type("12 Elm", into: finder)

        #expect(await eventuallyTrue { suggester.asked == ["12 Elm and addresses"] })
    }

    /// Nothing typed, or the words just searched for again: nothing to ask.
    @Test func nothingIsAskedForNothingOrForWordsAlreadySearchedFor() async {
        let suggester = Suggester()
        suggester.answers["dog"] = [Self.runSuggestion]
        let finder = finder(suggester: suggester)
        type("dog", into: finder)
        #expect(await eventuallyTrue { !finder.suggestions.isEmpty })
        await finder.search()

        type("dog ", into: finder)
        #expect(finder.suggestions.isEmpty, "the words searched for, again")
        type("   ", into: finder)
        #expect(finder.suggestions.isEmpty, "nothing typed")
        for _ in 0..<20 { await Task.yield() }

        #expect(suggester.asked == ["dog"])
    }

    /// Apple answers for "fen" after the words became "fenway": "fenway"'s
    /// answer is the one shown.
    @Test func anAnswerForOlderWordsIsNotShownOverNewerOnes() async {
        let suggester = Suggester()
        suggester.holds = ["fen"]
        suggester.answers["fen"] = [PlaceSuggestion(kind: .place, title: "Fenwick Pond", subtitle: "")]
        suggester.answers["fenway"] = [Self.runSuggestion]
        let finder = finder(suggester: suggester)

        type("fen", into: finder)
        #expect(await eventuallyTrue { suggester.isHolding })
        type("fenway", into: finder)
        #expect(await eventuallyTrue { finder.suggestions == [Self.runSuggestion] })
        suggester.release("fen")
        #expect(await eventuallyTrue { suggester.answered == ["fenway", "fen"] })

        #expect(finder.suggestions == [Self.runSuggestion])
    }

    /// A place suggestion is searched for by its name and address, and the
    /// result with its name is the one chosen, marked when it is ours.
    @Test func aPlaceSuggestionChosenIsThePlaceItNames() async {
        let directory = Directory()
        let finder = finder(suggester: Suggester(), directory: directory, marksAdded: true)

        let choice = await finder.choose(Self.runSuggestion)

        #expect(choice == .place(ApplePlaceFinder.Found(hit: Self.run, placeID: "apple_I1")))
        #expect(directory.asked == ["places Fenway Dog Run, 1 Park Dr, Boston, MA 02215"])
        #expect(finder.choosing == nil)
    }

    @Test func anAddressSuggestionChosenIsTheAddressAsAppleWritesIt() async {
        let directory = Directory()
        let finder = finder(suggester: Suggester(), directory: directory, findsAddresses: true)

        let choice = await finder.choose(Self.elmSuggestion)

        #expect(choice == .address("12 Elm St, Somerville, MA 02144", Self.elm))
        #expect(directory.asked == ["addresses 12 Elm St, Somerville, MA"])
    }

    /// Apple suggested an address it then cannot find: the suggestion's own
    /// words, with nothing for a map.
    @Test func anAddressAppleCannotFindIsTheSuggestionsWords() async {
        let finder = finder(suggester: Suggester(), directory: Directory(streets: []), findsAddresses: true)

        #expect(await finder.choose(Self.elmSuggestion) == .address("12 Elm St, Somerville, MA", nil))
    }

    /// A place Apple suggested and then finds nothing for: the search for its
    /// name runs instead, so its results show.
    @Test func aPlaceSuggestionThatFindsNothingSearchesForItsName() async {
        let directory = Directory(hits: [])
        let finder = finder(suggester: Suggester(), directory: directory)
        finder.query = "fenw"

        #expect(await finder.choose(Self.runSuggestion) == nil)

        #expect(finder.query == "Fenway Dog Run")
        #expect(finder.showsResults && finder.state == .found([]))
        #expect(directory.asked == ["places Fenway Dog Run, 1 Park Dr, Boston, MA 02215", "places Fenway Dog Run"])
    }

    @Test func aSuggestionThatCannotBeSearchedForSaysSo() async {
        let finder = finder(suggester: Suggester(), directory: Directory(fails: true))
        finder.query = "fenway"

        #expect(await finder.choose(Self.runSuggestion) == nil)

        #expect(finder.state == .failed(String(localized: "Couldn't search Apple Maps. Try again.")))
        #expect(finder.showsResults, "the failure shows where results do")
    }

    #if PETNOTE_FAULT_INJECTION
    /// The emulator build's suggestions, as UI tests type: the table's
    /// places by any of their words, and an address for words with a number,
    /// which the stand-in directory then finds.
    @Test func theStandInSuggestsTablePlacesAndAStreetAddress() async throws {
        let standIn = StandInPlaceSuggester()

        let places = await standIn.suggestions(for: "fenway", addresses: false)
        #expect(places.map(\.title) == ["TEST CONTENT Fenway Dog Run"])
        let both = await standIn.suggestions(for: "12 Elm St", addresses: true)
        #expect(both == [PlaceSuggestion(kind: .address, title: "12 Elm St", subtitle: "Medford, MA 02155")])
        #expect(await standIn.suggestions(for: "12 Elm St", addresses: false).isEmpty)

        let found = try await StandInPlaceDirectory().search(try #require(places.first).searchText)
        #expect(found.map(\.applePlaceID) == ["TESTAPPLEDOGRUN01"], "a suggestion is found by its name and address")
    }
    #endif
}
