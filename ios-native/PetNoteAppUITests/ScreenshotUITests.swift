import XCTest

/// Drives the core path and writes screenshots somewhere a person can open
/// them. Not assertions — evidence.
///
/// These run on a simulator, so what they prove is L4: the screens compose and
/// the data arrives. How any of it looks and feels on a phone is L5 and needs
/// the device.
final class ScreenshotUITests: XCTestCase {
    private let outputDirectory = "/tmp/petnote-shots"

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true
        )
    }

    private func shoot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
    }

    func testCapturesTheCorePath() {
        let app = XCUIApplication()
        app.launchArguments = ["-petnote-start-signed-out"]
        app.launch()

        XCTAssertTrue(app.staticTexts["login.title"].waitForExistence(timeout: 15))
        shoot("01-login")

        let email = app.textFields["login.email"]
        email.tap()
        email.typeText("accept-a@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("Passw0rd!x")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(
            waitForExistence(of: app.navigationBars["PetNote"], in: app, timeout: 40),
            "Never reached the feed"
        )
        waitForQuietUI(app)
        // Images arrive over the network; give the first screenful a moment so
        // the shot shows the loaded state rather than placeholders.
        Thread.sleep(forTimeInterval: 4)
        shoot("02-feed")

        // Scroll far enough to prove paging actually appended.
        let list = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        for _ in 0..<6 { list.swipeUp(velocity: .fast) }
        Thread.sleep(forTimeInterval: 3)
        shoot("03-feed-scrolled")

        // Into a post.
        let firstComments = app.buttons.matching(identifier: "post.comments").firstMatch
        if firstComments.waitForExistence(timeout: 10), firstComments.isHittable {
            firstComments.tap()
            Thread.sleep(forTimeInterval: 4)
            shoot("04-detail")

            let field = app.textFields["composer.field"]
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText("TEST CONTENT 来自原生客户端的评论")
                Thread.sleep(forTimeInterval: 1)
                shoot("05-composer")
            }
        }
    }
}
