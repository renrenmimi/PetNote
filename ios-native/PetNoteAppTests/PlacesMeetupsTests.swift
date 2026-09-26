import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// Places and meetups: what a stored document becomes, the web's rules for
/// what is shown, and the detail screen's joining, leaving and cancelling.
@MainActor
struct PlacesMeetupsTests {
    // MARK: - Fakes

    /// Every record taken under the lock: changing the filter starts a read
    /// while another may still be running, so two calls can overlap.
    final class FakeMeetups: MeetupsReading, @unchecked Sendable {
        private let lock = NSLock()
        var upcomingList: [Meetup] = []
        var weekList: [Meetup] = []
        var mineList: [Meetup] = []
        var stored: [String: Meetup] = [:]
        var participantList: [MeetupParticipant] = []
        var address: MeetupPlace?
        var joinAnswer: MeetupJoinOutcome = .joined
        var readError: Error?
        /// What `settle` turns the stored meetup into.
        var afterSettle: Meetup?
        private var _weekFrom: Date?
        private var _mineFor: String?
        private var _joined: [(String, String?)] = []
        private var _left: [(String, String)] = []
        private var _cancelled: [String] = []
        private var _settled: [String] = []
        private var _addressReads = 0

        var weekFrom: Date? { lock.withLock { _weekFrom } }
        var mineFor: String? { lock.withLock { _mineFor } }
        var joined: [(String, String?)] { lock.withLock { _joined } }
        var left: [(String, String)] { lock.withLock { _left } }
        var cancelled: [String] { lock.withLock { _cancelled } }
        var settled: [String] { lock.withLock { _settled } }
        var addressReads: Int { lock.withLock { _addressReads } }

        func upcoming(limit: Int) async throws -> [Meetup] {
            if let readError { throw readError }
            return upcomingList
        }
        func thisWeek(from now: Date, limit: Int) async throws -> [Meetup] {
            lock.withLock { _weekFrom = now }
            return weekList
        }
        func mine(uid: String) async throws -> [Meetup] {
            lock.withLock { _mineFor = uid }
            return mineList
        }
        func atPlace(placeID: String, limit: Int) async throws -> [Meetup] { [] }
        func meetup(id: String) async throws -> Meetup? {
            if let readError { throw readError }
            return lock.withLock { stored[id] }
        }
        func participants(meetupID: String) async throws -> [MeetupParticipant] { participantList }
        func privateAddress(meetupID: String) async -> MeetupPlace? {
            lock.withLock { _addressReads += 1 }
            return address
        }
        func join(meetupID: String, petID: String?) async throws -> MeetupJoinOutcome {
            lock.withLock { _joined.append((meetupID, petID)) }
            return joinAnswer
        }
        func leave(meetupID: String, uid: String) async throws { lock.withLock { _left.append((meetupID, uid)) } }
        func cancel(meetupID: String) async throws { lock.withLock { _cancelled.append(meetupID) } }
        func settle(meetupID: String) async throws {
            lock.withLock {
                _settled.append(meetupID)
                if let afterSettle { stored[meetupID] = afterSettle }
            }
        }
    }

    final class NoPets: PetChoiceProviding, @unchecked Sendable {
        func pets(ownedBy uid: String) async throws -> [Pet] { [] }
    }

    private static func meetup(
        _ id: String = "m1", organizer: String = "u-org", date: Date? = Date().addingTimeInterval(3600),
        status: String = "upcoming", visibility: String? = "everyone", petType: String = "any", maxPets: Int = 0,
        count: Int = 1, ratingOpen: Bool = false, locationID: String? = nil
    ) -> Meetup {
        var data: [String: Any] = [
            "organizerId": organizer, "organizerName": "Org", "title": "TEST \(id)",
            "duration": 60, "status": status, "participantCount": count, "isRatingOpen": ratingOpen,
            "location": ["name": "Park", "address": "1 Main St", "lat": 42.0, "lng": -71.0, "city": "Boston", "state": "MA"],
            "requirements": ["petType": petType, "maxPets": maxPets],
        ]
        if let date { data["date"] = Timestamp(date: date) }
        if let visibility { data["locationVisibility"] = visibility }
        if let locationID { data["locationId"] = locationID }
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

    // MARK: - Reviews

    /// Records calls under a lock, and can hold a submission at the server
    /// so that a second tap really overlaps the first.
    final class FakeReviews: PlaceReviewing, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [PlaceReviewDraft] = []
        private var held: CheckedContinuation<Void, Never>?
        var holdNext = false
        var error: Error?
        var reviewed: Set<String> = []

        var submitted: [PlaceReviewDraft] { lock.withLock { calls } }
        var isHolding: Bool { lock.withLock { held != nil } }

        func submitReview(_ draft: PlaceReviewDraft) async throws {
            let hold = lock.withLock { () -> Bool in
                calls.append(draft)
                return holdNext
            }
            if hold {
                await withCheckedContinuation { continuation in
                    lock.withLock { held = continuation }
                }
            }
            if let error { throw error }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }

        func hasReviewed(placeID: String, uid: String, meetupID: String?) async throws -> Bool {
            lock.withLock { reviewed.contains(PlaceReviewDraft.reviewID(uid: uid, meetupID: meetupID)) }
        }
    }

