import FirebaseFunctions
import Foundation
import Testing
@testable import PetNote

/// A review's photos, the web's three at most: sent first, their addresses
/// with the review, each sent once however many times the review is tried.
@MainActor
@Suite struct ReviewPhotosTests {
    private func photo() -> Data { UploadTestImages.jpeg(width: 300, height: 200, quality: 0.5) }

    private func model(_ reviews: PlacesMeetupsTests.FakeReviews, uploader: FakeUploader) -> PlaceReviewModel {
        let model = PlaceReviewModel(placeID: "p1", placeName: "Park", source: reviews, uploader: uploader)
        model.draft.rating = 4
        return model
    }

    @Test func thePhotosGoFirstAndTheirAddressesWithTheReview() async throws {
        let reviews = PlacesMeetupsTests.FakeReviews()
        let uploader = FakeUploader()
        let model = model(reviews, uploader: uploader)
        model.photos.add(data: photo(), filename: "a.jpg")
        model.photos.add(data: photo(), filename: "b.jpg")

        await model.submit()

        #expect(model.outcome == .submitted)
        #expect(uploader.sentItems.map(\.resourceType) == [.image, .image])
        let payload = try #require(reviews.submitted.first).payload
        #expect((payload["photos"] as? [String])?.map { URL(string: $0)?.lastPathComponent } == ["1.jpg", "2.jpg"])
    }

    @Test func theWebsThreeAtMost() {
        let model = model(PlacesMeetupsTests.FakeReviews(), uploader: FakeUploader())
        for _ in 0..<4 { model.photos.add(data: photo(), filename: "a.jpg") }
        #expect(model.photos.items.count == 3 && model.photos.left == 0)
    }

    @Test func noPhotosSendAnEmptyList() async throws {
        let reviews = PlacesMeetupsTests.FakeReviews()
        let uploader = FakeUploader()
        let model = model(reviews, uploader: uploader)

        await model.submit()

        #expect(uploader.sendCount == 0)
        #expect((try #require(reviews.submitted.first).payload["photos"] as? [String]) == [])
    }

    @Test func aPhotoThatDoesNotGoSendsNoReview() async {
        let reviews = PlacesMeetupsTests.FakeReviews()
        let uploader = FakeUploader()
        uploader.fail(atSend: [1])
        let model = model(reviews, uploader: uploader)
        model.photos.add(data: photo(), filename: "a.jpg")

        await model.submit()

        #expect(model.outcome == .failed("The photo upload timed out. Your review was not sent."))
        #expect(reviews.submitted.isEmpty, "a review sent without the photo meant for it")
        #expect(model.canSubmit, "a failed photo left Submit Review off")
        model.photos.remove(model.photos.items[0].id)
        #expect(model.photos.items.isEmpty, "the photos stayed locked after the failure")
    }

    /// While the review is being sent, its photos stay as they are being
    /// sent.
    @Test(.timeLimit(.minutes(1))) func thePhotosStayAsTheyAreWhileTheReviewIsSent() async {
        let uploader = HeldUploader()
        let model = PlaceReviewModel(
            placeID: "p1", placeName: "Park", source: PlacesMeetupsTests.FakeReviews(), uploader: uploader
        )
        model.draft.rating = 4
        model.photos.add(data: photo(), filename: "a.jpg")
        let first = model.photos.items[0].id

        let sending = Task { await model.submit() }
        #expect(await eventuallyTrue { uploader.isHolding })
        model.photos.add(data: photo(), filename: "b.jpg")
        model.photos.remove(first)
        #expect(model.photos.items.map(\.id) == [first], "the photos changed while they were being sent")
        uploader.release()
        await sending.value
    }

    /// Refused once the photos are up — here, the server out for a moment:
    /// the next try sends the review with the same addresses and no photo
    /// again.
    @Test func aRefusedReviewIsTriedAgainWithThePhotosAlreadyUp() async throws {
        let reviews = PlacesMeetupsTests.FakeReviews()
        reviews.error = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.unavailable.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "Try again later."])
        let uploader = FakeUploader()
        let model = model(reviews, uploader: uploader)
        model.photos.add(data: photo(), filename: "a.jpg")
        await model.submit()
        reviews.error = nil

        await model.submit()

        #expect(model.outcome == .submitted)
        #expect(uploader.sendCount == 1)
        #expect(reviews.submitted.map { $0.photos.map(\.lastPathComponent) } == [["1.jpg"], ["1.jpg"]])
    }
}
