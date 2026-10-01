import FirebaseFunctions
import Foundation
import Testing
@testable import PetNote

/// The server's check-ins: keeps every draft, gives the set answer, and says
/// who has checked in where on which day.
final class FakeCheckins: PlaceCheckingIn, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [CheckinDraft] = []
    private var asked: [(String, String, Date)] = []
    var answer: Result<Void, Error> = .success(())
    var checkedIn: Set<String> = []

    var sent: [CheckinDraft] { lock.withLock { drafts } }
    var questions: [(placeID: String, uid: String, date: Date)] { lock.withLock { asked } }

    func checkIn(_ draft: CheckinDraft) async throws {
        lock.withLock { drafts.append(draft) }
        try answer.get()
    }

    func hasCheckedIn(placeID: String, uid: String, on date: Date) async throws -> Bool {
        lock.withLock { asked.append((placeID, uid, date)) }
        return checkedIn.contains("\(placeID)/\(CheckinDraft.checkinID(uid: uid, on: date))")
    }
}

/// Checking in: a photo first, as the web sends it, then the place with the
/// photo's address and the person's words and pet, which are theirs to leave
/// out; and the server's day, which is UTC's.
@MainActor
@Suite struct CheckInTests {
    /// What `FakeUploader` answers for the first upload.
    private nonisolated static let firstUpload = "https://res.cloudinary.com/petnote/image/upload/v1/u/1.jpg"

    private func model(
        checker: FakeCheckins = FakeCheckins(), uploader: FakeUploader = FakeUploader(),
        pets: [Pet] = [], isEmailVerified: Bool = true
    ) -> CheckInModel {
        CheckInModel(
            placeID: "park", placeName: "Riverside Dog Park", uid: "me", isEmailVerified: isEmailVerified,
            checker: checker, uploader: uploader, pets: FixedPets(pets: pets)
        )
    }

    private func photo() -> Data { UploadTestImages.jpeg(width: 400, height: 300, quality: 0.5) }

    /// One place, and nothing under it.
    private struct OnePlace: PlacesReading {
        let place: Place
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { [place] }
        func search(prefix: String) async throws -> [Place] { [] }
        func places(applePlaceIDs ids: [String]) async throws -> [Place] { [] }
        func place(id: String) async throws -> Place? { id == place.id ? place : nil }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }

    @Test func thePhotoGoesFirstThenThePlaceWithTheWordsAndThePet() async throws {
        let checker = FakeCheckins()
        let uploader = FakeUploader()
        let model = model(checker: checker, uploader: uploader, pets: [PetFixture.pet(id: "pet-1", name: "Momo")])
        await model.loadPets()
        model.choosePhoto(data: photo(), filename: "c.jpg")
        model.caption = "  At the gate.  "
        model.toggle(petID: "pet-1")

        await model.submit()

        #expect(model.outcome == .checkedIn)
        #expect(uploader.sentItems.map(\.resourceType) == [.image])
        #expect(uploader.sentItems.first?.mimeType == "image/jpeg")
        let payload = try #require(checker.sent.first).payload
        #expect(payload["locationId"] as? String == "park")
        #expect(payload["photoUrl"] as? String == Self.firstUpload)
        #expect(payload["caption"] as? String == "At the gate.")
        #expect(payload["petId"] as? String == "pet-1")
        #expect(!model.canSubmit, "a check-in that went could be sent again")
    }

    @Test func noWordsAndNoPetAreLeftOut() async throws {
        let checker = FakeCheckins()
        let model = model(checker: checker)
        model.choosePhoto(data: photo(), filename: "c.jpg")
        model.caption = "   "

        await model.submit()

        let payload = try #require(checker.sent.first).payload
        #expect(payload["caption"] == nil)
        #expect(payload["petId"] == nil)
    }

