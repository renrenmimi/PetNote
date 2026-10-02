import FirebaseFunctions
import Foundation
import Testing
@testable import PetNote

/// Adding a place found on Apple Maps: what goes to the server (Apple's
/// identifier and our own words, nothing of Apple's), what a search shows for
/// places someone added already, and what is said when the server answers.
@MainActor
@Suite struct AddPlaceTests {
    private nonisolated static let run = PlaceDetails(
        name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095
    )
    private nonisolated static let shop = PlaceDetails(
        name: "Corner Pet Shop", address: "20 Elm St, Somerville, MA", latitude: 42.3967, longitude: -71.122
    )
    private nonisolated static let found = [
        PlaceSearchHit(applePlaceID: "I1", details: run), PlaceSearchHit(applePlaceID: "I2", details: shop),
    ]

    /// Apple Maps answering every search with the same places, or not at
    /// all. A held search waits for `release()`; the ones after it do not.
    private final class Directory: PlaceDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private let hits: [[PlaceSearchHit]]
        private let fails: Bool
        private var asked = 0
        private var held: CheckedContinuation<Void, Never>?
        private let holdFirst: Bool

        init(_ hits: [[PlaceSearchHit]] = [AddPlaceTests.found], fails: Bool = false, holdFirst: Bool = false) {
            self.hits = hits
            self.fails = fails
            self.holdFirst = holdFirst
        }

