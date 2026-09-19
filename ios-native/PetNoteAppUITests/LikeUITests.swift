import XCTest

/// Does tapping the heart actually like the post.
///
/// Worth its own test because nothing before this ever tapped it: the model's
/// three-state handling was covered by unit tests against fakes, and the UI
/// tests only ever read the button's label.
final class LikeUITests: XCTestCase {
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

    func testTappingTheHeartLikesThePost() {
        let app = signedIn()
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30), "no like button")

        let before = like.value as? String ?? "?"
        let labelBefore = like.label
        print("MEASURED before: label=\(labelBefore) value=\(before) frame=\(like.frame)")

        like.tap()
        Thread.sleep(forTimeInterval: 3)

        let after = app.buttons.matching(identifier: "post.like").firstMatch
        print("MEASURED after: label=\(after.label) value=\(after.value as? String ?? "?")")

        XCTAssertNotEqual(
            after.label, labelBefore,
            "the heart did not change state — label stayed \(labelBefore)"
        )
        XCTAssertFalse(
            app.staticTexts["feed.likeError"].exists,
            "a like failure was reported: \(app.staticTexts["feed.likeError"].label)"
        )
    }
}
