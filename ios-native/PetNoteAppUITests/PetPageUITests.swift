import XCTest

/// A pet's page, reached the way a visitor reaches it, for a pet whose posts
/// include a video.
///
/// The page lists the pet's posts as the feed's own cards, and a video card
/// takes the playback coordinator from the environment. The pet page was
/// pushed without one, so the app crashed as soon as a video card was built
/// (found by `SearchUITests`' discover walk, 2026-09-24). The seed's Mochi
/// has a video among its first posts (`seed-ios-native.mjs`, VIDEO_INDEXES).
final class PetPageUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var uid: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testAPetWhosePostsIncludeAVideoOpensAndStaysOpen() throws {
        let (app, me) = try signInAsNewAccount("pet-page-\(run)@petnote.test")
        uid = me

        let search = app.buttons["feed.search"]
        XCTAssertTrue(waitUntilHittable(search, in: app, timeout: 30), "no search on the feed")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "no search field\n\(app.debugDescription)")
        field.tap()
        field.typeText("Mochi\n")
        // BEGINSWITH: the result's own Follow button is labelled "Follow Mochi".
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mochi")).firstMatch
        XCTAssertTrue(waitUntilHittable(result, in: app, timeout: 30), "search did not find Mochi\n\(app.debugDescription)")
        result.tap()

        let name = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: name, in: app, timeout: 30), "the pet page did not open")
        XCTAssertEqual(name.label, "Mochi")

        // Down the page until a video card has been built.
        let video = app.otherElements.matching(identifier: "video.surface").firstMatch
        for _ in 0..<8 where !video.exists {
            app.swipeUp()
        }
        XCTAssertTrue(video.waitForExistence(timeout: 20), "no video card on Mochi's page\n\(app.debugDescription)")
        // Still this app, still this page: the crash took the whole app down.
        XCTAssertEqual(app.state, .runningForeground, "the app is not running after a video card was drawn")
        XCTAssertTrue(app.staticTexts["pet.name"].exists || app.navigationBars.buttons["BackButton"].exists,
                      "the pet page is gone\n\(app.debugDescription)")
    }
}