        var isHolding: Bool { lock.withLock { held != nil } }

        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { nil }
        func locate(address: String) async throws -> PlaceDetails? { nil }
        func search(_ text: String) async throws -> [PlaceSearchHit] {
            let turn = lock.withLock { () -> Int in
                defer { asked += 1 }
                return asked
            }
            if turn == 0, holdFirst {
                await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
            }
            if fails { throw URLError(.notConnectedToInternet) }
            return hits[min(turn, hits.count - 1)]
        }
        func forget() async {}

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }
    }

    /// Our places: the run has been added, the shop has not.
    private struct Places: PlacesReading {
        var added = [Place.decode(id: "apple_I1", ["applePlaceId": "I1", "category": "dog_park"])]
        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] { [] }
        func search(prefix: String) async throws -> [Place] { [] }
        func places(applePlaceIDs ids: [String]) async throws -> [Place] {
            added.filter { $0.applePlaceID.map(ids.contains) ?? false }
        }
        func place(id: String) async throws -> Place? { nil }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }

    /// The server: keeps every draft it is sent, and gives the set answer.
    private final class Adder: PlaceAdding, @unchecked Sendable {
        private let lock = NSLock()
        private var drafts: [ApplePlaceDraft] = []
        var answer: Result<AddedPlace, Error> = .success(AddedPlace(placeID: "apple_I2", alreadyExisted: false))

        var sent: [ApplePlaceDraft] { lock.withLock { drafts } }

        func addPlace(_ draft: ApplePlaceDraft) async throws -> AddedPlace {
            lock.withLock { drafts.append(draft) }
            return try answer.get()
        }
    }

    private func found(_ model: AddPlaceModel) -> [ApplePlaceFinder.Found] {
        if case .found(let found) = model.finder.state { return found }
        return []
    }

    /// The shop chosen and described, ready to add.
    private func shopReady(
        adder: Adder = Adder(), reviewer: PlacesMeetupsTests.FakeReviews = PlacesMeetupsTests.FakeReviews(),
        uploader: any MediaUploading = FakeUploader()
    ) async -> AddPlaceModel {
        let model = AddPlaceModel(query: "pet", places: Places(), adder: adder, reviewer: reviewer, uploader: uploader, directory: Directory())
        await model.finder.search()
        if let shop = found(model).first(where: { $0.id == "I2" }) { model.choose(shop) }
        model.description = "Treats at the counter."
        return model
    }

    @Test func aSearchMarksThePlacesSomeoneHasAddedAlready() async {
        let model = AddPlaceModel(query: "  pet  ", places: Places(), adder: Adder(), reviewer: PlacesMeetupsTests.FakeReviews(), uploader: FakeUploader(), directory: Directory())

        await model.finder.search()

        #expect(found(model).map(\.id) == ["I1", "I2"])
        #expect(found(model).map(\.placeID) == ["apple_I1", nil])
    }

    @Test func aPlaceSomeoneAddedAlreadyIsNotChosenToBeAddedAgain() async {
        let model = AddPlaceModel(query: "pet", places: Places(), adder: Adder(), reviewer: PlacesMeetupsTests.FakeReviews(), uploader: FakeUploader(), directory: Directory())
        await model.finder.search()

        model.choose(found(model)[0])
        #expect(model.chosen == nil)
        model.choose(found(model)[1])
        #expect(model.chosen?.applePlaceID == "I2")
    }

    /// Apple's terms let a place keep the identifier and nothing else of
    /// Apple's, and the server refuses a name, an address or a position.
    @Test func whatIsSentIsTheIdentifierAndOurOwnWordsOnly() async throws {
        let adder = Adder()
        let model = await shopReady(adder: adder)
        model.category = .petStore
        model.description = "  Treats at the counter.  "
        for feature in ["parking", "off_leash", "shade", "shade"] { model.toggle(feature: feature) }

        await model.save()

        #expect(model.outcome == .added(AddedPlace(placeID: "apple_I2", alreadyExisted: false), rated: false))
        let payload = try #require(adder.sent.first).payload
        #expect(Set(payload.keys) == ["applePlaceId", "category", "description", "features"])
        #expect(payload["applePlaceId"] as? String == "I2")
        #expect(payload["category"] as? String == "pet_store")
        #expect(payload["description"] as? String == "Treats at the counter.")
        #expect(payload["features"] as? [String] == ["off_leash", "parking"], "in the web's order, once each")
    }

    @Test func aPlaceNeedsAChosenPlaceAndADescriptionOfAtMost500() async {
        let empty = AddPlaceModel(query: "pet", places: Places(), adder: Adder(), reviewer: PlacesMeetupsTests.FakeReviews(), uploader: FakeUploader(), directory: Directory())
        empty.description = "Shady."
        #expect(!empty.canSave, "nothing chosen")

        let model = await shopReady()
        #expect(model.canSave)
        model.description = "   "
        #expect(!model.canSave, "only spaces")
        model.description = String(repeating: "a", count: 500)
        #expect(model.canSave)
        model.description = String(repeating: "🐶", count: 251)
        #expect(!model.canSave, "502 as the server counts, over its 500")
    }

    @Test func aRefusalSaysTheServersWordsAndLeavesTheFormAsItWas() async {
        let adder = Adder()
        adder.answer = .failure(NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Verify your email before creating places."]
        ))
        let model = await shopReady(adder: adder)

        await model.save()

        #expect(model.outcome == .failed("Verify your email before creating places."))
        #expect(model.chosen?.applePlaceID == "I2" && model.description == "Treats at the counter.")
        #expect(model.canSave, "a refusal left the button disabled")
    }

    @Test func aPlaceAddedByAnotherInTheMeantimeIsSaidToBeThere() async {
        let adder = Adder()
        adder.answer = .success(AddedPlace(placeID: "apple_I2", alreadyExisted: true))
        let model = await shopReady(adder: adder)

        await model.save()

        #expect(model.outcome == .added(AddedPlace(placeID: "apple_I2", alreadyExisted: true), rated: false))
        #expect(!model.canSave, "added, if not by this person: nothing more to send")
    }

    /// The web's order: the place, then the rating as a review of it, with
    /// only the scores given (the server fills the rest in with the rating).
    @Test func aRatingGoesAsAReviewOfThePlaceJustAdded() async throws {
        let reviewer = PlacesMeetupsTests.FakeReviews()
        let model = await shopReady(reviewer: reviewer)
        model.rating = 4
        model.space = 5

        await model.save()

        #expect(model.outcome == .added(AddedPlace(placeID: "apple_I2", alreadyExisted: false), rated: true))
        let review = try #require(reviewer.submitted.first)
        #expect(review.placeID == "apple_I2" && review.meetupID == nil)
        #expect(review.rating == 4 && review.space == 5 && review.safety == 0 && review.cleanliness == 0)
    }

    @Test func aRatingGoesToAPlaceSomeoneElseAddedMeanwhile() async {
        let adder = Adder()
        adder.answer = .success(AddedPlace(placeID: "apple_I2", alreadyExisted: true))
        let reviewer = PlacesMeetupsTests.FakeReviews()
        let model = await shopReady(adder: adder, reviewer: reviewer)
        model.rating = 5

        await model.save()

        #expect(model.outcome == .added(AddedPlace(placeID: "apple_I2", alreadyExisted: true), rated: true))
        #expect(reviewer.submitted.map(\.placeID) == ["apple_I2"])
    }

    @Test func aRefusedRatingLeavesThePlaceAddedAndSaysWhy() async {
        let reviewer = PlacesMeetupsTests.FakeReviews()
        // A place someone added meanwhile, which this person had reviewed.
        reviewer.error = NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.alreadyExists.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "You have already reviewed this location."]
        )
        let model = await shopReady(reviewer: reviewer)
        model.rating = 3

        await model.save()

        #expect(model.outcome == .notRated(AddedPlace(placeID: "apple_I2", alreadyExisted: false), "You have already reviewed this location."))
        #expect(!model.canSave, "the place is in: nothing more to add")
    }

    @Test func noRatingSendsNoReviewAndAPlaceRefusedSendsNoRating() async {
        let reviewer = PlacesMeetupsTests.FakeReviews()
        let unrated = await shopReady(reviewer: reviewer)
        await unrated.save()
        #expect(reviewer.submitted.isEmpty, "a review without a rating")

        let adder = Adder()
        adder.answer = .failure(URLError(.notConnectedToInternet))
        let refused = await shopReady(adder: adder, reviewer: reviewer)
        refused.rating = 4
        await refused.save()
        #expect(reviewer.submitted.isEmpty, "a rating for a place that was not added")
    }

    /// The web's order: the photos first, each prepared as the composer
    /// prepares one, then the place with their addresses.
    @Test func thePhotosGoFirstAndTheirAddressesWithThePlace() async throws {
        let adder = Adder()
        let uploader = FakeUploader()
        let model = await shopReady(adder: adder, uploader: uploader)
        model.photos.add(data: UploadTestImages.jpeg(width: 400, height: 300, quality: 0.5), filename: "a.jpg")
        model.photos.add(data: UploadTestImages.jpeg(width: 300, height: 400, quality: 0.5), filename: "b.jpg")

        await model.save()

        #expect(uploader.sentItems.map(\.resourceType) == [.image, .image])
        #expect(uploader.sentItems.allSatisfy { $0.mimeType == "image/jpeg" })
        let draft = try #require(adder.sent.first)
        #expect(draft.photos.map(\.lastPathComponent) == ["1.jpg", "2.jpg"], "in the order picked")
        #expect((draft.payload["photos"] as? [String])?.allSatisfy { $0.hasPrefix("https://res.cloudinary.com/") } == true)
    }

    @Test func aPhotoThatDoesNotGoAddsNothing() async {
        let adder = Adder()
        let uploader = FakeUploader()
        uploader.fail(atSend: [2])
        let model = await shopReady(adder: adder, uploader: uploader)
        model.photos.add(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "a.jpg")
        model.photos.add(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "b.jpg")

        await model.save()

        #expect(model.outcome == .failed("The photo upload timed out. The place was not added."))
        #expect(adder.sent.isEmpty, "a place added without a photo meant for it")
        #expect(model.canSave, "a failed photo left Submit off")
        model.photos.remove(model.photos.items[1].id)
        #expect(model.photos.items.count == 1, "the photos stayed locked after the failure")
    }

    /// While the place is being added, its photos stay as they are being sent.
    @Test(.timeLimit(.minutes(1))) func thePhotosStayAsTheyAreWhileThePlaceIsAdded() async {
        let uploader = HeldUploader()
        let model = await shopReady(uploader: uploader)
        model.photos.add(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "a.jpg")

        let first = model.photos.items[0].id

        let saving = Task { await model.save() }
        #expect(await eventuallyTrue { uploader.isHolding })
        model.photos.add(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "b.jpg")
        model.photos.remove(first)
        #expect(model.photos.items.map(\.id) == [first], "the photos changed while they were being sent")
        uploader.release()
        await saving.value
    }

    /// Sharp in its square on a phone: a 4:3 photo's short side at three
    /// pixels a point.
    @Test func aPickedPhotosThumbnailCoversItsSquare() async throws {
        let model = await shopReady()
        model.photos.add(data: UploadTestImages.jpeg(width: 1200, height: 900, quality: 0.5), filename: "a.jpg")

        let thumbnail = try #require(model.photos.items.first?.thumbnail)
        #expect(min(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale >= 264, "\(thumbnail.size)")
    }

    /// Refused once the photos are up: the next try adds the place with the
    /// same addresses and sends no photo again.
    @Test func aRefusedPlaceIsTriedAgainWithThePhotosAlreadyUp() async throws {
        let adder = Adder()
        adder.answer = .failure(NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.resourceExhausted.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Too many requests."]
        ))
        let uploader = FakeUploader()
        let model = await shopReady(adder: adder, uploader: uploader)
        model.photos.add(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "a.jpg")
        model.photos.add(data: UploadTestImages.jpeg(width: 200, height: 200, quality: 0.5), filename: "b.jpg")
        await model.save()
        adder.answer = .success(AddedPlace(placeID: "apple_I2", alreadyExisted: false))

        await model.save()

        #expect(uploader.sendCount == 2)
        #expect(adder.sent.map { $0.photos.map(\.lastPathComponent) } == [["1.jpg", "2.jpg"], ["1.jpg", "2.jpg"]])
    }

    @Test func atMostFivePhotos() async {
        let model = await shopReady()
        for index in 0..<6 {
            model.photos.add(data: UploadTestImages.jpeg(width: 100, height: 100, quality: 0.5), filename: "\(index).jpg")
        }
        #expect(model.photos.items.count == 5 && model.photos.left == 0)

        model.photos.remove(model.photos.items[0].id)
        #expect(model.photos.items.count == 4 && model.photos.left == 1)
    }

    @Test func noPhotosNoUploads() async throws {
        let adder = Adder()
        let uploader = FakeUploader()
        let model = await shopReady(adder: adder, uploader: uploader)

        await model.save()

        #expect(uploader.sendCount == 0)
        #expect(try #require(adder.sent.first).payload["photos"] == nil)
    }

    @Test func aSearchAppleCannotAnswerSaysSo() async {
        let model = AddPlaceModel(query: "pet", places: Places(), adder: Adder(), reviewer: PlacesMeetupsTests.FakeReviews(), uploader: FakeUploader(), directory: Directory(fails: true))

        await model.finder.search()

        #expect(model.finder.state == .failed(String(localized: "Couldn't search Apple Maps. Try again.")))
    }

    /// A slow answer to the first search must not replace the second's.
    @Test func anOlderSearchDoesNotReplaceANewerOne() async {
        let directory = Directory([[PlaceSearchHit(applePlaceID: "I1", details: Self.run)], [PlaceSearchHit(applePlaceID: "I2", details: Self.shop)]], holdFirst: true)
        let model = AddPlaceModel(query: "dog run", places: Places(), adder: Adder(), reviewer: PlacesMeetupsTests.FakeReviews(), uploader: FakeUploader(), directory: directory)

        let first = Task { await model.finder.search() }
        #expect(await eventuallyTrue { directory.isHolding })
        model.finder.query = "pet shop"
        await model.finder.search()
        directory.release()
        await first.value

        #expect(found(model).map(\.id) == ["I2"])
    }
}
