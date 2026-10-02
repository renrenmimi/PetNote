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
    /// Accounts whose meetups to remove, found by organiser: a test that
    /// fails between creating one and reading its id back would otherwise
    /// leave it in everyone's list.
    private var organisers: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for organiser in organisers {
            for name in (try? JourneyAdmin.documentNames(in: "meetups", field: "organizerId", equals: organiser)) ?? [] {
                let id = String(name.split(separator: "/").last ?? "")
                // A place the server made for this meetup, which this account
                // organised; never a seeded one a meetup links to.
                if let place = JourneyAdmin.string((try? JourneyAdmin.fields(path: "meetups/\(id)"))?["locationId"]),
                   let made = try? JourneyAdmin.fields(path: "locations/\(place)"),
                   JourneyAdmin.string(made["source"]) == "meetup", JourneyAdmin.string(made["addedBy"]) == organiser {
                    cleanup.append("locations/\(place)")
                }
                cleanup += ["meetups/\(id)", "meetups/\(id)/private/address", "meetups/\(id)/participants/\(organiser)"]
            }
        }
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

    /// A place added from Apple Maps stores its identifier and none of what
    /// Apple says about it. The emulator build answers the identifier from
    /// StandInPlaceDirectory, as the app on a phone asks Apple: the list names
    /// the place, and the place shows an address, a map and directions that
    /// the server does not hold. The words below are that table's.
    func testAPlaceFromAppleMapsIsShownFromWhatAppleSays() throws {
        let place = try landmark("place_apple")
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "locations/\(place)"))
        XCTAssertEqual(JourneyAdmin.string(stored["applePlaceId"]), "TESTAPPLEDOGRUN01")
        for field in ["name", "address", "lat", "lng"] {
            XCTAssertNil(stored[field], "the server holds the \(field) of a place from Apple Maps")
        }
        let (app, me) = try signInAsNewAccount("apple-\(run)@petnote.test")
        uid = me

        app.tabBars.buttons["Places"].tap()
        let row = app.buttons["place.\(place)"]
        for _ in 0..<4 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30), "the place is not listed\n\(app.debugDescription)")
        let named = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "TEST CONTENT Fenway Dog Run"), object: row
        )
        XCTAssertEqual(XCTWaiter().wait(for: [named], timeout: 20), .completed, "the row is not named: \(row.label)")
        // The list's places on an Apple map, as Apple's terms ask of a list
        // that names a place in Apple's words; its marker opens it.
        let showMap = app.buttons["places.showMap"]
        XCTAssertTrue(waitUntilHittable(showMap, in: app, timeout: 10), "no Map\n\(app.debugDescription)")
        showMap.tap()
        let map = app.descendants(matching: .any)["places.map"]
        XCTAssertTrue(map.waitForExistence(timeout: 10), "no map of the list\n\(app.debugDescription)")
        let marker = map.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "TEST CONTENT Fenway Dog Run")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "no marker for the place from Apple Maps\n\(app.debugDescription)")
        marker.tap()
        let name = app.staticTexts["place.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 20), "the place did not open\n\(app.debugDescription)")
        XCTAssertEqual(name.label, "TEST CONTENT Fenway Dog Run")
        XCTAssertEqual(app.staticTexts["place.address"].label, "1 Park Dr, Boston, MA 02215")
        XCTAssertTrue(app.descendants(matching: .any)["place.map"].waitForExistence(timeout: 10), "no map with the address")
        XCTAssertTrue(app.links["place.directions"].exists || app.buttons["place.directions"].exists, "no directions")

        // A meetup held there stores the identifier too, and is named the same.
        let fetch = app.buttons["place.meetup.\(try landmark("meetup_apple"))"]
        for _ in 0..<6 where !(fetch.exists && fetch.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForExistence(of: fetch, in: app, timeout: 20), "the meetup held there is not shown\n\(app.debugDescription)")
        assertLabel(of: fetch, contains: "TEST CONTENT Fenway Dog Run")
    }

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

    /// A name search asks Apple Maps too, and lists the places Apple finds
    /// that someone has added here, named from what Apple says: the server
    /// holds no name for the web's search to find. The stand-in finds the
    /// Apple place for "dog run", and the pet shop, which nobody has added,
    /// for "pet shop". Common words, so the keyboard has nothing to correct.
    func testSearchingFindsAPlaceFromAppleMapsByWhatAppleCallsIt() throws {
        let apple = try landmark("place_apple")
        let park = try landmark("place_reviewed")
        let (app, me) = try signInAsNewAccount("applesearch-\(run)@petnote.test")
        uid = me

        app.tabBars.buttons["Places"].tap()
        XCTAssertTrue(waitForExistence(of: app.buttons["place.\(park)"], in: app, timeout: 30), "\(app.debugDescription)")
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !(field.exists && field.isHittable) { app.swipeDown() }
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 10), "no search field\n\(app.debugDescription)")
        field.tap()
        field.typeText("dog run\n")

        let row = app.buttons["place.\(apple)"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 20), "the place from Apple Maps is not found\n\(app.debugDescription)")
        assertLabel(of: row, contains: "TEST CONTENT Fenway Dog Run")
        XCTAssertTrue(waitForDisappearance(of: app.buttons["place.\(park)"], timeout: 20), "the park is listed for \"dog run\"")

        // Apple knows the pet shop, but nobody has added it here.
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.waitForExistence(timeout: 5) {
            clear.tap()
        } else {
            let typed = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        }
        field.typeText("pet shop\n")
        let empty = app.descendants(matching: .any)["places.empty"]
        XCTAssertTrue(waitForExistence(of: empty, in: app, timeout: 20), "a place nobody has added is listed\n\(app.debugDescription)")
        XCTAssertFalse(row.exists)
    }

    /// Adding a place found on Apple Maps: the pet shop, which the stand-in
    /// knows and nobody has added. The server keeps Apple's identifier and
    /// what was written here, and none of Apple's words; the place's page
    /// shows Apple's name and address. Found again, it is opened, not added
    /// twice.
    func testAddingAPlaceFromAppleMaps() throws {
        let added = "locations/apple_TESTAPPLEPETSHOP1"
        // Cleaned up even when this run finds one left by an earlier one.
        cleanup.append(added)
        XCTAssertNil(try JourneyAdmin.fields(path: added), "the pet shop is on the server already; an earlier run left it")
        // Photos go to the upload stand-in (scripts/upload-standin.py), which
        // answers as Cloudinary would.
        let (app, me) = try signInAsNewAccount(
            "addplace-\(run)@petnote.test", extraArguments: ["-petnote-upload-standin", "http://127.0.0.1:8766"]
        )
        uid = me
        cleanup.append("\(added)/reviews/\(me)")

        app.tabBars.buttons["Places"].tap()
        try openAddPlace(in: app)
        let search = app.textFields["applePlace.search"]
        search.typeText("pet shop\n")
        let shop = app.buttons["applePlace.result.TESTAPPLEPETSHOP1"]
        XCTAssertTrue(waitForExistence(of: shop, in: app, timeout: 20), "Apple Maps found no pet shop\n\(app.debugDescription)")
        XCTAssertFalse(shop.label.contains("Already on PetNote"), shop.label)
        let save = app.buttons["addPlace.save"]
        XCTAssertFalse(save.isEnabled, "Submit before a place is chosen")
        shop.tap()

        let chosen = app.descendants(matching: .any)["applePlace.chosen"]
        XCTAssertTrue(waitForExistence(of: chosen, in: app, timeout: 10), "\(app.debugDescription)")
        XCTAssertTrue(chosen.label.contains("TEST CONTENT Corner Pet Shop"), chosen.label)
        XCTAssertTrue(app.descendants(matching: .any)["place.map"].exists, "no map with Apple's address")
        for id in ["addPlace.category.pet_store", "addPlace.feature.parking"] {
            let chip = app.buttons[id]
            for _ in 0..<6 where !(chip.exists && chip.isHittable) { app.swipeUp() }
            XCTAssertTrue(waitUntilHittable(chip, in: app, timeout: 10), "no \(id)\n\(app.debugDescription)")
            chip.tap()
        }
        XCTAssertFalse(save.isEnabled, "Submit without a description, which the web asks for")
        // A photo from the library.
        let addPhotos = app.buttons["photos.add"]
        reveal(addPhotos, in: app)
        XCTAssertTrue(waitUntilHittable(addPhotos, in: app, timeout: 10), "no Add photos\n\(app.debugDescription)")
        addPhotos.tap()
        try pickFirstPhoto(app)
        XCTAssertTrue(app.descendants(matching: .any)["photos.photo.0"].waitForExistence(timeout: 20), "the photo was not picked")
        let description = app.descendants(matching: .any)["addPlace.description"]
        for _ in 0..<6 where !(description.exists && description.isHittable) { app.swipeDown() }
        XCTAssertTrue(waitUntilHittable(description, in: app, timeout: 10), "\(app.debugDescription)")
        description.tap()
        description.typeText("TEST CONTENT Treats at the counter.")
        // And four stars, which go as a review of the place once it is in.
        let rating = app.descendants(matching: .any)["addPlace.rating"]
        reveal(rating, in: app)
        rating.buttons["4 out of 5"].tap()
        XCTAssertTrue(waitUntilHittable(save, in: app, timeout: 10), "Submit stayed off")
        save.tap()

        // The place's own page, named from Apple Maps.
        let name = app.staticTexts["place.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 30), "the added place did not open\n\(app.debugDescription)")
        XCTAssertEqual(name.label, "TEST CONTENT Corner Pet Shop")
        XCTAssertEqual(app.staticTexts["place.address"].label, "20 Elm St, Somerville, MA 02144")

        // What the server keeps.
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: added), "nothing at \(added)")
        XCTAssertEqual(JourneyAdmin.string(stored["applePlaceId"]), "TESTAPPLEPETSHOP1")
        XCTAssertEqual(JourneyAdmin.string(stored["category"]), "pet_store")
        XCTAssertEqual(JourneyAdmin.string(stored["description"]), "TEST CONTENT Treats at the counter.")
        XCTAssertEqual(JourneyAdmin.string(stored["addedBy"]), me)
        let features = ((stored["features"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any]
        XCTAssertEqual(features?.compactMap(JourneyAdmin.string), ["parking"])
        for field in ["name", "address", "lat", "lng", "city", "state"] {
            XCTAssertNil(stored[field], "the server holds the \(field) of a place from Apple Maps")
        }
        let review = try XCTUnwrap(try JourneyAdmin.fields(path: "\(added)/reviews/\(me)"), "the rating did not go as a review")
        XCTAssertEqual(Self.number(review["rating"]), 4)
        let photos = ((stored["photos"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any]
        let photo = try XCTUnwrap(photos?.compactMap(JourneyAdmin.string).first, "the photo was not kept with the place")
        XCTAssertTrue(photo.hasPrefix("https://res.cloudinary.com/"), photo)
        XCTAssertEqual(photos?.count, 1)

        // Back on the list, which has it now, named from Apple Maps.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let row = app.buttons["place.apple_TESTAPPLEPETSHOP1"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 20), "the list does not have the place just added\n\(app.debugDescription)")
        assertLabel(of: row, contains: "TEST CONTENT Corner Pet Shop")

        // Found again: there already, and opened rather than added.
        try openAddPlace(in: app)
        app.textFields["applePlace.search"].typeText("pet shop\n")
        XCTAssertTrue(waitForExistence(of: shop, in: app, timeout: 20), "\(app.debugDescription)")
        assertLabel(of: shop, contains: "Already on PetNote")
        shop.tap()
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 20), "the place there already did not open\n\(app.debugDescription)")
        XCTAssertEqual(name.label, "TEST CONTENT Corner Pet Shop")
    }

    /// The Add button on the places list, and the sheet's search field ready
    /// for typing.
    private func openAddPlace(in app: XCUIApplication) throws {
        let add = app.buttons["places.add"]
        XCTAssertTrue(waitUntilHittable(add, in: app, timeout: 30), "no Add\n\(app.debugDescription)")
        add.tap()
        let search = app.textFields["applePlace.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 10), "no search in Add a Place\n\(app.debugDescription)")
        search.tap()
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

    /// Where a meetup made in the iOS app is: a place from Apple Maps, stored
    /// by its identifier only, or an address its organiser typed. The list
    /// and the meetup name the one from what Apple says and the other in the
    /// organiser's words, each on a map; a participants-only one says only
    /// the area its organiser named until this person joins. The words below
    /// are StandInPlaceDirectory's and the seed's.
    func testMeetupsAtAPlaceFromAppleMapsAndAtATypedAddress() throws {
        let apple = try landmark("meetup_apple")
        let hidden = try landmark("meetup_applePrivate")
        let typed = try landmark("meetup_typed")
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(apple)"))
        let location = ((stored["location"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any]
        XCTAssertEqual(location.map { Set($0.keys) }, ["applePlaceId"], "the server holds more of the place than Apple's identifier")
        let (app, me) = try signInAsNewAccount("applemeetups-\(run)@petnote.test")
        uid = me
        let petName = "Pepper \(run)"
        try givePet(named: petName, to: me)

        // The list: Apple's name, the area the organiser named, and the
        // organiser's label. The three come last, in that order.
        app.tabBars.buttons["Meetups"].tap()
        let appleRow = app.buttons["meetup.\(apple)"]
        let hiddenRow = app.buttons["meetup.\(hidden)"]
        let typedRow = app.buttons["meetup.\(typed)"]
        XCTAssertTrue(waitForExistence(of: app.buttons["meetups.filter.upcoming"], in: app, timeout: 30))
        for _ in 0..<8 where !(typedRow.exists && typedRow.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForExistence(of: typedRow, in: app, timeout: 30), "\(app.debugDescription)")
        assertLabel(of: appleRow, contains: "TEST CONTENT Fenway Dog Run")
        XCTAssertTrue(hiddenRow.label.contains("Somerville"), hiddenRow.label)
        XCTAssertFalse(hiddenRow.label.contains("Pet Shop") || hiddenRow.label.contains("Elm"), "the private place is in the list: \(hiddenRow.label)")
        XCTAssertTrue(typedRow.label.contains("TEST CONTENT Oak Ave yard"), typedRow.label)

        // At a place from Apple Maps: Apple's name and address, on a map.
        try openMeetup(apple, in: app)
        assertMeetupPlace(["TEST CONTENT Fenway Dog Run", "1 Park Dr, Boston, MA 02215"], in: app)
        XCTAssertTrue(app.buttons["meetupDetail.place"].exists, "no way to the place it is at")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        // At a typed address: the organiser's words, on the map Apple found
        // for them, and no place made of somebody's yard.
        try openMeetup(typed, in: app)
        assertMeetupPlace(["TEST CONTENT Oak Ave yard", "5 Oak Ave, Medford, MA"], in: app)
        XCTAssertFalse(app.buttons["meetupDetail.place"].exists, "a typed address made a place")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()

        // Participants-only at a place from Apple Maps: nothing of it until
        // joined, then all of it.
        try openMeetup(hidden, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["meetupDetail.addressHidden"].exists, "the place showed before joining")
        XCTAssertFalse(app.descendants(matching: .any)["place.map"].exists, "a map showed before joining")
        try join(in: app, pet: petName)
        cleanup.append("meetups/\(hidden)/participants/\(me)")
        assertMeetupPlace(["TEST CONTENT Corner Pet Shop", "20 Elm St, Somerville, MA 02144"], in: app)
    }

    /// Creating a meetup at an address typed here, which only those who
    /// join may see, for small dogs: the server keeps the organiser's words
    /// in the private copy and the area they named in the public one, makes
    /// no place, keeps who may join, and puts the organiser and their pet on
    /// the guest list. Its page shows its organiser where it is, and everyone
    /// who may join.
    func testCreatingAMeetupAtATypedAddressOnlyThoseWhoJoinSee() throws {
        let (app, me) = try signInAsNewAccount("createmeetup-\(run)@petnote.test")
        uid = me
        inboxes.append(me)
        organisers.append(me)
        let petName = "Juniper \(run)"
        try givePet(named: petName, to: me)
        let title = "TEST CONTENT Yard games \(run)"

        app.tabBars.buttons["Meetups"].tap()
        try openCreateMeetup(in: app)
        try type(title + "\n", into: "createMeetup.title", in: app)
        try type("TEST CONTENT A fenced yard.", into: "createMeetup.description", in: app)
        // One search for where it is, and the words as typed taken as the
        // address.
        try type("5 Oak Ave, Medford, MA\n", into: "applePlace.search", in: app)
        try tapButton("applePlace.asTyped", in: app)
        XCTAssertEqual(app.textFields["createMeetup.address"].value as? String, "5 Oak Ave, Medford, MA")
        try type("TEST CONTENT Oak yard\n", into: "createMeetup.label", in: app)
        try type("Medford\n", into: "createMeetup.area", in: app)

        // Who may join: small dogs, four at most, whose people have posted.
        for id in ["createMeetup.petType.dog", "createMeetup.dogSize.small"] {
            let chip = app.buttons[id]
            reveal(chip, in: app)
            XCTAssertTrue(waitUntilHittable(chip, in: app, timeout: 10), "no \(id)\n\(app.debugDescription)")
            chip.tap()
        }
        let maxPets = app.steppers["createMeetup.maxPets"]
        reveal(maxPets, in: app)
        XCTAssertTrue(waitUntilHittable(maxPets, in: app, timeout: 10), "\(app.debugDescription)")
        // SwiftUI names the stepper's buttons after it: "<identifier>-Increment".
        let more = maxPets.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "-Increment")).firstMatch
        for _ in 0..<4 { more.tap() }
        let posts = app.switches["createMeetup.mustHavePosts"]
        reveal(posts, in: app)
        XCTAssertTrue(waitUntilHittable(posts, in: app, timeout: 10), "\(app.debugDescription)")
        // The switch itself, at the right of the row, as SettingsUITests taps one.
        posts.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        if posts.value as? String != "1" {
            Thread.sleep(forTimeInterval: 0.5)
            posts.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(posts.value as? String, "1", "the switch for having posted did not turn on")
        try type("TEST CONTENT Bring water.", into: "createMeetup.notes", in: app)
        let create = app.buttons["createMeetup.save"]
        XCTAssertTrue(waitUntilHittable(create, in: app, timeout: 10), "Create stayed off")
        create.tap()

        // Its page, as its organiser sees it: the private address, and who
        // may join.
        let shownTitle = app.staticTexts["meetupDetail.title"]
        XCTAssertTrue(waitForExistence(of: shownTitle, in: app, timeout: 30), "the meetup did not open\n\(app.debugDescription)")
        XCTAssertEqual(shownTitle.label, title)
        assertMeetupPlace(["TEST CONTENT Oak yard", "5 Oak Ave, Medford, MA"], in: app)
        let rules = app.descendants(matching: .any)["meetupDetail.requirements"]
        for _ in 0..<4 where !rules.exists { app.swipeUp() }
        XCTAssertTrue(waitForExistence(of: rules, in: app, timeout: 10), "no requirements\n\(app.debugDescription)")
        for line in ["Dogs only.", "Size: Small.", "Up to 4 pets.", "Must have posted at least once.", "TEST CONTENT Bring water."] {
            XCTAssertTrue(rules.label.contains(line), "no \"\(line)\": \(rules.label)")
        }

        // What the server keeps.
        let id = try createdMeetup(by: me)
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)"))
        XCTAssertEqual(JourneyAdmin.string(stored["title"]), title)
        XCTAssertEqual(JourneyAdmin.string(stored["locationVisibility"]), "participants_only")
        XCTAssertNil(stored["locationId"], "a meetup at a typed address made a place")
        XCTAssertEqual(Self.mapStrings(stored["location"]), ["name": "Meetup near Medford", "area": "Medford"])
        let hidden = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)/private/address"))
        XCTAssertEqual(Self.strings(of: hidden), ["address": "5 Oak Ave, Medford, MA", "label": "TEST CONTENT Oak yard"])
        let organiser = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)/participants/\(me)"), "the organiser is not on the guest list")
        XCTAssertEqual(JourneyAdmin.string(organiser["petName"]), petName)
        let rulesStored = ((stored["requirements"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
        XCTAssertEqual(JourneyAdmin.string(rulesStored["petType"]), "dog")
        XCTAssertEqual(JourneyAdmin.string(rulesStored["dogSize"]), "small")
        XCTAssertEqual(Self.number(rulesStored["maxPets"]), 4)
        XCTAssertEqual(JourneyAdmin.bool(rulesStored["mustHavePosts"]), true)
        XCTAssertEqual(JourneyAdmin.bool(rulesStored["mustHavePetProfile"]), false)
        XCTAssertEqual(JourneyAdmin.string(rulesStored["additionalNotes"]), "TEST CONTENT Bring water.")
    }

    /// Creating a meetup at a street address Apple Maps found, a home say:
    /// one search finds it among the addresses, the form shows it on Apple's
    /// map while the words are still Apple's and not once they are changed,
    /// and the server keeps the organiser's words and makes no place.
    func testCreatingAMeetupAtAnAddressAppleMapsFound() throws {
        let (app, me) = try signInAsNewAccount("addressmeetup-\(run)@petnote.test")
        uid = me
        inboxes.append(me)
        organisers.append(me)
        let title = "TEST CONTENT Backyard fetch \(run)"

        app.tabBars.buttons["Meetups"].tap()
        try openCreateMeetup(in: app)
        try type(title + "\n", into: "createMeetup.title", in: app)
        try type("TEST CONTENT A fenced yard.", into: "createMeetup.description", in: app)
        try type("12 Elm St\n", into: "applePlace.search", in: app)
        try tapButton("applePlace.address.0", in: app)
        let address = app.textFields["createMeetup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the address was not chosen\n\(app.debugDescription)")
        XCTAssertEqual(address.value as? String, "12 Elm St, Medford, MA 02155")
        let map = app.descendants(matching: .any)["place.map"]
        XCTAssertTrue(map.waitForExistence(timeout: 10), "no map for the address Apple found\n\(app.debugDescription)")

        // A flat number: the organiser's words now, so Apple's map goes.
        reveal(address, in: app)
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        XCTAssertTrue(Self.hasKeyboardFocus(address), "the address did not take the keyboard")
        address.typeText(", Apt 2\n")
        XCTAssertTrue(waitForDisappearance(of: map, timeout: 10), "Apple's map stayed for words that are no longer Apple's")
        try type("Medford\n", into: "createMeetup.area", in: app)
        let create = app.buttons["createMeetup.save"]
        XCTAssertTrue(waitUntilHittable(create, in: app, timeout: 10), "Create stayed off")
        create.tap()

        let shownTitle = app.staticTexts["meetupDetail.title"]
        XCTAssertTrue(waitForExistence(of: shownTitle, in: app, timeout: 30), "the meetup did not open\n\(app.debugDescription)")
        let id = try createdMeetup(by: me)
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)"))
        XCTAssertEqual(JourneyAdmin.string(stored["locationVisibility"]), "participants_only", "an address is private unless chosen otherwise")
        XCTAssertNil(stored["locationId"], "a meetup at an address made a place")
        let hidden = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)/private/address"))
        XCTAssertEqual(Self.strings(of: hidden), ["address": "12 Elm St, Medford, MA 02155, Apt 2", "label": ""])
    }

    /// Creating a public meetup at a place from Apple Maps, with a cover: the
    /// server keeps the identifier and links the meetup to the place it makes
    /// for it, which holds none of Apple's words either, and keeps the
    /// cover's address. Its page names the place from Apple Maps, on a map.
    func testCreatingAMeetupAtAPlaceFromAppleMaps() throws {
        let place = "locations/apple_TESTAPPLEDOGRUN01"
        cleanup.append(place)
        XCTAssertNil(try JourneyAdmin.fields(path: place), "a place for the dog run is on the server already; an earlier run left it")
        // The cover goes to the upload stand-in (scripts/upload-standin.py),
        // which answers as Cloudinary would.
        let (app, me) = try signInAsNewAccount(
            "applemeetup-\(run)@petnote.test", extraArguments: ["-petnote-upload-standin", "http://127.0.0.1:8766"]
        )
        uid = me
        inboxes.append(me)
        organisers.append(me)

        app.tabBars.buttons["Meetups"].tap()
        try openCreateMeetup(in: app)
        // A cover, first in the form as on the web.
        let chooseCover = app.buttons["createMeetup.cover.choose"]
        XCTAssertTrue(waitUntilHittable(chooseCover, in: app, timeout: 10), "no Upload cover\n\(app.debugDescription)")
        chooseCover.tap()
        try pickFirstPhoto(app)
        let chosen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'createMeetup.cover' AND label == 'New cover'")).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: 20), "the cover was not chosen\n\(app.debugDescription)")
        try type("TEST CONTENT Fetch at the run \(run)\n", into: "createMeetup.title", in: app)
        try type("TEST CONTENT Bring a ball.", into: "createMeetup.description", in: app)
        try type("dog run\n", into: "applePlace.search", in: app)
        let result = app.buttons["applePlace.result.TESTAPPLEDOGRUN01"]
        XCTAssertTrue(waitForExistence(of: result, in: app, timeout: 20), "Apple Maps found no dog run\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["applePlace.chosen"].waitForExistence(timeout: 10))
        let everyone = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Everyone")).firstMatch
        reveal(everyone, in: app)
        XCTAssertTrue(waitUntilHittable(everyone, in: app, timeout: 10), "\(app.debugDescription)")
        everyone.tap()
        let create = app.buttons["createMeetup.save"]
        XCTAssertTrue(waitUntilHittable(create, in: app, timeout: 10), "Create stayed off")
        create.tap()

        XCTAssertTrue(waitForExistence(of: app.staticTexts["meetupDetail.title"], in: app, timeout: 30), "the meetup did not open\n\(app.debugDescription)")
        assertMeetupPlace(["TEST CONTENT Fenway Dog Run", "1 Park Dr, Boston, MA 02215"], in: app)
        XCTAssertTrue(app.buttons["meetupDetail.place"].exists, "no way to the place it is at")

        let id = try createdMeetup(by: me)
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)"))
        XCTAssertEqual(JourneyAdmin.string(stored["locationVisibility"]), "everyone")
        XCTAssertEqual(Self.mapStrings(stored["location"]), ["applePlaceId": "TESTAPPLEDOGRUN01"])
        XCTAssertEqual(JourneyAdmin.string(stored["locationId"]), "apple_TESTAPPLEDOGRUN01")
        let cover = try XCTUnwrap(JourneyAdmin.string(stored["coverImage"]), "the cover was not kept with the meetup")
        XCTAssertTrue(cover.hasPrefix("https://res.cloudinary.com/"), cover)
        let made = try XCTUnwrap(try JourneyAdmin.fields(path: place), "no place made for the meetup")
        XCTAssertEqual(JourneyAdmin.string(made["applePlaceId"]), "TESTAPPLEDOGRUN01")
        for field in ["name", "address", "lat", "lng", "city", "state"] {
            XCTAssertNil(made[field], "the place made for the meetup holds the \(field)")
        }
    }

    /// Editing a meetup made on the web, as its organiser: a new title, and
    /// the meetup stays where it was, in the web's shape, linked to the place
    /// the server makes for a public meetup there, as the web's edit does.
    /// Then moved to a typed address: the new shape, the link gone, and the
    /// place the server made let go as nothing else uses it.
    func testEditingAMeetupKeepsWhereItWasUntilItMoves() throws {
        let (app, me) = try signInAsNewAccount("editmeetup-\(run)@petnote.test")
        uid = me
        inboxes.append(me)
        organisers.append(me)
        let id = "ui-\(run)-edit"
        let lot = "TEST CONTENT Elm Street lot \(run)"
        let web: [String: Any] = [
            "name": lot, "address": "9 Elm St, Boston, MA", "lat": 42.35123, "lng": -71.06321,
            "city": "Boston", "state": "MA",
        ]
        try Self.write(path: "meetups/\(id)", [
            "organizerId": me, "organizerName": "Organiser \(run)", "organizerAvatar": "",
            "title": "TEST CONTENT Lot walk \(run)", "description": "TEST CONTENT Around the lot.",
            "date": Date().addingTimeInterval(5 * 24 * 3600), "duration": 60, "location": web,
            "locationVisibility": "everyone",
            "requirements": ["petType": "any", "dogSize": "any", "maxPets": 0, "mustHavePosts": false,
                             "mustHavePetProfile": false, "minFollowers": 0, "additionalNotes": ""],
            "status": "upcoming", "participantCount": 1, "isRatingOpen": false,
        ])
        try Self.write(path: "meetups/\(id)/participants/\(me)", [
            "meetupId": id, "userId": me, "userName": "Organiser \(run)", "userAvatar": "",
            "petId": "", "petName": "Organizer", "petAvatar": "", "joinedAt": Date(),
            "status": "confirmed", "counted": true,
        ])

        app.tabBars.buttons["Meetups"].tap()
        let mine = app.buttons["meetups.filter.mine"]
        XCTAssertTrue(waitUntilHittable(mine, in: app, timeout: 30))
        mine.tap()
        try openMeetup(id, in: app)

        // A new title, and nothing else. Where it is shows as kept, further
        // down the form, which builds its rows as they come into view.
        try openEdit(in: app)
        try replace(with: "TEST CONTENT Edited \(run)\n", in: "createMeetup.title", app: app)
        let kept = app.descendants(matching: .any)["createMeetup.unchanged"]
        reveal(kept, in: app)
        XCTAssertTrue(kept.exists, "where it was is not shown as kept\n\(app.debugDescription)")
        XCTAssertTrue(kept.label.contains(lot), kept.label)
        XCTAssertTrue(app.buttons["createMeetup.changeWhere"].exists, "no way to choose somewhere else\n\(app.debugDescription)")
        try save(in: app)
        // The server first, and the place it made noted for cleanup before
        // anything that can fail: a run that stopped on the title below left
        // the place in everyone's list, and pushed a seeded one off screen.
        var edited: [String: Any] = [:]
        for _ in 0..<20 {
            edited = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)"))
            if JourneyAdmin.string(edited["title"]) == "TEST CONTENT Edited \(run)" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let place = try XCTUnwrap(JourneyAdmin.string(edited["locationId"]), "no place linked, as the web's edit links one")
        cleanup.append("locations/\(place)")
        XCTAssertEqual(JourneyAdmin.string(edited["title"]), "TEST CONTENT Edited \(run)")
        XCTAssertEqual(Self.mapStrings(edited["location"])["name"], lot, "the meetup moved")
        XCTAssertEqual(Self.mapStrings(edited["location"])["address"], "9 Elm St, Boston, MA")
        let shownTitle = app.staticTexts["meetupDetail.title"]
        XCTAssertTrue(waitForLabel(of: shownTitle, "TEST CONTENT Edited \(run)"), "the new title is not shown: \(shownTitle.label)")

        // Moved to a typed address.
        try openEdit(in: app)
        try tapButton("createMeetup.changeWhere", in: app)
        try type("5 Oak Ave, Medford, MA\n", into: "applePlace.search", in: app)
        try tapButton("applePlace.asTyped", in: app)
        try save(in: app)
        assertMeetupPlace(["5 Oak Ave, Medford, MA"], in: app)
        var moved: [String: Any] = [:]
        for _ in 0..<20 {
            moved = try XCTUnwrap(try JourneyAdmin.fields(path: "meetups/\(id)"))
            if Self.mapStrings(moved["location"])["address"] == "5 Oak Ave, Medford, MA" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(Self.mapStrings(moved["location"]), ["address": "5 Oak Ave, Medford, MA", "label": ""])
        XCTAssertNil(moved["locationId"], "a meetup at a typed address is still linked to a place")
        XCTAssertNil(try JourneyAdmin.fields(path: "locations/\(place)"), "the place made for it was not let go")
    }

    private func openEdit(in app: XCUIApplication) throws {
        let edit = app.buttons["meetupDetail.edit"]
        for _ in 0..<4 where !(edit.exists && edit.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(edit, in: app, timeout: 20), "no Edit for the organiser\n\(app.debugDescription)")
        edit.tap()
        XCTAssertTrue(waitForExistence(of: app.descendants(matching: .any)["createMeetup.title"], in: app, timeout: 10),
                      "no Edit Meetup\n\(app.debugDescription)")
    }

    /// A button of the form, scrolled to and tapped once it can be.
    private func tapButton(_ identifier: String, in app: XCUIApplication) throws {
        let button = app.buttons[identifier]
        reveal(button, in: app)
        XCTAssertTrue(waitUntilHittable(button, in: app, timeout: 20), "no \(identifier)\n\(app.debugDescription)")
        button.tap()
    }

    private func save(in app: XCUIApplication) throws {
        let save = app.buttons["createMeetup.save"]
        XCTAssertTrue(waitUntilHittable(save, in: app, timeout: 10), "Save stayed off\n\(app.debugDescription)")
        save.tap()
        XCTAssertTrue(waitForDisappearance(of: save, timeout: 30), "the edit was not saved\n\(app.debugDescription)")
    }

    /// Clears a one-line field and types into it. Tapped at its right end,
    /// which puts the cursor after the text: a tap in the middle left half of
    /// the old title in front of the deletes.
    private func replace(with text: String, in identifier: String, app: XCUIApplication) throws {
        let field = app.descendants(matching: .any)[identifier]
        reveal(field, in: app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        XCTAssertTrue(Self.hasKeyboardFocus(field), "\(identifier) did not take the keyboard")
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        XCTAssertTrue(((field.value as? String) ?? "").isEmpty || field.value as? String == field.placeholderValue,
                      "\(identifier) still says \(field.value ?? "")")
        field.typeText(text)
    }

    private func waitForLabel(of element: XCUIElement, _ label: String, timeout: TimeInterval = 20) -> Bool {
        let said = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [said], timeout: timeout) == .completed
    }

    /// The Create button on the meetups list.
    private func openCreateMeetup(in app: XCUIApplication) throws {
        let create = app.buttons["meetups.create"]
        XCTAssertTrue(waitUntilHittable(create, in: app, timeout: 30), "no Create\n\(app.debugDescription)")
        create.tap()
        XCTAssertTrue(waitForExistence(of: app.descendants(matching: .any)["createMeetup.title"], in: app, timeout: 10),
                      "no Create Meetup\n\(app.debugDescription)")
    }

    /// Types into a field of a form, scrolled to first: one below the
    /// keyboard is not hittable. A swipe can also leave a field under the
    /// navigation bar, which then takes the tap ("Neither element nor any
    /// descendant has keyboard focus"); it is pulled back down and tapped
    /// again. Safe here: a sheet with something written closes only on
    /// Cancel.
    private func type(_ text: String, into identifier: String, in app: XCUIApplication) throws {
        let field = app.descendants(matching: .any)[identifier]
        reveal(field, in: app)
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 10), "no \(identifier)\n\(app.debugDescription)")
        field.tap()
        if !Self.hasKeyboardFocus(field) {
            drag(app, from: 0.2, to: 0.45)
            XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 10), "no \(identifier)\n\(app.debugDescription)")
            field.tap()
        }
        XCTAssertTrue(Self.hasKeyboardFocus(field), "\(identifier) did not take the keyboard\n\(app.debugDescription)")
        field.typeText(text)
    }

    /// Scrolls a form until `element` is well inside what can be tapped:
    /// below the sheet's bar and clear of the keyboard. "Hittable" is not
    /// enough. A field just under the bar took a tap meant for it, and a
    /// segmented control a few points above the keyboard lost one to it.
    /// Up a quarter of the screen at a time, which is less than the band is
    /// tall, so nothing is carried past it; back down a little when too high.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            if element.exists, element.isHittable {
                let keyboard = app.keyboards.firstMatch
                let bottom = keyboard.exists ? keyboard.frame.minY - 44 : app.frame.maxY - 120
                let frame = element.frame
                if frame.minY < 200 {
                    drag(app, from: 0.25, to: 0.35)
                    continue
                }
                if frame.maxY <= bottom { return }
            }
            drag(app, from: 0.45, to: 0.2)
        }
    }

    /// Held still at the end, so the form does not coast: a tap on a list
    /// still scrolling only stops it, and a switch tapped then stays off.
    private func drag(_ app: XCUIApplication, from start: CGFloat, to end: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start)).press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)),
            withVelocity: .slow, thenHoldForDuration: 0.3
        )
    }

    private static func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    /// The meetup this account created. tearDown removes it, with its guest
    /// list and private address, by its organiser.
    private func createdMeetup(by organiser: String) throws -> String {
        var names: [String] = []
        for _ in 0..<20 {
            names = try JourneyAdmin.documentNames(in: "meetups", field: "organizerId", equals: organiser)
            if !names.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let id = try XCTUnwrap(names.first.map { String($0.split(separator: "/").last ?? "") }, "the server has no meetup by \(organiser)")
        XCTAssertEqual(names.count, 1, "more than one meetup was created")
        return id
    }

    /// A map field's string values, as the REST API returns them.
    private static func mapStrings(_ value: Any?) -> [String: String] {
        let fields = ((value as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
        return fields.compactMapValues { JourneyAdmin.string($0) }
    }

    private static func strings(of fields: [String: Any]) -> [String: String] {
        fields.compactMapValues { JourneyAdmin.string($0) }
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
        // On the guest list, as the create callable puts them, and still
        // offered neither Leave nor Join: the web's rule.
        XCTAssertFalse(app.buttons["meetupDetail.leave"].exists, "the organiser is offered Leave")
        XCTAssertFalse(app.buttons["meetupDetail.join"].exists, "the organiser is offered Join")
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

    // MARK: - Check-ins

    /// Checking in at a place: a photo from the library, sent to the upload
    /// stand-in, and a caption. The server keeps the day's check-in under the
    /// person and the day, with the photo's address, and the place's page
    /// says today's is done. At a place of its own, so the seeded places'
    /// counts stay as the other tests expect them.
    func testCheckingInAtAPlace() throws {
        let place = "ui-\(run)-checkin"
        cleanup.append("locations/\(place)")
        try Self.write(path: "locations/\(place)", [
            "name": "TEST CONTENT Check-in corner \(run)", "category": "park", "description": "",
            "address": "4 Corner St, Cambridge, MA", "city": "Cambridge", "state": "MA",
            "lat": 42.3656, "lng": -71.104, "features": [Any](), "photos": [Any](), "tags": [Any](),
            "source": "user", "verified": false, "addedBy": "ui-test", "addedByName": "UI Test",
            "totalPhotos": 0, "averageRating": 0, "totalRatings": 0, "totalCheckins": 0, "createdAt": Date(),
        ])
        let (app, me) = try signInAsNewAccount(
            "checkin-\(run)@petnote.test", extraArguments: ["-petnote-upload-standin", "http://127.0.0.1:8766"]
        )
        uid = me
        let today = "locations/\(place)/checkins/\(me)_\(Self.utcDay(Date()))"
        cleanup.append(today)

        // The newest place, so first in the list.
        app.tabBars.buttons["Places"].tap()
        let row = app.buttons["place.\(place)"]
        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 30), "the new place is not listed\n\(app.debugDescription)")
        row.tap()
        let checkIn = app.buttons["place.checkIn"]
        for _ in 0..<6 where !(checkIn.exists && checkIn.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(checkIn, in: app, timeout: 20), "no Check In\n\(app.debugDescription)")
        checkIn.tap()

        let save = app.buttons["checkIn.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Check In sheet\n\(app.debugDescription)")
        XCTAssertFalse(save.isEnabled, "a check-in without a photo could be sent")
        let photo = app.buttons["checkIn.photo"]
        XCTAssertTrue(waitUntilHittable(photo, in: app, timeout: 10), "\(app.debugDescription)")
        photo.tap()
        try pickFirstPhoto(app)
        let chosen = app.buttons
            .matching(NSPredicate(format: "identifier == 'checkIn.photo' AND label == 'Change the photo'")).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: 20), "the photo was not chosen\n\(app.debugDescription)")
        try type("TEST CONTENT At the corner \(run)", into: "checkIn.caption", in: app)
        XCTAssertTrue(waitForEnabled(save, timeout: 5), "Check In stayed off")
        save.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["place.checkedInToday"].waitForExistence(timeout: 30),
            "the page does not say today's is done\n\(app.debugDescription)"
        )
        let shown = app.descendants(matching: .any).matching(identifier: "place.checkin").firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "the check-in is not listed")
        XCTAssertTrue(shown.label.contains("At the corner \(run)"), shown.label)

        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: today), "no check-in for today on the server")
        XCTAssertEqual(JourneyAdmin.string(stored["userId"]), me)
        XCTAssertEqual(JourneyAdmin.string(stored["caption"]), "TEST CONTENT At the corner \(run)")
        let photoURL = try XCTUnwrap(JourneyAdmin.string(stored["photoUrl"]), "the check-in has no photo")
        XCTAssertTrue(photoURL.hasPrefix("https://res.cloudinary.com/"), photoURL)
        XCTAssertNil(stored["petId"], "a pet was sent that was not chosen")
    }

    /// The server's day, as it names a person's check-in of the day.
    private static func utcDay(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - Reviews

    /// A review with a photo, sent to the upload stand-in first; the review
    /// keeps its address. At a place of its own, which goes with everything
    /// under it, so the seeded places' photos stay as the other tests expect
    /// them.
    func testAReviewWithAPhoto() throws {
        let place = "ui-\(run)-reviewphoto"
        cleanup.append("locations/\(place)")
        try Self.write(path: "locations/\(place)", [
            "name": "TEST CONTENT Photo corner \(run)", "category": "park", "description": "",
            "address": "5 Corner St, Cambridge, MA", "city": "Cambridge", "state": "MA",
            "lat": 42.3657, "lng": -71.1041, "features": [Any](), "photos": [Any](), "tags": [Any](),
            "source": "user", "verified": false, "addedBy": "ui-test", "addedByName": "UI Test",
            "totalPhotos": 0, "averageRating": 0, "totalRatings": 0, "totalCheckins": 0, "createdAt": Date(),
        ])
        let (app, me) = try signInAsNewAccount(
            "reviewphoto-\(run)@petnote.test", extraArguments: ["-petnote-upload-standin", "http://127.0.0.1:8766"]
        )
        uid = me
        cleanup.append("locations/\(place)/reviews/\(me)")

        // The newest place, so first in the list.
        app.tabBars.buttons["Places"].tap()
        let row = app.buttons["place.\(place)"]
        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 30), "the new place is not listed\n\(app.debugDescription)")
        row.tap()
        let write = app.buttons["place.writeReview"]
        for _ in 0..<6 where !(write.exists && write.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(write, in: app, timeout: 20), "no Write a review\n\(app.debugDescription)")
        write.tap()

        let submit = app.buttons["review.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["review.rating"].buttons["5 out of 5"].tap()
        // Below the tags, in a form that builds its rows as they come into
        // view.
        let addPhotos = app.buttons["photos.add"]
        for _ in 0..<6 where !(addPhotos.exists && addPhotos.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(addPhotos, in: app, timeout: 10), "no Add photos\n\(app.debugDescription)")
        addPhotos.tap()
        try pickFirstPhoto(app)
        XCTAssertTrue(app.descendants(matching: .any)["photos.photo.0"].waitForExistence(timeout: 20), "the photo was not picked")
        XCTAssertTrue(waitForEnabled(submit, timeout: 5), "Submit Review stayed off")
        submit.tap()

        let review = app.descendants(matching: .any).matching(identifier: "place.review").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 30), "the review is not on the page\n\(app.debugDescription)")
        let stored = try XCTUnwrap(try JourneyAdmin.fields(path: "locations/\(place)/reviews/\(me)"), "no review on the server")
        XCTAssertEqual(Self.number(stored["rating"]), 5)
        let photos = ((stored["photos"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any]
        let photo = try XCTUnwrap(photos?.compactMap(JourneyAdmin.string).first, "the photo was not kept with the review")
        XCTAssertTrue(photo.hasPrefix("https://res.cloudinary.com/"), photo)
        XCTAssertEqual(photos?.count, 1)
    }

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

    /// Waits for `element`'s label to say `words`: a name looked up on Apple
    /// Maps comes in after the row does.
    private func assertLabel(
        of element: XCUIElement, contains words: String, timeout: TimeInterval = 20,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let said = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", words), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [said], timeout: timeout), .completed, "not \(words): \(element.label)", file: file, line: line)
    }

    /// The meetup's place: its name and then its address in one element,
    /// with a map and directions.
    private func assertMeetupPlace(
        _ words: [String], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let place = app.descendants(matching: .any)["meetupDetail.address"]
        XCTAssertTrue(waitForExistence(of: place, in: app, timeout: 20), "no place\n\(app.debugDescription)", file: file, line: line)
        assertLabel(of: place, contains: words[0], file: file, line: line)
        for word in words.dropFirst() {
            XCTAssertTrue(place.label.contains(word), "no \(word): \(place.label)", file: file, line: line)
        }
        XCTAssertTrue(app.descendants(matching: .any)["place.map"].waitForExistence(timeout: 10), "no map", file: file, line: line)
        XCTAssertTrue(
            app.links["meetupDetail.directions"].exists || app.buttons["meetupDetail.directions"].exists,
            "no directions", file: file, line: line
        )
    }

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