    /// What goes to the server: the scores given, and only those — the
    /// server refuses a 0 and fills a missing score in with the rating.
    @Test func aReviewSendsOnlyTheScoresGiven() {
        var draft = PlaceReviewDraft(placeID: "p1", meetupID: nil)
        draft.rating = 4
        draft.comment = "  TEST CONTENT lovely  "
        #expect(draft.payload["petFriendly"] == nil)
        #expect(draft.payload["meetupId"] == nil)
        #expect(draft.payload["comment"] as? String == "TEST CONTENT lovely")
        #expect(draft.payload["rating"] as? Int == 4)

        draft.space = 5
        let friendly = draft.payload["petFriendly"] as? [String: Any]
        #expect(friendly?["space"] as? Int == 5)
        #expect(friendly?["safety"] == nil)

        let forMeetup = PlaceReviewDraft(placeID: "p1", meetupID: "m1")
        #expect(forMeetup.payload["meetupId"] as? String == "m1")
        #expect(PlaceReviewDraft.reviewID(uid: "u1", meetupID: "m1") == "u1_m1")
        #expect(PlaceReviewDraft.reviewID(uid: "u1", meetupID: nil) == "u1")
    }

    @Test func aReviewNeedsARatingAndAShortEnoughComment() {
        var draft = PlaceReviewDraft(placeID: "p1", meetupID: nil)
        #expect(!draft.canSubmit, "no overall rating")
        draft.rating = 3
        #expect(draft.canSubmit)
        draft.comment = String(repeating: "a", count: PlaceReviewDraft.maxComment + 1)
        #expect(!draft.canSubmit)
        // Counted as the web and the server count: an emoji is two.
        draft.comment = String(repeating: "🐕", count: PlaceReviewDraft.maxComment / 2)
        #expect(draft.canSubmit)
        draft.comment += "🐕"
        #expect(draft.comment.count == 151)
        #expect(!draft.canSubmit, "151 emoji are 302 UTF-16 units, over the server's 300")
    }

    /// A second tap while the first is still with the server sends nothing.
    @MainActor
    @Test func aSecondTapWhileSubmittingSendsNothing() async {
        let reviews = FakeReviews()
        reviews.holdNext = true
        let model = PlaceReviewModel(placeID: "p1", placeName: "Park", source: reviews)
        model.draft.rating = 5
        let first = Task { await model.submit() }
        #expect(await eventuallyTrue { reviews.isHolding }, "the first submission never reached the server")
        await model.submit()
        reviews.release()
        await first.value
        #expect(reviews.submitted.count == 1, "the review was sent twice")
        #expect(model.outcome == .submitted)
    }

