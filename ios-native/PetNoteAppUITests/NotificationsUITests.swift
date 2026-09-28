import XCTest

/// In-app notifications through the screens, against the emulator.
///
/// The notifications are written straight into the emulator here, shaped as
/// the server's triggers write them (functions/src/notifications.ts). What is
/// under test is the app: the dot on the bell, the list, where a tap goes,
/// marking one read and marking all read — each read back from the server.
/// The triggers themselves are covered where they live, in the functions
/// tests and the test-project run.
final class NotificationsUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "notify-\(run)@petnote.test" }
    private var uid: String?
    private var written: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for id in written { JourneyAdmin.deleteDocument(path: "notifications/\(id)") }
        if let uid { JourneyAdmin.removeProfile(uid: uid) }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testTheBellTheListATapAndMarkingAllRead() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        let manifest = try EmulatorAdmin.seedManifest()
        let postID = try XCTUnwrap(manifest.post(index: 1))
        let post = try XCTUnwrap(try JourneyAdmin.fields(path: "posts/\(postID)"))
        let postText = try XCTUnwrap(JourneyAdmin.string(post["text"]))

        try write("like", for: me, fields: [
            "type": "like", "fromUserId": "u-notify-a", "fromUserName": "Notifier",
            "message": "liked your post", "postId": postID,
        ], secondsAgo: 60)
        try write("warn", for: me, fields: [
            "type": "warning", "fromUserId": "petnote-system", "fromUserName": "PetNote Team",
            "message": "TEST CONTENT a reminder about the rules", "warningDetails": "TEST CONTENT details",
        ], secondsAgo: 30)

        // The dot, after the feed reads again.
        let bell = app.buttons["feed.notifications"]
        XCTAssertTrue(waitUntilHittable(bell, in: app, timeout: 30), "no bell\n\(app.debugDescription)")
        app.tabBars.buttons["Profile"].tap()
        app.tabBars.buttons["Home"].tap()
        let dotted = expectation(for: NSPredicate(format: "value == 'Unread'"), evaluatedWith: bell)
        XCTAssertEqual(XCTWaiter().wait(for: [dotted], timeout: 20), .completed, "the bell shows nothing unread")
        bell.tap()

        let likeRow = app.buttons["notification.\(written[0])"]
        XCTAssertTrue(waitForExistence(of: likeRow, in: app, timeout: 30), "the list is missing a notification\n\(app.debugDescription)")
        XCTAssertTrue(likeRow.label.contains("Notifier liked your post"), likeRow.label)
        XCTAssertTrue(waitForExistence(of: app.staticTexts["notifications.unreadCount"], in: app, timeout: 10))
        XCTAssertEqual(app.staticTexts["notifications.unreadCount"].label, "2 unread")
        XCTAssertTrue(app.buttons["notification.\(written[1])"].label.contains("PetNote Team"))

        // A tap opens the post it is about and marks it read.
        likeRow.tap()
        let opened = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: opened, in: app, timeout: 30), "the notification opened nothing")
        XCTAssertEqual(opened.label, postText)
        try waitFor(read: true, id: written[0])
        XCTAssertEqual(JourneyAdmin.bool(try JourneyAdmin.fields(path: "notifications/\(written[1])")?["read"]), false,
                       "opening one marked another read")

        // Back, and mark everything read.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let markAll = app.buttons["notifications.markAllRead"]
        XCTAssertTrue(waitUntilHittable(markAll, in: app, timeout: 20))
        markAll.tap()
        try waitFor(read: true, id: written[1])
        XCTAssertTrue(waitForDisappearance(of: app.staticTexts["notifications.unreadCount"], timeout: 10))

        // And the bell agrees.
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let cleared = expectation(for: NSPredicate(format: "value != 'Unread'"), evaluatedWith: bell)
        XCTAssertEqual(XCTWaiter().wait(for: [cleared], timeout: 20), .completed, "the bell still shows unread")
    }

    func testNothingYetSaysSo() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        let bell = app.buttons["feed.notifications"]
        XCTAssertTrue(waitUntilHittable(bell, in: app, timeout: 30))
        bell.tap()
        XCTAssertTrue(waitForExistence(of: app.descendants(matching: .any)["notifications.empty"], in: app, timeout: 30),
                      "an empty inbox did not say so\n\(app.debugDescription)")
    }

    // MARK: - Emulator writes

    private func write(_ name: String, for uid: String, fields: [String: String], secondsAgo: Int) throws {
        let id = "ui-\(run)-\(name)"
        var body: [String: Any] = [:]
        for (key, value) in fields { body[key] = ["stringValue": value] }
        body["userId"] = ["stringValue": uid]
        body["read"] = ["booleanValue": false]
        let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(-secondsAgo)))
        body["createdAt"] = ["timestampValue": created]
        let path = "projects/\(EmulatorAdmin.projectID)/databases/(default)/documents/notifications/\(id)"
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(EmulatorAdmin.firestore)/v1/\(path)")))
        request.httpMethod = "PATCH"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": body])
        let done = expectation(description: "notification \(name) written")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        XCTAssertEqual(status, 200, "the emulator refused the notification")
        written.append(id)
    }

    private func waitFor(read expected: Bool, id: String) throws {
        var value: Bool?
        for _ in 0..<20 {
            value = JourneyAdmin.bool(try JourneyAdmin.fields(path: "notifications/\(id)")?["read"])
            if value == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("notification \(id) read=\(String(describing: value)), expected \(expected)")
    }
}
