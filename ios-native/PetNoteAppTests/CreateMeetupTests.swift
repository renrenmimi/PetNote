import FirebaseFunctions
import Foundation
import Testing
@testable import PetNote

/// Creating a meetup: what goes to the server for each shape of where (a
/// place from Apple Maps by its identifier only, or the organiser's own words
/// for an address), what the form needs before Create is on, and what is said
/// when the server answers.
@MainActor
@Suite struct CreateMeetupTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private nonisolated static let run = PlaceSearchHit(
        applePlaceID: "I1",
        details: PlaceDetails(name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095)
    )

    private struct Directory: PlaceDirectory {
        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { nil }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] { [CreateMeetupTests.run] }
        func forget() async {}
    }

    /// Our places, counting how often they are read.
    private final class Places: PlacesReading, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var readsByAppleID: Int { lock.withLock { reads } }
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { [] }
        func search(prefix: String) async throws -> [Place] { [] }
        func places(applePlaceIDs ids: [String]) async throws -> [Place] {
            lock.withLock { reads += 1 }
            return []
        }
        func place(id: String) async throws -> Place? { nil }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }

    /// The server: keeps every draft, gives the set answer.
    private final class Creator: MeetupCreating, @unchecked Sendable {
        private let lock = NSLock()
        private var drafts: [MeetupDraft] = []
        var answer: Result<String, Error> = .success("m-new")
        var sent: [MeetupDraft] { lock.withLock { drafts } }
        func createMeetup(_ draft: MeetupDraft) async throws -> String {
            lock.withLock { drafts.append(draft) }
            return try answer.get()
        }
    }

    private func model(creator: Creator = Creator(), places: Places = Places(), pets: [Pet] = []) -> CreateMeetupModel {
        CreateMeetupModel(
            uid: "me", creator: creator, places: places, pets: FixedPets(pets: pets),
            directory: Directory(), now: { Self.now }
        )
    }

    /// Written, timed, at a place: ready for Create.
    private func ready(_ model: CreateMeetupModel) async {
        model.draft.title = "  Morning fetch  "
        model.draft.description = "  Bring a ball. "
        model.finder.query = "dog run"
        await model.finder.search()
        if case .found(let found) = model.finder.state, let first = found.first { model.choose(first) }
    }

    @Test func aMeetupAtAPlaceFromAppleMapsSendsItsIdentifierAndNothingOfApples() async throws {
        let creator = Creator()
        let model = model(creator: creator, pets: [PetFixture.pet(id: "pet-1", name: "Momo")])
        await model.loadPets()
        await ready(model)
        model.draft.isAddressPrivate = false
        model.draft.duration = 90

        await model.create()

        #expect(model.outcome == .created("m-new"))
        let payload = try #require(creator.sent.first).payload
        #expect(payload["location"] as? [String: String] == ["kind": "applePlace", "applePlaceId": "I1"])
        #expect(payload["locationVisibility"] as? String == "everyone")
        #expect(payload["title"] as? String == "Morning fetch")
        #expect(payload["description"] as? String == "Bring a ball.")
        #expect(payload["duration"] as? Int == 90)
        #expect(payload["dateMillis"] as? Int == Int(model.draft.date.timeIntervalSince1970 * 1000))
        #expect((payload["requirements"] as? [String: Any])?.isEmpty == true, "the server's defaults until requirements come")
        #expect(payload["organizerPetId"] as? String == "pet-1", "the web brings the organiser's first pet")
    }

    @Test func aMeetupAtATypedAddressSendsTheOrganisersWordsAndTheAreaEveryoneSees() async throws {
        let creator = Creator()
        let model = model(creator: creator)
        model.draft.title = "Yard games"
        model.draft.description = "Fenced yard."
        model.draft.whereKind = .address
        model.draft.address = " 5 Oak Ave, Medford, MA "
        model.draft.label = " Oak yard "
        model.draft.area = " Medford "

        await model.create()

        let payload = try #require(creator.sent.first).payload
        #expect(payload["location"] as? [String: String] == [
            "kind": "address", "address": "5 Oak Ave, Medford, MA", "label": "Oak yard", "area": "Medford",
        ])
        #expect(payload["locationVisibility"] as? String == "participants_only", "the web's default")
        #expect(payload["organizerPetId"] == nil, "no pet, so the organiser goes alone")
    }

    /// The address is the organiser's choice; a place left chosen from
    /// before is not sent with it, nor an address with a place.
    @Test func onlyTheChosenShapeOfWhereIsSent() async throws {
        let model = model()
        await ready(model)
        model.draft.address = "5 Oak Ave"
        model.draft.label = "Oak yard"

        let atPlace = try #require(model.draft.payload["location"] as? [String: String])
        #expect(atPlace == ["kind": "applePlace", "applePlaceId": "I1", "area": ""], "private, with no area named")

        model.draft.whereKind = .address
        let atAddress = try #require(model.draft.payload["location"] as? [String: String])
        #expect(atAddress == ["kind": "address", "address": "5 Oak Ave", "label": "Oak yard", "area": ""])
    }

    @Test func createIsOnOnlyWithATitleADescriptionATimeToComeAndWhere() async {
        let model = model()
        #expect(!model.canSave, "empty")
        await ready(model)
        #expect(model.canSave)

        model.draft.title = "   "
        #expect(!model.canSave, "no title")
        model.draft.title = String(repeating: "a", count: 60)
        #expect(model.canSave)
        model.draft.title = String(repeating: "🐶", count: 31)
        #expect(!model.canSave, "62 as the server counts, over its 60")
        model.draft.title = "Fetch"

        model.draft.description = String(repeating: "a", count: 501)
        #expect(!model.canSave, "over 500")
        model.draft.description = "Bring a ball."

        model.draft.date = Self.now.addingTimeInterval(-60)
        #expect(!model.canSave, "a time that has passed")
        model.draft.date = Self.now.addingTimeInterval(3600)

        model.changePlace()
        #expect(!model.canSave, "no place")
        model.draft.whereKind = .address
        #expect(!model.canSave, "no address")
        model.draft.address = "5 Oak Ave"
        #expect(model.canSave)
        model.draft.label = String(repeating: "a", count: 61)
        #expect(!model.canSave, "a label over 60")
        model.draft.label = ""
        model.draft.area = String(repeating: "a", count: 101)
        #expect(!model.canSave, "an area over 100")
        model.draft.isAddressPrivate = false
        #expect(model.canSave, "an area is only for a meetup whose address is private")
    }

    @Test func aRefusalSaysTheServersWordsAndKeepsTheForm() async {
        let creator = Creator()
        creator.answer = .failure(NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Verify your email before creating meetups."]
        ))
        let model = model(creator: creator)
        await ready(model)

        await model.create()

        #expect(model.outcome == .failed("Verify your email before creating meetups."))
        #expect(model.draft.title == "  Morning fetch  " && model.draft.place != nil)
        #expect(model.canSave, "a refusal left Create off")
    }

    @Test func aCreatedMeetupIsNotSentAgain() async {
        let creator = Creator()
        let model = model(creator: creator)
        await ready(model)

        await model.create()
        await model.create()

        #expect(creator.sent.count == 1)
        #expect(!model.canSave)
    }

    /// Any place can hold a meetup, so a search for one does not look for
    /// which are on PetNote.
    @Test func aSearchForWhereDoesNotReadOurPlaces() async {
        let places = Places()
        let model = model(places: places)
        model.finder.query = "dog run"

        await model.finder.search()

        guard case .found(let found) = model.finder.state else {
            Issue.record("no results: \(model.finder.state)")
            return
        }
        #expect(found.map(\.id) == ["I1"] && found[0].placeID == nil)
        #expect(places.readsByAppleID == 0)
    }

    @Test func itStartsTomorrowAtTenForAnHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = MeetupDraft.defaultDate(now: Self.now, calendar: calendar)

        #expect(calendar.dateComponents([.hour, .minute], from: date) == DateComponents(hour: 10, minute: 0))
        #expect(calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: Self.now)!))
        #expect(MeetupDraft(date: date).duration == 60)
        #expect(MeetupDraft.durations.map(MeetupDraft.durationLabel) == ["30 min", "1 hour", "1.5 hours", "2 hours", "3 hours", "Half day"])
    }
}