    /// The server's own words for a refusal — "You have already reviewed
    /// this location." — are what the person reads.
    @MainActor
    @Test func aRefusedReviewSaysTheServersWords() async {
        let reviews = FakeReviews()
        reviews.error = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.alreadyExists.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "You have already reviewed this location."])
        let model = PlaceReviewModel(placeID: "p1", placeName: "Park", source: reviews)
        model.draft.rating = 2
        await model.submit()
        #expect(model.outcome == .failed("You have already reviewed this location."))
        #expect(model.canSubmit, "a refusal left the button disabled")
    }

    /// Rating a meetup's place: completed, rating open, someone who was
    /// there, not yet rated — the server's own conditions.
    @MainActor
    @Test func onlySomeoneWhoWasThereRatesACompletedMeetupOnce() async {
        let source = FakeMeetups()
        source.stored["m1"] = Self.meetup(date: Date().addingTimeInterval(-3 * 86_400), status: "completed",
                                          ratingOpen: true, locationID: "p1")
        let reviews = FakeReviews()

        let stranger = MeetupDetailModel(meetupID: "m1", viewerID: "me", source: source, pets: NoPets(), reviewer: reviews)
        await stranger.load()
        #expect(!stranger.canRate, "someone who was not there could rate")

        source.participantList = [Self.participant("me")]
        let there = MeetupDetailModel(meetupID: "m1", viewerID: "me", source: source, pets: NoPets(), reviewer: reviews)
        await there.load()
        #expect(there.canRate)

        reviews.reviewed = ["me_m1"]
        let rated = MeetupDetailModel(meetupID: "m1", viewerID: "me", source: source, pets: NoPets(), reviewer: reviews)
        await rated.load()
        #expect(!rated.canRate, "rated twice")
        #expect(rated.hasRated == true)

        source.stored["m1"] = Self.meetup(status: "upcoming", locationID: "p1")
        let notYet = MeetupDetailModel(meetupID: "m1", viewerID: "me", source: source, pets: NoPets(), reviewer: reviews)
        await notYet.load()
        #expect(!notYet.canRate, "an upcoming meetup offered rating")
    }

    // MARK: - The places list

    /// Records every read under a lock; a read can be held so that a newer
    /// choice overtakes it.
    final class FakePlaces: PlacesReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads: [(PlaceCategory?, PlaceSort, String?)] = []
        private var _searches: [String] = []
        private var held: CheckedContinuation<Void, Never>?
        var holdNextRead = false
        var pages: [[Place]] = [[]]
        var found: [Place] = []

        var reads: [(PlaceCategory?, PlaceSort, String?)] { lock.withLock { _reads } }
        var searches: [String] { lock.withLock { _searches } }
        var isHolding: Bool { lock.withLock { held != nil } }

        func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] {
            let (hold, index) = lock.withLock { () -> (Bool, Int) in
                _reads.append((category, sort, last))
                defer { holdNextRead = false }
                return (holdNextRead, min(_reads.filter { $0.2 != nil }.count, pages.count - 1))
            }
            if hold { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
            return last == nil ? pages[0] : pages[index]
        }
        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume()
        }
        func search(prefix: String) async throws -> [Place] {
            lock.withLock { _searches.append(prefix) }
            return found
        }
        func place(id: String) async throws -> Place? { nil }
        func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] { [] }
        func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] { [] }
    }

    private static func place(_ id: String) -> Place { Place.decode(id: id, ["name": "TEST \(id)", "category": "cafe"]) }

    @Test func aCategoryAndASortAreReadAsChosen() async {
        let source = FakePlaces()
        source.pages = [[Self.place("a")]]
        let model = PlacesModel(source: source)
        await model.load()
        #expect(source.reads.last?.0 == nil)
        #expect(source.reads.last?.1 == .newest, "the default is not the web's (newest without a location)")

        model.category = .dogPark
        #expect(await eventuallyTrue { source.reads.contains { $0.0 == .dogPark } })
        model.sort = .topRated
        #expect(await eventuallyTrue { source.reads.contains { $0.0 == .dogPark && $0.1 == .topRated } })
    }

    @Test func aNameSearchReplacesTheListAndClearingItComesBack() async {
        let source = FakePlaces()
        source.pages = [[Self.place("listed")]]
        source.found = [Self.place("found")]
        let model = PlacesModel(source: source)
        await model.load()
        model.search("  Riv ")
        #expect(await eventuallyTrue { model.items.map(\.id) == ["found"] })
        #expect(source.searches == ["Riv"], "the search text was not trimmed")
        #expect(!model.hasMore, "a search result offered more pages")
        model.search("")
        #expect(await eventuallyTrue { model.items.map(\.id) == ["listed"] })
    }

    /// A slow answer for the old choice must not replace the new choice's.
    @Test func aSlowOldAnswerDoesNotOverwriteANewerChoice() async {
        let source = FakePlaces()
        source.pages = [[Self.place("any")]]
        let model = PlacesModel(source: source)
        await model.load()
        source.holdNextRead = true
        model.category = .beach
        #expect(await eventuallyTrue { source.isHolding }, "the first read never reached the source")
        source.pages = [[Self.place("vet")]]
        model.category = .vet
        #expect(await eventuallyTrue { model.items.map(\.id) == ["vet"] })
        source.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.items.map(\.id) == ["vet"], "the held answer for beaches replaced the vets")
    }

    @Test func aFullPageMeansMoreAndTheNextPageStartsAfterTheLast() async {
        let source = FakePlaces()
        source.pages = [(0..<PlacesModel.pageSize).map { Self.place("p\($0)") }, [Self.place("tail")]]
        let model = PlacesModel(source: source)
        await model.load()
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.items.count == PlacesModel.pageSize + 1)
        #expect(source.reads.last?.2 == "p\(PlacesModel.pageSize - 1)")
        #expect(!model.hasMore)
    }
}
