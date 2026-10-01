import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Testing
@testable import PetNote

/// Editing a meetup: the form starts from the meetup as its organiser sees
/// it, where it is goes back in the shape it was in unless the organiser
/// chooses somewhere else, and the server's answer is what is said.
@MainActor
@Suite struct EditMeetupTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private nonisolated static let nextWeek = Date(timeIntervalSince1970: 1_790_000_000 + 7 * 86_400)
    private nonisolated static let run = PlaceDetails(
        name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095
    )

    /// The server: keeps every edit, gives the set answer.
    private final class Editor: MeetupEditing, @unchecked Sendable {
        private let lock = NSLock()
        private var edits: [(String, MeetupDraft)] = []
        var answer: Result<Void, Error> = .success(())
        var sent: [(String, MeetupDraft)] { lock.withLock { edits } }
        func updateMeetup(id: String, _ draft: MeetupDraft) async throws {
            lock.withLock { edits.append((id, draft)) }
            try answer.get()
        }
    }

    private struct Places: PlacesReading {
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { [] }
        func search(prefix: String) async throws -> [Place] { [] }
        func places(applePlaceIDs ids: [String]) async throws -> [Place] { [] }
        func place(id: String) async throws -> Place? { nil }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }

    private struct Directory: PlaceDirectory {
        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { nil }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] { [] }
        func forget() async {}
    }

    private func meetup(
        _ location: [String: Any], visibility: String = "everyone", requirements: [String: Any] = [:],
        date: Date = nextWeek, cover: URL? = nil
    ) -> Meetup {
        var fields: [String: Any] = [
            "title": "Morning walk", "description": "Bring water.", "organizerId": "me", "status": "upcoming",
            "date": Timestamp(date: date), "duration": 90, "location": location,
            "locationVisibility": visibility, "requirements": requirements,
        ]
        if let cover { fields["coverImage"] = cover.absoluteString }
        return Meetup.decode(id: "m1", fields)
    }

    private func model(
        _ meetup: Meetup, place: MeetupPlace? = nil, details: PlaceDetails? = nil, editor: Editor = Editor(),
        uploader: FakeUploader = FakeUploader()
    ) -> MeetupFormModel {
        MeetupFormModel(
            editing: meetup, place: place ?? meetup.place, details: details,
            editor: editor, places: Places(), uploader: uploader, directory: Directory(), now: { Self.now }
        )
    }

    private static let webPark: [String: Any] = [
        "name": "Riverside Dog Park", "address": "1 River St, Cambridge, MA",
        "lat": 42.3601, "lng": -71.0942, "city": "Cambridge", "state": "MA",
    ]

    @Test func theFormStartsFromTheMeetup() {
        let model = model(meetup(Self.webPark))

        #expect(model.purpose == .edit(meetupID: "m1"))
        #expect(model.draft.title == "Morning walk" && model.draft.description == "Bring water.")
        #expect(model.draft.date == Self.nextWeek && model.draft.duration == 90)
        #expect(!model.draft.isAddressPrivate)
        #expect(model.canSave, "an edit with nothing changed can be saved as it is")
    }

    /// A meetup made on the web is at a place with a name, address and
    /// position of its own: an edit sends that back as it was, in the web's
    /// shape, so a new title does not move the meetup or unlink its place.
    @Test func aMeetupMadeOnTheWebGoesBackWhereItWas() throws {
        let model = model(meetup(Self.webPark))

        #expect(model.draft.whereKind == .unchanged)
        let location = try #require(model.draft.payload["location"] as? [String: Any])
        #expect(location as NSDictionary == Self.webPark as NSDictionary, "the web's shape, no kind, no area")
    }

    @Test func choosingSomewhereElseLeavesTheWebsPlaceBehind() throws {
        let model = model(meetup(Self.webPark))
        model.draft.whereKind = .address
        model.draft.address = "5 Oak Ave, Medford, MA"

        let location = try #require(model.draft.payload["location"] as? [String: String])
        #expect(location == ["kind": "address", "address": "5 Oak Ave, Medford, MA", "label": ""])
    }

    @Test func aMeetupAtAPlaceFromAppleMapsStaysThere() throws {
        let model = model(meetup(["applePlaceId": "I1"]), details: Self.run)

        #expect(model.draft.whereKind == .applePlace)
        #expect(model.draft.place == PlaceSearchHit(applePlaceID: "I1", details: Self.run), "shown as chosen, with Apple's words")
        #expect(model.draft.payload["location"] as? [String: String] == ["kind": "applePlace", "applePlaceId": "I1"])
    }

    @Test func aMeetupAtATypedAddressKeepsTheOrganisersWords() throws {
        let model = model(meetup(["address": "5 Oak Ave, Medford, MA", "label": "Oak yard"]))

        #expect(model.draft.whereKind == .address)
        #expect(model.draft.payload["location"] as? [String: String] == [
            "kind": "address", "address": "5 Oak Ave, Medford, MA", "label": "Oak yard",
        ])
    }

    /// Participants-only: the form starts from the private copy, which its
    /// organiser may read, and the area the public one names.
    @Test func aPrivateMeetupKeepsItsAreaAndItsAddress() throws {
        let hidden = meetup(["name": "Meetup near Medford", "area": "Medford"], visibility: "participants_only")
        let model = model(hidden, place: MeetupPlace.decode(["address": "5 Oak Ave, Medford, MA", "label": "Oak yard"]))

        #expect(model.draft.isAddressPrivate && model.draft.area == "Medford")
        #expect(model.draft.payload["location"] as? [String: String] == [
            "kind": "address", "address": "5 Oak Ave, Medford, MA", "label": "Oak yard", "area": "Medford",
        ])
        #expect(model.draft.payload["locationVisibility"] as? String == "participants_only")
    }

    @Test func whatTheMeetupAsksIsWhatTheFormStartsWith() {
        let model = model(meetup(Self.webPark, requirements: [
            "petType": "any_dog", "dogSize": "small", "maxPets": 4, "mustHavePosts": true,
            "minFollowers": 2, "additionalNotes": "Bring water.",
        ]))
        var expected = MeetupDraft.Requirements()
        expected.petType = "dog"
        expected.dogSize = "small"
        expected.maxPets = 4
        expected.mustHavePosts = true
        expected.minFollowers = 2
        expected.notes = "Bring water."

        #expect(model.draft.requirements == expected, "the web's any_dog is the form's dogs")
    }

    @Test func savingSendsTheEditForThisMeetupWithNoPet() async {
        let editor = Editor()
        let model = model(meetup(Self.webPark), editor: editor)
        model.draft.title = "Evening walk"

        await model.loadPets()
        await model.submit()

        #expect(model.outcome == .saved)
        #expect(editor.sent.map(\.0) == ["m1"])
        #expect(editor.sent.first?.1.title == "Evening walk")
        #expect(editor.sent.first?.1.payload["organizerPetId"] == nil, "a pet is for a new meetup only")
        #expect(!model.canSave, "saved: nothing more to send")
    }

    @Test func aRefusalSaysTheServersWords() async {
        let editor = Editor()
        editor.answer = .failure(NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Cannot edit this meetup."]
        ))
        let model = model(meetup(Self.webPark), editor: editor)

        await model.submit()

        #expect(model.outcome == .failed("Cannot edit this meetup."))
        #expect(model.canSave)
    }

    /// The cover it has is shown and not sent back: the server keeps it when
    /// none is sent.
    @Test func theCoverItHasStaysUnlessANewOneIsChosen() async throws {
        let cover = URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/u/old.jpg")!
        let editor = Editor()
        let uploader = FakeUploader()
        let model = model(meetup(Self.webPark, cover: cover), editor: editor, uploader: uploader)
        #expect(model.currentCover == cover)

        await model.submit()

        #expect(uploader.sendCount == 0)
        #expect(try #require(editor.sent.first).1.payload["coverImage"] == nil)
    }

    @Test func aNewCoverIsUploadedAndSent() async throws {
        let editor = Editor()
        let uploader = FakeUploader()
        let model = model(meetup(Self.webPark), editor: editor, uploader: uploader)
        model.chooseCover(data: UploadTestImages.jpeg(width: 400, height: 300, quality: 0.5), filename: "c.jpg")

        await model.submit()

        #expect(model.outcome == .saved)
        #expect(uploader.sendCount == 1)
        let payload = try #require(editor.sent.first).1.payload
        #expect(payload["coverImage"] as? String == "https://res.cloudinary.com/petnote/image/upload/v1/u/1.jpg")
    }

    @Test func aNewCoverThatDoesNotGoChangesNothing() async {
        let editor = Editor()
        let uploader = FakeUploader()
        uploader.fail(atSend: [1], with: UploadError.transport("offline"))
        let model = model(meetup(Self.webPark), editor: editor, uploader: uploader)
        model.chooseCover(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "c.jpg")

        await model.submit()

        #expect(model.outcome == .failed("The cover could not be uploaded. The meetup was not changed."))
        #expect(editor.sent.isEmpty)
    }

    @Test func aTimeThatHasPassedWaitsForANewOne() {
        let model = model(meetup(Self.webPark, date: Self.now.addingTimeInterval(-3600)))
        #expect(!model.canSave, "the server refuses a time that has passed")
        model.draft.date = Self.nextWeek
        #expect(model.canSave)
    }

    @Test func aDurationTheWebDoesNotOfferIsStillShown() {
        #expect(MeetupDraft.durationChoices(including: 45) == [30, 45, 60, 90, 120, 180, 240])
        #expect(MeetupDraft.durationChoices(including: 60) == MeetupDraft.durations)
    }
}
