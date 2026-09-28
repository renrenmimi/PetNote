import XCTest

/// Proves the running app says which backend it is talking to.
///
/// This exists because of a specific gap: device acceptance produces
/// screenshots, and a screenshot of the feed looks the same whether the data
/// came from the emulator, from an independent test project, or — the case
/// that matters — from production. Evidence that cannot distinguish those is
/// not evidence of anything.
///
/// So the badge is asserted here rather than assumed. If it ever stops
/// rendering, every device screenshot taken afterwards silently loses its
/// meaning, and nothing else in the suite would notice.
final class EnvironmentBadgeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheSignedInScreenNamesItsBackendAndProject() {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()
        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))

        let email = app.textFields["login.email"]
        email.tap()
        email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40))

        let badge = app.staticTexts["env.badge"]
        XCTAssertTrue(waitForExistence(of: badge, in: app, timeout: 15),
                      "No environment badge — a device screenshot could not say which backend it came from")

        // The label has to carry both halves. The backend alone does not say
        // which project; the project alone does not say whether the traffic
        // stayed on this machine.
        let label = badge.label
        XCTAssertTrue(label.contains("·"), "Badge does not name both backend and project: \(label)")

        // This build is the emulator configuration. Two things must be true,
        // and the second is the one that catches a real accident.
        XCTAssertTrue(label.hasPrefix("EMULATOR"), "Badge does not name the backend: \(label)")
        XCTAssertFalse(label.contains("petnote-a9dac"),
                       "An emulator build is showing the production project: \(label)")
    }
}
