import XCTest

/// The half of the comment gates that can be produced for real: an unverified
/// account really being refused by the server, a comment really being posted,
/// and the composer surviving a trip away from the screen.
///
/// The branches that need a ban, a block, or a lost response are asserted in
/// PostDetailViewModelTests with injected errors — putting the emulator into
/// those states would mean seeding data that looks like moderation, and losing
/// a response on purpose is not something a UI test can do.
final class CommentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(signedInAs email: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))

        let emailField = app.textFields["login.email"]
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["login.password"]
        passwordField.tap()
        passwordField.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(
            waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40),
            "did not reach the feed"
        )
        waitForQuietUI(app)
        return app
    }

    /// Comments whose text contains `needle`, counted as comments rather than
    /// as accessibility elements: a combined row and the Text inside it both
    /// match a plain label search, which reports two where there is one.
    private func commentRows(in app: XCUIApplication, containing needle: String) -> [XCUIElement] {
        app.staticTexts.matching(identifier: "comment.row").allElementsBoundByIndex
            .filter { $0.exists && $0.label.contains(needle) }
    }

    private func openFirstPost(_ app: XCUIApplication) {
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(waitUntilHittable(comments, in: app, timeout: 30), "no post to open")
        comments.tap()
        XCTAssertTrue(
            waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 30),
            "composer never appeared"
        )
    }

    /// 4.6's second half: the server refuses, and the words come from us.
    func testUnverifiedAccountIsRefusedWithOurWords() {
        let app = launch(signedInAs: "accept-new@example.com")
        openFirstPost(app)

        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText("TEST CONTENT from an unverified account")
        app.buttons["composer.send"].tap()

        let error = app.staticTexts["composer.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 30), "no refusal was shown")
        XCTAssertEqual(error.label, "Verify your email before commenting.")

        // Nothing from the SDK, and no claim that it merely failed.
        for leak in ["FIRFunctions", "permission-denied", "PERMISSION_DENIED", "NSError", "Error Domain"] {
            XCTAssertFalse(error.label.contains(leak), "raw error leaked: \(leak)")
        }
        // The text is still there to fix or copy.
        XCTAssertTrue(
            app.textFields["composer.field"].value as? String != "Add a comment",
            "the typed comment was thrown away"
        )
    }

    /// A verified account posts, and the comment appears without a refresh.
    func testVerifiedAccountCanComment() {
        let app = launch(signedInAs: "accept-a@example.com")
        openFirstPost(app)

        let unique = "TEST CONTENT native \(Int(Date().timeIntervalSince1970))"
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(unique)
        app.buttons["composer.send"].tap()

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "comment.row")
                .containing(NSPredicate(format: "label CONTAINS %@", unique)).firstMatch,
                in: app, timeout: 30),
            "the comment never appeared in the list"
        )
        XCTAssertFalse(
            app.staticTexts["composer.error"].exists,
            "a successful send should not show an error"
        )
    }

    /// Tapping send twice quickly must not post twice. The composer disables
    /// while sending, but the count is what is asserted, not the disabling.
    func testDoubleTapSendPostsOneComment() {
        let app = launch(signedInAs: "accept-a@example.com")
        openFirstPost(app)

        let unique = "TEST CONTENT double \(Int(Date().timeIntervalSince1970))"
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(unique)

        let send = app.buttons["composer.send"]
        send.tap()
        send.tap()   // immediately again

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "comment.row")
                .containing(NSPredicate(format: "label CONTAINS %@", unique)).firstMatch,
                in: app, timeout: 30)
        )
        // Let any second send land before counting.
        Thread.sleep(forTimeInterval: 4)
        let rows = commentRows(in: app, containing: unique)
        XCTAssertEqual(rows.count, 1, "the comment was posted \(rows.count) times")
    }

    /// Leaving the screen and coming back must not lose a draft the person has
    /// not sent — and must not silently send it either.
    func testLeavingWithAnUnsentDraftDoesNotSendIt() {
        let app = launch(signedInAs: "accept-a@example.com")
        openFirstPost(app)

        let unique = "TEST CONTENT unsent \(Int(Date().timeIntervalSince1970))"
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(unique)

        // Back to the feed without sending.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 20))
        openFirstPost(app)

        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(
            commentRows(in: app, containing: unique).count, 0,
            "an unsent draft was posted by leaving the screen"
        )
    }
}
