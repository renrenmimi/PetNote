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

    /// Which post the first row is, so the test can name it when checking the
    /// backend afterwards. The seed puts the index in every post's text.
    private func firstPostIndex(_ app: XCUIApplication) -> String? {
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        guard text.waitForExistence(timeout: 20) else { return nil }
        guard let range = text.label.range(of: #"\[#(\d+)\]"#, options: .regularExpression) else { return nil }
        return String(text.label[range].dropFirst(2).dropLast())
    }

    /// Like, then unlike, checking the button state and the displayed count at
    /// each step — and writing the post id out so the run can be reconciled
    /// against the emulator afterwards.
    ///
    /// Three things have to agree and this covers two of them; the third (the
    /// like document and the aggregate on the server) is checked by the script
    /// that reads the emulator after this test, because XCUITest cannot.
    func testLikeThenUnlikeLeavesButtonAndCountWhereTheyStarted() {
        let app = signedIn()
        let like = app.buttons.matching(identifier: "post.like").firstMatch
        XCTAssertTrue(waitUntilHittable(like, in: app, timeout: 30))
        let index = firstPostIndex(app) ?? "?"
        print("MEASURED target post index: \(index)")

        let startLabel = like.label
        let startValue = like.value as? String ?? "?"
        print("MEASURED start: label=\(startLabel) value=\(startValue)")

        like.tap()
        Thread.sleep(forTimeInterval: 3)
        let afterLike = app.buttons.matching(identifier: "post.like").firstMatch
        let likedLabel = afterLike.label
        let likedValue = afterLike.value as? String ?? "?"
        print("MEASURED after like: label=\(likedLabel) value=\(likedValue)")
        XCTAssertNotEqual(likedLabel, startLabel, "the button did not change state")

        afterLike.tap()
        Thread.sleep(forTimeInterval: 3)
        let afterUnlike = app.buttons.matching(identifier: "post.like").firstMatch
        print("MEASURED after unlike: label=\(afterUnlike.label) value=\(afterUnlike.value as? String ?? "?")")

        XCTAssertEqual(afterUnlike.label, startLabel, "the button did not come back")
        XCTAssertEqual(
            afterUnlike.value as? String, startValue,
            "the count did not come back: \(startValue) → \(afterUnlike.value as? String ?? "?")"
        )
        print("MEASURED RECONCILE post=ios-post-\(index.count == 3 ? index : "0" + index) expect=unliked")
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
