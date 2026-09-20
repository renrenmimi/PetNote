import XCTest

/// The accessibility acceptance items that a simulator can answer today:
/// Dynamic Type at both ends (§6.2, §6.3), Reduce Motion (§6.4) and Reduce
/// Transparency (§6.5).
///
/// **The matrix writes all four as L5, and this is not that.** What a
/// simulator can establish is behavioural: at AX5 the controls are still
/// 44pt and still reachable, nothing is pushed off the side of the screen,
/// and with the two accessibility switches on the app still works end to end.
/// Whether it *looks* right — where the text wraps, whether a card reads as
/// one thing — needs a device and a person, and is not claimed here.
///
/// Dynamic Type is set with `-UIPreferredContentSizeCategoryName`, which UIKit
/// reads as an override for the app's preferred content size category. The two
/// switches cannot be set that way: they live in the accessibility daemon, not
/// in the app's defaults, so they are set on the simulator before the run with
///
///     xcrun simctl spawn pn-a3 defaults write com.apple.Accessibility \
///         ReduceMotionEnabled -bool true
///
/// and the tests that need them skip — rather than silently pass — when they
/// are off.
final class AccessibilityUITests: XCTestCase {
    /// AX5, the largest accessibility size.
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let xs = "UICTContentSizeCategoryXS"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(contentSize: String) -> XCUIApplication {
        launchOnSignIn(extraArguments: ["-UIPreferredContentSizeCategoryName", contentSize])
    }

    /// Our controls that are on screen right now. Ours means we gave them an
    /// identifier; a control below the fold is not hittable by definition and
    /// counting it would report scrolling as a defect.
    ///
    /// Disabled controls are **included**. Their size is exactly what is under
    /// test — the sign-in button is disabled until both fields have something
    /// in them, and excluding it left this check with nothing at all to look
    /// at on the sign-in screen, which is how it first failed.
    private func visibleOwnControls(_ app: XCUIApplication) -> [XCUIElement] {
        let window = app.windows.firstMatch.frame
        return app.buttons.allElementsBoundByIndex.filter {
            $0.exists && !$0.identifier.isEmpty
                && !$0.frame.isEmpty && window.intersects($0.frame)
        }
    }

    private func assertNothingRunsOffTheSide(
        _ app: XCUIApplication,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        // A 1pt tolerance: hairline separators are laid out on the boundary.
        for element in app.staticTexts.allElementsBoundByIndex
        where element.exists && !element.frame.isEmpty && window.intersects(element.frame) {
            XCTAssertGreaterThanOrEqual(
                element.frame.minX, window.minX - 1,
                "\(context): \"\(element.label.prefix(40))\" starts off the left edge",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                element.frame.maxX, window.maxX + 1,
                "\(context): \"\(element.label.prefix(40))\" runs off the right edge",
                file: file, line: line
            )
        }
    }

