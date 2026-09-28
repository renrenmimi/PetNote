import XCTest

/// Profile → Check-ins, against the emulator's seed: Accept A checked in at
/// the reviewed park with Mochi, and Accept B checked in there too
/// (`seed-ios-native.mjs`, `seedGatherings`).
///
/// Signed in as the seeded Accept A rather than a fresh account, because
/// nothing here writes. A check-in can only be made through
/// `checkInCallable`, which needs a photo upload; one written for a fresh
/// account with the Admin API would also move the park's `totalCheckins`
/// through the check-in trigger, which `PlacesMeetupsUITests` reads as 2.
final class CheckinHistoryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMyCheckinNamesItsPlaceAndOpensIt() throws {
        let park = try XCTUnwrap(try EmulatorAdmin.seedManifest().post("place_reviewed"),
                                 "the seed has no place_reviewed; reseed the emulator")
        let me = try XCTUnwrap(try JourneyAdmin.uid(forEmail: "accept-a@example.com"), "no seeded Accept A")
        let other = try XCTUnwrap(try JourneyAdmin.uid(forEmail: "accept-b@example.com"), "no seeded Accept B")
        // What the server holds, so the row is checked against the data and
        // not against the seed script's wording.
        let placeName = try XCTUnwrap(JourneyAdmin.string(try JourneyAdmin.fields(path: "locations/\(park)")?["name"]))
        let mine = try XCTUnwrap(try Self.checkin(by: me, at: park), "Accept A has no check-in at \(park); reseed")
        let caption = try XCTUnwrap(JourneyAdmin.string(mine.fields["caption"]))
        let theirs = try XCTUnwrap(try Self.checkin(by: other, at: park), "Accept B has no check-in at \(park); reseed")
        let theirCaption = try XCTUnwrap(JourneyAdmin.string(theirs.fields["caption"]))

        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        app.tabBars.buttons["Profile"].tap()
        let entry = app.buttons["profile.checkins"]
        for _ in 0..<4 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 20), "no Check-ins on the profile\n\(app.debugDescription)")
        entry.tap()

        let row = app.buttons["checkins.row.\(park).\(mine.id)"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 30),
                      "Accept A's check-in is not listed\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(placeName), "the row does not name its place: \(row.label)")
        XCTAssertTrue(row.label.contains(caption), "the row does not show the caption: \(row.label)")
        if let pet = JourneyAdmin.string(mine.fields["petName"]) {
            XCTAssertTrue(row.label.contains(pet), "the row does not name the pet: \(row.label)")
        }
        // Only this person's: Accept B checked in at the same park.
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checkins.row."))
        XCTAssertEqual(listed.matching(NSPredicate(format: "label CONTAINS %@", theirCaption)).count, 0,
                       "someone else's check-in is in this person's list")

        XCTAssertTrue(waitUntilHittable(row, in: app, timeout: 10))
        row.tap()
        let name = app.staticTexts["place.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 20), "the row opened nothing\n\(app.debugDescription)")
        XCTAssertEqual(name.label, placeName, "the row opened a different place")
    }

    /// A person's check-in at one place, read with the owner's rights: its
    /// document id — `{uid}_{day}`, the day being the seed's — and its fields.
    private static func checkin(by uid: String, at place: String) throws -> (id: String, fields: [String: Any])? {
        let parent = "\(EmulatorAdmin.firestore)/v1/projects/\(EmulatorAdmin.projectID)"
            + "/databases/(default)/documents/locations/\(place)"
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "checkins"]],
                "where": ["fieldFilter": [
                    "field": ["fieldPath": "userId"], "op": "EQUAL", "value": ["stringValue": uid],
                ]],
                "limit": 1,
            ]
        ]
        let response = try EmulatorAdmin.post("\(parent):runQuery", body: body, owner: true)
        for row in response["array"] as? [Any] ?? [] {
            guard let document = (row as? [String: Any])?["document"] as? [String: Any],
                  let name = document["name"] as? String,
                  let id = name.split(separator: "/").last.map(String.init) else { continue }
            return (id, document["fields"] as? [String: Any] ?? [:])
        }
        return nil
    }
}
