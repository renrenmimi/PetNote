import XCTest

/// Places and meetups through the screens, against the emulator's seeded
/// places and meetups (`seed-ios-native.mjs`, `seedGatherings`).
///
/// Joining, leaving and cancelling run the real server code — the callables
/// and the participant trigger — and each is read back from the server, not
/// from what the screen says.
final class PlacesMeetupsUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var uid: String?
    private var cleanup: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for path in cleanup.reversed() { JourneyAdmin.deleteDocument(path: path) }
        if let uid { JourneyAdmin.removeProfile(uid: uid) }
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

    // MARK: - Emulator writes

    static func number(_ value: Any?) -> Int? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["integerValue"] as? String { return Int(text) }
        if let double = value["doubleValue"] as? Double { return Int(double) }
        return nil
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