    /// The web's rules: a photo, a verified email, and words within the
    /// server's limit.
    @Test func checkInIsOnOnlyWithAPhotoAVerifiedEmailAndWordsWithinTheLimit() {
        let model = model()
        #expect(!model.canSubmit, "a check-in without a photo")
        model.choosePhoto(data: photo(), filename: "c.jpg")
        #expect(model.canSubmit)
        model.caption = String(repeating: "a", count: CheckinDraft.maxCaption)
        #expect(model.canSubmit)
        model.caption += "a"
        #expect(!model.canSubmit, "a caption over the server's limit")

        let unverified = self.model(isEmailVerified: false)
        unverified.choosePhoto(data: photo(), filename: "c.jpg")
        #expect(!unverified.canSubmit, "the server checks in only a verified email")
    }

    @Test func aSecondTapTakesThePetBack() {
        let model = model()
        model.toggle(petID: "pet-1")
        #expect(model.petID == "pet-1")
        model.toggle(petID: "pet-2")
        #expect(model.petID == "pet-2")
        model.toggle(petID: "pet-2")
        #expect(model.petID == nil)
    }

    @Test func aPhotoThatDoesNotGoChecksNothingIn() async {
        let checker = FakeCheckins()
        let uploader = FakeUploader()
        uploader.fail(atSend: [1])
        let model = model(checker: checker, uploader: uploader)
        model.choosePhoto(data: photo(), filename: "c.jpg")

        await model.submit()

        #expect(model.outcome == .failed("The photo upload timed out. You were not checked in."))
        #expect(checker.sent.isEmpty)
        #expect(model.canSubmit, "a failed photo left Check In off")
    }

    /// Refused once the photo is up — here, a second check-in today: the
    /// server's words, and another try sends the same address without
    /// uploading the photo again.
    @Test func aRefusalSaysTheServersWordsAndTheNextTryKeepsThePhoto() async {
        let checker = FakeCheckins()
        checker.answer = .failure(NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.alreadyExists.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "You already checked in here today."]
        ))
        let uploader = FakeUploader()
        let model = model(checker: checker, uploader: uploader)
        model.choosePhoto(data: photo(), filename: "c.jpg")

        await model.submit()
        #expect(model.outcome == .failed("You already checked in here today."))
        checker.answer = .success(())
        await model.submit()

        #expect(model.outcome == .checkedIn)
        #expect(uploader.sendCount == 1)
        #expect(checker.sent.map(\.photoURL.absoluteString) == [Self.firstUpload, Self.firstUpload])
    }

    @Test func somethingChosenOrWrittenKeepsTheSheetOpen() {
        let model = model()
        #expect(!model.hasInput)
        model.caption = "Hi"
        #expect(model.hasInput)
        model.caption = ""
        model.choosePhoto(data: photo(), filename: "c.jpg")
        #expect(model.hasInput)
    }

    /// The server's day is UTC's: late in the evening in Boston is already
    /// tomorrow there.
    @Test func theDayIsTheServersUTCDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let lateEvening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 22, minute: 30)))

        #expect(CheckinDraft.dayKey(lateEvening) == "2026-10-02")
        #expect(CheckinDraft.checkinID(uid: "me", on: lateEvening) == "me_2026-10-02")
    }

    /// The place's page asks whether today's check-in is done, for the viewer
    /// and the server's day.
    @Test func thePlacesPageKnowsWhetherTodaysIsDone() async {
        let checker = FakeCheckins()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        checker.checkedIn = ["park/\(CheckinDraft.checkinID(uid: "me", on: now))"]
        let place = Place.decode(id: "park", ["name": "Riverside Dog Park", "category": "dog_park"])
        let page = PlaceDetailModel(
            placeID: "park", viewerID: "me", places: OnePlace(place: place),
            reviewer: PlacesMeetupsTests.FakeReviews(), checker: checker, meetups: PlacesMeetupsTests.FakeMeetups(),
            now: { now }
        )

        await page.load()

        #expect(page.hasCheckedInToday == true)
        #expect(checker.questions.map(\.uid) == ["me"])
    }
}
