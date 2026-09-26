import XCTest

/// Screens for putting beside the web client's, taken once the system's
/// "Save Password?" sheet has come and gone — the core-path screenshots are
/// taken under it, dimmed, which is no use for judging colour.
///
/// Evidence, not assertions: the files go to `/tmp/petnote-visual` for a
/// person to look at. It likes the first post to show the liked state and
/// takes the like back before it finishes.
final class VisualComparisonUITests: XCTestCase {
    private let outputDirectory = "/tmp/petnote-visual"

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true
        )
    }

    private func shoot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
    }

    func testTheScreensToCompare() {
        let app = launchOnSignIn()
        XCTAssertTrue(app.textFields["login.email"].waitForExistence(timeout: 30), "no sign-in screen")
        shoot("01-login")

        signIn(app, email: "accept-a@example.com")
        waitForQuietUI(app)
        shoot("02-feed")

        let like = app.buttons.matching(identifier: "post.like").firstMatch
        if waitUntilHittable(like, in: app, timeout: 20) {
            like.tap()
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            shoot("03-feed-liked")
            like.tap()
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        }

        openFirstPost(app)
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        shoot("04-detail")
    }

    /// The feed bar at the default size and at the largest accessibility
    /// size, with the video probe on, written out item by item: which items
    /// the bar kept, where, and whether the principal item (where the probe
    /// lives) and the account button survived. The lockup, the environment
    /// badge, the principal item and three buttons share 402pt.
    func testTheFeedBarAtTheDefaultSizeAndAtAX5() {
        for (tag, size) in [("default", "UICTContentSizeCategoryL"),
                            ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")] {
            let app = launchOnSignIn(extraArguments: [
                "-UIPreferredContentSizeCategoryName", size, "-petnote-video-probe",
            ])
            signIn(app, email: "accept-a@example.com")
            waitForQuietUI(app)
            shoot("05-feed-bar-\(tag)")
            let bar = app.navigationBars.firstMatch
            print("VISUAL [\(tag)] probe in bar: \(bar.staticTexts.matching(identifier: "video.probe").firstMatch.exists)")
            print("VISUAL [\(tag)] account in bar: \(app.buttons["account.menu"].exists)")
            print("VISUAL [\(tag)] bar:\n\(bar.debugDescription)")
            app.terminate()
        }
    }
}
