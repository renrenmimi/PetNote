import XCTest

/// Places and meetups through the screens, against the emulator's seeded
/// places and meetups (`seed-ios-native.mjs`, `seedGatherings`).
///
/// Joining, leaving and cancelling run the real server code — the callables
/// and the participant trigger — and each is read back from the server, not
/// from what the screen says. So do settling a meetup that is over and the
/// two meetup notifications, which are the server's triggers' own writes.
final class PlacesMeetupsUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var uid: String?
    /// The second account, in the test that needs two.
    private var otherUID: String?
    private var cleanup: [String] = []
    /// Accounts whose notifications to remove: the meetup triggers write
    /// them under ids of their own, so they are found by recipient.
    private var inboxes: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for path in cleanup.reversed() { JourneyAdmin.deleteDocument(path: path) }
        for inbox in inboxes {
            for name in (try? JourneyAdmin.documentNames(in: "notifications", field: "userId", equals: inbox)) ?? [] {
                EmulatorAdmin.deleteComment(documentName: name)
            }
        }
        for account in [uid, otherUID].compactMap({ $0 }) { JourneyAdmin.removeProfile(uid: account) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    private func landmark(_ key: String) throws -> String {
        try XCTUnwrap(try EmulatorAdmin.seedManifest().post(key), "the seed has no \(key); reseed the emulator")
    }

    // MARK: - Places

    func testThePlacesListAPlaceAndAMeetupHeldThere() throws {
        let park = try landmark("place_reviewed")
        let cafe = try landmark("place_quiet")
        let soon = try landmark("meetup_soon")
        let (app, me) = try signInAsNewAccount("places-\(run)@petnote.test")
        uid = me

        app.tabBars.buttons["Places"].tap()
        let parkRow = app.buttons["place.\(park)"]
        XCTAssertTrue(waitForExistence(of: parkRow, in: app, timeout: 30), "the seeded park is not listed\n\(app.debugDescription)")
        // The numbers are the triggers', read back from the server.
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "locations/\(park)"))
        XCTAssertEqual(Self.number(stored["totalRatings"]), 2)
        XCTAssertTrue(parkRow.label.contains("4.5 (2 reviews)"), parkRow.label)
        XCTAssertTrue(parkRow.label.contains("2 check-ins"), parkRow.label)

        // A category narrows the list to it. Dog Parks, because it is on
        // screen: Cafés is fifth in a row that scrolls sideways.
        XCTAssertTrue(app.buttons["place.\(cafe)"].exists)
        app.buttons["places.category.dog_park"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["place.\(cafe)"], timeout: 10), "the café is still listed under Dog Parks")
        XCTAssertTrue(parkRow.exists)
        app.buttons["places.category.all"].tap()
        XCTAssertTrue(waitUntilHittable(parkRow, in: app, timeout: 20))

        // The place: what it is, its reviews and check-ins, and its meetups.
        parkRow.tap()
        let name = app.staticTexts["place.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 20), "the place did not open\n\(app.debugDescription)")
        XCTAssertEqual(name.label, JourneyAdmin.string(stored["name"]))
        XCTAssertEqual(app.staticTexts["place.rating"].label, "⭐ 4.5 (2 reviews)")
        XCTAssertTrue(app.links["place.directions"].exists || app.buttons["place.directions"].exists, "no directions")
        let reviews = app.descendants(matching: .any).matching(identifier: "place.review")
        XCTAssertTrue(waitForExistence(of: reviews.firstMatch, in: app, timeout: 20))
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "place.checkin").count, 2)

        let meetupRow = app.buttons["place.meetup.\(soon)"]
        for _ in 0..<6 where !(meetupRow.exists && meetupRow.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(meetupRow, in: app, timeout: 10), "the meetup held there is not shown\n\(app.debugDescription)")
        meetupRow.tap()
        let title = app.staticTexts["meetupDetail.title"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 20))
        let meetup = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(soon)"))
        XCTAssertEqual(title.label, JourneyAdmin.string(meetup["title"]))
    }

    /// Each sort puts the seeded places in the order the server's numbers
    /// give — newest by `createdAt`, top rated by average and then count,
    /// most reviewed by count — read from the server, not written down here.
    /// The seed makes the three orders differ, so a sort that read the wrong
    /// field, or the wrong way round, puts them in the wrong order. Only the
    /// seeded three are compared: anything else in the emulator may stand
    /// between them.
    func testEachSortOrdersThePlacesByTheServersNumbers() throws {
        let places = try seededPlaces()
        let newest = places.sorted { $0.created > $1.created }.map { $0.id }
        let topRated = places.sorted { ($0.average, $0.reviews) > ($1.average, $1.reviews) }.map { $0.id }
        let mostReviewed = places.sorted { $0.reviews > $1.reviews }.map { $0.id }
        // No ties, and three different orders — or this test could not fail.
        let dates = Set(places.map { $0.created }).count
        let averages = Set(places.map { $0.average }).count
        let counts = Set(places.map { $0.reviews }).count
        let orders = Set([newest, topRated, mostReviewed]).count
        XCTAssertTrue(
            dates == places.count && averages == places.count && counts == places.count && orders == 3,
            "the seeded places cannot tell the sorts apart; reseed with the current seed-ios-native.mjs\n\(describe(places))"
        )
        let (app, me) = try signInAsNewAccount("sorts-\(run)@petnote.test")
        uid = me

        app.tabBars.buttons["Places"].tap()
        let menu = app.buttons["places.sort"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 30), "no sort control\n\(app.debugDescription)")
        XCTAssertEqual(menu.value as? String, "Newest", "the list does not start on the web's default")
        assertShown(newest, of: places, in: app, sortedBy: "Newest", timeout: 30)

        chooseSort("Top Rated", identifier: "places.sort.topRated", in: app)
        assertShown(topRated, of: places, in: app, sortedBy: "Top Rated")
        chooseSort("Most Reviewed", identifier: "places.sort.mostReviewed", in: app)
        assertShown(mostReviewed, of: places, in: app, sortedBy: "Most Reviewed")
        chooseSort("Newest", identifier: "places.sort.newest", in: app)
        assertShown(newest, of: places, in: app, sortedBy: "Newest, chosen again")
    }

    /// A name search is a prefix of the name, as the web's: the places whose
    /// names start with what was typed, and no others; clearing it brings the
    /// list back.
    func testSearchingPlacesByTheStartOfTheirNameAndClearingIt() throws {
        let places = try seededPlaces()
        // Every seeded name starts "TEST CONTENT "; "Hi" then picks the trail
        // and leaves out the café, whose name also goes on with an H. A whole
        // word last, so the keyboard has nothing to autocorrect.
        let prefix = "TEST CONTENT Hi"
        let found = places.filter { $0.name.hasPrefix(prefix) }
        let left = places.filter { !$0.name.hasPrefix(prefix) }
        XCTAssertTrue(!found.isEmpty && !left.isEmpty,
                      "the seeded names no longer split on \"\(prefix)\"; reseed\n\(describe(places))")
        let (app, me) = try signInAsNewAccount("placesearch-\(run)@petnote.test")
        uid = me

        app.tabBars.buttons["Places"].tap()
        for place in places {
            XCTAssertTrue(waitForExistence(of: app.buttons["place.\(place.id)"], in: app, timeout: 30),
                          "\(place.name) is not listed before searching\n\(app.debugDescription)")
        }
        let field = app.searchFields.firstMatch
        // A drawer search field hides once the list has moved; a pull at the
        // top brings it back (and, harmlessly, reloads).
        for _ in 0..<3 where !(field.exists && field.isHittable) { app.swipeDown() }
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 10), "no search field\n\(app.debugDescription)")
        field.tap()
        // A space either side, as people leave them. No name starts with a
        // space and "Hilltop" does not go on with one, so untrimmed, this
        // search would find nothing.
        field.typeText(" \(prefix) \n")

        for place in left {
            XCTAssertTrue(waitForDisappearance(of: app.buttons["place.\(place.id)"], timeout: 20),
                          "\(place.name) does not start with \"\(prefix)\" and is still listed\n\(app.debugDescription)")
        }
        for place in found {
            XCTAssertTrue(waitForExistence(of: app.buttons["place.\(place.id)"], in: app, timeout: 20),
                          "\(place.name) starts with \"\(prefix)\" and is not listed\n\(app.debugDescription)")
        }
        // Nor anything else in the emulator: every row shown starts that way.
        let shown = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "place."))
            .allElementsBoundByIndex
            .compactMap { $0.exists ? $0.label : nil }
        XCTAssertFalse(shown.isEmpty)
        for label in shown {
            XCTAssertTrue(label.contains(prefix), "a row that does not start with \"\(prefix)\": \(label)")
        }

        // Cleared with the field's own clear button, then out of searching.
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.waitForExistence(timeout: 5) {
            clear.tap()
        } else {
            let typed = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        }
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 3), cancel.isHittable { cancel.tap() }
        for place in places {
            XCTAssertTrue(waitForExistence(of: app.buttons["place.\(place.id)"], in: app, timeout: 20),
                          "\(place.name) did not come back after clearing the search\n\(app.debugDescription)")
        }
    }

    // MARK: - Meetups

    func testJoiningLeavingAPrivateAddressAndAFullMeetup() throws {
        let soon = try landmark("meetup_soon")
        let hidden = try landmark("meetup_private")
        let full = try landmark("meetup_full")
        let cancelled = try landmark("meetup_cancelled")
        let later = try landmark("meetup_later")
        let (app, me) = try signInAsNewAccount("meetups-\(run)@petnote.test")
        uid = me
        let petName = "Biscuit \(run)"
        try givePet(named: petName, to: me)

        app.tabBars.buttons["Meetups"].tap()
        // Upcoming: not the cancelled one. This Week: not the one in ten days.
        XCTAssertTrue(waitForExistence(of: app.buttons["meetup.\(soon)"], in: app, timeout: 30), "\(app.debugDescription)")
        XCTAssertTrue(app.buttons["meetup.\(later)"].exists)
        XCTAssertFalse(app.buttons["meetup.\(cancelled)"].exists, "a cancelled meetup is listed as upcoming")
        XCTAssertTrue(app.buttons["meetup.\(hidden)"].label.contains("Somerville"), app.buttons["meetup.\(hidden)"].label)
        XCTAssertFalse(app.buttons["meetup.\(hidden)"].label.contains("Elm"), "the private street is in the list")
        app.buttons["meetups.filter.thisWeek"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["meetup.\(later)"], timeout: 15), "ten days away is not this week")
        XCTAssertTrue(app.buttons["meetup.\(soon)"].exists)
        app.buttons["meetups.filter.upcoming"].tap()

        // Join with the pet, then leave.
        try openMeetup(soon, in: app)
        try join(in: app, pet: petName)
        cleanup.append("meetups/\(soon)/participants/\(me)")
        try waitFor(participant: me, in: soon, present: true)
        XCTAssertTrue(waitForExistence(of: app.descendants(matching: .any)["meetupDetail.going"], in: app, timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["meetupDetail.participant.\(me)"].exists)
        XCTAssertEqual(try count(of: soon), 2, "joining did not count")
        let leave = app.buttons["meetupDetail.leave"]
        XCTAssertTrue(waitUntilHittable(leave, in: app, timeout: 10))
        leave.tap()
        try confirm("Leave", besides: "meetupDetail.leave", in: app)
        try waitFor(participant: me, in: soon, present: false)
        XCTAssertTrue(waitUntilHittable(app.buttons["meetupDetail.join"], in: app, timeout: 20))
        try waitFor(count: 1, of: soon)
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        // A participants-only meetup: no address until joined.
        try openMeetup(hidden, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["meetupDetail.addressHidden"].exists, "the address showed before joining")
        try join(in: app, pet: petName)
        cleanup.append("meetups/\(hidden)/participants/\(me)")
        let address = app.descendants(matching: .any)["meetupDetail.address"]
        XCTAssertTrue(waitForExistence(of: address, in: app, timeout: 20), "joining did not show the address\n\(app.debugDescription)")
        XCTAssertTrue(address.label.contains("12 Elm St"), address.label)
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        // A full one: the server's refusal, in its words, and nothing written.
        try openMeetup(full, in: app)
        try join(in: app, pet: petName)
        let refusal = app.staticTexts["meetupDetail.error"]
        XCTAssertTrue(waitForExistence(of: refusal, in: app, timeout: 20), "a full meetup said nothing\n\(app.debugDescription)")
        XCTAssertEqual(refusal.label, "Meetup is full.")
        XCTAssertNil(try JourneyAdmin.fields(path: "meetups/\(full)/participants/\(me)"))
    }

    func testAnOrganiserCancelsTheirMeetupFromMyMeetups() throws {
        let (app, me) = try signInAsNewAccount("organiser-\(run)@petnote.test")
        uid = me
        let id = "ui-\(run)-meetup"
        try Self.write(path: "meetups/\(id)", [
            "organizerId": me, "organizerName": "Organiser \(run)", "organizerAvatar": "",
            "title": "TEST CONTENT Organiser \(run)", "description": "",
            "date": Date().addingTimeInterval(5 * 24 * 3600), "duration": 60,
            "location": ["name": "TEST CONTENT Somewhere", "address": "", "lat": 0.0, "lng": 0.0, "city": "Boston", "state": "MA"],
            "locationVisibility": "everyone",
            "requirements": ["petType": "any", "dogSize": "any", "maxPets": 0, "mustHavePosts": false,
                             "mustHavePetProfile": false, "minFollowers": 0, "additionalNotes": ""],
            "status": "upcoming", "participantCount": 1, "isRatingOpen": false,
        ])
        cleanup.append("meetups/\(id)")
        try Self.write(path: "meetups/\(id)/participants/\(me)", [
            "meetupId": id, "userId": me, "userName": "Organiser \(run)", "userAvatar": "",
            "petId": "", "petName": "Organizer", "petAvatar": "", "joinedAt": Date(),
            "status": "confirmed", "counted": true,
        ])
        cleanup.append("meetups/\(id)/participants/\(me)")

        app.tabBars.buttons["Meetups"].tap()
        let mine = app.buttons["meetups.filter.mine"]
        XCTAssertTrue(waitUntilHittable(mine, in: app, timeout: 30))
        mine.tap()
        let row = app.buttons["meetup.\(id)"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 20), "an organised meetup is not in My Meetups\n\(app.debugDescription)")
        row.tap()
        let cancel = app.buttons["meetupDetail.cancel"]
        XCTAssertTrue(waitUntilHittable(cancel, in: app, timeout: 20), "no Cancel for the organiser\n\(app.debugDescription)")
        cancel.tap()
        try confirm("Cancel Meetup", besides: "meetupDetail.cancel", in: app)
        var status: String?
        for _ in 0..<30 {
            status = JourneyAdmin.string(try JourneyAdmin.fields(path: "meetups/\(id)")?["status"])
            if status == "cancelled" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(status, "cancelled")
        XCTAssertTrue(waitForExistence(of: app.staticTexts["meetupDetail.over"], in: app, timeout: 20))
        XCTAssertFalse(app.buttons["meetupDetail.join"].exists, "a cancelled meetup still offers Join")
    }

    /// Past its end and still "upcoming" — which is how every meetup ends
    /// where the 15-minute job does not run (the test project, and this
    /// emulator). Opening it asks the server to settle it
    /// (`checkMeetupStatusCallable`, functions/src/meetups.ts:818-851), and
    /// the screen shows what the server then holds.
    ///
    /// Written here, not seeded: opening it is what changes it, so a seeded
    /// one would be spent by the first run. This one is somebody else's
    /// (nobody's "My Meetups"), at no place (no place's meetups), for any pet
    /// (not under Dogs or Cats), in the past (not This Week) — so while it
    /// exists it is only in Upcoming, first, being the earliest; and
    /// tearDown removes it.
    func testOpeningAMeetupThatHasEndedSettlesIt() throws {
        let (app, me) = try signInAsNewAccount("settle-\(run)@petnote.test")
        uid = me
        let id = "ui-\(run)-ended"
        // Three hours ago, for an hour: two hours over.
        try writeMeetup(id, title: "TEST CONTENT Ended \(run)", organiser: "ui-\(run)-host",
                        organiserName: "Host \(run)", date: Date().addingTimeInterval(-3 * 3600))
        XCTAssertEqual(JourneyAdmin.string(try JourneyAdmin.fields(path: "meetups/\(id)")?["status"]), "upcoming")

        // Listed as upcoming, because that is what the document says.
        app.tabBars.buttons["Meetups"].tap()
        let row = app.buttons["meetup.\(id)"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30), "the unsettled meetup is not listed\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains("Upcoming"), row.label)

        try openMeetup(id, in: app)
        let over = app.staticTexts["meetupDetail.over"]
        XCTAssertTrue(waitForExistence(of: over, in: app, timeout: 20), "a meetup two hours over opened as still on\n\(app.debugDescription)")
        XCTAssertEqual(over.label, "This meetup has ended.")
        XCTAssertFalse(app.buttons["meetupDetail.join"].exists, "a meetup that has ended still offers Join")
        // Settled on the server, not only on the screen.
        try waitFor(status: "completed", of: id)
        XCTAssertEqual(JourneyAdmin.bool(try JourneyAdmin.fields(path: "meetups/\(id)")?["isRatingOpen"]), true,
                       "the server completed it without opening it for rating")

        // Read again, the upcoming list no longer has it. Switching filters
        // empties the list and reads it again; the chip being selected says
        // the emptying has happened (the same assignment does both), and then
        // another row coming up says the new read is in. A row missing from
        // an empty list, or from This Week's, would prove nothing.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let thisWeek = app.buttons["meetups.filter.thisWeek"]
        XCTAssertTrue(waitUntilHittable(thisWeek, in: app, timeout: 20))
        thisWeek.tap()
        let upcoming = app.buttons["meetups.filter.upcoming"]
        upcoming.tap()
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: upcoming)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed, "Upcoming was not chosen again")
        let anyRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meetup.")).firstMatch
        XCTAssertTrue(waitForExistence(of: anyRow, in: app, timeout: 30), "the upcoming list did not come back\n\(app.debugDescription)")
        XCTAssertFalse(row.exists, "a settled meetup is still listed as upcoming")
    }

    // MARK: - Meetup notifications

    /// The two notifications the meetup triggers write
    /// (functions/src/notifications.ts:696-762), each seen in the app of the
    /// person it is for and read back from the server: someone joining tells
    /// the organiser, the organiser cancelling tells whoever joined — and
    /// neither tells the one who did it.
    ///
    /// Two fresh accounts, one app, signing out and in between: the join and
    /// the cancel go through the same screens as the tests above.
    func testAJoinTellsTheOrganiserAndACancellationTellsWhoJoined() throws {
        let hostEmail = "host-\(run)@petnote.test"
        let guestEmail = "guest-\(run)@petnote.test"
        let host = try EmulatorAdmin.createVerifiedAccount(email: hostEmail, password: "Passw0rd!x")
        otherUID = host
        inboxes.append(host)
        let id = "ui-\(run)-told"
        let title = "TEST CONTENT Told \(run)"
        try writeMeetup(id, title: title, organiser: host, organiserName: "Host \(run)",
                        date: Date().addingTimeInterval(24 * 3600))

        // The guest joins.
        let (app, guest) = try signInAsNewAccount(guestEmail)
        uid = guest
        inboxes.append(guest)
        let petName = "Guest \(run)"
        try givePet(named: petName, to: guest)
        app.tabBars.buttons["Meetups"].tap()
        try openMeetup(id, in: app)
        try join(in: app, pet: petName)
        cleanup.append("meetups/\(id)/participants/\(guest)")
        try waitFor(participant: guest, in: id, present: true)

        // The organiser is told, under the guest's name, once.
        let joined = try waitForNotification("meetup_join", to: host)
        let guestName = try displayName(of: guest)
        XCTAssertEqual(JourneyAdmin.string(joined.fields["fromUserId"]), guest)
        XCTAssertEqual(JourneyAdmin.string(joined.fields["fromUserName"]), guestName)
        XCTAssertEqual(JourneyAdmin.string(joined.fields["message"]), "joined your meetup \(title)")
        XCTAssertEqual(try notifications(for: host).map { $0.kind }, ["meetup_join"], "the organiser was not told exactly once")

        // In the organiser's list. A tap marks it read and stays there: it
        // carries no meetup id to open, on the web either.
        switchAccount(app, to: hostEmail)
        openNotifications(app)
        let joinedRow = app.buttons["notification.\(joined.id)"]
        XCTAssertTrue(waitForExistence(of: joinedRow, in: app, timeout: 30), "the organiser's list does not have it\n\(app.debugDescription)")
        XCTAssertTrue(joinedRow.label.contains("\(guestName) joined your meetup \(title)"), joinedRow.label)
        joinedRow.tap()
        try waitFor(read: true, notification: joined.id)
        XCTAssertTrue(joinedRow.exists && app.buttons["notifications.markAllRead"].exists,
                      "a meetup notification opened something\n\(app.debugDescription)")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        // The organiser cancels.
        app.tabBars.buttons["Meetups"].tap()
        let mine = app.buttons["meetups.filter.mine"]
        XCTAssertTrue(waitUntilHittable(mine, in: app, timeout: 30))
        mine.tap()
        try openMeetup(id, in: app)
        let cancel = app.buttons["meetupDetail.cancel"]
        for _ in 0..<4 where !(cancel.exists && cancel.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(cancel, in: app, timeout: 20), "no Cancel for the organiser\n\(app.debugDescription)")
        cancel.tap()
        try confirm("Cancel Meetup", besides: "meetupDetail.cancel", in: app)
        try waitFor(status: "cancelled", of: id)
        XCTAssertTrue(waitForExistence(of: app.staticTexts["meetupDetail.over"], in: app, timeout: 20))

        // The guest is told, under the organiser's name, once; the organiser
        // is not told of their own cancellation, nor the guest of their join.
        let cancelled = try waitForNotification("meetup_cancelled", to: guest)
        let hostName = try displayName(of: host)
        XCTAssertEqual(JourneyAdmin.string(cancelled.fields["fromUserId"]), host)
        XCTAssertEqual(JourneyAdmin.string(cancelled.fields["fromUserName"]), hostName)
        XCTAssertEqual(JourneyAdmin.string(cancelled.fields["message"]), "cancelled the meetup \(title)")
        XCTAssertEqual(try notifications(for: guest).map { $0.kind }, ["meetup_cancelled"], "the guest was not told exactly once")
        XCTAssertEqual(try notifications(for: host).map { $0.kind }, ["meetup_join"], "the organiser was told of their own cancellation")

        // In the guest's list.
        switchAccount(app, to: guestEmail)
        openNotifications(app)
        let cancelledRow = app.buttons["notification.\(cancelled.id)"]
        XCTAssertTrue(waitForExistence(of: cancelledRow, in: app, timeout: 30), "the guest's list does not have it\n\(app.debugDescription)")
        XCTAssertTrue(cancelledRow.label.contains("\(hostName) cancelled the meetup \(title)"), cancelledRow.label)
    }

    // MARK: - Reviews

    func testWritingAReviewOfAPlace() throws {
        let park = try landmark("place_reviewed")
        let (app, me) = try signInAsNewAccount("review-\(run)@petnote.test")
        uid = me
        let before = Self.number(try JourneyAdmin.fields(path: "locations/\(park)")?["totalRatings"]) ?? -1

        app.tabBars.buttons["Places"].tap()
        let row = app.buttons["place.\(park)"]
        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 30))
        row.tap()
        let write = app.buttons["place.writeReview"]
        for _ in 0..<6 where !(write.exists && write.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(write, in: app, timeout: 20), "no Write a review\n\(app.debugDescription)")
        write.tap()

        let submit = app.buttons["review.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(submit.isEnabled, "a review with no rating could be sent")
        app.descendants(matching: .any)["review.rating"].buttons["4 out of 5"].tap()
        app.buttons["review.tag.0"].tap()
        // A form builds only the rows on screen; the comment is below the
        // tags, so it is not in the hierarchy until scrolled to.
        let comment = app.descendants(matching: .any)["review.comment"]
        for _ in 0..<5 where !comment.exists { app.swipeUp() }
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "no comment field\n\(app.debugDescription)")
        comment.tap()
        comment.typeText("TEST CONTENT \(run)")
        XCTAssertTrue(waitForEnabled(submit, timeout: 5))
        submit.tap()
        cleanup.append("locations/\(park)/reviews/\(me)")

        // On the server, under the id the server gives a place review.
        var review: [String: Any]?
        for _ in 0..<30 {
            review = try JourneyAdmin.fields(path: "locations/\(park)/reviews/\(me)")
            if review != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let stored = try XCTUnwrap(review, "the review is not on the server")
        XCTAssertEqual(Self.number(stored["rating"]), 4)
        XCTAssertEqual(JourneyAdmin.string(stored["comment"]), "TEST CONTENT \(run)")
        XCTAssertTrue("\(stored["tags"] ?? "")".contains("Spacious"), "\(stored["tags"] ?? "")")
        try waitFor(ratings: before + 1, at: park)
        // Written once: the screen stops offering it.
        XCTAssertTrue(waitForDisappearance(of: write, timeout: 20), "Write a review is still offered")

        // Leave the place as the other tests expect it.
        JourneyAdmin.deleteDocument(path: "locations/\(park)/reviews/\(me)")
        try waitFor(ratings: before, at: park)
    }

    func testRatingThePlaceOfACompletedMeetup() throws {
        let past = try landmark("meetup_past")
        let park = try landmark("place_reviewed")
        let (app, me) = try signInAsNewAccount("rater-\(run)@petnote.test")
        uid = me
        let before = Self.number(try JourneyAdmin.fields(path: "locations/\(park)")?["totalRatings"]) ?? -1
        // There, as the join callable would have written it — but not
        // counted, so removing it afterwards takes nothing off the count.
        try Self.write(path: "meetups/\(past)/participants/\(me)", [
            "meetupId": past, "userId": me, "userName": "Rater \(run)", "userAvatar": "",
            "petId": "", "petName": "Organizer", "petAvatar": "", "joinedAt": Date(), "status": "confirmed",
            "counted": false,
        ])
        cleanup.append("meetups/\(past)/participants/\(me)")

        app.tabBars.buttons["Meetups"].tap()
        let mine = app.buttons["meetups.filter.mine"]
        XCTAssertTrue(waitUntilHittable(mine, in: app, timeout: 30))
        mine.tap()
        try openMeetup(past, in: app)
        XCTAssertTrue(app.staticTexts["meetupDetail.over"].exists)
        let rate = app.buttons["meetupDetail.rate"]
        for _ in 0..<4 where !(rate.exists && rate.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(rate, in: app, timeout: 20), "no Rate this place\n\(app.debugDescription)")
        rate.tap()
        let submit = app.buttons["review.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["review.rating"].buttons["5 out of 5"].tap()
        XCTAssertTrue(waitForEnabled(submit, timeout: 5))
        submit.tap()
        cleanup.append("locations/\(park)/reviews/\(me)_\(past)")

        var review: [String: Any]?
        for _ in 0..<30 {
            review = try JourneyAdmin.fields(path: "locations/\(park)/reviews/\(me)_\(past)")
            if review != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let stored = try XCTUnwrap(review, "the meetup review is not on the server")
        XCTAssertEqual(JourneyAdmin.string(stored["meetupId"]), past)
        XCTAssertEqual(Self.number(stored["rating"]), 5)
        XCTAssertTrue(waitForExistence(of: app.descendants(matching: .any)["meetupDetail.rated"], in: app, timeout: 20),
                      "the screen still offers rating after it was done\n\(app.debugDescription)")

        JourneyAdmin.deleteDocument(path: "locations/\(park)/reviews/\(me)_\(past)")
        try waitFor(ratings: before, at: park)
    }

    /// The count is the review triggers'; wait for it, not for a guess.
    private func waitFor(ratings expected: Int, at place: String) throws {
        var value: Int?
        for _ in 0..<60 {
            value = Self.number(try JourneyAdmin.fields(path: "locations/\(place)")?["totalRatings"])
            if value == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("totalRatings of \(place) is \(String(describing: value)), expected \(expected)")
    }

    // MARK: - Steps

    private func openMeetup(_ id: String, in app: XCUIApplication) throws {
        let row = app.buttons["meetup.\(id)"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 20), "no row for \(id)\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["meetupDetail.title"], in: app, timeout: 20))
    }

    /// The dialog's button, not the page's button of the same name under
    /// it: `firstMatch` found the page's first, and a tap on it behind the
    /// dialog did nothing (measured: hit point {-1, -1}).
    private func confirm(_ label: String, besides pageIdentifier: String, in app: XCUIApplication) throws {
        let button = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", label, pageIdentifier)
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(label) in the dialog\n\(app.debugDescription)")
        button.tap()
    }

    private func join(in app: XCUIApplication, pet: String) throws {
        let join = app.buttons["meetupDetail.join"]
        for _ in 0..<4 where !(join.exists && join.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(join, in: app, timeout: 20), "no Join\n\(app.debugDescription)")
        join.tap()
        let choice = app.buttons[pet]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the pet was not offered\n\(app.debugDescription)")
        choice.tap()
    }

    /// A pet this account owns, as the server writes one: the pet and the
    /// owner's family entry, which is what the pet picker and the join
    /// callable both read.
    private func givePet(named name: String, to uid: String) throws {
        let id = "ui-\(run)-pet"
        try Self.write(path: "pets/\(id)", [
            "name": name, "species": "dog", "ownerId": uid, "primaryOwnerId": uid,
            "avatarUrl": "", "createdAt": Date(),
        ])
        cleanup.append("pets/\(id)")
        try Self.write(path: "pets/\(id)/family/\(uid)", [
            "userId": uid, "petId": id, "role": "primary", "relationship": "mom", "joinedAt": Date(),
        ])
        cleanup.append("pets/\(id)/family/\(uid)")
    }

    private func waitFor(participant: String, in meetup: String, present: Bool) throws {
        for _ in 0..<30 {
            let exists = try JourneyAdmin.fields(path: "meetups/\(meetup)/participants/\(participant)") != nil
            if exists == present { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("participant \(participant) in \(meetup): expected present=\(present)")
    }

    private func count(of meetup: String) throws -> Int? {
        Self.number(try JourneyAdmin.fields(path: "meetups/\(meetup)")?["participantCount"])
    }

    /// The count comes down in a trigger, after the entry is gone.
    private func waitFor(count expected: Int, of meetup: String) throws {
        var value: Int?
        for _ in 0..<40 {
            value = try count(of: meetup)
            if value == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("participantCount of \(meetup) is \(String(describing: value)), expected \(expected)")
    }

    private func waitFor(status expected: String, of meetup: String) throws {
        var status: String?
        for _ in 0..<30 {
            status = JourneyAdmin.string(try JourneyAdmin.fields(path: "meetups/\(meetup)")?["status"])
            if status == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("meetup \(meetup) is \(String(describing: status)) on the server, expected \(expected)")
    }

    /// A meetup as the create callable writes one, with its organiser as the
    /// first participant (`meetups.ts:401-418`). Both are removed in
    /// tearDown. The organiser's own entry tells nobody anything: the join
    /// trigger skips the organiser.
    private func writeMeetup(_ id: String, title: String, organiser: String, organiserName: String, date: Date) throws {
        try Self.write(path: "meetups/\(id)", [
            "organizerId": organiser, "organizerName": organiserName, "organizerAvatar": "",
            "title": title, "description": "",
            "date": date, "duration": 60,
            "location": ["name": "TEST CONTENT Somewhere", "address": "", "lat": 0.0, "lng": 0.0, "city": "Boston", "state": "MA"],
            "locationVisibility": "everyone",
            "requirements": ["petType": "any", "dogSize": "any", "maxPets": 0, "mustHavePosts": false,
                             "mustHavePetProfile": false, "minFollowers": 0, "additionalNotes": ""],
            "status": "upcoming", "participantCount": 1, "isRatingOpen": false,
        ])
        cleanup.append("meetups/\(id)")
        try Self.write(path: "meetups/\(id)/participants/\(organiser)", [
            "meetupId": id, "userId": organiser, "userName": organiserName, "userAvatar": "",
            "petId": "", "petName": "Organizer", "petAvatar": "", "joinedAt": Date(),
            "status": "confirmed", "counted": true,
        ])
        cleanup.append("meetups/\(id)/participants/\(organiser)")
    }

    // MARK: - Sorting places

    /// A seeded place with the numbers the sorts read, as the server has them.
    private struct StoredPlace {
        let id: String
        let name: String
        let created: Date
        let average: Double
        let reviews: Int
    }

    /// The park, the café and the trail, read from the server.
    private func seededPlaces() throws -> [StoredPlace] {
        try ["place_reviewed", "place_quiet", "place_trail"].map { key -> StoredPlace in
            let id = try landmark(key)
            let fields = try XCTUnwrap(try JourneyAdmin.fields(path: "locations/\(id)"), "\(key) is not on the server; reseed the emulator")
            let stamp = try XCTUnwrap((fields["createdAt"] as? [String: Any])?["timestampValue"] as? String, "\(key) has no createdAt")
            // To the second: the seed puts them a day apart, and the server
            // writes fractions of a second in more than one length.
            let created = try XCTUnwrap(ISO8601DateFormatter().date(from: String(stamp.prefix(19)) + "Z"), stamp)
            let name = try XCTUnwrap(JourneyAdmin.string(fields["name"]), "\(key) has no name")
            return StoredPlace(
                id: id, name: name, created: created,
                average: Self.real(fields["averageRating"]) ?? 0,
                reviews: Self.number(fields["totalRatings"]) ?? 0
            )
        }
    }

    private func describe(_ places: [StoredPlace]) -> String {
        places.map { "\($0.name): created \($0.created), average \($0.average), \($0.reviews) reviews" }
            .joined(separator: "\n")
    }

    /// The sort menu's option: by identifier where the menu carries it
    /// through, by its words where it does not.
    private func chooseSort(_ label: String, identifier: String, in app: XCUIApplication) {
        let menu = app.buttons["places.sort"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 20), "no sort control\n\(app.debugDescription)")
        menu.tap()
        let option = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        ).firstMatch
        XCTAssertTrue(waitUntilHittable(option, in: app, timeout: 10), "no \(label) in the sort menu\n\(app.debugDescription)")
        option.tap()
        let chosen = expectation(for: NSPredicate(format: "value == %@", label), evaluatedWith: menu)
        XCTAssertEqual(XCTWaiter().wait(for: [chosen], timeout: 10), .completed, "the sort control does not say \(label)")
    }

    /// Waits for the seeded places to stand in `expected` order, top to
    /// bottom, and fails with what the screen showed instead. A new sort
    /// keeps the old rows up until the server answers, so one look is not
    /// enough. Rows are only moved by a sort, never removed, so reading each
    /// one's frame after seeing it exist is safe.
    private func assertShown(
        _ expected: [String], of places: [StoredPlace], in app: XCUIApplication, sortedBy sort: String,
        timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line
    ) {
        func names(_ ids: [String]) -> [String] { ids.map { id in places.first { $0.id == id }?.name ?? id } }
        var shown: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            dismissSavePasswordSheetIfPresent(app)
            shown = expected
                .compactMap { id -> (id: String, top: CGFloat)? in
                    let row = app.buttons["place.\(id)"]
                    guard row.exists else { return nil }
                    return (id: id, top: row.frame.minY)
                }
                .sorted { $0.top < $1.top }
                .map { $0.id }
            if shown == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        XCTFail(
            "\(sort): the screen has \(names(shown)); the server's numbers put them \(names(expected))\n\(describe(places))",
            file: file, line: line
        )
    }

    // MARK: - Notifications, read from the server

    /// A notification as the server wrote it.
    private struct StoredNotification {
        let id: String
        let fields: [String: Any]
        var kind: String { JourneyAdmin.string(fields["type"]) ?? "" }
    }

    private func notifications(for uid: String) throws -> [StoredNotification] {
        try JourneyAdmin.documentNames(in: "notifications", field: "userId", equals: uid)
            .compactMap { name -> StoredNotification? in
                guard let fields = try JourneyAdmin.fields(documentName: name) else { return nil }
                return StoredNotification(id: String(name.split(separator: "/").last ?? ""), fields: fields)
            }
    }

    /// A trigger writes it after the change it is about; wait for it.
    private func waitForNotification(_ kind: String, to uid: String) throws -> StoredNotification {
        var found: StoredNotification?
        for _ in 0..<40 {
            found = try notifications(for: uid).first { $0.kind == kind }
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let held = try notifications(for: uid).map { $0.kind }
        return try XCTUnwrap(found, "the server wrote no \(kind) notification for \(uid); it holds \(held)")
    }

    private func waitFor(read expected: Bool, notification id: String) throws {
        var value: Bool?
        for _ in 0..<20 {
            value = JourneyAdmin.bool(try JourneyAdmin.fields(path: "notifications/\(id)")?["read"])
            if value == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("notification \(id) read=\(String(describing: value)), expected \(expected)")
    }

    /// The name the server signs what this account does with: its
    /// profile's, which the app had made on its first sign-in — or the
    /// server's stand-in for a profile without one
    /// (`getNotificationActor`, notifications.ts:60-85).
    private func displayName(of uid: String) throws -> String {
        let name = JourneyAdmin.string(try JourneyAdmin.fields(path: "users/\(uid)")?["displayName"]) ?? ""
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "PetNote User" : name
    }

    private func openNotifications(_ app: XCUIApplication) {
        let bell = app.buttons["feed.notifications"]
        XCTAssertTrue(waitUntilHittable(bell, in: app, timeout: 30), "no bell\n\(app.debugDescription)")
        bell.tap()
    }

    /// Out of this account and into another, in the same app. The account
    /// menu is on the feed, so back to Home first.
    private func switchAccount(_ app: XCUIApplication, to email: String) {
        popToTabRoot(app, then: "Home")
        signOutFromAccountMenu(app)
        signIn(app, email: email, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "did not reach the feed as \(email)\n\(app.debugDescription)")
    }

    // MARK: - Emulator writes

    static func number(_ value: Any?) -> Int? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["integerValue"] as? String { return Int(text) }
        if let double = value["doubleValue"] as? Double { return Int(double) }
        return nil
    }

    /// A number with its fraction. The server stores a whole average (5) as
    /// an integer and 4.5 as a double.
    static func real(_ value: Any?) -> Double? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["integerValue"] as? String { return Double(text) }
        return value["doubleValue"] as? Double
    }

    private static func encode(_ value: Any) -> [String: Any] {
        switch value {
        case let text as String: return ["stringValue": text]
        case let flag as Bool: return ["booleanValue": flag]
        case let whole as Int: return ["integerValue": String(whole)]
        case let real as Double: return ["doubleValue": real]
        case let date as Date: return ["timestampValue": ISO8601DateFormatter().string(from: date)]
        case let map as [String: Any]: return ["mapValue": ["fields": map.mapValues(encode)]]
        case let list as [Any]: return ["arrayValue": ["values": list.map(encode)]]
        default: return ["nullValue": NSNull()]
        }
    }

    static func write(path: String, _ fields: [String: Any]) throws {
        let url = "\(EmulatorAdmin.firestore)/v1/projects/\(EmulatorAdmin.projectID)/databases/(default)/documents/\(path)"
        var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
        request.httpMethod = "PATCH"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields.mapValues(encode)])
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        XCTAssertEqual(status, 200, "the emulator refused \(path)")
    }
}
