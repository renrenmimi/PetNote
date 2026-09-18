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

        let account = app.staticTexts["session.email"]
        XCTAssertTrue(
            account.waitForExistence(timeout: 20),
            "Did not reach the signed-in state.\n\(app.debugDescription)"
        )
        XCTAssertEqual(account.label, "Account: accept-a@example.com")
    }

    /// 4.5 — the wrong password produces our words, never the SDK's.
    func testWrongPasswordShowsOurMessageNotTheSDKs() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "definitely-not-the-password")

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 20), "No error was shown")
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
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        XCTAssertEqual(error.label, "That email and password do not match an account.")
    }

    /// 4.6 — an unverified account signs in; the gate is on what it may do
    /// afterwards, which the server enforces.
    func testUnverifiedAccountSignsInAndIsMarkedUnverified() {
        let app = launchSignedOut()
        signIn(app, email: "accept-new@example.com", password: "Passw0rd!x")

        let account = app.staticTexts["session.email"]
        XCTAssertTrue(account.waitForExistence(timeout: 20), "Unverified account did not sign in")
        XCTAssertEqual(account.label, "Account: accept-new@example.com")

        let verified = app.staticTexts["session.verified"]
        XCTAssertTrue(verified.waitForExistence(timeout: 5))
        XCTAssertEqual(verified.label, "Email verified: no")
    }

    /// Every control on the signed-in screen, not just the one a test happens
    /// to tap. The sign-out button shipped 20pt tall and untappable because
    /// .frame(minHeight:) was on the Button rather than its label; a check that
    /// names one button would have missed the next one.
    func testEveryControlMeetsTheMinimumTouchTarget() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "Passw0rd!x")
        XCTAssertTrue(app.staticTexts["session.email"].waitForExistence(timeout: 20))

        let buttons = app.buttons.allElementsBoundByIndex
        XCTAssertFalse(buttons.isEmpty, "No buttons found to check")
        for button in buttons where button.exists && button.isEnabled {
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(
                frame.height, 44,
                "\(button.label) is \(frame.height)pt tall"
            )
            XCTAssertTrue(button.isHittable, "\(button.label) is not hittable")
        }
    }

    /// 4.4 — signing out returns to the sign-in screen.
    func testSignOutReturnsToSignIn() {
        let app = launchSignedOut()
        signIn(app, email: "accept-a@example.com", password: "Passw0rd!x")
        XCTAssertTrue(app.staticTexts["session.email"].waitForExistence(timeout: 20))

        let signOut = app.buttons["session.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "Sign out button missing")
        if !signOut.isHittable {
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
            app.staticTexts["login.title"].waitForExistence(timeout: 10),
            "Did not return to sign-in after signing out.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.staticTexts["session.email"].exists,
                       "Previous account still visible after sign-out")
    }
}
