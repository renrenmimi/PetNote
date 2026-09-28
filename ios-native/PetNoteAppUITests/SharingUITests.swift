import XCTest

/// Sharing a post, through the screens: the menu, the copied link (a test
/// build's, which opens the app), opening that link, and iOS's own share
/// sheet for the link and for the card.
///
/// The test process may not read the pasteboard — iOS refuses a process in
/// the background ("Operation not authorized", measured on the first run) —
/// so the copied link is pasted into the app's own comment box and read from
/// there. What the card looks like is `SharingTests`; here it is only that
/// the sheet opens for it and copying from it does not fail.
final class SharingUITests: XCTestCase {
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

    func testCopyTheLinkShareItAndShareTheCard() throws {
        let email = "share-\(run)@petnote.test"
        let (app, me) = try signInAsNewAccount(email)
        uid = me

        // In the feed, every post has the button.
        let feedShare = app.buttons.matching(identifier: "post.share").firstMatch
        XCTAssertTrue(waitUntilHittable(feedShare, in: app, timeout: 30), "no share button in the feed\n\(app.debugDescription)")

        // Open the first post, and share from there.
        let firstText = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitUntilHittable(firstText, in: app, timeout: 20))
        firstText.tap()
        let composer = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(composer, in: app, timeout: 20), "the post did not open\n\(app.debugDescription)")
        let shownText = app.staticTexts.matching(identifier: "post.text").firstMatch.label

        // A tall photo leaves the post's buttons under the comment box, where
        // a tap lands on Send instead (measured: share at y 793, Send at 788).
        // Drag the post up until they are clear of it.
        let share = app.buttons["post.share"]
        for _ in 0..<4 where share.frame.maxY > composer.frame.minY - Spacing.clearance {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertLessThan(share.frame.maxY, composer.frame.minY, "the share button is still under the comment box")
        share.tap()
        let copy = app.buttons["Copy Link"]
        XCTAssertTrue(waitUntilHittable(copy, in: app, timeout: 10), "no Copy Link\n\(app.debugDescription)")
        copy.tap()

        // Paste it into the comment box — the app reads its own pasteboard.
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "no Paste in the edit menu\n\(app.debugDescription)")
        paste.tap()
        let pasted = try XCTUnwrap(composer.value as? String)
        let link = try XCTUnwrap(URL(string: pasted), "not a link: \(pasted)")
        // A test build links to the app, not to the website: the website
        // reads production, where this emulator's post does not exist.
        XCTAssertEqual(link.scheme, "petnote", "\(link)")
        XCTAssertEqual(link.host(), "post", "\(link)")
        let postID = String(link.path().dropFirst())
        // The link is to *this* post: its text on the server is what is on screen.
        let post = try XCTUnwrap(try JourneyAdmin.fields(path: "posts/\(postID)"), "the link names no post: \(link)")
        XCTAssertEqual(JourneyAdmin.string(post["text"]), shownText, "the link is to another post")
        // Not sent: clear the box.
        composer.tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: pasted.count))

        // Share to…: iOS's sheet opens, and closes again.
        share.tap()
        app.buttons["Share to…"].tap()
        XCTAssertTrue(waitForShareSheet(app), "the share sheet did not open\n\(app.debugDescription)")
        closeShareSheet(app)

        // Share as Image: the sheet opens for the card, and copying from it
        // hands the card over without the app failing.
        share.tap()
        app.buttons["Share as Image"].tap()
        XCTAssertTrue(waitForShareSheet(app), "the share sheet did not open for the card\n\(app.debugDescription)")
        // iOS offers what it offers for a picture — "Assign to Contact" and
        // "Print" are only there for an image, which is the first sign the
        // card went over as one. Its actions are cells, not buttons.
        XCTAssertTrue(app.cells["Assign to Contact"].waitForExistence(timeout: 15),
                      "the sheet does not treat the card as a picture\n\(app.debugDescription)")
        let sheetCopy = app.cells["Copy"]
        XCTAssertTrue(waitUntilHittable(sheetCopy, in: app, timeout: 15), "the sheet has no Copy\n\(app.debugDescription)")
        sheetCopy.tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["ActivityListView"])
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 20), .completed,
                       "the sheet stayed open after Copy\n\(app.debugDescription)")
        // Exists, not hittable: the comment box takes its focus back when the
        // sheet closes, and the keyboard then covers the post's buttons.
        XCTAssertTrue(share.exists, "the post was not there after copying the card\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)

        // And the copied link works. First with the app running: from the
        // feed, the system opens the link and the app shows that post.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(waitForExistence(of: app.buttons.matching(identifier: "post.share").firstMatch, in: app, timeout: 20))
        XCTAssertFalse(app.textFields["composer.field"].exists, "still on the post")
        XCUIDevice.shared.system.open(link)
        confirmOpenInAppIfAsked()
        XCTAssertTrue(waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 20),
                      "the link opened nothing in the running app\n\(app.debugDescription)")
        XCTAssertEqual(app.staticTexts.matching(identifier: "post.text").firstMatch.label, shownText,
                       "the link opened another post")

        // Then from cold: `open` relaunches the app, which these tests start
        // signed out — so the link arrives before anyone is signed in, and
        // must open once someone is (measured: the relaunch lands on sign-in).
        app.open(link)
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 30), "the relaunch did not land on sign-in")
        _ = signIn(app, email: email, expectFeed: false)
        XCTAssertTrue(waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 40),
                      "a link from before sign-in was not opened after it\n\(app.debugDescription)")
        XCTAssertEqual(app.staticTexts.matching(identifier: "post.text").firstMatch.label, shownText)
    }

    /// iOS may ask before handing a link to an app; answer yes if it does.
    private func confirmOpenInAppIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private enum Spacing { static let clearance: CGFloat = 8 }

    private func waitForShareSheet(_ app: XCUIApplication) -> Bool {
        let sheet = app.otherElements["ActivityListView"]
        let close = app.buttons["Close"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if sheet.exists || close.exists { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func closeShareSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"]
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["ActivityListView"])
        _ = XCTWaiter().wait(for: [gone], timeout: 10)
    }
}
