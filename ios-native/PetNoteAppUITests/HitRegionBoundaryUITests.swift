import XCTest

/// How tall is the hit region, in absolute screen coordinates.
///
/// Every earlier attempt measured outwards from the element's centre, and that
/// cannot answer the question. "22pt above activates, 22pt below does not"
/// is consistent with a 44pt region whose centre sits half a point high, and
/// equally consistent with a 43pt one. Reaching from the middle conflates
/// *where the centre is* with *how tall the region is*, and only the second
/// is what §6.4 asks about.
///
/// So this finds the two boundaries as screen coordinates and subtracts. No
/// assumption of symmetry, and no inference from one side to the other.
///
/// Binary search rather than a 1pt sweep for a practical reason: activating
/// the back button pops the screen, so every probe costs a full navigation
/// round trip. A sweep of sixty rungs would take half an hour; six probes per
/// boundary take a couple of minutes and land on the same answer.
final class HitRegionBoundaryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The back button, because it is the cheapest bar button to probe: it
    /// pops a screen that can be pushed again, where sign-out destroys the
    /// session and costs a fresh login each time. The two are laid out by the
    /// same bar under the same rules.
    private func openDetail(_ app: XCUIApplication) -> XCUIElement {
        let rows = app.buttons.matching(identifier: "post.comments")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "feed never arrived")
        rows.firstMatch.tap()
        let back = Self.backButton(app)
        XCTAssertTrue(waitUntilHittable(back, in: app, timeout: 20), "no back button")
        return back
    }

    /// The leftmost button in the bar.
    ///
    /// Not `.firstMatch`: that returned an 87x36 element — the sign-out
    /// button, which is in the same bar and is the one control here whose
    /// activation cannot be undone. The first probe duly signed the session
    /// out and every subsequent one had no bar to find. Position is what
    /// distinguishes them; the back button carries no identifier of its own.
    private static func backButton(_ app: XCUIApplication) -> XCUIElement {
        let buttons = app.navigationBars.buttons.allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        guard let leftmost = buttons.min(by: { $0.frame.minX < $1.frame.minX }) else {
            return app.navigationBars.buttons.firstMatch
        }
        return leftmost
    }

    /// True when a tap at `y` (absolute, in window coordinates) activates the
    /// back button.
    private func activates(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> Bool {
        _ = openDetail(app)
        let window = app.windows.firstMatch
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
        target.tap()
        // Back on the feed means it activated. The detail screen still being
        // there means it did not.
        let popped = waitForExistence(
            of: app.buttons.matching(identifier: "post.comments").firstMatch, in: app, timeout: 6
        )
        if !popped {
            // Leave the app where the next probe expects it.
            Self.backButton(app).tap()
            _ = waitForExistence(
                of: app.buttons.matching(identifier: "post.comments").firstMatch, in: app, timeout: 10
            )
        }
        return popped
    }

    /// The last coordinate in `[inside, outside)` that still activates,
    /// to a quarter of a point.
    private func boundary(
        _ app: XCUIApplication, x: CGFloat, inside: CGFloat, outside: CGFloat
    ) -> CGFloat {
        var good = inside
        var bad = outside
        while abs(bad - good) > 0.25 {
            let mid = (good + bad) / 2
            if activates(app, x: x, y: mid) { good = mid } else { bad = mid }
        }
        return good
    }

    func testTheBackButtonsHitRegionIsAtLeast44ptTall() {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 20))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-b@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))

        let back = openDetail(app)
        let frame = back.frame
        XCTAssertLessThan(frame.width, 60,
                          "this is not the back button — \(frame.size) looks like the sign-out control")
        let centreX = frame.midX
        let centreY = frame.midY
        print("MEASURED back button reported frame: \(frame)")

        // Confirm the middle activates before searching outwards from it. If
        // it does not, the numbers below would be measuring nothing, and the
        // search would happily return a boundary anyway.
        XCTAssertTrue(activates(app, x: centreX, y: centreY),
                      "the centre of the button does not activate it; the probe is not measuring this control")

        // 30pt each way is comfortably past any plausible boundary — the bar
        // itself is 44pt tall — so both searches start with a known-bad end.
        let top = boundary(app, x: centreX, inside: centreY, outside: centreY - 30)
        let bottom = boundary(app, x: centreX, inside: centreY, outside: centreY + 30)
        let height = bottom - top

        print("MEASURED back button hit region: top=\(top) bottom=\(bottom) height=\(height)")
        print("MEASURED back button centre=\(centreY) reach up=\(centreY - top) down=\(bottom - centreY)")

        XCTAssertGreaterThanOrEqual(
            height, 44,
            """
            The hit region is \(height)pt tall, and §6.4 asks for 44. \
            Reported frame was \(frame.size); the two are different numbers and \
            this is the one that matters.
            """
        )
    }
}
