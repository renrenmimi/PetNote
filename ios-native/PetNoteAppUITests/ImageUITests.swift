import XCTest

/// Photos in the real interface: the failure state, the way to see the whole
/// picture, and the promise that nothing moves when the bytes land.
///
/// The broken image here is the seeded one — a Cloudinary public id that does
/// not exist, so the 404 is a property of the URL rather than of the network
/// weather. A CDN that is merely slow would make a different test flake; a
/// public id that was never uploaded returns 404 every time.
final class ImageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func signIn(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"] + extraArguments
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))
        waitForQuietUI(app)
        XCTAssertTrue(
            list(app).cells.firstMatch.waitForExistence(timeout: 90),
            "the feed never showed a row"
        )
        return app
    }

    private func list(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
    }

    /// 5A.7: a photo that cannot load says so and offers a way out, and the
    /// way out is a button rather than the row underneath it.
    func testABrokenPhotoOffersRetryAndTheRetryDoesNotNavigate() {
        let app = signIn()

        var retry = app.buttons["image.retry"].firstMatch
        for _ in 0..<14 where !retry.exists {
            list(app).swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.6)
            retry = app.buttons["image.retry"].firstMatch
        }
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "the 404 photo never offered a retry")

        // §5.6: retrying a photo must not open the post. The whole card is
        // tappable, so the button has to win the tap.
        retry.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            app.navigationBars["PetNote"].exists,
            "tapping retry navigated somewhere instead of retrying"
        )
        // The asset is still missing, so the state it lands back in is the
        // same one — that is the correct end state, not a hung placeholder.
        XCTAssertTrue(
            app.buttons["image.retry"].firstMatch.waitForExistence(timeout: 15),
            "after a failed retry the photo should still offer another"
        )
    }

    /// 6.4: the feed frame crops, so the whole photo has to be reachable —
    /// and the card has to say so.
    func testTheWholePhotoIsReachableFromTheDetailScreen() {
        let app = signIn()

        // Open the first post.
        let firstCard = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 20))
        firstCard.tap()
        XCTAssertTrue(
            app.otherElements["detail.root"].waitForExistence(timeout: 20)
                || app.staticTexts.matching(identifier: "post.text").firstMatch.waitForExistence(timeout: 20),
            "the detail screen never appeared"
        )

        // The hint only appears where there is somewhere to go.
        let hint = app.staticTexts["post.croppedHint"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "no hint that the photo is cropped")

        // The photo itself opens it — identified by what it says it is, not by
        // being the first image on the screen.
        //
        // It was the first image, and that is why this test failed at random:
        // the author's avatar is an `Image` too and comes first in the tree, so
        // whenever the avatar managed to load, this tapped the avatar. Tapping
        // an avatar correctly does nothing, and the failure then landed on the
        // assertion about the full photo — describing the wrong thing.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "no photo element to tap")
        photo.tap()

        let close = app.buttons["fullImage.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "the full photo never opened")
        // Hittable, not merely existing: a cover that is still presenting has
        // its controls in the tree and swallows taps aimed at them, and that
        // reads exactly like a button that does nothing.
        XCTAssertTrue(waitUntilHittable(close, in: app, timeout: 15),
                      "the close control never became tappable")
        close.tap()

        // Closed means *the screen underneath works again*, which is a
        // positive fact about a live query, and not `!close.exists`.
        //
        // The negative form reported this button as doing nothing three times
        // over, and it was wrong every time: polling `exists` once a second
        // held it true for thirty seconds, a quiet six-second wait then one
        // check held it true as well — and the tree dumped immediately after
        // each of those showed the detail screen with no cover on it. A held
        // element's `exists` is answered from a cached snapshot that nothing
        // was invalidating; `app.debugDescription` forces a fresh one, which
        // is why the dump and the assertion disagreed.
        //
        // A full-screen cover takes every touch, so a composer that can be
        // tapped is proof the cover is gone — and the query behind it is made
        // afresh on every attempt.
        // The check is an action, not a reading: go back to the feed. A cover
        // that is still up owns the whole screen, so it would swallow the tap
        // and the feed would never arrive.
        //
        // Readings were tried first and could not settle it. `close.exists`
        // stayed true for thirty seconds of polling, and stayed true after a
        // quiet six-second wait — while `app.debugDescription`, taken
        // immediately after each, showed the detail screen with no cover on
        // it. One of those two is answered from a stale snapshot and the other
        // forces a fresh traversal; which is which cannot be decided from
        // here, and an action does not depend on knowing.
        popToFeed(app)
    }

    /// 6.4: an image arriving must not move anything.
    ///
    /// Images are deliberately delayed by three seconds here
    /// (`-petnoteImageDelayMilliseconds`), because otherwise the placeholder
    /// exists for a few milliseconds on a warm simulator and the interesting
    /// moment cannot be sampled at all. The measurement is the y position of
    /// the actions row underneath a photo, watched across the whole window in
    /// which every visible photo finishes loading.
    func testNothingMovesWhenThePhotosArrive() {
        let app = signIn(extraArguments: ["-petnoteImageDelayMilliseconds", "3000"])

        let anchor = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 30))

        var positions: [CGFloat] = []
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard anchor.exists else { break }
            positions.append(anchor.frame.minY)
            Thread.sleep(forTimeInterval: 0.5)
        }

        let measured = positions.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        print("MEASURED actions-row y across the load window: \(measured)")
        XCTAssertGreaterThan(positions.count, 8, "not enough samples to say anything")
        let first = positions[0]
        for (index, position) in positions.enumerated() {
            XCTAssertEqual(
                position, first, accuracy: 0.5,
                "the row moved by \(position - first)pt at sample \(index) — a photo pushed the layout"
            )
        }
    }
}
