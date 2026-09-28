import XCTest

/// Reporting somebody else's post, through the screens, read back from the
/// emulator: the report document is the only evidence that the callable ran.
///
/// A fresh account, so no post in the feed is its own and every one offers
/// Report — and so the report it files can be removed without touching
/// anything a seeded account did.
final class ReportUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "report-\(run)@petnote.test" }
    private var uid: String?
    private var reportedPost: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid, let reportedPost {
            JourneyAdmin.deleteDocument(path: "reports/\(uid)_post_\(reportedPost)")
        }
        if let uid {
            if let name = try? JourneyAdmin.fields(path: "users/\(uid)").flatMap({ JourneyAdmin.string($0["displayName"]) }) {
                JourneyAdmin.deleteDocument(path: "usernames/\(JourneyAdmin.reservationID(for: name))")
            }
            JourneyAdmin.deleteDocument(path: "users/\(uid)")
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testReportingSomeoneElsesPostFilesOneReport() throws {
        let uid = try EmulatorAdmin.createVerifiedAccount(email: email, password: "Passw0rd!x")
        self.uid = uid
        let app = launchOnSignIn()
        signIn(app, email: email, expectFeed: false)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app))

        openFirstPost(app)
        let postID = try XCTUnwrap(currentDetailPostID(app), "could not tell which post is open")
        reportedPost = postID

        let menu = app.buttons["post.actions"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 30), "no post menu")
        menu.tap()
        let report = app.buttons["post.actions.report"]
        XCTAssertTrue(waitUntilHittable(report, in: app, timeout: 10),
                      "someone else's post offers no Report\n\(app.debugDescription)")
        report.tap()

        let reason = app.buttons["report.reason.1"]   // "Inappropriate content"
        XCTAssertTrue(waitUntilHittable(reason, in: app, timeout: 20), "the report sheet did not open")
        reason.tap()
        app.buttons["report.send"].tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["report.sent"], in: app, timeout: 30),
                      "the report was not confirmed\n\(app.debugDescription)")

        let filed = try XCTUnwrap(try JourneyAdmin.fields(path: "reports/\(uid)_post_\(postID)"),
                                  "no report document on the server")
        XCTAssertEqual(JourneyAdmin.string(filed["reason"]), "Inappropriate content")
        XCTAssertEqual(JourneyAdmin.string(filed["targetType"]), "post")
        XCTAssertEqual(JourneyAdmin.string(filed["reporterId"]), uid)
        app.buttons["report.done"].tap()
    }

    /// Which post the detail screen is showing, from the one text the card
    /// carries and the server's copy of it.
    private func currentDetailPostID(_ app: XCUIApplication) -> String? {
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch
        guard text.waitForExistence(timeout: 20) else { return nil }
        let names = (try? JourneyAdmin.postDocumentNames(withText: text.label)) ?? []
        return names.count == 1 ? names.first?.split(separator: "/").last.map(String.init) : nil
    }
}
