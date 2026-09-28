import XCTest

/// The feed's "⭐ Popular Pets" row and birthday banner, through the screens,
/// against the emulator.
///
/// What the server holds is written straight into the emulator here — a post
/// the spotlight has to rank first, pets whose birthday is or is not today —
/// in the shapes the app reads (`PostDecoder`, `PetDecoder`, and the family
/// entry `FirestorePetChoiceSource` looks for). What is under test is the
/// app: what it draws from them and where a tap goes. Both run as fresh
/// accounts, so nothing a seeded account has opened or owns decides the
/// outcome.
final class FeedExtrasUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var uid: String?
    /// Documents to remove, each put down *before* it is written: a write
    /// that lands and then times out on the way back fails the test before a
    /// line after it could note the document, and a post with a million likes
    /// left behind heads every spotlight on this emulator for a week.
    private var cleanup: [String] = []
    /// Accounts whose seen-spotlight list this run left in the app's own
    /// defaults, where no emulator call reaches.
    private var seenListsWritten: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for path in cleanup.reversed() { JourneyAdmin.deleteDocument(path: path) }
        if let uid { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        for account in seenListsWritten { forgetSeenSpotlights(of: account) }
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
        cleanup.append("posts/\(postID)")
        try PlacesMeetupsUITests.write(path: "posts/\(postID)", [
            "authorId": "ui-\(run)-author", "authorName": "Spotlight \(run)", "authorAvatar": "",
            "text": text, "createdAt": Date(), "likeCount": 1_000_000, "commentCount": 0,
            "petName": petName,
        ])

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

        // Opening a tile stores it as seen, under this account, in the app's
        // defaults — noted before the tap, so a failure after it still tidies.
        seenListsWritten.append(me)
        tile.tap()
        XCTAssertTrue(waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 40),
                      "tapping the tile did not open a post\n\(app.debugDescription)")
        let opened = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: opened, in: app, timeout: 20), "the post that opened has no text")
        XCTAssertEqual(opened.label, text, "the tile opened a different post")
    }

    // MARK: - Birthday banner

    func testABirthdayTodayIsCelebratedSharedAndDismissedForTheSession() throws {
        // One "today" for the whole run, in the calendar the app reads
        // birthdays in (the same simulator's), taken clear of midnight.
        let today = try todayWellClearOfMidnight()
        let (app, me) = try signInAsNewAccount(
            "birthday-\(run)@petnote.test", extraArguments: ["-petnote-feed-extras-probe"]
        )
        uid = me
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch, in: app, timeout: 60),
            "the feed never loaded\n\(app.debugDescription)"
        )
        // No banner is only a finding once the read that would have drawn one
        // has come back; the probe counts those reads.
        XCTAssertTrue(waitForBannerReads(atLeast: 1, in: app),
                      "the first banner read never came back (probe: \(bannerReads(app)))")
        let banner = app.descendants(matching: .any)["feed.birthday"]
        XCTAssertFalse(banner.exists, "an account with no pets has a birthday banner")

        // Two pets, one with its birthday today and one without. With two the
        // composer chooses neither by itself, so the pet it opens on is the
        // banner's doing.
        let petName = "Cake \(run)"
        let thisYear = try XCTUnwrap(today.year)
        let cakeID = try givePet(
            named: petName, id: "ui-\(run)-cake",
            bornOn: DateComponents(year: thisYear - 3, month: today.month, day: today.day),
            to: me
        )
        let inSixMonths = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: 6, to: Date()))
        var otherDay = Calendar.current.dateComponents([.year, .month, .day], from: inSixMonths)
        otherDay.year = try XCTUnwrap(otherDay.year) - 2
        let plainID = try givePet(named: "Plain \(run)", id: "ui-\(run)-plain", bornOn: otherDay, to: me)

        // Written after the first read, so the banner arriving is the
        // refresh's doing and not the first load's.
        let readsBeforeRefresh = bannerReads(app)
        pullToRefreshFeed(app)
        XCTAssertTrue(waitForBannerReads(atLeast: readsBeforeRefresh + 1, in: app),
                      "the refresh did not read the banner again (probe: \(bannerReads(app)))")
        let title = app.staticTexts["birthday.title"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 30),
                      "no birthday banner after a refresh\n\(app.debugDescription)")
        XCTAssertEqual(title.label, "🎂🎉 Happy Birthday, \(petName)! 🎉🎂")
        XCTAssertEqual(app.staticTexts["birthday.age"].label, "Turning 3 years old today!")

        // "Share a birthday post": the composer, on the birthday pet.
        let share = app.buttons["birthday.share"]
        XCTAssertTrue(waitUntilHittable(share, in: app, timeout: 20), "no way to share a birthday post")
        share.tap()
        let chosen = app.buttons["compose.pet.\(cakeID)"]
        let other = app.buttons["compose.pet.\(plainID)"]
        XCTAssertTrue(waitForExistence(of: chosen, in: app, timeout: 30),
                      "the composer did not open with this account's pets\n\(app.debugDescription)")
        XCTAssertTrue(waitForExistence(of: other, in: app, timeout: 10), "the composer is missing the other pet")
        XCTAssertTrue(waitForSelected(chosen, timeout: 10), "the composer did not start on the birthday pet")
        XCTAssertFalse(other.isSelected, "the composer chose the other pet")
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: chosen, timeout: 20), "the composer did not close")

        // Still there, because nothing dismissed it.
        let dismiss = app.buttons["birthday.dismiss"]
        XCTAssertTrue(waitUntilHittable(dismiss, in: app, timeout: 20), "the banner went away on its own")
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(of: title, timeout: 10), "dismissing did not hide the banner")

        // For the rest of the session: a refresh — one whose read has come
        // back — does not bring it back.
        let readsBeforeSecondRefresh = bannerReads(app)
        pullToRefreshFeed(app)
        XCTAssertTrue(waitForBannerReads(atLeast: readsBeforeSecondRefresh + 1, in: app),
                      "the second refresh did not read the banner, so its absence would prove nothing")
        XCTAssertFalse(title.exists, "a refresh brought a dismissed banner back")

        // And all of the above was about the day the pets were written for.
        XCTAssertEqual(Self.today(), today, "the day changed during the run; the birthday written is yesterday's")
    }

    // MARK: - The day

    /// Today in this device's calendar — the one the app reads birthdays in.
    private static func today() -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: Date())
    }

    /// Today, taken far enough from midnight that the run cannot straddle
    /// it: within ten minutes of midnight this waits for the new day first,
    /// rather than write a birthday that is yesterday's by the time the app
    /// reads it.
    private func todayWellClearOfMidnight() throws -> DateComponents {
        let calendar = Calendar.current
        let now = Date()
        let midnight = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        let left = midnight.timeIntervalSince(now)
        if left < 10 * 60 {
            print("MEASURED \(Int(left))s to midnight; waiting for the new day before writing a birthday")
            Thread.sleep(forTimeInterval: left + 5)
        }
        return Self.today()
    }

    // MARK: - The probe

    /// `bannerReads=N` from the feed's DEBUG-only probe, or -1 without one.
    private func bannerReads(_ app: XCUIApplication) -> Int {
        let probe = app.staticTexts.matching(identifier: "feed.extrasProbe").firstMatch
        guard probe.exists, let range = probe.label.range(of: "bannerReads=") else { return -1 }
        return Int(probe.label[range.upperBound...]) ?? -1
    }

    private func waitForBannerReads(atLeast count: Int, in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSavePasswordSheetIfPresent(app)
            if bannerReads(app) >= count { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return bannerReads(app) >= count
    }

    private func waitForSelected(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isSelected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.exists && element.isSelected
    }

    // MARK: - Emulator writes, and the app's own tidy-up

    /// A pet this account owns, as the clients write one: the canonical
    /// month and day of the birthday, and the legacy timestamp at *local*
    /// midnight of that day — where both clients put it (AddPet.tsx:290-306,
    /// `FirestorePetRepository.birthdayFields`), and where the age comes
    /// from — and the owner's family entry, which is what the app's "my pets"
    /// read looks for.
    private func givePet(named name: String, id: String, bornOn birthday: DateComponents, to uid: String) throws -> String {
        let month = try XCTUnwrap(birthday.month)
        let day = try XCTUnwrap(birthday.day)
        let born = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: birthday.year, month: month, day: day)))

        cleanup.append("pets/\(id)")
        try PlacesMeetupsUITests.write(path: "pets/\(id)", [
            "name": name, "species": "dog", "ownerId": uid, "primaryOwnerId": uid,
            "avatarUrl": "", "createdAt": Date(),
            "birthday": born, "birthdayMonth": month, "birthdayDay": day,
        ])
        cleanup.append("pets/\(id)/family/\(uid)")
        try PlacesMeetupsUITests.write(path: "pets/\(id)/family/\(uid)", [
            "userId": uid, "petId": id, "role": "primary", "relationship": "mom", "joinedAt": Date(),
        ])
        return id
    }

    /// The seen list lives in the app's defaults, so the app removes it: a
    /// launch with the debug-only flag clears it in `PetNoteApp.init`, before
    /// anything else runs, and the sign-in screen appearing says that launch
    /// got that far.
    private func forgetSeenSpotlights(of account: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out", "-petnote-forget-seen-spotlights", account]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 30),
                      "the tidy-up launch never came up, so \(account)'s seen list may still be there")
        app.terminate()
    }
}
