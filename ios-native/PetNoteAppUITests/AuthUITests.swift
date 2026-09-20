import XCTest

/// Writes a screenshot somewhere a human can open it. XCTAttachment only ends
/// up inside the result bundle, which is awkward to get at from a terminal.
private func saveScreenshot(_ app: XCUIApplication, named name: String) {
    let data = XCUIScreen.main.screenshot().pngRepresentation
    let url = URL(fileURLWithPath: "/tmp/petnote-uitest-\(name).png")
    try? data.write(to: url)
}

/// Acceptance 4.1, 4.3–4.6 and 6.9 at the UI level, against the emulator.
///
/// L4: these assert the behaviour that is asserted. They say nothing about how
/// the screen looks on a phone, or about the keyboard — the keyboard cannot be
/// raised programmatically on iOS at all, so that evidence is L5 and needs a
/// person to tap once.
///
/// 4.3 and 4.4 are written as **L5** in the matrix because they are about a
/// device. What is here is the same behaviour asserted one layer down; it does
/// not discharge the L5 requirement and is not claimed to.
final class AuthUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    /// 4.1 — a seeded, verified account reaches the signed-in state.
    func testSignInWithSeededAccount() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
    }

    /// 4.5 — the wrong password produces our words, never the SDK's.
    func testWrongPasswordShowsOurMessageNotTheSDKs() {
        let app = launchOnSignIn()
        typeCredentials(app, email: "accept-a@example.com", password: "definitely-not-the-password")

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
        let app = launchOnSignIn()
        typeCredentials(app, email: "nobody-here@example.com", password: "Passw0rd!x")

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
        let app = launchOnSignIn()
        signIn(app, email: "accept-new@example.com")
    }

    // MARK: - 4.3 Restoring a session

    /// A cold start with a session must not show the sign-in screen on the way.
    ///
    /// The assertion is the *absence*: waiting for the feed and then declaring
    /// success would pass just as happily on a build that flashed sign-in for
    /// half a second first, which is the thing 4.3 is about.
    func testColdStartRestoresTheSessionWithoutShowingSignIn() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")

        app.terminate()
        // No -petnote-start-signed-out this time: this is what a person's
        // second launch looks like.
        app.launchArguments = []
        app.launch()

        let deadline = Date().addingTimeInterval(60)
        var sawFeed = false
        while Date() < deadline {
            dismissSavePasswordSheetIfPresent(app)
            if app.staticTexts["login.title"].exists {
                saveScreenshot(app, named: "cold-start-showed-signin")
                XCTFail("The sign-in screen appeared during a restore.\n\(app.debugDescription)")
                return
            }
            if app.navigationBars["PetNote"].exists { sawFeed = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawFeed, "Never reached the feed on a cold start.\n\(app.debugDescription)")
    }

    // MARK: - 4.4 Signing out, and the next account

    /// 4.4 — signing out returns to the sign-in screen.
    func testSignOutReturnsToSignIn() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")

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
            waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 20),
            "Did not return to sign-in after signing out.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.buttons["session.signOut"].exists,
                       "Still in the signed-in state after signing out")
        // Someone who tapped "sign out" knows why they are here. Saying their
        // session ended would be telling them something untrue.
        XCTAssertFalse(app.staticTexts["login.sessionExpired"].exists,
                       "A deliberate sign-out was reported as an expired session")
    }

    /// 4.4's second half: nothing of the previous account survives into the
    /// next one — not the screen it was on, and not what was typed into it.
    func testTheNextAccountInheritsNothingFromTheLastOne() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let draft = "TEST CONTENT a3 draft that must not travel"
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(draft)
        popToFeed(app)

        let signOut = app.buttons["session.signOut"]
        XCTAssertTrue(waitUntilHittable(signOut, in: app, timeout: 20), "sign out is not reachable")
        signOut.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 20))

        signIn(app, email: "accept-b@example.com")

        // The stack is back at its root: the previous account's screen is gone.
        XCTAssertFalse(
            app.textFields["composer.field"].exists,
            "the previous account's post detail was still on the stack"
        )

        openFirstPost(app)
        let value = app.textFields["composer.field"].value as? String
        XCTAssertEqual(
            value, "Add a comment",
            "the previous account's draft came along: \(String(describing: value))"
        )
        XCTAssertEqual(
            commentRows(in: app, containing: draft).count, 0,
            "an unsent draft from the previous account was posted"
        )
    }

    // MARK: - 6.9 A session revoked on the server

    /// The server takes the session away while the app is in the background,
    /// and the app finds out when it comes back.
    ///
    /// Disabling the account rather than deleting it, because the uid has to
    /// survive: the place the person was is only given back to the same
    /// account, so deleting and recreating would be testing a different
    /// person. It is created here and removed in tearDown — the seeded
    /// accounts are shared and are not touched.
    ///
    /// Why backgrounding is the trigger: a cached ID token stays valid for an
    /// hour, and neither Firestore nor the callables ask whether the account
    /// behind it still exists. Nothing notices until something forces a
    /// refresh, and coming back to the app is where that now happens.
    func testARevokedSessionEndsTheSessionAndGivesTheScreenBack() throws {
        let email = "a3-expire@example.com"
        let uid = try EmulatorAdmin.createVerifiedAccount(email: email, password: "Passw0rd!x")

        // The probe separates the two ways this can fail. Without it, "not
        // given back" covers both "nothing was held for this account" and "a
        // route was pushed and something else emptied the stack afterwards",
        // and those have different owners and opposite fixes.
        let app = launchOnSignIn(extraArguments: ["-petnote-session-probe"])
        signIn(app, email: email)
        openFirstPost(app)
        let postText = app.staticTexts["post.text"].firstMatch.label
        XCTAssertFalse(postText.isEmpty, "could not identify which post is open")

        XCUIDevice.shared.press(.home)
        try EmulatorAdmin.setAccountDisabled(uid: uid, true)
        app.activate()

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 60),
            "A revoked session left the app usable.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts["login.sessionExpired"].exists,
            "The app dropped to sign-in without saying why.\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.textFields["composer.field"].exists,
            "the signed-in screen was still reachable behind sign-in"
        )

        // Signing in again puts them back where they were.
        try EmulatorAdmin.setAccountDisabled(uid: uid, false)
        signIn(app, email: email, expectFeed: false)

        let cameBack = waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 60)
        if !cameBack {
            // Read the probe before saying anything about what went wrong.
            let probe = app.staticTexts["session.resumeProbe"]
            let reading = probe.exists ? probe.label : "no probe (is -petnote-session-probe set?)"
            XCTFail("""
                The screen the session ended on was not given back. The feed's own \
                reading of what it decided: "\(reading)". "resume=restored path=0" means \
                the route was pushed and the stack was emptied afterwards — by \
                SignedInView's account-switch reset, which runs on first appearance too. \
                "resume=nothingHeld" means the session held nothing for this uid, which \
                is a SessionStore question instead.
                \(app.debugDescription)
                """)
        }
        XCTAssertEqual(
            app.staticTexts["post.text"].firstMatch.label, postText,
            "came back to a different post than the one the session ended on"
        )
        XCTAssertFalse(
            app.staticTexts["login.sessionExpired"].exists,
            "the expiry notice outlived the expiry"
        )
    }

    // MARK: - Touch targets on the signed-in screen

    /// Every control on the signed-in screen, not just the one a test happens
    /// to tap. The sign-out button shipped 20pt tall and untappable because
    /// .frame(minHeight:) was on the Button rather than its label; a check that
    /// names one button would have missed the next one.
    func testEveryControlMeetsTheMinimumTouchTarget() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
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
}
