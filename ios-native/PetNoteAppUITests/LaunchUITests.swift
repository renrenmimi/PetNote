import XCTest

/// Acceptance item 2.5: the app launches and shows the sign-in screen.
///
/// Deliberately thin. It proves L4 — the app starts and puts the right screen
/// up — and nothing about how that screen looks or behaves on a real phone,
/// which is L5 and needs a device.
final class LaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchShowsSignIn() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["login.title"].waitForExistence(timeout: 10),
            "Sign-in screen did not appear within 10s of launch"
        )
        XCTAssertTrue(app.textFields["login.email"].exists, "Email field missing")
        XCTAssertTrue(app.secureTextFields["login.password"].exists, "Password field missing")
        XCTAssertTrue(app.buttons["login.submit"].exists, "Sign-in button missing")
    }

    /// The hit target rule from §5.5, checked where it is cheapest to check.
    func testSignInButtonMeetsMinimumTouchTarget() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 10))
        let frame = app.buttons["login.submit"].frame
        XCTAssertGreaterThanOrEqual(frame.height, 44, "Sign-in button is \(frame.height)pt tall")
    }
}
