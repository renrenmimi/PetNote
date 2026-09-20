import XCTest

/// The half of the comment contract that can be produced for real: an
/// unverified account really being refused by the server, a comment really
/// being written, and paging a list that really has 120 comments in it.
///
/// **Every send here is checked against the server, not against the screen.**
/// A row on screen proves the app drew a row; the acceptance criterion is that
/// a comment was written, and the only place that can be answered is Firestore.
/// The previous version of this file counted a combined accessibility row plus
/// the `Text` inside it as two comments while the server held one — reading the
/// server makes that class of mistake impossible rather than merely unlikely.
///
/// The branches that need a ban, a block, or a lost response are asserted in
/// PostDetailViewModelTests with injected errors: putting the emulator into
/// those states would mean seeding data that looks like moderation, and losing
/// a response on purpose is not something a UI test can do.
final class CommentUITests: XCTestCase {
    /// Text this test wrote, removed in tearDown. The seed is shared with the
    /// other agents' runs; adding to it is allowed, leaving things behind is
    /// not.
    private var writtenTexts: [String] = []

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        var leftBehind: [String] = []
        for text in writtenTexts {
            leftBehind += EmulatorAdmin.deleteComments(withExactText: text)
        }
        writtenTexts = []
        // Failing here on purpose. The emulator is seeded once and shared with
        // the other agents' runs; a test that cannot clean up after itself is
        // changing what the next run sees, and a silent 403 is how that
        // happened the first time.
        XCTAssertTrue(leftBehind.isEmpty, "comments left in the shared emulator: \(leftBehind)")
        super.tearDown()
    }

    private func uniqueText(_ label: String) -> String {
        let text = "TEST CONTENT a3 \(label) \(Int(Date().timeIntervalSince1970 * 1000))"
        writtenTexts.append(text)
        return text
    }

    /// Opens the post the emulator says has the most comments — 5C.11 needs
    /// more than 50, and asking the server which post that is beats assuming a
    /// position in the feed.
    @discardableResult
    private func openTheMostCommentedPost(_ app: XCUIApplication) throws -> String {
        let post = try EmulatorAdmin.postWithMostComments()
        openPost(app, withText: post.text)
        return post.id
    }

    private func type(_ text: String, into app: XCUIApplication) {
        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20))
        field.tap()
        field.typeText(text)
    }

    // MARK: - 5C.6 The unverified gate, enforced by the server

    /// 4.6's second half: the server refuses, the words come from us, and
    /// nothing is written.
    func testUnverifiedAccountIsRefusedAndNothingIsWritten() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-new@example.com")
        openFirstPost(app)

        let text = uniqueText("unverified")
        type(text, into: app)
        app.buttons["composer.send"].tap()

        let error = app.staticTexts["composer.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 40), "no refusal was shown")
        XCTAssertEqual(error.label, "Verify your email before commenting.")

        // Nothing from the SDK, and no claim that it merely failed.
        for leak in ["FIRFunctions", "permission-denied", "PERMISSION_DENIED", "NSError", "Error Domain"] {
            XCTAssertFalse(error.label.contains(leak), "raw error leaked: \(leak)")
        }

        // The text is still there to fix or copy (5C.6: 不丢输入).
        XCTAssertEqual(
            app.textFields["composer.field"].value as? String, text,
            "the typed comment was thrown away"
        )
        // Verifying an email is not something a retry can do, so no retry is
        // offered. The composer's own send button stays available — the person
        // may edit and try something else — but the app does not suggest that
        // pressing the same thing again will work.
        XCTAssertFalse(app.buttons["composer.retry"].exists,
                       "offered a retry for a refusal a retry cannot fix")

        XCTAssertEqual(commentRows(in: app, containing: text).count, 0,
                       "the optimistic row was left behind after the refusal")
        assertServerCommentCount(text, equals: 0)
    }

    // MARK: - 5C.4 A comment that is actually written

    func testVerifiedAccountCommentIsWrittenToTheServer() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("write")
        type(text, into: app)
        app.buttons["composer.send"].tap()

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "comment.row")
                .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch,
                in: app, timeout: 40),
            "the comment never appeared in the list"
        )
        XCTAssertFalse(app.staticTexts["composer.error"].exists,
                       "a successful send should not show an error")
        XCTAssertEqual(app.textFields["composer.field"].value as? String, "Add a comment",
                       "the composer was not cleared after a successful send")

        assertServerCommentCount(text, equals: 1)
    }

    /// Written, and still there after the screen is rebuilt from the server —
    /// which is the difference between "the app drew it" and "it exists".
    func testAWrittenCommentSurvivesLeavingAndComingBack() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("readback")
        type(text, into: app)
        app.buttons["composer.send"].tap()
        assertServerCommentCount(text, equals: 1)

        popToFeed(app)
        openFirstPost(app)

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "comment.row")
                .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch,
                in: app, timeout: 40),
            "the comment was not there when the list was loaded again"
        )
        XCTAssertEqual(commentRows(in: app, containing: text).count, 1,
                       "the comment was drawn more than once after a reload")
    }

    // MARK: - Duplicate submission

    /// Tapping send twice must not write twice. The composer disables while
    /// sending, but what is asserted is the number of documents — a disabled
    /// control is a UI convention, not a guarantee.
    func testDoubleTapSendWritesOneComment() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("double")
        type(text, into: app)

        let send = app.buttons["composer.send"]
        send.tap()
        send.tap()   // immediately again

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts.matching(identifier: "comment.row")
                .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch,
                in: app, timeout: 40)
        )
        assertServerCommentCount(text, equals: 1, settleFor: 8)
        XCTAssertEqual(commentRows(in: app, containing: text).count, 1,
                       "the comment is on screen twice")
    }

    /// Leaving the screen and coming back must not lose a draft the person has
    /// not sent — and must not silently send it either.
    func testLeavingWithAnUnsentDraftDoesNotSendIt() {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("unsent")
        type(text, into: app)

        popToFeed(app)
        openFirstPost(app)

        XCTAssertEqual(commentRows(in: app, containing: text).count, 0,
                       "an unsent draft was posted by leaving the screen")
        assertServerCommentCount(text, equals: 0)
    }

    // MARK: - 5C.10 A response that went missing

    /// The write lands, the answer is thrown away, and the app has to resolve
    /// that without ever sending again.
    ///
    /// This is the branch the whole design turns on: `createCommentCallable`
    /// has no idempotency key, so one automatic resend is one duplicate
    /// comment. The server count at the end is what proves there was none —
    /// the screen could not tell the difference between "resolved by looking"
    /// and "resolved by sending again and getting lucky".
    func testALostResponseIsResolvedByLookingAndNeverBySendingAgain() {
        let app = launchOnSignIn(extraArguments: ["-petnote-comment-lose-response"])
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("lost-response")
        type(text, into: app)
        app.buttons["composer.send"].tap()

        // Every message this composer showed, in order.
        //
        // Sampled rather than asserted one state at a time, because the
        // interim "we could not confirm" state is short-lived by design — the
        // check is one read against a local emulator and can finish before a
        // query returns. A test that demanded to *see* the interim state would
        // be asserting that resolving is slow, which is the opposite of what
        // is wanted. What must hold is the sequence: nothing ever claims a
        // plain failure, and the last word is the resolved one.
        let error = app.staticTexts["composer.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 40), "nothing was reported")

        var seen: [String] = []
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if error.exists {
                let label = error.label
                if seen.last != label { seen.append(label) }
                if label.contains("posted after all") { break }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertFalse(seen.isEmpty, "no message was ever shown")
        for message in seen {
            XCTAssertFalse(
                message.lowercased().contains("failed"),
                "claimed a certain failure for an unknown outcome: \(message)"
            )
            XCTAssertFalse(
                message.contains("not posted"),
                "claimed the comment was not posted when it was: \(message)"
            )
        }
        XCTAssertTrue(
            seen.last?.contains("posted after all") == true,
            "the app never resolved the unknown outcome. messages: \(seen)"
        )
        // Resolved, so there is nothing left to press — and nothing that could
        // turn one comment into two.
        XCTAssertFalse(app.buttons["composer.retry"].exists,
                       "a retry was offered after the comment was confirmed posted")
        XCTAssertEqual(app.textFields["composer.field"].value as? String, "Add a comment",
                       "the text was left in the box, inviting a duplicate")
        XCTAssertEqual(commentRows(in: app, containing: text).count, 1,
                       "the comment is on screen more than once")

        // And exactly one document, after long enough for a resend to have
        // landed if there had been one.
        assertServerCommentCount(text, equals: 1, settleFor: 10)
    }

    // MARK: - Offline: a certain failure, not an uncertain one

    /// Nothing left the device, so nothing was written, so sending again is
    /// safe — and is offered. §6.11 also asks that the words differ from a
    /// server-side refusal's.
    func testAnOfflineSendWritesNothingAndOffersARetry() {
        let app = launchOnSignIn(extraArguments: ["-petnote-comment-offline"])
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("offline")
        type(text, into: app)
        app.buttons["composer.send"].tap()

        let error = app.staticTexts["composer.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 40))
        XCTAssertTrue(error.label.lowercased().contains("offline"),
                      "an offline send was not reported as one: \(error.label)")
        XCTAssertNotEqual(error.label, "Could not post that comment.",
                          "offline is not distinguishable from a server failure")
        XCTAssertFalse(error.label.contains("could not confirm"),
                       "a request that never left the device is not an unknown outcome")

        XCTAssertEqual(app.textFields["composer.field"].value as? String, text,
                       "the text was thrown away")
        XCTAssertTrue(waitUntilHittable(app.buttons["composer.retry"], in: app, timeout: 10),
                      "no retry offered for a failure that is safe to repeat")
        XCTAssertEqual(commentRows(in: app, containing: text).count, 0,
                       "the optimistic row was left behind")
        assertServerCommentCount(text, equals: 0)
    }

    // MARK: - 5C.11 Paging a long list, and refreshing it

    /// 120 comments, a page size of 30. Paging must bring in comments that
    /// were not there before, and must not move what is already on screen.
    func testPagingALongCommentListDoesNotMoveWhatIsAlreadyThere() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        try openTheMostCommentedPost(app)

        let rows = app.staticTexts.matching(identifier: "comment.row")
        XCTAssertTrue(waitForExistence(of: rows.firstMatch, in: app, timeout: 40),
                      "the first page of comments never arrived")

        let firstPage = Set(labels(of: rows))
        XCTAssertGreaterThan(firstPage.count, 1, "only \(firstPage.count) comments realised")

        // Scroll until the last realised row is one the first page did not
        // contain: that, and not a spinner, is what proves a page arrived.
        var anchorLabel: String?
        var anchorY: CGFloat = 0
        var sawNewComments = false
        for step in 0..<12 {
            if step == 6, let label = labels(of: rows).first {
                // Halfway down, pin something and watch whether the next page
                // pushes it around. Comments are newest-first and pages append
                // below, so nothing already on screen has any business moving.
                anchorLabel = label
                anchorY = rows.containing(NSPredicate(format: "label == %@", label))
                    .firstMatch.frame.minY
            }
            app.swipeUp()
            let now = Set(labels(of: rows))
            if !now.subtracting(firstPage).isEmpty { sawNewComments = true }
            if sawNewComments, anchorLabel != nil { break }
        }
        XCTAssertTrue(sawNewComments, "scrolling to the end of page one loaded nothing more")

        if let label = anchorLabel {
            let anchor = rows.containing(NSPredicate(format: "label == %@", label)).firstMatch
            if anchor.exists {
                XCTAssertEqual(
                    anchor.frame.minY, anchorY, accuracy: 1.0,
                    "a comment already on screen moved when the next page arrived"
                )
            }
        }
    }

    /// A refresh must replace the list, not append to it. The failure this
    /// catches is the one that reads as "every comment is here twice".
    func testRefreshingACommentListDoesNotDuplicateIt() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        try openTheMostCommentedPost(app)

        let rows = app.staticTexts.matching(identifier: "comment.row")
        XCTAssertTrue(waitForExistence(of: rows.firstMatch, in: app, timeout: 40))

        // Page once, then come back up and pull to refresh, so the refresh has
        // more than one page of state to get wrong.
        for _ in 0..<4 { app.swipeUp() }
        for _ in 0..<8 { app.swipeDown() }

        let before = labels(of: rows)
        app.swipeDown()   // the pull-to-refresh
        Thread.sleep(forTimeInterval: 3)

        let after = labels(of: rows)
        XCTAssertEqual(Set(after).count, after.count,
                       "the refresh left duplicates on screen: \(after.count) rows, \(Set(after).count) distinct")
        XCTAssertFalse(after.isEmpty, "the refresh emptied the list")
        XCTAssertFalse(app.staticTexts["detail.noComments"].exists,
                       "a list with 120 comments reported itself empty after a refresh")
        XCTAssertFalse(app.staticTexts["detail.commentsError"].exists,
                       "the refresh failed: \(app.staticTexts["detail.commentsError"].label)")
        XCTAssertFalse(before.isEmpty)
    }

    private func labels(of query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.filter { $0.exists }.map { $0.label }
    }
}
