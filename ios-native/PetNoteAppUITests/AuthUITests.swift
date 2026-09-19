import XCTest

/// Writes a screenshot somewhere a human can open it. XCTAttachment only ends
/// up inside the result bundle, which is awkward to get at from a terminal.
private func saveScreenshot(_ app: XCUIApplication, named name: String) {
    let data = XCUIScreen.main.screenshot().pngRepresentation
    let url = URL(fileURLWithPath: "/tmp/petnote-uitest-\(name).png")
    try? data.write(to: url)
}

/// Acceptance 4.1, 4.5, 4.6 at the UI level, against the emulator.
///
/// L4: these assert the behaviour that is asserted. They say nothing about how
/// the screen looks on a phone, or about the keyboard — the keyboard cannot be
/// raised programmatically on iOS at all, so that evidence is L5 and needs a
/// person to tap once.
final class AuthUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchSignedOut() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15),
                      "Sign-in screen did not appear")
        return app
    }

    /// Signed in means the feed's navigation bar is up.
    ///
    /// Not the sign-out button and not the list: the button is inside a
    /// toolbar whose tree settles late, and the list needs a round trip to the
    /// emulator first. The navigation bar is there as soon as the session
    /// resolves, which is the thing being asserted.
    private func reachedFeed(_ app: XCUIApplication, timeout: TimeInterval = 40) -> Bool {
        waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: timeout)
    }

    private func signIn(_ app: XCUIApplication, email: String, password: String) {
        let emailField = app.textFields["login.email"]
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["login.password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["login.submit"].tap()
    }

    /// 4.1 — a seeded, verified account reaches the signed-in state.
    func testSignInWithSeededAccount() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "Passw0rd!x")

        XCTAssertTrue(reachedFeed(app), "Did not reach the feed.\n\(app.debugDescription)")
    }

    /// 4.5 — the wrong password produces our words, never the SDK's.
    func testWrongPasswordShowsOurMessageNotTheSDKs() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "definitely-not-the-password")

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app), "No error was shown")
        XCTAssertEqual(error.label, "That email and password do not match an account.")

        // Nothing from the SDK may reach the screen.
        for leak in ["FIRAuth", "INVALID_PASSWORD", "ERROR_", "NSError", "Firebase", "17009"] {
            XCTAssertFalse(error.label.contains(leak), "Raw error leaked: \(leak)")
        }
        // And it must still be possible to try again.
        XCTAssertTrue(app.buttons["login.submit"].isEnabled)
    }

    /// The same message for a nonexistent account: telling the two apart would
    /// be an account-enumeration oracle.
    func testUnknownAccountShowsTheSameMessage() {
        let app = launchSignedOut()
        signIn(app, email: "nobody-here@example.com", password: "Passw0rd!x")

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app))
        XCTAssertEqual(error.label, "That email and password do not match an account.")
    }

    /// 4.6 — an unverified account signs in and sees the feed.
    ///
    /// Signing in is all that is asserted here on purpose: verification gates
    /// what may be *written*, and the server is what enforces that. The other
    /// half of 4.6 — a comment from this account being refused with the right
    /// words — belongs with the comment tests.
    func testUnverifiedAccountSignsIn() {
        let app = launchSignedOut()
        signIn(app, email: "accept-new@example.com", password: "Passw0rd!x")

        XCTAssertTrue(
            reachedFeed(app),
            "Unverified account did not reach the feed.\n\(app.debugDescription)"
        )
    }

    /// Every control on the signed-in screen, not just the one a test happens
    /// to tap. The sign-out button shipped 20pt tall and untappable because
    /// .frame(minHeight:) was on the Button rather than its label; a check that
    /// names one button would have missed the next one.
    func testEveryControlMeetsTheMinimumTouchTarget() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "Passw0rd!x")
        XCTAssertTrue(reachedFeed(app))
        waitForQuietUI(app)

        // Only our own controls: a control is ours if we gave it an identifier.
        // The save-password sheet's buttons are the system's and are not what
        // this is asserting about.
        // Visible ones only. A list keeps rows below the fold in the
        // accessibility tree, and a control that is off screen is not hittable
        // by definition — counting those would report a defect that is really
        // just scrolling.
        let window = app.windows.firstMatch.frame
        let ours = app.buttons.allElementsBoundByIndex.filter {
            $0.exists && $0.isEnabled && !$0.identifier.isEmpty
                && !$0.frame.isEmpty && window.intersects($0.frame)
        }
        XCTAssertFalse(ours.isEmpty, "No identified controls found to check")

        // Two rules, because XCUITest reports geometry and the requirement is
        // about the touch area, and those are the same number only for controls
        // we lay out ourselves.
        //
        //   - Content controls: we own the layout, so .contentShape makes the
        //     frame the hit area. Size is checkable and is checked.
        //   - Navigation bar items: the bar is 44pt tall and lays items out
        //     inside it, so the label measures ~36pt however it is written
        //     (measured: .frame(minHeight:) and padding both leave it at 36).
        //     UIKit extends the touch area past the label, which is why these
        //     are asserted hittable rather than tall.
        //
        // The gap this leaves — whether the extended area is really 44pt — is
        // not measurable from here. It needs a device and a person, and is
        // recorded as such rather than asserted away.
        // A closure, not a key path: XCUIElement's properties are main-actor
        // isolated and a key path cannot cross that boundary.
        let barButtonIDs = Set(
            app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists }
                .map { $0.identifier }
        )

        for button in ours {
            if barButtonIDs.contains(button.identifier) {
                // waitUntilHittable, not a bare assertion: the save-password
                // sheet can arrive late and cover the bar, which is not a
                // touch-target defect.
                XCTAssertTrue(
                    waitUntilHittable(button, in: app, timeout: 10),
                    "\(button.identifier) is not hittable"
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    button.frame.height, 44,
                    "\(button.identifier) is \(button.frame.height)pt tall"
                )
                XCTAssertTrue(button.isHittable, "\(button.identifier) is not hittable")
            }
        }
    }

    /// 4.4 — signing out returns to the sign-in screen.
    func testSignOutReturnsToSignIn() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "Passw0rd!x")
        XCTAssertTrue(reachedFeed(app))

        let signOut = app.buttons["session.signOut"]
        if !waitUntilHittable(signOut, in: app) {
            saveScreenshot(app, named: "signout-not-hittable")
            XCTFail("""
                Sign out button is not hittable.
                frame: \(signOut.frame)
                window: \(app.windows.firstMatch.frame)
                \(app.debugDescription)
                """)
        }
        signOut.tap()
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 10),
            "Did not return to sign-in after signing out.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.buttons["session.signOut"].exists,
                       "Still in the signed-in state after signing out")
    }
}
