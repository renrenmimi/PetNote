import FirebaseFirestore
import Foundation
import Testing

@testable import PetNote

/// Places and meetups: what a stored document becomes, the web's rules for
/// what is shown, and the detail screen's joining, leaving and cancelling.
@MainActor
struct PlacesMeetupsTests {
    // MARK: - Fakes

    final class FakeMeetups: MeetupsReading, @unchecked Sendable {
        var upcomingList: [Meetup] = []
        var weekList: [Meetup] = []
        var mineList: [Meetup] = []
        var stored: [String: Meetup] = [:]
        var participantList: [MeetupParticipant] = []
        var address: MeetupPlace?
        var joinAnswer: MeetupJoinOutcome = .joined
        var readError: Error?
        private(set) var weekFrom: Date?
        private(set) var mineFor: String?
        private(set) var joined: [(String, String?)] = []
        private(set) var left: [(String, String)] = []
        private(set) var cancelled: [String] = []
        private(set) var settled: [String] = []
        private(set) var addressReads = 0
        /// What `settle` turns the stored meetup into.
        var afterSettle: Meetup?

        func upcoming(limit: Int) async throws -> [Meetup] {
            if let readError { throw readError }
            return upcomingList
        }
        func thisWeek(from now: Date, limit: Int) async throws -> [Meetup] { weekFrom = now; return weekList }
        func mine(uid: String) async throws -> [Meetup] { mineFor = uid; return mineList }
        func atPlace(placeID: String, limit: Int) async throws -> [Meetup] { [] }
        func meetup(id: String) async throws -> Meetup? {
            if let readError { throw readError }
            return stored[id]
        }
        func participants(meetupID: String) async throws -> [MeetupParticipant] { participantList }
        func privateAddress(meetupID: String) async -> MeetupPlace? { addressReads += 1; return address }
        func join(meetupID: String, petID: String?) async throws -> MeetupJoinOutcome {
            joined.append((meetupID, petID))
            return joinAnswer
        }
        func leave(meetupID: String, uid: String) async throws { left.append((meetupID, uid)) }
        func cancel(meetupID: String) async throws { cancelled.append(meetupID) }
        func settle(meetupID: String) async throws {
            settled.append(meetupID)
            if let afterSettle { stored[meetupID] = afterSettle }
        }
    }

    final class NoPets: PetChoiceProviding, @unchecked Sendable {
        func pets(ownedBy uid: String) async throws -> [Pet] { [] }
    }

    private static func meetup(
        _ id: String = "m1", organizer: String = "u-org", date: Date? = Date().addingTimeInterval(3600),
        status: String = "upcoming", visibility: String? = "everyone", petType: String = "any", maxPets: Int = 0,
        count: Int = 1
    ) -> Meetup {
        var data: [String: Any] = [
            "organizerId": organizer, "organizerName": "Org", "title": "TEST \(id)",
            "duration": 60, "status": status, "participantCount": count,
            "location": ["name": "Park", "address": "1 Main St", "lat": 42.0, "lng": -71.0, "city": "Boston", "state": "MA"],
            "requirements": ["petType": petType, "maxPets": maxPets],
        ]
        if let date { data["date"] = Timestamp(date: date) }
        if let visibility { data["locationVisibility"] = visibility }
        return Meetup.decode(id: id, data)
    }

    private static func participant(_ uid: String) -> MeetupParticipant {
        MeetupParticipant.decode(id: uid, ["userId": uid, "userName": "P", "petName": "Rex"])
    }

    // MARK: - Places

    @Test func aStoredPlaceBecomesAPlace() {
        let place = Place.decode(id: "p1", [
            "name": "Riverside", "category": "dog_park", "lat": 42.36, "lng": -71.09,
            "averageRating": 4.5, "totalRatings": 2, "totalCheckins": 3, "verifiedByCheckins": true,
            "features": ["off_leash", "something_new"], "photos": ["https://example.test/a.jpg"],
        ])
        #expect(place.category == .dogPark)
        #expect(place.ratingLine == "4.5 (2 reviews)")
        #expect(place.totalCheckins == 3)
        #expect(place.verifiedByCheckins)
        #expect(place.features.map(Place.featureLabel) == ["Off-leash", "something new"], "an unknown feature was dropped")
        let directions = place.directionsURL?.absoluteString ?? ""
        #expect(directions.hasPrefix("https://maps.apple.com/"), "\(directions)")
        #expect(directions.contains("ll=42.36,-71.09"), "\(directions)")
    }

    @Test func anUnreviewedPlaceSaysSoAndOneWithoutCoordinatesHasNoDirections() {
        let place = Place.decode(id: "p2", ["name": "New", "category": "not_a_category"])
        #expect(place.ratingLine == nil)
        #expect(place.category == .other)
        #expect(place.directionsURL == nil)
    }

    /// The web offers no "Other" chip: choosing it showed every place.
    @Test func thereIsNoOtherFilter() {
        #expect(!PlaceCategory.filters.contains(.other))
        #expect(PlaceCategory.filters.count == 8)
    }

    // MARK: - Meetups as stored

