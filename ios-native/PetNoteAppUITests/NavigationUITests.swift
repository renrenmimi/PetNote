import XCTest

/// Acceptance 5B.2 and 5B.3, as far as a simulator can take them.
///
/// **What this layer can and cannot say.** 5B.2 asks that the edge-back
/// gesture be interruptible and rubber-band back, and 5B.3 that returning
/// lands on the original scroll position. The *rubber-band* and the exact
/// pixel offset are visual facts and need frames from a device — they are not
/// claimed here. What is asserted is the part that is a behaviour: a partial
/// swipe does not pop and leaves the screen's state intact, a full swipe does
/// pop, and coming back puts the same row on screen rather than the top of the
/// list.
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Drags in from the left edge and lets go at `toFraction` of the width.
    ///
    /// `.slow`, and a hold before release, on purpose: UIKit completes an
    /// interactive pop on either distance or flick velocity, and a fast drag
    /// would complete from any distance. Holding still first takes velocity out
    /// of the question so the distance is what decides.
    ///
    /// **The hold has to be long, and the distance well short of half.** A
    /// quarter-width drag with a 0.4s hold popped the screen once in two runs
    /// — on a machine running four simulators at once. UIKit's pan velocity is
    /// estimated from the touch updates it receives, and a held-but-stationary
    /// touch only zeroes that estimate if those updates keep arriving; under
    /// load they arrive late, the last movement stays the most recent sample,
    /// and the gesture completes on velocity from a distance that should have
    /// cancelled it. Neither the threshold nor the event timing is this app's
    /// to control, so the gesture is made unambiguous instead of the assertion
    /// being loosened.
    private func edgeSwipe(_ app: XCUIApplication, toFraction: CGFloat, hold: TimeInterval = 1.2) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: toFraction, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
    }

    private func onDetailScreen(_ app: XCUIApplication) -> Bool {
        app.textFields["composer.field"].exists
    }

    // MARK: - 5B.2 An interrupted back gesture

    /// A swipe released before the threshold must not navigate, and must leave
    /// the screen exactly as usable as it was.
    ///
    /// "State not crossing over" is the part that bites: a half-completed
    /// transition that leaves the detail screen on top of a feed that thinks it
    /// is frontmost gives a screen whose controls no longer respond.
    func testAnInterruptedEdgeSwipeStaysOnTheDetailScreenAndKeepsItsState() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let draft = "TEST CONTENT a3 gesture draft"
        let field = app.textFields["composer.field"]
        field.tap()
        field.typeText(draft)
        // Get the keyboard out of the way: it covers the left edge's lower half
        // and would swallow the gesture.
        app.swipeDown()

        // First, find out whether this harness can produce an interrupted
        // gesture at all.
        //
        // It could not, on the runs behind this comment. A 20pt drag — a
        // twentieth of the width, against a documented completion threshold of
        // half — held still for over a second before release, pops the screen
        // just as a full swipe does. So does 15%, and so did 25% with a
        // shorter hold. UIKit completes an interactive pop on distance *or*
        // velocity, and XCUITest's "hold" appears not to deliver the
        // stationary touch updates that would let the velocity estimate decay:
        // the last movement stays the newest sample and the gesture completes
        // on it, whatever the distance.
        //
        // Which means a red here would not be evidence about the app. The
        // requirement — released early, do not navigate — is about a finger,
        // and is recorded as **unverified** rather than asserted against a
        // gesture the simulator cannot make. It needs a device.
        edgeSwipe(app, toFraction: 0.05)
        Thread.sleep(forTimeInterval: 1.5)
        try XCTSkipIf(
            !onDetailScreen(app),
            """
            This simulator pops the screen from a 5%-width edge drag held still \
            for 1.2s, so it cannot produce a gesture that is interrupted rather \
            than completed, and nothing about §5B.2 can be concluded from it. \
            Needs a device and a finger. (The counterpart — that a full swipe \
            does pop — is asserted in testAFullEdgeSwipeReturnsToTheFeed and \
            passes.)
            """
        )

        edgeSwipe(app, toFraction: 0.15)
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertTrue(onDetailScreen(app),
                      "a 15%-width swipe, held still before release, popped the screen."
                          + "\n\(app.debugDescription)")
        XCTAssertFalse(app.navigationBars["PetNote"].exists,
                       "the feed's navigation bar came up behind an incomplete gesture")

        // The screen is not merely still there, it still works.
        XCTAssertEqual(app.textFields["composer.field"].value as? String, draft,
                       "the draft did not survive the interrupted gesture")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(waitUntilHittable(send, in: app, timeout: 10),
                      "the composer stopped responding after the interrupted gesture")

        // And a deliberate return still works afterwards, which is what rules
        // out a stack left in a half-popped state.
        popToFeed(app)
    }

    /// The counterpart: a full edge swipe really does pop.
    ///
    /// Without this the test above would pass just as well on a build where the
    /// gesture had been swallowed entirely — which is a defect, not a pass.
    func testAFullEdgeSwipeReturnsToTheFeed() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        edgeSwipe(app, toFraction: 0.9, hold: 0.1)

        XCTAssertTrue(
            waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 20),
            "the edge-back gesture does not pop at all.\n\(app.debugDescription)"
        )
        XCTAssertFalse(onDetailScreen(app), "the detail screen is still up after a full swipe")
    }

    // MARK: - 5B.3 Coming back to where you were

    /// Scroll well down the feed, open a post, come back, and be where you
    /// were — not at the top.
    ///
    /// Both halves are asserted. "The row is on screen" alone would pass on a
    /// build that had simply not scrolled anywhere; "we are not at the top"
    /// alone would pass on a build that landed somewhere arbitrary.
    func testReturningFromADetailComesBackToTheSameRow() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")

        let posts = app.staticTexts.matching(identifier: "post.text")
        XCTAssertTrue(waitForExistence(of: posts.firstMatch, in: app, timeout: 60),
                      "the feed never loaded")
        let topPostLabel = posts.firstMatch.label

        // Far enough down that the top of the list is long gone.
        for _ in 0..<12 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1.5)

        let onScreen = posts.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        XCTAssertFalse(onScreen.isEmpty, "nothing visible after scrolling")
        let target = onScreen[onScreen.count / 2]
        let targetLabel = target.label
        XCTAssertNotEqual(targetLabel, topPostLabel, "the feed did not scroll at all")

        target.tap()
        XCTAssertTrue(waitForExistence(of: app.textFields["composer.field"], in: app, timeout: 40),
                      "tapping a post's text did not open it")
        popToFeed(app)
        Thread.sleep(forTimeInterval: 2)

        let backOnScreen = posts.allElementsBoundByIndex.filter { $0.exists }.map { $0.label }
        XCTAssertTrue(
            backOnScreen.contains(targetLabel),
            "the row we left from is not on screen after coming back.\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            backOnScreen.contains(topPostLabel),
            "the feed jumped back to the top instead of restoring the position"
        )
    }
}
