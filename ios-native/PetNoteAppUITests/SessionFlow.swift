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
    func launchOnSignIn(
        extraArguments: [String] = [], file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"] + extraArguments

        // Two attempts, because a launch that hangs does not only lose its own
        // test. Measured on a loaded machine: one case waited 762 seconds for
        // the app to go idle, ended in kAXErrorServerNotFound — the
        // accessibility service never came up — and left process 29459 alive.
        // The *next* test then failed in setUp with "Failed to terminate
        // dev.local.petnote.native:29459", which is a report about the
        // previous failure wearing the words of a new one.
        //
        // Terminating before the retry is the part that matters; relaunching
        // on top of a wedged process reproduces the wedge.
        for attempt in 1...2 {
            app.launch()
            if app.staticTexts["login.title"].waitForExistence(timeout: 30) { return app }
            if attempt == 1 {
                app.terminate()
                _ = app.wait(for: .notRunning, timeout: 30)
            }
        }
        XCTFail(
            "Sign-in screen did not appear after two launches\n\(app.debugDescription)",
            file: file, line: line
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
    /// Closes onboarding if it is offered — the session-only dismissal the web
    /// client has. A fresh account, or one whose profile the app had to create,
    /// has not been through it, and it covers the feed until closed.
    ///
    /// Waits for Close to be *hittable*, not only present. Right after a
    /// sign-in, while the screen is still settling, XCUITest computes no hit
    /// point for anything in the app ("{-1, -1}"): a tap sent then is dropped
    /// without an error, onboarding stays up, and every tap after it lands on
    /// nothing. Three journeys failed that way before this waited.
    func dismissOnboardingIfShown(_ app: XCUIApplication, timeout: TimeInterval = 15) {
        let close = app.buttons["onboarding.close"]
        guard close.waitForExistence(timeout: timeout) else { return }
        XCTAssertTrue(waitUntilHittable(close, in: app, timeout: 20), "onboarding's Close never became tappable")
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "onboarding did not close")
    }

    /// Moves a list up by about a quarter of the screen, slowly enough that it
    /// stops where it is put rather than flinging on past the row.
    func nudgeListUp(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    func openFirstPost(_ app: XCUIApplication) {
        let comments = app.buttons.matching(identifier: "post.comments").firstMatch
        XCTAssertTrue(waitForExistence(of: comments, in: app, timeout: 60), "the feed has no posts")

        var reachable = false
        for _ in 0..<10 {
            dismissSavePasswordSheetIfPresent(app)
            if comments.exists, comments.isHittable { reachable = true; break }
            // In the lower half, the first card's action row is under the tab
            // bar or just past the list's edge: a small move brings it up. A
            // full swipe from there carried that card off the top of the
            // screen, and the next card's row landed under the bar again.
            if comments.exists, comments.frame.midY > app.windows.firstMatch.frame.midY {
                nudgeListUp(app)
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(
            reachable,
            """
            a post's comments button could not be reached by scrolling; \
            last at \(comments.frame) in \(app.windows.firstMatch.frame)
            \(app.debugDescription)
            """
        )

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
        // The pushed screen's own bar, not `app.navigationBars` as a whole.
        //
        // That query spans every bar in the tree, and index 0 of it is
        // whichever one the tree happens to list first. The feed's bar is
        // still there underneath, and it carried the sign-out button until it moved into the account menu — so
        // "no back button" was sometimes a report about the wrong bar, and
        // tapping index 0 could have ended the session instead of going back.
        // The same mistake, in the touch-target measurement, did exactly that.
        // Frames read in the same pass that selects, and kept as values.
        // Gathering elements and then reading `.frame` off them is two
        // traversals of a tree that moves, and the second one fails with
        // "Failed to get matching snapshot" — which reads like a missing
        // control. This is the fifth place in this suite to make that
        // mistake; the shape is the tell, not the symptom.
        let bar = app.navigationBars.allElementsBoundByIndex
            .compactMap { element -> (XCUIElement, CGRect)? in
                guard element.exists, element.identifier != "PetNote" else { return nil }
                let frame = element.frame
                return frame.isEmpty ? nil : (element, frame)
            }
            .first?.0 ?? app.navigationBars.firstMatch
        let back = bar.buttons.allElementsBoundByIndex
            .compactMap { button -> (XCUIElement, CGFloat)? in
                guard button.exists else { return nil }
                let frame = button.frame
                return frame.isEmpty ? nil : (button, frame.minX)
            }
            .min { $0.1 < $1.1 }?.0 ?? bar.buttons.firstMatch
        // The diagnosis is gathered *before* the assertion, in one pass, and
        // kept as text.
        //
        // It used to be built inline in the failure message, which meant it
        // re-walked the tree reading .frame and .isHittable — and it was only
        // ever evaluated when the tree was already in trouble. So the
        // diagnostic threw "Failed to get matching snapshot" and replaced the
        // diagnosis it existed to provide.
        let diagnosis = app.navigationBars.allElementsBoundByIndex
            .compactMap { navigationBar -> String? in
                guard navigationBar.exists else { return nil }
                let buttons = navigationBar.buttons.allElementsBoundByIndex
                    .compactMap { button -> String? in
                        guard button.exists else { return nil }
                        let name = button.identifier.isEmpty ? button.label : button.identifier
                        return "\(name)@\(button.frame)"
                    }
                return "\(navigationBar.identifier): [\(buttons.joined(separator: ", "))]"
            }
            .joined(separator: "\n  ")

        XCTAssertTrue(
            waitUntilHittable(back, in: app, timeout: 20),
            """
            no back button on the pushed screen.
              \(diagnosis)
            """
        )
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

// MARK: - The account menu

extension XCTestCase {
    /// Opens the account menu and waits until its own control can be tapped.
    ///
    /// Two waits, not one. The entry being hittable says the navigation bar has
    /// settled; the row being hittable says the sheet has finished presenting.
    /// Waiting only on the row would pass the moment the sheet exists, which is
    /// before it has stopped moving, and a tap during a presentation animation
    /// lands where the row is going to be rather than where it is.
    func openAccountMenu(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let entry = app.buttons["account.menu"]
        XCTAssertTrue(
            waitUntilHittable(entry, in: app, timeout: 30),
            "the account entry is not reachable\n\(app.debugDescription)", file: file, line: line
        )
        entry.tap()
        XCTAssertTrue(
            waitUntilHittable(app.buttons["session.signOut"], in: app, timeout: 20),
            "the account menu did not open\n\(app.debugDescription)", file: file, line: line
        )
    }

    /// Closes the menu without signing out: a tap on the dimmed area above it,
    /// falling back to a downward drag.
    ///
    /// Deliberately not "tap something inside the menu": the point of the
    /// helper is that leaving the menu and ending the session are different
    /// things, so it must not go near the row that ends it.
    func closeAccountMenu(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        let bounds = window.frame
        let origin = window.coordinate(withNormalizedOffset: .zero)
        // Dragged down by the header, not flicked at the middle of the screen.
        // `app.swipeDown()` starts at the centre of the app's frame, which is
        // the dimmed area *behind* the sheet, so it reaches nothing; and a tap
        // on that dimmed area did not dismiss this sheet either (measured).
        // The header is also the one part of the menu that is safe to grab:
        // the gesture never begins on the control that ends the session.
        let headerY = max(bounds.minY + 1, app.buttons["session.signOut"].frame.minY - 30)
        origin.withOffset(CGVector(dx: bounds.midX, dy: headerY))
            .press(
                forDuration: 0.1,
                thenDragTo: origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.maxY - 2)),
                withVelocity: .default,
                thenHoldForDuration: 0.1
            )
        var deadline = Date().addingTimeInterval(6)
        while Date() < deadline, app.buttons["session.signOut"].exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if app.buttons["session.signOut"].exists {
            origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + bounds.height * 0.15)).tap()
            deadline = Date().addingTimeInterval(6)
            while Date() < deadline, app.buttons["session.signOut"].exists {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        XCTAssertFalse(
            app.buttons["session.signOut"].exists,
            "the account menu would not close", file: file, line: line
        )
    }

    /// Menu, then sign-out: the two taps the product now asks for.
    func signOutFromAccountMenu(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        openAccountMenu(app, file: file, line: line)
        app.buttons["session.signOut"].tap()
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 20),
            "did not return to sign-in after signing out\n\(app.debugDescription)",
            file: file, line: line
        )
    }
}
