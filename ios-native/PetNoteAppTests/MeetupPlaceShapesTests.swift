import Foundation
import Testing
@testable import PetNote

/// Where a meetup is comes in three shapes (functions/src/meetups.ts): the
/// web's name, address and position; a place from Apple Maps by its
/// identifier only; an address the organiser typed. A participants_only
/// meetup's public copy has only the area it is near. These pin how each is
/// read and what a list row and the meetup say about it.
@MainActor
@Suite struct MeetupPlaceShapesTests {
    private static let dogRun = PlaceDetails(
        name: "Fenway Dog Run", address: "1 Park Dr, Boston, MA", latitude: 42.3434, longitude: -71.095
    )

    /// Apple Maps as a table, for places and for typed addresses.
    private struct Directory: PlaceDirectory {
        var places: [String: PlaceDetails] = [:]
        var addresses: [String: PlaceDetails] = [:]
        func details(forApplePlaceID id: String) async throws -> PlaceDetails? { places[id] }
        func locate(address: String) async throws -> PlaceDetails? { addresses[address] }
        func search(_ text: String) async throws -> [PlaceSearchHit] { [] }
        func forget() async {}
    }

    private func meetup(_ location: [String: Any], visibility: String) -> Meetup {
        Meetup.decode(id: "m1", [
            "title": "Morning walk", "organizerId": "o1", "status": "upcoming",
            "location": location, "locationVisibility": visibility,
        ])
    }

    @Test func eachShapeIsReadAsItself() {
        let web = MeetupPlace.decode(["name": "Riverside Dog Park", "address": "1 River St", "lat": 42.36, "lng": -71.09])
        let apple = MeetupPlace.decode(["applePlaceId": "I1"])
        let typed = MeetupPlace.decode(["address": "12 Elm St, Somerville, MA", "label": "Alex's backyard"])
        let hidden = MeetupPlace.decode(["name": "Meetup near Somerville", "area": "Somerville"])

        #expect(web.shape == .stored)
        #expect(apple.shape == .apple("I1"))
        #expect(typed.shape == .typed)
        #expect(typed.storedDetails.name == "Alex's backyard")
        #expect(hidden.shape == .stored)
        #expect(hidden.cityLine == "Somerville", "the organiser's area stands for the city")
    }

    @Test func aPrivateMeetupsRowShowsTheAreaItsOrganiserNamedAndNothingElse() {
        let row = meetup(["name": "Meetup near Somerville", "area": "Somerville"], visibility: "participants_only")
        let unnamed = meetup(["name": "Private meetup", "area": ""], visibility: "participants_only")

        #expect(MeetupSummary.whereLine(row, lookups: PlaceLookups(directory: Directory())) == "Somerville")
        #expect(MeetupSummary.whereLine(unnamed, lookups: PlaceLookups(directory: Directory())) == String(localized: "City hidden"))
    }

    @Test func aPublicMeetupAtAPlaceFromAppleMapsIsNamedByApple() async {
        let lookups = PlaceLookups(directory: Directory(places: ["I1": Self.dogRun]))
        let row = meetup(["applePlaceId": "I1"], visibility: "everyone")

        #expect(MeetupSummary.whereLine(row, lookups: lookups) == String(localized: "Loading…"))
        await lookups.lookUp(meetupPlaces: [row.place])
        #expect(MeetupSummary.whereLine(row, lookups: lookups) == "Fenway Dog Run")
    }

    @Test func aTypedAddressShowsTheOrganisersWordsAtOnceAndGoesOnTheMapOnceFound() async {
        let located = PlaceDetails(name: "12 Elm St", address: "12 Elm St, Somerville, MA 02144", latitude: 42.3876, longitude: -71.0995)
        let lookups = PlaceLookups(directory: Directory(addresses: ["12 Elm St, Somerville, MA": located]))
        let row = meetup(["address": "12 Elm St, Somerville, MA", "label": "Alex's backyard"], visibility: "everyone")

        #expect(MeetupSummary.whereLine(row, lookups: lookups) == "Alex's backyard")
        #expect(lookups.shown(row.place) == .found(PlaceDetails(
            name: "Alex's backyard", address: "12 Elm St, Somerville, MA", latitude: 0, longitude: 0
        )), "no position yet, so no map, but the words are there")

        await lookups.lookUp(meetupPlaces: [row.place])
        guard case .found(let shown) = lookups.shown(row.place) else {
            Issue.record("a typed address should always have something to show")
            return
        }
        #expect(shown.name == "Alex's backyard")
        #expect(shown.address == "12 Elm St, Somerville, MA", "the organiser's words, not Apple's")
        #expect(shown.latitude == 42.3876 && shown.directionsURL != nil)
    }

    /// The meetup's own page comes in while Apple is asked where it is: the
    /// pets to join with and the rating button wait only for the server.
    @Test func aSlowAppleHoldsUpOnlyWhereTheMeetupIs() async throws {
        let directory = PlaceLookupsTests.SlowDirectory(["I1": Self.dogRun])
        let source = PlacesMeetupsTests.FakeMeetups()
        source.stored = ["m1": Meetup.decode(id: "m1", [
            "title": "Morning walk", "organizerId": "o1", "status": "completed",
            "location": ["applePlaceId": "I1"], "locationVisibility": "everyone", "locationId": "apple_I1",
        ])]
        let model = MeetupDetailModel(
            meetupID: "m1", viewerID: "me", source: source, pets: PlacesMeetupsTests.NoPets(),
            reviewer: PlacesMeetupsTests.FakeReviews(), lookups: PlaceLookups(directory: directory)
        )

        let loading = Task { await model.load() }
        #expect(await eventuallyTrue { directory.isAsked })
        #expect(await eventuallyTrue { model.hasRated == false }, "the rest of the meetup waited for Apple")
        let place = try #require(model.shownPlace)
        #expect(model.lookups.shown(place) == .looking)

        directory.answer()
        await loading.value
        #expect(model.lookups.name(of: place) == "Fenway Dog Run")
    }

    @Test func aTypedAddressAppleCannotFindIsStillShownInTheOrganisersWords() async {
        let lookups = PlaceLookups(directory: Directory())
        let row = meetup(["address": "Behind the old mill", "label": ""], visibility: "everyone")

        await lookups.lookUp(meetupPlaces: [row.place])

        #expect(MeetupSummary.whereLine(row, lookups: lookups) == "Behind the old mill")
        #expect(lookups.shown(row.place) == .found(PlaceDetails(
            name: "Behind the old mill", address: "Behind the old mill", latitude: 0, longitude: 0
        )))
    }
}
