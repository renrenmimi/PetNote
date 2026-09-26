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

        // The two screens the shell also frames, and back.
        let signUp = app.buttons["login.signUp"]
        if waitUntilHittable(signUp, in: app, timeout: 10) {
            signUp.tap()
            _ = app.staticTexts["signup.title"].waitForExistence(timeout: 10)
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            shoot("01b-signup")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let forgot = app.buttons["login.forgotPassword"]
        if waitUntilHittable(forgot, in: app, timeout: 10) {
            forgot.tap()
            _ = app.staticTexts["forgot.title"].waitForExistence(timeout: 10)
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            shoot("01c-forgot")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        _ = app.textFields["login.email"].waitForExistence(timeout: 10)

        signIn(app, email: "accept-a@example.com")
        waitForQuietUI(app)
        shoot("02-feed")

        // Liked and saved, then both taken back.
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        let save = app.buttons.matching(identifier: "post.bookmark").firstMatch
        if waitUntilHittable(like, in: app, timeout: 20), waitUntilHittable(save, in: app, timeout: 5) {
            like.tap()
            save.tap()
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            shoot("03-feed-liked-saved")
            like.tap()
            save.tap()
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        }

        openFirstPost(app)
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        shoot("04-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        _ = app.navigationBars["PetNote"].waitForExistence(timeout: 10)

        // A pet's page: the same cards, under the pet.
        let search = app.buttons["feed.search"]
        if waitUntilHittable(search, in: app, timeout: 10) {
            search.tap()
            let field = app.searchFields.firstMatch
            if waitUntilHittable(field, in: app, timeout: 10) {
                field.tap()
                field.typeText("Mochi\n")
                let result = app.buttons["search.pet.ios-pet-latin"]
                if waitUntilHittable(result, in: app, timeout: 20) {
                    result.tap()
                    _ = app.staticTexts["pet.name"].waitForExistence(timeout: 20)
                    app.swipeUp()
                    _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
                    shoot("06-pet-page")
                }
            }
        }
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

    /// The states that are not the happy path, as they look on the new cards:
    /// a lost next page, a failed refresh, a long name, and empty lists.
    func testTheEdgeStates() {
        // A lost page, where it happened, under the cards already read.
        var app = launchOnSignIn(extraArguments: ["-petnote-feed-tiny-pages", "-petnote-feed-next-page-fails-once"])
        signIn(app, email: "accept-a@example.com")
        for _ in 0..<14 where !app.staticTexts["feed.pagingError"].exists { app.swipeUp() }
        if app.staticTexts["feed.pagingError"].waitForExistence(timeout: 10) {
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            shoot("07-paging-failure")
        }
        app.terminate()

        // A refresh that fails: the banner over a feed that is still there.
        app = launchOnSignIn(extraArguments: ["-petnote-feed-refresh-fails-once"])
        signIn(app, email: "accept-a@example.com")
        waitForQuietUI(app)
        pullToRefreshFeed(app)
        if app.staticTexts["feed.refreshError"].waitForExistence(timeout: 30) {
            _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
            shoot("08-refresh-failure")
        }

        // The long name: the seed's CJK pet, whose name runs past the card.
        let longName = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "麻薯团子")).firstMatch
        for _ in 0..<6 where !(longName.exists && longName.isHittable) { nudgeListUp(app) }
        _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
        shoot("09-long-name")

        // Empty: a pet with no posts.
        let search = app.buttons["feed.search"]
        if waitUntilHittable(search, in: app, timeout: 10) {
            search.tap()
            let field = app.searchFields.firstMatch
            if waitUntilHittable(field, in: app, timeout: 10) {
                field.tap()
                field.typeText("Mochi\n")
                let result = app.buttons["search.pet.accept-pet"]
                if waitUntilHittable(result, in: app, timeout: 20) {
                    result.tap()
                    _ = app.staticTexts["pet.name"].waitForExistence(timeout: 20)
                    _ = waitForQuietUI(app, quietFor: 1, timeout: 10)
                    shoot("10-empty-pet")
                }
            }
        }
    }
}
