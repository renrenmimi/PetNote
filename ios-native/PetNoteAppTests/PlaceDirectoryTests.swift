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

    @Test func anAddressIsTrimmedAndAnEmptyOneIsNotAsked() async throws {
        let asked = Asked()
        let directory = directory(asked: asked)

        #expect(try await directory.locate(address: "   ") == nil)
        #expect(try await directory.locate(address: "  12 Elm St \n")?.name == "12 Elm St")
        #expect(try await directory.locate(address: "12 Elm St")?.name == "12 Elm St")
        #expect(asked.all == ["address 12 Elm St"])
    }
}
