import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// Three decimals, because the bracket every measurement below is quoted to is
/// one device pixel — 0.333pt at 3x. Fewer digits would round the answer away.
private func fmt3(_ value: CGFloat) -> String { String(format: "%.3f", value) }

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

        // Two taps, and the first one is not the destructive one: the bar
        // opens the menu, the menu ends the session.
        openAccountMenu(app)
        XCTAssertTrue(
            app.navigationBars["PetNote"].exists,
            "opening the account menu already left the signed-in screen"
        )

        let signOut = app.buttons["session.signOut"]
        if !waitUntilHittable(signOut, in: app) {
            saveScreenshot(app, named: "signout-not-hittable")
            XCTFail("""
                Sign out row is not hittable.
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

        signOutFromAccountMenu(app)

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
        signIn(app, email: email, expectFeed: false)
        // A fresh account: its profile is created on sign-in and it is offered
        // onboarding over the feed, which hides the feed from VoiceOver — and
        // so from this test — until it is closed.
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "did not reach the feed")
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
        //
        // And not under the tab bar, for the same reason: a feed row passing
        // behind the bar is a row that has not been scrolled to, and is no
        // more hittable than one below the screen. The bar's own items are
        // the system's, laid out like the navigation bar's.
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        let underBar = tabBar.exists ? tabBar.frame : .null
        let ours = app.buttons.allElementsBoundByIndex.filter {
            $0.exists && $0.isEnabled && !$0.identifier.isEmpty
                && !$0.frame.isEmpty && window.intersects($0.frame)
                && !underBar.intersects($0.frame)
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
        //
        // One pass, not `.filter` then `.map`. Two traversals of a tree that
        // moves — a feed row resizes as its image arrives — resolve their
        // indices into different layouts, and the second comes back "No
        // matches found for Element at index N", which reads like a missing
        // control. Five places in this suite have made that mistake; this was
        // one of them.
        let barButtonIDs = Set(
            app.navigationBars.buttons.allElementsBoundByIndex
                .compactMap { $0.exists ? $0.identifier : nil }
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

    // MARK: - The account menu

    /// The account the hit-region measurement signs in and out of, repeatedly.
    ///
    /// A seeded account rather than one this suite creates: the measurement
    /// ends the session on purpose a dozen times, and doing that to an account
    /// that `tearDown` then deletes would mix "the control did not activate"
    /// with "the account went away".
    private static let measurementAccount = "accept-a@example.com"

    /// Opening the menu must not be the act of signing out.
    ///
    /// Asserting that the sign-out row *appeared* is not enough on its own —
    /// it would pass on a build that signed out and drew the menu on the way.
    /// So the session itself is checked, from both sides: the feed's bar is
    /// still there, and the sign-in screen is not.
    func testOpeningTheAccountMenuDoesNotEndTheSession() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")

        let entry = app.buttons["account.menu"]
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30),
                      "the account entry is not reachable\n\(app.debugDescription)")
        entry.tap()

        XCTAssertTrue(waitUntilHittable(app.buttons["session.signOut"], in: app, timeout: 20),
                      "the account menu did not open\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["login.title"].exists,
                       "opening the account menu signed the person out")
        XCTAssertTrue(app.navigationBars["PetNote"].exists,
                      "opening the account menu left the signed-in screen")

        // Two controls, not one wearing two names. The container traps in this
        // project produced exactly that shape: a child reporting its parent's
        // identifier, or its parent's rectangle.
        let entryFrame = app.buttons["account.menu"].frame
        let menuRowFrame = app.buttons["session.signOut"].frame
        print("MEASURED account.menu frame=\(entryFrame) session.signOut frame=\(menuRowFrame)")
        XCTAssertFalse(entryFrame.equalTo(menuRowFrame),
                       "the entry and the sign-out row are the same rectangle")

        // Leaving the menu is not signing out either.
        closeAccountMenu(app)
        XCTAssertFalse(app.staticTexts["login.title"].exists,
                       "dismissing the account menu signed the person out")
        XCTAssertTrue(waitUntilHittable(app.buttons["account.menu"], in: app, timeout: 20),
                      "the signed-in screen did not come back after closing the menu")
    }

    /// What a tool can check about VoiceOver: both controls have something to
    /// announce, neither announces machinery, and the menu can be reached.
    func testTheAccountEntryAndItsMenuAnnounceThemselves() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")

        let entry = app.buttons["account.menu"]
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 30))
        let entryLabel = entry.label
        print("MEASURED account.menu label=\"\(entryLabel)\" hittable=\(entry.isHittable)")
        XCTAssertFalse(entryLabel.trimmingCharacters(in: .whitespaces).isEmpty,
                       "the account entry has nothing to announce")
        XCTAssertFalse(entryLabel.contains("account.menu"),
                       "the account entry announces its own identifier")
        // An icon-only control with no label announces the SF Symbol's name,
        // which is the failure this catches rather than an empty string.
        XCTAssertFalse(entryLabel.lowercased().contains("person.crop"),
                       "the account entry announces a symbol name: \"\(entryLabel)\"")

        openAccountMenu(app)

        let row = app.buttons["session.signOut"]
        let rowLabel = row.label
        print("MEASURED session.signOut label=\"\(rowLabel)\" type=\(row.elementType.rawValue) "
              + "hittable=\(row.isHittable)")
        XCTAssertFalse(rowLabel.trimmingCharacters(in: .whitespaces).isEmpty,
                       "the sign-out row has nothing to announce")
        XCTAssertFalse(rowLabel.contains("session.signOut"),
                       "the sign-out row announces its own identifier")
        XCTAssertEqual(row.elementType, .button, "the sign-out row is not a focusable control")
        XCTAssertTrue(row.isHittable, "the sign-out row cannot be reached")

        // And the menu says whose session it is, so "sign out" is not an
        // instruction given in the dark.
        XCTAssertTrue(app.staticTexts["account.title"].exists, "the menu does not name itself")
        let email = app.staticTexts["account.email"]
        XCTAssertTrue(waitForExistence(of: email, in: app, timeout: 10))
        XCTAssertEqual(email.label, "accept-a@example.com")

        // Printed because the measured hit region of the row reaches about
        // 14.7pt past the rectangle it is drawn in, on both sides. That is
        // fine while the space it reaches into is padding, and not fine if it
        // reaches the line above — so the gap is recorded rather than assumed.
        print("MEASURED account.title frame=\(app.staticTexts["account.title"].frame) "
              + "account.email frame=\(email.frame) "
              + "session.signOut frame=\(app.buttons["session.signOut"].frame)")
    }

    /// The menu is an account entry and a sign-out row. It is not a settings
    /// screen, and this is what would notice it becoming one.
    ///
    /// Hittability is the filter, and it is the right one here: while a sheet
    /// is up, the screen behind it is not reachable, so what is both identified
    /// and hittable is exactly what this menu offers.
    func testTheAccountMenuHoldsNothingButSignOut() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openAccountMenu(app)

        // A closure rather than a key path: XCUIElement's properties are
        // main-actor isolated and a key path cannot cross that boundary.
        let reachable = app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && !$0.identifier.isEmpty }
            .map { $0.identifier }
            .sorted()
        print("MEASURED account menu offers: \(reachable)")
        // Sign-out, and a way to leave without it. `account.close` is not a
        // feature arriving without a decision — it is the decision that a
        // sheet whose only control ends the session is not a menu, and it is
        // pinned here rather than merely allowed so that a third control still
        // fails this.
        XCTAssertEqual(
            Set(reachable), ["account.close", "session.signOut"],
            """
            The account menu offers \(reachable). This stage is an account \
            entry, a way out and sign-out; anything else here is a settings \
            screen arriving without the decision to build one.
            """
        )
    }

    /// Leaving the account menu must be something a person can tap.
    ///
    /// Before this there was exactly one control on the sheet, and it ended
    /// the session. A SwiftUI sheet does not close when the dimmed area behind
    /// it is tapped — `closeAccountMenu` records measuring that — so the only
    /// way out was a drag, advertised by nothing but the grabber. Someone who
    /// opened the menu by brushing the corner of the bar had a choice between
    /// a gesture they may not know and the one button on screen, which signs
    /// them out.
    ///
    /// The assertion is about *a* way out, not about a particular button, so
    /// it keeps saying something if the control is renamed or redrawn.
    func testTheAccountMenuCanBeLeftWithoutEndingTheSession() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openAccountMenu(app)

        // Identifiers read in the same pass that filters, kept as values: a
        // sheet that is still settling is a tree that moves, and a second
        // traversal answers about a different one.
        let offered = app.buttons.allElementsBoundByIndex.compactMap { button -> String? in
            guard button.exists, button.isHittable, !button.identifier.isEmpty else { return nil }
            return button.identifier
        }.sorted()
        print("MEASURED account menu offers: \(offered)")

        let waysOut = offered.filter { $0 != "session.signOut" }
        XCTAssertFalse(
            waysOut.isEmpty,
            """
            The account menu offers \(offered). The only control on it is the \
            one that ends the session: closing the menu is a drag gesture and \
            nothing else, and a sheet does not dismiss on a tap outside it.
            """
        )

        let close = app.buttons["account.close"]
        XCTAssertTrue(waitUntilHittable(close, in: app, timeout: 10),
                      "the account menu has no close control")
        close.tap()

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, app.buttons["session.signOut"].exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(app.buttons["session.signOut"].exists, "the close control did not close the menu")
        XCTAssertFalse(app.staticTexts["login.title"].exists,
                       "closing the account menu ended the session")
        XCTAssertTrue(waitUntilHittable(app.buttons["account.menu"], in: app, timeout: 20),
                      "the signed-in screen did not come back after closing the menu")
    }


    // MARK: - Where the sign-out row's hit region actually is

    /// The reading, in absolute window coordinates, kept so `restoreAccountMenu`
    /// can notice if the geometry moves between probes.
    private var rowFrame: CGRect?

    /// The hit region of the sign-out row, measured as two absolute boundaries.
    ///
    /// **Absolute, not "N points from the centre."** Reaching outwards from a
    /// centre cannot tell a 44pt region whose centre sits half a point high
    /// from a 43pt one; that conflation is the whole reason
    /// `HitRegionBoundaryUITests` exists, and it is why the navigation-bar
    /// button's height could only ever be stated as the interval
    /// [43.438, 44.062). Each boundary here is found as a coordinate and the
    /// extent is the difference between two of them.
    ///
    /// Two kinds of claim come out of it and they are not the same kind:
    ///
    ///   * **a floor is a fact** — two points activated, and a UIKit hit region
    ///     is one connected rectangle, so everything between them is inside it;
    ///   * **a ceiling is the complement** — two points did not activate, so the
    ///     region reaches neither.
    ///
    /// Cost: only an *activating* probe costs anything, because it ends the
    /// session. A probe that misses leaves the menu open, or at worst closed,
    /// and is reopened for nothing. No relaunch either way — signing in again
    /// is enough, which is what makes a real bisection affordable here where it
    /// was not for the bar button.
    func testTheSignOutRowsHitRegionMeasuredAbsolutely() {
        // These are measurements. One boundary that cannot be found must not
        // throw away the others.
        continueAfterFailure = true
        rowFrame = nil

        let app = launchOnSignIn()
        signIn(app, email: Self.measurementAccount)
        openAccountMenu(app)

        let window = app.windows.firstMatch
        let windowFrame = window.frame
        let originOnScreen = window.coordinate(withNormalizedOffset: .zero).screenPoint
        let scale = XCUIScreen.main.screenshot().image.scale
        // One device pixel. Stopping finer would be inventing resolution:
        // there is no coordinate between two adjacent pixels for a tap to land
        // on, so a narrower bracket describes the search, not the control.
        let tolerance = 1 / scale
        print("MEASURED conditions coordinates=window window=\(windowFrame) "
              + "window(0,0)onScreen=\(originOnScreen) scale=\(fmt3(scale))x "
              + "pixel=\(fmt3(tolerance))pt bracket=\(fmt3(tolerance))pt")
        print("MEASURED windows: \(app.windows.allElementsBoundByIndex.map { $0.frame })")

        let frame = settledRowFrame(app)
        rowFrame = frame
        print("MEASURED session.signOut reported(accessibility) frame = \(frame)")
        XCTAssertFalse(frame.isEmpty, "there is no frame to measure from")

        let centreX = frame.midX
        let centreY = frame.midY

        // 0. The region is where the row is drawn, and not the whole screen.
        //
        // This project has shipped a control whose reported rectangle was
        // 603x874 at x=-100 because an `.accessibilityAction` sat on a
        // container; every tap then "hit" it from anywhere. A tap far outside
        // the menu that ends the session would be that failure, and it costs
        // one probe to rule out.
        let farY = windowFrame.minY + windowFrame.height * 0.15
        let farAway = probeSignOut(app, x: windowFrame.midX, y: farY)
        print("MEASURED session.signOut far-away tap at (\(fmt3(windowFrame.midX)), "
              + "\(fmt3(farY))) -> \(farAway ? "activated" : "nothing")")
        XCTAssertFalse(
            farAway,
            "a tap outside the menu ended the session — the hit region is not where the row is drawn"
        )

        // 1. The width floor, as a fact: two activating points 44.000 apart.
        //    Width is not bisected — the row spans the sheet — so the floor is
        //    all that is claimed about it.
        let left = probeSignOut(app, x: centreX - 22, y: centreY)
        let right = probeSignOut(app, x: centreX + 22, y: centreY)
        print("MEASURED session.signOut width: x=\(fmt3(centreX - 22)) -> "
              + "\(left ? "activated" : "nothing"), x=\(fmt3(centreX + 22)) -> "
              + "\(right ? "activated" : "nothing")")
        XCTAssertTrue(
            left && right,
            "width >= 44.000 not established: two points 44.000 apart did not both activate"
        )

        // 2. Both vertical boundaries, absolutely, then the extent between them.
        let top = findVerticalEdge(
            app, name: "signOut.top", x: centreX,
            inside: centreY, limit: frame.minY - 24, tolerance: tolerance
        )
        print("MEASURED \(top.description)")
        let bottom = findVerticalEdge(
            app, name: "signOut.bottom", x: centreX,
            inside: centreY, limit: frame.maxY + 24, tolerance: tolerance
        )
        print("MEASURED \(bottom.description)")

        let verdict = extent("height", from: top, to: bottom, requirement: 44)
        print("MEASURED session.signOut VERDICT height=\(verdict) "
              + "width=\(left && right ? ">= 44.000" : "not established") "
              + "reportedFrame=\(frame)")
        XCTAssertEqual(
            verdict, "PASS",
            "the sign-out row's measured height does not establish 44pt; see the MEASURED lines"
        )
    }

    // MARK: Measurement machinery

    private struct Edge {
        let name: String
        /// The furthest coordinate in this direction that activated.
        let inside: CGFloat
        /// The nearest that did not. `nil` when the search ran out of room
        /// before it ran out of hit region.
        let outside: CGFloat?
        let searchedUpwards: Bool
        let probes: Int

        var description: String {
            guard let outside else {
                return "\(name): still activating at \(fmt3(inside)), which is the limit of the "
                    + "search — no outer boundary was reached"
            }
            // Searching towards larger coordinates the boundary is the last
            // coordinate inside, so it lies in [inside, outside); towards
            // smaller ones it is the first inside, so (outside, inside].
            let bracket = searchedUpwards
                ? "[\(fmt3(inside)), \(fmt3(outside)))"
                : "(\(fmt3(outside)), \(fmt3(inside))]"
            return "\(name): boundary in \(bracket) — activates at \(fmt3(inside)), "
                + "does not at \(fmt3(outside)) [\(probes) probes]"
        }
    }

    /// Bisects between a coordinate known to activate and one known not to.
    ///
    /// `limit` is probed first and a `nil` outside is returned if it activates
    /// too: that is a fact about the screen, not a failed search, and bisecting
    /// anyway would report a boundary that is really just where we stopped.
    private func findVerticalEdge(
        _ app: XCUIApplication, name: String, x: CGFloat,
        inside: CGFloat, limit: CGFloat, tolerance: CGFloat
    ) -> Edge {
        var probes = 0
        func test(_ y: CGFloat) -> Bool {
            probes += 1
            let hit = probeSignOut(app, x: x, y: y)
            print("MEASURED   \(name) #\(probes) at \(fmt3(y)) -> \(hit ? "activated" : "nothing")")
            return hit
        }

        let upwards = limit > inside
        if test(limit) {
            return Edge(name: name, inside: limit, outside: nil,
                        searchedUpwards: upwards, probes: probes)
        }
        var good = inside
        var bad = limit
        while abs(bad - good) > tolerance {
            let mid = (good + bad) / 2
            if test(mid) { good = mid } else { bad = mid }
        }
        return Edge(name: name, inside: good, outside: bad,
                    searchedUpwards: upwards, probes: probes)
    }

    /// An extent, as the interval the two brackets allow, and the verdict that
    /// interval supports — which is sometimes neither pass nor fail.
    @discardableResult
    private func extent(
        _ name: String, from low: Edge, to high: Edge, requirement: CGFloat
    ) -> String {
        guard let lowOutside = low.outside, let highOutside = high.outside else {
            print("MEASURED session.signOut \(name): UNRESOLVED — the region ran past the limit of "
                  + "the search on at least one side")
            return "UNRESOLVED"
        }
        let atLeast = high.inside - low.inside
        let lessThan = abs(highOutside - lowOutside)
        let verdict: String
        if atLeast >= requirement {
            verdict = "PASS"
        } else if lessThan <= requirement {
            verdict = "FAIL"
        } else {
            verdict = "UNCONFIRMED"
        }
        print("MEASURED session.signOut \(name) in [\(fmt3(atLeast)), \(fmt3(lessThan))) vs "
              + "required \(fmt3(requirement)) -> \(verdict)")
        return verdict
    }

    /// A tap at an absolute point in the window's coordinate space.
    ///
    /// Deliberately not `element.coordinate(withNormalizedOffset:)`: that form
    /// divides by the element's own size, so the same written offset means a
    /// different distance on a 36pt control than on a 56pt one — and that size
    /// is the variable under study.
    private func tapAbsolute(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
            .tap()
    }

    /// The row's frame once it has stopped moving.
    ///
    /// A sheet is still animating when its contents first become hittable, and
    /// a frame read mid-presentation is a coordinate the row is passing
    /// through rather than one it occupies.
    private func settledRowFrame(_ app: XCUIApplication) -> CGRect {
        var last = app.buttons["session.signOut"].frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = app.buttons["session.signOut"].frame
            if now.equalTo(last) { return now }
            last = now
        }
        return last
    }

    /// Puts the app back in front of an open account menu, whatever the last
    /// probe did to it — signed out, menu dismissed, or neither.
    private func restoreAccountMenu(_ app: XCUIApplication) {
        dismissSavePasswordSheetIfPresent(app)
        if app.staticTexts["login.title"].exists {
            signIn(app, email: Self.measurementAccount)
        }
        if !app.buttons["session.signOut"].exists {
            openAccountMenu(app)
        }
        guard let expected = rowFrame else { return }
        let now = settledRowFrame(app)
        if !now.equalTo(expected) {
            // Coordinates from the first reading would then be measuring
            // something that has moved, which is worth knowing loudly.
            print("MEASURED WARNING signOut row moved between probes: \(expected) -> \(now)")
        }
    }

    /// One probe. True when the tap ended the session.
    private func probeSignOut(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> Bool {
        restoreAccountMenu(app)
        tapAbsolute(app, x: x, y: y)
        return waitForExistence(of: app.staticTexts["login.title"], in: app, timeout: 6)
    }
}