    /// The web treats a meetup without a visibility as participants-only,
    /// and shows only its city in a list.
    @Test func aMeetupWithoutAVisibilityIsPrivate() {
        let meetup = Self.meetup(visibility: nil)
        #expect(meetup.isAddressPrivate)
        #expect(MeetupSummary.whereLine(meetup) == "Boston, MA")
        #expect(!MeetupSummary.whereLine(meetup).contains("Park"))
        let nowhere = Meetup.decode(id: "m", ["title": "x", "location": ["name": "Somewhere"]])
        #expect(MeetupSummary.whereLine(nowhere) == "City hidden")
    }

    @Test func theRequirementsAreTheServersRules() {
        let meetup = Self.meetup(petType: "any_dog", maxPets: 4)
        #expect(meetup.requirements.lines == ["Dogs only.", "Up to 4 pets."])
        #expect(MeetupSummary.countLine(meetup) == "1/4 pets")
        #expect(MeetupSummary.countLine(Self.meetup(count: 3)) == "3 going")
    }

    @Test func theFiltersFollowTheMeetupsPetType() {
        #expect(Self.meetup(petType: "dog").isFor(.dogs))
        #expect(Self.meetup(petType: "any_cat").isFor(.cats))
        #expect(!Self.meetup(petType: "any").isFor(.dogs))
        #expect(Self.meetup(petType: "other").isFor(.otherPets))
    }

    // MARK: - The list

    @Test func eachFilterAsksForItsOwnList() async {
        let source = FakeMeetups()
        source.upcomingList = [Self.meetup("dog", petType: "dog"), Self.meetup("cat", petType: "cat")]
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let model = MeetupsModel(uid: "me", source: source, now: { fixed })
        await model.load()
        #expect(model.items.map(\.id) == ["dog", "cat"])

        model.filter = .dogs
        await model.load()
        #expect(model.items.map(\.id) == ["dog"])

        model.filter = .thisWeek
        await model.load()
        #expect(source.weekFrom == fixed)

        model.filter = .mine
        await model.load()
        #expect(source.mineFor == "me")
    }

    @Test func aFailedFirstReadSaysSoRatherThanLookingEmpty() async {
        let source = FakeMeetups()
        source.readError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let model = MeetupsModel(uid: "me", source: source)
        await model.load()
        #expect(model.state == .failed("No connection. Check your network and try again."))
    }

    // MARK: - One meetup

    private func detail(_ source: FakeMeetups, viewer: String = "me", now: Date = Date()) -> MeetupDetailModel {
        MeetupDetailModel(meetupID: "m1", viewerID: viewer, source: source, pets: NoPets(), now: { now })
    }

    /// Past its end and still upcoming: the server is asked to settle it,
    /// and what it says is what is shown.
    @Test func anEndedMeetupIsSettledByTheServer() async {
        let source = FakeMeetups()
        source.stored["m1"] = Self.meetup(date: Date().addingTimeInterval(-3 * 3600))
        source.afterSettle = Self.meetup(date: Date().addingTimeInterval(-3 * 3600), status: "completed")
        let model = detail(source)
        await model.load()
        #expect(source.settled == ["m1"])
        #expect(model.meetup?.status == .completed)
        #expect(!model.canAct, "an ended meetup still offers actions")
    }

    @Test func aMeetupStillOnIsNotSettled() async {
        let source = FakeMeetups()
        source.stored["m1"] = Self.meetup()
        let model = detail(source)
        await model.load()
        #expect(source.settled.isEmpty)
    }

    /// The private address is read only by those the rules let read it —
    /// asking otherwise is a refused read on every open.
    @Test func thePrivateAddressIsReadOnlyByThoseAllowedIt() async {
        let source = FakeMeetups()
        source.stored["m1"] = Self.meetup(visibility: "participants_only")
        source.address = MeetupPlace.decode(["name": "Backyard", "address": "12 Elm St"])

        let stranger = detail(source)
        await stranger.load()
        #expect(source.addressReads == 0)
        #expect(stranger.shownPlace == nil)

        source.participantList = [Self.participant("me")]
        let joined = detail(source)
        await joined.load()
        #expect(source.addressReads == 1)
        #expect(joined.shownPlace?.address == "12 Elm St")

        source.participantList = []
        let organiser = detail(source, viewer: "u-org")
        await organiser.load()
        #expect(source.addressReads == 2)
    }

    @Test func aRefusedJoinSaysTheServersReasonAndChangesNothing() async {
        let source = FakeMeetups()
        source.stored["m1"] = Self.meetup(maxPets: 1)
        source.joinAnswer = .refused("Meetup is full.")
        let model = detail(source)
        await model.load()
        await model.join(petID: "pet-1")
        #expect(source.joined.map(\.1) == ["pet-1"])
        #expect(model.actionMessage == "Meetup is full.")
        #expect(!model.hasJoined)
    }

    @Test func leavingIsOnlyForAParticipantAndCancellingOnlyForTheOrganiser() async {
        let source = FakeMeetups()
        source.stored["m1"] = Self.meetup()
        let model = detail(source)
        await model.load()
        await model.leave()
        await model.cancel()
        #expect(source.left.isEmpty, "left a meetup it had not joined")
        #expect(source.cancelled.isEmpty, "a non-organiser cancelled")

        source.participantList = [Self.participant("me")]
        await model.load()
        await model.leave()
        #expect(source.left.map(\.1) == ["me"])

        let organiser = detail(source, viewer: "u-org")
        await organiser.load()
        await organiser.cancel()
        #expect(source.cancelled == ["m1"])
    }
}
