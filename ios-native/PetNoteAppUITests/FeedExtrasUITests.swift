import XCTest

/// The feed's "⭐ Popular Pets" row and birthday banner, through the screens,
/// against the emulator.
///
/// What the server holds is written straight into the emulator here — a post
/// the spotlight has to rank first, a pet whose birthday is today — in the
/// shapes the app reads (`PostDecoder`, `PetDecoder`, and the family entry
/// `FirestorePetChoiceSource` looks for). What is under test is the app: what
/// it draws from them and where a tap goes. Both run as fresh accounts, so
/// nothing a seeded account has opened or owns decides the outcome.
final class FeedExtrasUITests: XCTestCase {
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

    // MARK: - Spotlight

    func testTheSpotlightShowsPopularPostsAndATileOpensItsPost() throws {
        // The newest post there is and more liked than anything the seed can
        // hold, so the spotlight has to put it first whenever the seed ran.
        // Written before signing in: the feed's first read already has it.
        let postID = "ui-\(run)-spotlight"
        let text = "TEST CONTENT spotlight \(run)"
        let petName = "Sparkles \(run)"
        try PlacesMeetupsUITests.write(path: "posts/\(postID)", [
            "authorId": "ui-\(run)-author", "authorName": "Spotlight \(run)", "authorAvatar": "",
            "text": text, "createdAt": Date(), "likeCount": 1_000_000, "commentCount": 0,
            "petName": petName,
        ])
        cleanup.append("posts/\(postID)")

        let (app, me) = try signInAsNewAccount("spotlight-\(run)@petnote.test")
        uid = me

        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "spotlight.post."))
        XCTAssertTrue(waitForExistence(of: tiles.firstMatch, in: app, timeout: 60),
                      "the spotlight has no tiles\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(tiles.count, 1)
        XCTAssertTrue(app.descendants(matching: .any)["feed.spotlight"].exists, "no spotlight row")
        XCTAssertFalse(app.staticTexts["spotlight.empty"].exists, "the spotlight says it is empty")

        let tile = app.buttons["spotlight.post.\(postID)"]
        XCTAssertTrue(waitUntilHittable(tile, in: app, timeout: 20),
                      "the most liked post of the day is not in the spotlight\n\(app.debugDescription)")
        XCTAssertEqual(tiles.firstMatch.identifier, "spotlight.post.\(postID)", "the most liked post is not first")
        // The whole name is what is read; the tile only has room for eight.
        XCTAssertEqual(tile.label, petName)

        tile.tap()
        XCTAssertTrue(waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 40),
                      "tapping the tile did not open a post\n\(app.debugDescription)")
        let opened = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: opened, in: app, timeout: 20), "the post that opened has no text")
        XCTAssertEqual(opened.label, text, "the tile opened a different post")
    }

    // MARK: - Birthday banner

    func testABirthdayTodayIsCelebratedOpensThePetAndCanBeDismissed() throws {
        let (app, me) = try signInAsNewAccount("birthday-\(run)@petnote.test")
        uid = me
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch, in: app, timeout: 60),
            "the feed never loaded\n\(app.debugDescription)"
        )
        let open = app.buttons["birthday.open"]
        XCTAssertFalse(open.exists, "an account with no pets has a birthday banner")

        // Written after the feed has read, so the banner arriving is the
        // refresh's doing and not the first load's.
        let petName = "Cake \(run)"
        try givePet(named: petName, bornYearsAgo: 3, to: me)
        pullToRefreshFeed(app)

        XCTAssertTrue(waitUntilHittable(open, in: app, timeout: 30),
                      "no birthday banner after a refresh\n\(app.debugDescription)")
        XCTAssertTrue(open.label.contains("Happy Birthday, \(petName)!"), open.label)
        // Part of the button's label when SwiftUI folds the two lines into
        // it, its own text when it does not; either way it has to be there.
        let age = "Turning 3 years old today!"
        XCTAssertTrue(open.label.contains(age) || app.staticTexts[age].exists, "no age line: \(open.label)")
        XCTAssertTrue(app.descendants(matching: .any)["feed.birthday"].exists, "no banner container")

        // The banner opens the pet, and the pet's page agrees about the day.
        open.tap()
        let name = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 30),
                      "the banner did not open the pet's page\n\(app.debugDescription)")
        XCTAssertEqual(name.label, petName)
        XCTAssertTrue(app.staticTexts["pet.birthdayToday"].exists, "the pet page does not think it is the birthday")

        // Back: still there, because nothing dismissed it.
        popToFeed(app)
        XCTAssertTrue(waitUntilHittable(open, in: app, timeout: 20), "the banner went away on its own")

        let dismiss = app.buttons["birthday.dismiss"]
        XCTAssertTrue(waitUntilHittable(dismiss, in: app, timeout: 10), "no way to dismiss the banner")
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: open, timeout: 10), "dismissing did not hide the banner")

        // For the rest of the session: a refresh does not bring it back.
        pullToRefreshFeed(app)
        XCTAssertFalse(open.exists, "a refresh brought a dismissed banner back")
    }

    // MARK: - Emulator writes

    /// A pet this account owns, as the server writes one: the pet, with the
    /// canonical month and day of today in this device's calendar — the one
    /// the app reads — and the legacy timestamp at UTC midnight of the birth
    /// date, which is where the age comes from; and the owner's family entry,
    /// which is what the app's "my pets" read looks for.
    private func givePet(named name: String, bornYearsAgo years: Int, to uid: String) throws {
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = try XCTUnwrap(today.year)
        let month = try XCTUnwrap(today.month)
        let day = try XCTUnwrap(today.day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let born = try XCTUnwrap(utc.date(from: DateComponents(year: year - years, month: month, day: day)))

        let id = "ui-\(run)-birthday-pet"
        try PlacesMeetupsUITests.write(path: "pets/\(id)", [
            "name": name, "species": "dog", "ownerId": uid, "primaryOwnerId": uid,
            "avatarUrl": "", "createdAt": Date(),
            "birthday": born, "birthdayMonth": month, "birthdayDay": day,
        ])
        cleanup.append("pets/\(id)")
        try PlacesMeetupsUITests.write(path: "pets/\(id)/family/\(uid)", [
            "userId": uid, "petId": id, "role": "primary", "relationship": "mom", "joinedAt": Date(),
        ])
        cleanup.append("pets/\(id)/family/\(uid)")
    }
}