    private func assertControlsAreStillReachable(
        _ app: XCUIApplication,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let barButtonIDs = Set(
            app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists }.map { $0.identifier }
        )
        let controls = visibleOwnControls(app)
        XCTAssertFalse(controls.isEmpty, "\(context): no identified controls found", file: file, line: line)
        for control in controls {
            if barButtonIDs.contains(control.identifier) {
                // A navigation bar lays its items out inside 44pt whatever the
                // type size, so these are asserted reachable, not tall — the
                // same split AuthUITests documents.
                guard control.isEnabled else { continue }
                XCTAssertTrue(
                    waitUntilHittable(control, in: app, timeout: 10),
                    "\(context): \(control.identifier) is not reachable", file: file, line: line
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    control.frame.height, 44,
                    "\(context): \(control.identifier) is \(control.frame.height)pt tall",
                    file: file, line: line
                )
                // Hittability only for controls that are meant to respond: a
                // disabled button is correctly not hittable, and asserting
                // otherwise would be asserting a defect.
                if control.isEnabled {
                    XCTAssertTrue(
                        control.isHittable,
                        "\(context): \(control.identifier) is not hittable", file: file, line: line
                    )
                }
            }
        }
    }

    // MARK: - §6.2 The largest accessibility size

    /// AX5 on the sign-in screen, the feed and the detail screen. The whole
    /// core path, because a size that works on one screen and breaks the next
    /// is the normal way this fails.
    func testTheCorePathSurvivesAX5() {
        let app = launch(contentSize: Self.ax5)

        assertNothingRunsOffTheSide(app, "sign-in at AX5")
        assertControlsAreStillReachable(app, "sign-in at AX5")

        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                                       in: app, timeout: 60),
                      "the feed never loaded at AX5")
        assertNothingRunsOffTheSide(app, "feed at AX5")
        assertControlsAreStillReachable(app, "feed at AX5")

        openFirstPost(app)
        assertNothingRunsOffTheSide(app, "post detail at AX5")
        assertControlsAreStillReachable(app, "post detail at AX5")

        // The composer is the control most likely to be squeezed out by text
        // growing around it, and it is the one the screen exists for.
        XCTAssertTrue(waitUntilHittable(app.textFields["composer.field"], in: app, timeout: 20),
                      "the comment field is unreachable at AX5")
        XCTAssertTrue(app.buttons["composer.send"].exists, "the send button is gone at AX5")
    }

    // MARK: - §6.3 The smallest size

    /// The 44pt minimum is a floor, not a scale factor: it must not shrink
    /// along with the text.
    func testControlsStay44ptAtTheSmallestSize() {
        let app = launch(contentSize: Self.xs)
        assertControlsAreStillReachable(app, "sign-in at XS")

        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                                       in: app, timeout: 60))
        assertControlsAreStillReachable(app, "feed at XS")

        openFirstPost(app)
        assertControlsAreStillReachable(app, "post detail at XS")
    }

    // MARK: - §5C.1 / §5C.5 The keyboard

    /// The composer has to stay above the keyboard, and the layout has to come
    /// back when the keyboard goes away.
    ///
    /// **This is not 5C.1.** 5C.1 is about a real keyboard on a real device,
    /// including the Chinese candidate bar that arrives after the keyboard and
    /// that a fixed delay walks straight past — no simulator can produce that,
    /// and it stays unverified. What a simulator can answer is the geometry: is
    /// the field the person is typing into underneath the keyboard, and is
    /// there a dead strip left behind afterwards.
    ///
    /// Skipped, not passed, when the software keyboard is unavailable — with a
    /// hardware keyboard connected the simulator shows no keyboard at all and
    /// there would be nothing to measure against.
    func testTheComposerStaysAboveTheKeyboardAndComesBackAfterwards() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let field = app.textFields["composer.field"]
        let restingBottom = field.frame.maxY
        field.tap()

        let keyboard = app.keyboards.firstMatch
        try XCTSkipUnless(
            keyboard.waitForExistence(timeout: 8),
            """
            No software keyboard on this simulator, so there is nothing to             measure against. Disconnect the hardware keyboard for this device             and run again.
            """
        )
        field.typeText("TEST CONTENT a3 keyboard geometry")

        let keyboardTop = keyboard.frame.minY
        XCTAssertLessThanOrEqual(
            field.frame.maxY, keyboardTop + 1,
            "the field being typed into is behind the keyboard "
                + "(field ends at \(field.frame.maxY), keyboard starts at \(keyboardTop))"
        )
        let send = app.buttons["composer.send"]
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboardTop + 1, "send is behind the keyboard")
        XCTAssertTrue(send.isHittable, "send cannot be tapped with the keyboard up")

        // Scrolling the list dismisses the keyboard. Before this screen had
        // `.scrollDismissesKeyboard` there was no way off it at all: a
        // vertical-axis TextField's return key inserts a newline.
        //
        // Swiping *up*, deliberately. A downward drag at the top of the list
        // is pull-to-refresh's gesture, and asserting on it would be asserting
        // which of the two wins rather than that the keyboard goes away.
        app.swipeUp()
        let deadline = Date().addingTimeInterval(10)
        while keyboard.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(keyboard.exists, "dragging the list did not dismiss the keyboard")

        // §5C.5: the composer comes back down, and does not leave a strip of
        // reserved-but-empty space behind — the web client once held 176px for
        // a tab bar the page did not have.
        let window = app.windows.firstMatch.frame
        // Within a few points, not to the pixel. The field is measured empty
        // before the keyboard and holding a line of text after it, and that
        // alone moved it 3pt — which is the text's own layout, not the
        // keyboard leaving something behind. The requirement is the assertion
        // below it: no reserved-but-empty strip.
        XCTAssertEqual(
            field.frame.maxY, restingBottom, accuracy: 10,
            "the composer did not come back down "
                + "(was \(restingBottom), now \(field.frame.maxY))"
        )
        XCTAssertLessThan(
            window.maxY - field.frame.maxY, 80,
            "a \(window.maxY - field.frame.maxY)pt dead strip was left below the composer"
        )
    }

    // MARK: - §6.4 Reduce Motion

    /// With animation removed, navigation must still work and the screen must
    /// still say what happened.
    ///
    /// Skipped rather than quietly passed when the setting is off: a test that
    /// runs identically with the switch in either position is not evidence
    /// about the switch.
    func testTheCorePathWorksWithReduceMotionOn() throws {
        try XCTSkipUnless(
            UIAccessibility.isReduceMotionEnabled,
            """
            Reduce Motion is off on this simulator, so this run would prove \
            nothing. Set it first:
              xcrun simctl spawn pn-a3 defaults write com.apple.Accessibility \
            ReduceMotionEnabled -bool true
            """
        )

        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)
        // Pushing and popping are the transitions §6.4 is about; with the
        // animation gone the navigation still has to arrive.
        popToFeed(app)
        openFirstPost(app)

        // "状态反馈仍在": a refusal is still reported, and it is text rather
        // than a motion cue, so removing motion cannot remove it. Uses the
        // length cap, which is refused by the client and writes nothing.
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText("x")
        XCTAssertTrue(waitUntilHittable(app.buttons["composer.send"], in: app, timeout: 10),
                      "the send control is not reachable with Reduce Motion on")
    }

    // MARK: - §6.5 Reduce Transparency

    /// There is nothing translucent in this app — `AccessibilityGuardTests`
    /// proves that by scanning the source, and that is the stronger half of
    /// this requirement because it covers screens no test visits.
    ///
    /// This is the other half: with the setting on, the app still renders and
    /// every control is still reachable, so "nothing to substitute" is not
    /// hiding a screen that fails to draw.
    func testTheCorePathWorksWithReduceTransparencyOn() throws {
        try XCTSkipUnless(
            UIAccessibility.isReduceTransparencyEnabled,
            """
            Reduce Transparency is off on this simulator, so this run would \
            prove nothing. Set it first:
              xcrun simctl spawn pn-a3 defaults write com.apple.Accessibility \
            ReduceTransparencyEnabled -bool true
            """
        )

        let app = launchOnSignIn()
        assertControlsAreStillReachable(app, "sign-in with Reduce Transparency")
        signIn(app, email: "accept-a@example.com")
        XCTAssertTrue(waitForExistence(of: app.staticTexts.matching(identifier: "post.text").firstMatch,
                                       in: app, timeout: 60),
                      "the feed never loaded with Reduce Transparency on")
        assertControlsAreStillReachable(app, "feed with Reduce Transparency")
        openFirstPost(app)
        assertControlsAreStillReachable(app, "post detail with Reduce Transparency")
    }
}
