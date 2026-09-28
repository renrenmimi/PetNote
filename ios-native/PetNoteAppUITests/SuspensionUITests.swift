import XCTest

/// The suspended banner — the web client's `SuspendedBanner` — driven by the
/// same document the web reads, `users/{uid}/admin/state`, written here as an
/// administrator would (straight into the emulator; there is no admin screen
/// in this app).
///
/// The app reads the document rather than listening to it, and reads it again
/// whenever it comes back to the front. So the ban is set, the app leaves the
/// foreground and returns, and the banner has to be there — with the top bar
/// still usable under it, which is the defect the web's banner once had.
final class SuspensionUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "ban-\(run)@petnote.test" }
    private var uid: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid {
            JourneyAdmin.deleteDocument(path: "users/\(uid)/admin/state")
            JourneyAdmin.removeProfile(uid: uid)
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testABanShowsTheBannerOnReturnAndLiftingItTakesItAway() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        // `firstMatch`: every screen carries its own, and a pushed screen
        // leaves the one under it in the stack.
        let banner = app.staticTexts["suspended.banner"].firstMatch
        XCTAssertFalse(banner.exists, "an account that was never banned shows the banner")

        try setBanned(true, uid: me)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitForExistence(of: banner, in: app, timeout: 20),
                      "a ban did not show on returning to the app\n\(app.debugDescription)")
        XCTAssertEqual(banner.label, "Your account has been suspended.")
        // Beside the top bar, not over it: the feed's top bar still answers,
        // and the two frames do not overlap.
        let menu = app.buttons["account.menu"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 10), "the banner covers the top bar")
        XCTAssertFalse(banner.frame.intersects(menu.frame.insetBy(dx: 0, dy: 1)),
                       "the banner overlaps the top bar: \(banner.frame) vs \(menu.frame)")
        // And on a screen pushed from a tab, not only on the tab's root.
        app.tabBars.buttons["Profile"].tap()
        let saved = app.buttons["profile.saved"]
        for _ in 0..<4 where !(saved.exists && saved.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(saved, in: app, timeout: 20))
        saved.tap()
        XCTAssertTrue(waitForExistence(of: app.descendants(matching: .any)["saved.empty"], in: app, timeout: 30))
        XCTAssertTrue(banner.exists, "a pushed screen has no banner")
        popToTabRoot(app, then: "Home")

        try setBanned(false, uid: me)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitForDisappearance(of: banner, timeout: 20), "the banner stayed after the ban was lifted")
    }

    /// `banned` on the account's admin state, as `blockUserByAdmin` writes it.
    private func setBanned(_ banned: Bool, uid: String) throws {
        let path = "projects/\(EmulatorAdmin.projectID)/databases/(default)/documents/users/\(uid)/admin/state"
        var request = URLRequest(url: try XCTUnwrap(
            URL(string: "\(EmulatorAdmin.firestore)/v1/\(path)?updateMask.fieldPaths=banned")))
        request.httpMethod = "PATCH"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["fields": ["banned": ["booleanValue": banned]]])
        request.timeoutInterval = 20

        var status = 0
        let done = expectation(description: "admin state written")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 25)
        XCTAssertEqual(status, 200, "the emulator refused the admin state write")
    }
}
