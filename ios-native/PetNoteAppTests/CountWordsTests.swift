import Foundation
import Testing
@testable import PetNote

/// Counts in English that read right for one: "1 review", not the web's
/// "1 reviews". Chinese has no plural and keeps its own words for both;
/// `LocalizationTests.everyTranslationReachedTheApp` checks those.
@MainActor
@Suite struct CountWordsTests {
    private func place(ratings: Int, checkins: Int) -> Place {
        Place.decode(id: "p", [
            "name": "Riverside Dog Park", "averageRating": 5, "totalRatings": ratings, "totalCheckins": checkins,
        ])
    }

    @Test func aPlaceWithOneReviewOrOneCheckInSaysSo() {
        #expect(place(ratings: 1, checkins: 1).ratingLine == "5.0 (1 review)")
        #expect(place(ratings: 2, checkins: 2).ratingLine == "5.0 (2 reviews)")
        #expect(place(ratings: 0, checkins: 0).ratingLine == nil)
        #expect(place(ratings: 0, checkins: 1).checkinsLine == "1 check-in")
        #expect(place(ratings: 0, checkins: 2).checkinsLine == "2 check-ins")
        #expect(place(ratings: 0, checkins: 0).checkinsLine == nil)
    }

    @Test func aMeetupForOnePetOrOneFollowedPetSaysSo() {
        let one = MeetupRequirements.decode(["petType": "any", "maxPets": 1, "minFollowers": 1])
        let more = MeetupRequirements.decode(["petType": "any", "maxPets": 6, "minFollowers": 3])

        #expect(one.lines == ["Up to 1 pet.", "Requires at least 1 followed pet."])
        #expect(more.lines == ["Up to 6 pets.", "Requires at least 3 followed pets."])
    }

    @Test func whatIsReadOutSaysOneInTheSingular() {
        #expect(PlaceDetailView.photoCount(1) == "1 photo")
        #expect(PlaceDetailView.photoCount(3) == "3 photos")
        #expect(PostCard.likeCount(1) == "1 like")
        #expect(PostCard.likeCount(0) == "0 likes")
        #expect(PostDetailView.lengthLabel(remaining: 2) == "2 characters remaining")
        #expect(PostDetailView.lengthLabel(remaining: 1) == "1 character remaining")
        #expect(PostDetailView.lengthLabel(remaining: 0) == "0 characters remaining")
        #expect(PostDetailView.lengthLabel(remaining: -1) == "1 character too many")
        #expect(PostDetailView.lengthLabel(remaining: -3) == "3 characters too many")
        #expect(ReportModel.remainingLine(1) == "1 character left")
        #expect(ReportModel.remainingLine(12) == "12 characters left")
        #expect(ReportModel.remainingLine(-4) == "0 characters left")
    }
}
