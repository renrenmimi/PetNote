import XCTest

/// Driving the app to a known place, shared by the tests that need to start
/// from one.
///
/// The waits all go through `UITestSupport`'s helpers rather than
/// `waitForExistence`: iOS's "Save Password?" sheet lives in the app's own
/// process and can arrive after the screen it covers, so anything behind it
/// reads as "exists but not hittable" — which looks exactly like a defect and
/// is not one.
extension XCTestCase {
    /// A running app on the sign-in screen.
    ///
    /// `extraArguments` is how the accessibility tests ask for a content size
    /// category; it is passed to the app, not acted on here.
    func launchOnSignIn(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.staticTexts["login.title"].waitForExistence(timeout: 20),
            "Sign-in screen did not appear"
        )
        return app
    }

    func typeCredentials(_ app: XCUIApplication, email: String, password: String) {
        let emailField = app.textFields["login.email"]
        XCTAssertTrue(waitUntilHittable(emailField, in: app), "email field never became usable")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["login.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["login.submit"].tap()
    }

    /// Signed in means the feed's navigation bar is up.
    ///
    /// Not the sign-out button and not the list: the button sits in a toolbar
    /// whose tree settles late, and the list needs a round trip to the emulator
    /// first. The navigation bar is there as soon as the session resolves,
    /// which is the thing being asserted.
    @discardableResult
    func reachedFeed(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: timeout)
    }

    @discardableResult
    func signIn(
        _ app: XCUIApplication,
        email: String,
        password: String = "Passw0rd!x",
        expectFeed: Bool = true
    ) -> XCUIApplication {
        typeCredentials(app, email: email, password: password)
        if expectFeed {
            XCTAssertTrue(reachedFeed(app), "did not reach the feed as \(email)\n\(app.debugDescription)")
            waitForQuietUI(app)
        }
        return app
    }

    /// Opens a post from the feed via its comments button, scrolling to reach
    /// it if it is below the fold.
    ///
    /// The scrolling is not indulgence. At the largest accessibility size a
    /// card is taller than the screen, so the action row of the first card is
    /// genuinely off screen — that is the layout working, not failing, and a
    /// helper that refused to scroll reported it as "no post to open". What
    /// §6.2 actually requires is that the control be *reachable*, which is
    /// what this now establishes.
    ///
    /// At the default type size nothing is off screen and no swipe happens, so
    /// the tests that open the same post twice still get the same post.
    func openFirstPost(_ app: XCUIApplication) {
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(waitForExistence(of: comments, in: app, timeout: 60), "the feed has no posts")

        var reachable = false
        for _ in 0..<10 {
            dismissSavePasswordSheetIfPresent(app)
            if comments.exists, comments.isHittable { reachable = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(reachable, "a post's comments button could not be reached by scrolling")

        comments.tap()
        XCTAssertTrue(
            waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 40),
            "composer never appeared"
        )
    }

    /// Scrolls the feed until the post whose text is `text` is on screen, then
    /// opens it by tapping its text — which is inside the card's own tap
    /// gesture.
    ///
    /// By identity rather than by position: only the cards near the top of the
    /// list are realised, so indexing into the visible controls finds whatever
    /// happens to be on screen, not the post the test means.
    func openPost(_ app: XCUIApplication, withText text: String) {
        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(waitForExistence(of: posts.firstMatch, in: app, timeout: 60),
                      "the feed never loaded")

        let target = posts.containing(NSPredicate(format: "label == %@", text)).firstMatch
        var found = false
        for _ in 0..<15 {
            dismissSavePasswordSheetIfPresent(app)
            if target.exists, target.isHittable { found = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(found, "never found the post \"\(text.prefix(40))\" in the feed")

        target.tap()
        XCTAssertTrue(
            waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 40),
            "tapping the post did not open it"
        )
    }

    /// Back to the feed from a pushed screen, via the navigation bar.
    func popToFeed(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(waitUntilHittable(back, in: app, timeout: 20), "no back button")
        back.tap()
        XCTAssertTrue(
            waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 30),
            "did not return to the feed"
        )
    }

    /// A pull-to-refresh that is actually a pull.
    ///
    /// `swipeDown()` is a flick, and a flick is not reliably the gesture
    /// `.refreshable` responds to. Two tests spent a run reporting that the
    /// app had not adopted a change the app had never been asked to go and
    /// look for — the screen was right, the gesture was not. The list is
    /// brought to the top first, because a downward drag anywhere else only
    /// scrolls.
    func pullToRefreshFeed(_ app: XCUIApplication) {
        for _ in 0..<6 { app.swipeDown() }
        waitForQuietUI(app, quietFor: 1, timeout: 15)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
        waitForQuietUI(app, quietFor: 1, timeout: 20)
    }

    /// Which post the first row is, as a document id.
    ///
    /// The seed writes the index into every post's text — `[#007]` — and the
    /// prefix comes from the pinned manifest. Neither half is written down in
    /// a test: each seed run has its own namespace, so a literal
    /// `ios-post-007` would now name a document from no run at all, or from an
    /// abandoned one whose self-checks had failed.
    func firstPostID(in app: XCUIApplication) -> String? {
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        guard waitForExistence(of: text, in: app, timeout: 30) else { return nil }
        guard let range = text.label.range(of: #"\[#(\d+)\]"#, options: .regularExpression),
              let index = Int(text.label[range].dropFirst(2).dropLast()),
              let manifest = try? EmulatorAdmin.seedManifest() else { return nil }
        return manifest.post(index: index)
    }

    /// Comments whose text contains `needle`, counted as comments rather than
    /// as accessibility elements: a combined row and the `Text` inside it both
    /// match a plain label search, which reports two where there is one.
    func commentRows(in app: XCUIApplication, containing needle: String) -> [XCUIElement] {
        app.staticTexts.matching(identifier: "comment.row").allElementsBoundByIndex
            .filter { $0.exists && $0.label.contains(needle) }
    }

    /// Fails unless the server holds exactly `expected` comments with this text.
    ///
    /// This is the assertion that actually answers "was it written": the screen
    /// can only ever say what the app drew.
    func assertServerCommentCount(
        _ text: String,
        equals expected: Int,
        settleFor seconds: TimeInterval = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // A second send, if there is going to be one, has to be given time to
        // land before the count means anything.
        let deadline = Date().addingTimeInterval(seconds)
        var found: [String] = []
        while Date() < deadline {
            found = (try? EmulatorAdmin.commentDocumentIDs(withExactText: text)) ?? []
            if found.count > expected { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(
            found.count, expected,
            "the server holds \(found.count) comments with this text, expected \(expected)",
            file: file, line: line
        )
    }
}
