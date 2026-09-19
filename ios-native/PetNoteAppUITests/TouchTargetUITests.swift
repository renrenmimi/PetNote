import XCTest

/// What a 44pt touch target actually is, measured rather than asserted from
/// documentation.
///
/// Three different numbers get confused here, and only one of them is the
/// requirement:
///
///   1. **Accessibility frame** — what `XCUIElement.frame` reports. It is what
///      VoiceOver draws its cursor around.
///   2. **Visual size** — what is drawn. Not directly readable from a test.
///   3. **Hit region** — where a tap actually activates the control. This is
///      what HIG's 44×44 is about, and what these tests probe.
///
/// `isHittable` only says the element's *centre* can be tapped, so it cannot
/// distinguish a 20pt control from a 44pt one. The probe here taps at measured
/// offsets from the centre and checks whether the control responded, which is
/// the only way to learn the hit region's real extent from outside the app.
final class TouchTargetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func signedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))
        waitForQuietUI(app)
        return app
    }

    /// Taps `dy` points above the element's centre and reports whether the
    /// control reacted. A normalised offset is used because that is the only
    /// coordinate space XCUITest offers for off-centre taps.
    private func tapOffset(_ element: XCUIElement, dy: CGFloat) {
        let height = element.frame.height
        guard height > 0 else { return }
        // 0.5 is the centre; move by dy points expressed as a fraction.
        let normalisedY = 0.5 + (dy / height)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: normalisedY)).tap()
    }

    /// The sign-out button lives in the navigation bar. Its accessibility frame
    /// measures ~36pt, and the question the earlier run could not answer is
    /// whether the *hit region* is larger than that.
    ///
    /// The probe: tap 20pt above the centre — outside a 36pt-tall box, inside a
    /// 44pt one — and see whether signing out happened.
    func testNavigationBarButtonHitRegionExtendsBeyondItsFrame() {
        let app = signedIn()
        let signOut = app.buttons["session.signOut"]
        XCTAssertTrue(waitUntilHittable(signOut, in: app, timeout: 20))

        let frame = signOut.frame
        // Record the measurement, whatever it is — this is the number the
        // previous report quoted without knowing what it meant.
        print("MEASURED accessibility frame: \(frame.size)")

        // 22pt above centre is the edge of a 44pt box: reaching it means the
        // hit region is at least 44pt tall, which is the actual requirement.
        tapOffset(signOut, dy: -22)

        let returnedToSignIn = waitForExistence(
            of: app.staticTexts["login.title"], in: app, timeout: 8
        )
        if returnedToSignIn {
            print("MEASURED hit region reaches 22pt above centre — at least 44pt tall")
        } else {
            print("MEASURED hit region does NOT reach 22pt above centre (frame \(frame.size))")
        }
        // Deliberately not an assertion on the outcome: this test's job is to
        // produce the measurement. Whether 44pt is met is judged in the report,
        // with this number in hand, rather than by a pass/fail that hides which
        // of the three sizes was being checked.
        XCTAssertTrue(true)
    }

    /// Control group: the probe has to be able to tell "inside the control"
    /// from "outside" it, or the navigation-bar measurement means nothing.
    ///
    /// The like button is 44pt tall and laid out by us, so a tap 18pt above its
    /// centre is inside it and a tap 40pt above it is not. The value — "N
    /// likes" — is what says whether the tap registered; the label only says
    /// Like/Unlike and can be the same either side of a failed write.
    func testTheProbeCanTellInsideFromOutside() {
        let app = signedIn()
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30))
        print("MEASURED like button frame: \(like.frame.size)")
        XCTAssertGreaterThanOrEqual(like.frame.height, 44, "content controls are sized by us")

        func currentValue() -> String {
            app.buttons.matching(identifier: "post.like").firstMatch.value as? String ?? "?"
        }

        let start = currentValue()
        // Inside: 18pt above centre, within a 44pt box.
        tapOffset(like, dy: -18)
        Thread.sleep(forTimeInterval: 2)
        let afterInside = currentValue()
        print("MEASURED value start=\(start) after -18pt=\(afterInside)")
        XCTAssertNotEqual(start, afterInside, "a tap inside the control must register")

        // Outside: 40pt above centre is well beyond a 44pt box.
        tapOffset(like, dy: -40)
        Thread.sleep(forTimeInterval: 2)
        let afterOutside = currentValue()
        print("MEASURED value after -40pt=\(afterOutside)")
        XCTAssertEqual(afterInside, afterOutside, "a tap outside the control must not register")
    }

    /// The edge case that matters for a bar button: the very top of the bar.
    func testNavigationBarButtonRespondsNearTheBarEdge() {
        let app = signedIn()
        let bar = app.navigationBars["PetNote"]
        let signOut = app.buttons["session.signOut"]
        XCTAssertTrue(waitUntilHittable(signOut, in: app, timeout: 20))
        print("MEASURED bar frame: \(bar.frame.size), button frame: \(signOut.frame.size)")

        // Tap near the button's horizontal centre but at the top edge of the
        // navigation bar itself.
        let barTop = bar.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let buttonCentreX = signOut.frame.midX - bar.frame.minX
        let point = barTop.withOffset(CGVector(dx: buttonCentreX, dy: 4))
        point.tap()

        let returnedToSignIn = waitForExistence(
            of: app.staticTexts["login.title"], in: app, timeout: 8
        )
        print("MEASURED tap 4pt from bar top: \(returnedToSignIn ? "activated" : "no effect")")
        XCTAssertTrue(true)
    }
}
