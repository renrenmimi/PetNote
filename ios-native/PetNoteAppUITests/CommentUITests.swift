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
    /// more than one page of them, and asking the server which post that is
    /// beats assuming a position in the feed.
    ///
    /// The id is checked against this process's pinned manifest. Each seed run
    /// writes into its own namespace now, and "the post with the most
    /// comments" is a query over everything in the emulator: a document left
    /// behind by an abandoned run, or one another agent added, would answer it
    /// just as well and the test would then be describing data nobody meant.
    @discardableResult
    private func openTheMostCommentedPost(_ app: XCUIApplication) throws -> String {
        let post = try EmulatorAdmin.postWithMostComments()
        let manifest = try EmulatorAdmin.seedManifest()
        XCTAssertTrue(
            post.id.hasPrefix(manifest.postIdPrefix),
            """
            the most-commented post in the emulator is \(post.id), which is not \
            from this run (\(manifest.runId)). Testing against it would be testing \
            against data no seed run claims.
            """
        )
        openPost(app, withText: post.text)
        return post.id
    }

    /// How many comments the server holds for a post. A collection count, read
    /// straight from Firestore: the screen can only say what the app drew, and
    /// "the list paged" means nothing unless there was more than one page of
    /// comments to page through.
    private func serverCommentCount(postID: String) -> Int? {
        let url = URL(
            string: "http://127.0.0.1:8088/v1/projects/petnote-test/databases/(default)"
                + "/documents/posts/\(postID)/comments?pageSize=300"
        )!
        var request = URLRequest(url: url)
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        var count: Int?
        let answered = expectation(description: "comment count for \(postID)")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                count = (object["documents"] as? [Any])?.count ?? 0
            }
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 25)
        return count
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

    /// All three have to agree: the list on screen, the count the feed draws
    /// on the card, and the documents in the emulator.
    ///
    /// The count is the one that used to be taken on trust. `commentCount` is
    /// moved by a trigger, not by this write and not by the seed — a post with
    /// no comments has no such field at all — so "the row appeared" says
    /// nothing about whether the number a reader sees followed it.
    func testVerifiedAccountCommentIsWrittenToTheServer() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let postID = try XCTUnwrap(firstPostID(in: app), "could not tell which post the first row is")
        let countBefore = shownCommentCount(app)
        let backendBefore = serverPostCommentCount(postID: postID) ?? 0
        print("MEASURED target=\(postID) shown=\(String(describing: countBefore)) backend=\(backendBefore)")
        XCTAssertEqual(countBefore, backendBefore,
                       "the card's count and the aggregate disagree before anything was written")
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

        // The aggregate, once the trigger has had its turn. Polled, not slept
        // on: it is a separate write by a separate process.
        var backendAfter = backendBefore
        let settled = Date().addingTimeInterval(20)
        while Date() < settled {
            backendAfter = serverPostCommentCount(postID: postID) ?? backendBefore
            if backendAfter >= backendBefore + 1 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThanOrEqual(
            backendAfter, backendBefore + 1,
            "the comment is in the database but commentCount never moved: \(backendBefore) → \(backendAfter)"
        )

        // And the number a reader actually sees, back on the feed.
        //
        // After a refresh, not before one: the feed reads its posts when it
        // loads, and popping a screen off the stack is not a read. A card
        // still showing the count from a minute ago is the design working.
        popToFeed(app)
        pullToRefreshFeed(app)
        var shown: Int?
        let agree = Date().addingTimeInterval(20)
        while Date() < agree {
            shown = shownCommentCount(app)
            if shown == serverPostCommentCount(postID: postID) { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if shown != serverPostCommentCount(postID: postID) {
            // "The refresh did not read" and "the client will not adopt the
            // server's count" look identical from here, and have different
            // owners. A cold start separates them.
            app.terminate()
            let cold = launchOnSignIn()
            signIn(cold, email: "accept-a@example.com")
            waitForQuietUI(cold)
            let afterRelaunch = shownCommentCount(cold)
            XCTFail(
                "after a refresh the card says \(shown.map(String.init) ?? "nothing") comments; "
                    + "after a cold start \(afterRelaunch.map(String.init) ?? "nothing"); "
                    + "the aggregate says "
                    + "\(serverPostCommentCount(postID: postID).map(String.init) ?? "nothing")"
            )
        }
    }

    /// The number the first card's comments button is announcing.
    private func shownCommentCount(_ app: XCUIApplication) -> Int? {
        let button = app.buttons.matching(identifier: "post.comments").firstMatch
        guard waitForExistence(of: button, in: app, timeout: 30),
              let value = button.value as? String else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    /// `commentCount` on the post document, or 0 when the field is not there.
    ///
    /// Absent is the normal state for a post nobody has commented on: no
    /// script writes these aggregates any more, the trigger creates them, and
    /// a test that treats absence as an error reports the seed as broken.
    private func serverPostCommentCount(postID: String) -> Int? {
        let url = URL(
            string: "http://127.0.0.1:8088/v1/projects/petnote-test/databases/(default)"
                + "/documents/posts/\(postID)"
        )!
        var request = URLRequest(url: url)
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        var count: Int?
        let answered = expectation(description: "commentCount for \(postID)")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { answered.fulfill() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fields = object["fields"] as? [String: Any] else { return }
            guard let field = fields["commentCount"] as? [String: Any],
                  let raw = field["integerValue"] as? String, let value = Int(raw) else {
                count = 0
                return
            }
            count = value
        }.resume()
        wait(for: [answered], timeout: 25)
        return count
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

    /// Written, then deleted by its author through the screen: gone from the
    /// list, from the server, and from the count on both the detail screen
    /// and the feed. And the control is offered only where the rule allows —
    /// the comment's author and the post's author (`deleteCommentCallable`).
    func testDeletingYourOwnCommentRemovesItFromTheListTheServerAndTheCount() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let postID = try XCTUnwrap(firstPostID(in: app), "could not tell which post the first row is")
        let backendBefore = serverPostCommentCount(postID: postID) ?? 0
        openFirstPost(app)

        let text = uniqueText("delete")
        type(text, into: app)
        app.buttons["composer.send"].tap()
        let row = app.staticTexts.matching(identifier: "comment.row")
            .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 40), "the comment never appeared")
        assertServerCommentCount(text, equals: 1)
        let name = try XCTUnwrap(try EmulatorAdmin.commentDocumentIDs(withExactText: text).first)
        let commentID = try XCTUnwrap(name.split(separator: "/").last.map(String.init))

        // Who is offered it. If the post is someone else's, this comment is
        // the only one on screen with a delete; if it is ours, every one is.
        let me = try XCTUnwrap(stringField("authorId", in: try EmulatorAdmin.get(
            "\(EmulatorAdmin.firestore)/v1/\(name)", owner: true)))
        let postAuthor = stringField("authorId", in: try EmulatorAdmin.get(
            "\(EmulatorAdmin.firestore)/v1/projects/\(EmulatorAdmin.projectID)/databases/(default)/documents/posts/\(postID)",
            owner: true))
        let rows = app.staticTexts.matching(identifier: "comment.row").count
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'comment.delete.'")).count
        if postAuthor == me {
            XCTAssertEqual(deletes, rows, "the post's author is not offered every comment on it")
        } else {
            XCTAssertEqual(deletes, 1, "\(deletes) delete controls on someone else's post; only our comment may have one")
        }

        let delete = app.buttons["comment.delete.\(commentID)"]
        // The keyboard stays up after a send and the new comment is below it
        // (y 880 on an 874pt screen, measured). A swipe on the list scrolls it
        // up and, by `scrollDismissesKeyboard`, puts the keyboard away.
        for _ in 0..<4 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(delete, in: app, timeout: 20),
                      "no delete on our own comment (\(deletes) of \(rows) rows offer one)\n\(app.debugDescription)")
        delete.tap()
        let confirm = app.sheets.buttons["Delete"].exists
            ? app.sheets.buttons["Delete"]
            : app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch
        XCTAssertTrue(waitUntilHittable(confirm, in: app, timeout: 10), "no delete confirmation")
        confirm.tap()

        XCTAssertTrue(waitForDisappearance(of: row, timeout: 30), "the comment is still in the list")
        XCTAssertFalse(app.staticTexts["detail.commentDeleteError"].exists,
                       "a delete that worked reported a failure")
        assertServerCommentCount(text, equals: 0)

        // The aggregate comes down by the trigger; the screens follow it.
        var backendAfter = backendBefore + 1
        let settled = Date().addingTimeInterval(20)
        while Date() < settled {
            backendAfter = serverPostCommentCount(postID: postID) ?? backendAfter
            if backendAfter == backendBefore { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(backendAfter, backendBefore, "commentCount did not come back down")
        XCTAssertEqual(shownCommentCount(app), backendBefore, "the detail screen's count did not come down")

        popToFeed(app)
        pullToRefreshFeed(app)
        var shown: Int?
        let agree = Date().addingTimeInterval(20)
        while Date() < agree {
            shown = shownCommentCount(app)
            if shown == backendBefore { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(shown, backendBefore, "the feed still counts the deleted comment")
    }

    private func stringField(_ field: String, in document: [String: Any]) -> String? {
        ((document["fields"] as? [String: Any])?[field] as? [String: Any])?["stringValue"] as? String
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

    /// The other half of 5C.10: an unknown outcome that did **not** land.
    ///
    /// This is the branch where resending is most tempting and looks most
    /// harmless — nothing was written, so a resend would produce exactly one
    /// comment and nobody would ever know. `createCommentCallable` has no
    /// idempotency key, so the app cannot tell this case from the one above
    /// without looking, and "look, then tell the person" is the only policy
    /// that is safe in both. What is asserted here is that policy, from the
    /// outside: the words never claim a plain failure, the text is still in
    /// the box to send by hand, and the server holds nothing — which is what
    /// proves no request went out on the app's own initiative.
    func testAnUnknownOutcomeThatDidNotLandKeepsTheTextAndNeverResends() {
        let app = launchOnSignIn(extraArguments: ["-petnote-comment-lose-request"])
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let text = uniqueText("unknown-not-landed")
        type(text, into: app)
        app.buttons["composer.send"].tap()

        let error = app.staticTexts["composer.error"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 40), "nothing was reported")

        var seen: [String] = []
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if error.exists {
                let label = error.label
                if seen.last != label { seen.append(label) }
                if label.contains("not in the list") { break }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertTrue(
            seen.last?.contains("not in the list") == true,
            "the app never settled the unknown outcome. messages: \(seen)"
        )
        for message in seen {
            XCTAssertFalse(
                message.contains("was posted"),
                "claimed a comment was posted that was never written: \(message)"
            )
        }

        // 不丢输入: the text is still there, and the person is the one who
        // decides whether it goes again.
        XCTAssertEqual(
            app.textFields["composer.field"].value as? String, text,
            "the text was thrown away, so the only way to recover it is to type it again"
        )
        XCTAssertTrue(
            waitUntilHittable(app.buttons["composer.retry"], in: app, timeout: 10),
            "no way offered to send it by hand"
        )
        XCTAssertEqual(commentRows(in: app, containing: text).count, 0,
                       "the optimistic row was left behind for a comment that does not exist")

        // The load-bearing assertion. A settle window long enough for an
        // automatic resend — had there been one — to have landed.
        assertServerCommentCount(text, equals: 0, settleFor: 10)
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

    /// A page size of 30 against the post the seed gives the most comments —
    /// 60 in the current run, and read from the server rather than written
    /// down here, because the number is the seed's to choose. Paging must
    /// bring in comments that were not there before, and must not move what is
    /// already on screen.
    func testPagingALongCommentListDoesNotMoveWhatIsAlreadyThere() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        let postID = try openTheMostCommentedPost(app)

        // The premise, established rather than assumed: paging can only be
        // demonstrated against a post that really has more than one page.
        let held = try XCTUnwrap(serverCommentCount(postID: postID),
                                 "could not read \(postID)'s comments from the emulator")
        print("MEASURED paging target=\(postID) serverComments=\(held)")
        XCTAssertGreaterThan(
            held, 30,
            "\(postID) holds \(held) comments, which is one page or less — this run proves nothing"
        )

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
        // A held pull, not a flick. `swipeDown()` does not trigger
        // `.refreshable` — measured: ten in a row produced no reread. Every
        // assertion below was therefore being made about a screen that had
        // never refreshed, which is the shape of a test that cannot fail.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
        waitForQuietUI(app, quietFor: 1, timeout: 20)

        let after = labels(of: rows)
        XCTAssertEqual(Set(after).count, after.count,
                       "the refresh left duplicates on screen: \(after.count) rows, \(Set(after).count) distinct")
        XCTAssertFalse(after.isEmpty, "the refresh emptied the list")
        XCTAssertFalse(app.staticTexts["detail.noComments"].exists,
                       "a list with comments in it reported itself empty after a refresh")
        XCTAssertFalse(app.staticTexts["detail.commentsError"].exists,
                       "the refresh failed: \(app.staticTexts["detail.commentsError"].label)")
        XCTAssertFalse(before.isEmpty)
    }


    // MARK: - What the composer does after a send

    /// Sending a comment must not take the keyboard away.
    ///
    /// **Written to catch a defect that turned out not to be there, and kept
    /// because the question is worth a standing answer.** The composer field
    /// carries `.disabled(model.isSending)`, and a disabled text field
    /// resigns first responder — which says every send should drop the
    /// keyboard and never bring it back. Measured against the local
    /// emulator, it does not: eight consecutive reads after the comment
    /// landed all said "up". The modifier was going to be removed on the
    /// strength of the reasoning; it stays, because the reasoning was not
    /// what happened.
    ///
    /// What this does **not** establish is the slow case. A local send
    /// finishes well inside the time a disabled state would need to be
    /// noticed; a send over a real network does not, and no simulator run
    /// can say what happens then.
    ///
    /// Read several times rather than once: "the keyboard is gone" and "the
    /// keyboard has not finished coming back" look the same in a single read.
    func testSendingACommentDoesNotTakeTheKeyboardAway() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        openFirstPost(app)

        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 30),
                      "the comment field never became usable")
        field.tap()

        let keyboard = app.keyboards.firstMatch
        try XCTSkipUnless(
            keyboard.waitForExistence(timeout: 8),
            """
            No software keyboard on this simulator, so there is nothing to \
            observe. Disconnect the hardware keyboard for this device and run \
            again.
            """
        )

        let text = uniqueText("keyboard-after-send")
        field.typeText(text)
        app.buttons["composer.send"].tap()

        XCTAssertTrue(
            waitForExistence(
                of: app.staticTexts.matching(identifier: "comment.row")
                    .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch,
                in: app, timeout: 40
            ),
            "the comment never appeared, so this says nothing about the keyboard"
        )

        var readings: [Bool] = []
        for _ in 0..<8 {
            readings.append(keyboard.exists)
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("MEASURED keyboard after send: \(readings.map { $0 ? "up" : "down" })")
        XCTAssertTrue(
            readings.allSatisfy { $0 },
            """
            The keyboard went away when the comment was sent and did not come \
            back: \(readings.map { $0 ? "up" : "down" }). Nothing asked it to; \
            disabling the field the person is typing in resigns first responder.
            """
        )
        XCTAssertTrue(field.exists, "the composer is gone after a send")
    }


    /// The comment button on the detail screen has to do something.
    ///
    /// In the feed it opens the post. On the detail screen the post is
    /// already open, and the card was handed an empty closure — so the
    /// control drew a count, reported itself as an enabled button, took the
    /// tap, and did nothing with it. Measured before the fix:
    /// `MEASURED keyboard after tapping post.comments on detail:
    /// ["down" x19]`.
    ///
    /// **Two attempts to make it focus the composer were measured not to
    /// work** — assigned inline, and deferred one turn of the main actor,
    /// each left the keyboard down across nineteen and twenty reads. So the
    /// action is one whose result is visible instead: the list scrolls to
    /// the comments. That is also what a count next to a post is an
    /// invitation to look at.
    ///
    /// Asserted as a movement rather than as a final position. "The comments
    /// are on screen" would pass on a short post where they never left it;
    /// "they came a long way up" only passes if the tap did something.
    func testTheCommentButtonOnTheDetailScreenScrollsToTheComments() throws {
        let app = launchOnSignIn()
        signIn(app, email: "accept-a@example.com")
        // The post with the most comments, so there is certainly more list
        // than screen and the comments are certainly below the fold.
        try openTheMostCommentedPost(app)

        let rows = app.staticTexts.matching(identifier: "comment.row")
        XCTAssertTrue(waitForExistence(of: rows.firstMatch, in: app, timeout: 40),
                      "the comments never loaded")

        // Back to the top of the post, by flicks: a press-and-drag downward
        // here is pull-to-refresh's gesture, and `app.swipeDown()` is a flick,
        // which `.refreshable` does not answer.
        for _ in 0..<6 { app.swipeDown() }
        waitForQuietUI(app, quietFor: 1, timeout: 15)

        let window = app.windows.firstMatch.frame
        XCTAssertTrue(app.navigationBars["Post"].exists, "not on the detail screen")

        // Read in the pass that selects, kept as a value.
        let before = rows.firstMatch.exists ? rows.firstMatch.frame.minY : .infinity
        print(String(format: "MEASURED first comment row before tap: minY=%.1f window=%.1f",
                     before, window.maxY))

        var commentButton: XCUIElement?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, commentButton == nil {
            dismissSavePasswordSheetIfPresent(app)
            commentButton = app.buttons.matching(identifier: "post.comments")
                .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            if commentButton == nil { Thread.sleep(forTimeInterval: 0.25) }
        }
        let comments = try XCTUnwrap(commentButton, "the detail screen has no comment control")
        comments.tap()

        // Several reads, and the sequence is printed: one read cannot tell
        // "nothing happened" from "it has not happened yet".
        var readings: [CGFloat] = []
        let settle = Date().addingTimeInterval(6)
        while Date() < settle {
            readings.append(rows.firstMatch.exists ? rows.firstMatch.frame.minY : .infinity)
            if let last = readings.last, last < window.maxY * 0.5 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("MEASURED first comment row after tap: "
              + readings.map { String(format: "%.1f", $0) }.joined(separator: " | "))

        let after = try XCTUnwrap(readings.last, "nothing was read after the tap")
        XCTAssertLessThan(
            after, window.maxY * 0.5,
            """
            Tapping the comment count did not bring the comments up: the first \
            row sat at \(before) before and \(after) after, on a \(window.maxY)pt \
            window. The control took the tap and did nothing with it.
            """
        )
        XCTAssertLessThan(after, before, "the list did not move at all")
    }


    // MARK: - 5C.11's other half: what a lost comment page does to the ones already read
    //
    // `PostDetailView.commentsSection` carried a note saying this could not be
    // driven from a test — the fault injection in `FirestoreCommentRepository`
    // covered `create` only, so there was no way to make page two fail while
    // page one was up, and the branch in the view was the only evidence
    // available. `ReadFault` is the part that note was missing, and these are
    // the runs it makes possible. Every fault is one-shot and behind
    // `#if DEBUG`.

    /// A held pull that returns as soon as the drag is over.
    ///
    /// The shared `pullToRefreshFeed` settles afterwards, which is the window
    /// a stalled refresh has to be looked at inside. The gesture is the same
    /// one, and for the same reason: `swipeDown()` is a flick and does not
    /// trigger `.refreshable`.
    private func startPullToRefresh(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !element.exists
    }

    /// Losing page two must not take page one off the screen, and the retry
    /// offered for it must actually fetch something.
    ///
    /// The retry is the half that was broken. `loadComments` inserted the
    /// cursor into `requestedCursors` before the request and never took it out
    /// when the request failed, so `retryComments` walked straight into its
    /// own spent-cursor guard and returned having done nothing — leaving the
    /// screen on `.loading`, which draws a spinner under the comments that
    /// never resolves. From outside, a button that reports nothing when
    /// pressed. The assertion that catches it is "new comments appeared",
    /// not "the error went away": the error goes away either way.
    func testALostCommentPageKeepsTheCommentsAlreadyReadAndTheRetryAddsThem() throws {
        let app = launchOnSignIn(extraArguments: [
            "-petnote-comments-tiny-pages",
            "-petnote-comments-next-page-fails-once",
        ])
        signIn(app, email: "accept-a@example.com")
        try openTheMostCommentedPost(app)

        let rows = app.staticTexts.matching(identifier: "comment.row")
        XCTAssertTrue(waitForExistence(of: rows.firstMatch, in: app, timeout: 40),
                      "the first page of comments never arrived")

        var reported = false
        for _ in 0..<10 {
            if app.staticTexts["detail.commentsError"].exists { reported = true; break }
            app.swipeUp()
        }
        XCTAssertTrue(reported, "the lost comment page was never reported\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["detail.commentsRetry"].exists, "the failure offers no retry")

        let kept = labels(of: rows)
        print("MEASURED comments kept through a lost page: \(kept.count)")
        XCTAssertFalse(kept.isEmpty, "the comments went with the page that was lost")
        XCTAssertFalse(app.staticTexts["detail.noComments"].exists,
                       "a list with comments in it reported itself empty")
        XCTAssertEqual(Set(kept).count, kept.count, "duplicate comments after the failure")

        app.buttons["detail.commentsRetry"].tap()

        var seen = Set(kept)
        for _ in 0..<8 {
            let sample = labels(of: rows)
            XCTAssertEqual(Set(sample).count, sample.count, "a comment was on screen twice")
            seen.formUnion(sample)
            if seen.count > kept.count { break }
            Thread.sleep(forTimeInterval: 0.5)
            app.swipeUp()
        }
        print("MEASURED comments after the retry: \(seen.count) (kept \(kept.count))")
        XCTAssertGreaterThan(
            seen.count, kept.count,
            "the retry brought nothing back — the cursor it needed was still marked spent"
        )
    }

    /// A refresh that fails must keep the comments and say so separately,
    /// rather than reporting "could not load" about comments it deleted on the
    /// way to saying it.
    func testACommentRefreshThatFailsKeepsTheCommentsOnScreen() throws {
        let app = launchOnSignIn(extraArguments: ["-petnote-comments-refresh-fails-once"])
        signIn(app, email: "accept-a@example.com")
        try openTheMostCommentedPost(app)

        let rows = app.staticTexts.matching(identifier: "comment.row")
        XCTAssertTrue(waitForExistence(of: rows.firstMatch, in: app, timeout: 40))
        let before = labels(of: rows)
        XCTAssertFalse(before.isEmpty)

        startPullToRefresh(app)
        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["detail.commentsError"], in: app, timeout: 30),
            "the refresh did not fail, so nothing below is about a failed refresh"
        )

        let after = labels(of: rows)
        print("MEASURED comments before=\(before.count) after a failed refresh=\(after.count)")
        XCTAssertFalse(after.isEmpty, "a failed refresh emptied the comment list")
        XCTAssertFalse(app.staticTexts["detail.noComments"].exists,
                       "a failed refresh made the list look empty rather than stale")
        XCTAssertTrue(app.buttons["detail.commentsRetry"].exists, "no way to try again")
    }

    /// A stalled refresh answers, and the screen follows the answer.
    ///
    /// **This used to claim more than XCUITest can see, and failed saying so
    /// in a way that read like the app's fault.** It sampled the list for 6.5s
    /// after starting the pull and asserted at least one sample found rows.
    /// Every run reported `every reading during the refresh found an empty
    /// list: []` — and that `[]` is the sample array, not the list. No sample
    /// was ever taken.
    ///
    /// The reason is structural, not a matter of timing. Every XCUITest
    /// operation — synthesized gestures *and* element queries — waits for the
    /// app to go quiescent first. The injected fault stalls the refresh for
    /// eight seconds and `.refreshable` spins for all of it, so the app is not
    /// quiescent; `startPullToRefresh` returned only once the stall was over,
    /// and a query issued from another thread would have waited on the same
    /// thing. **"The list did not go blank while the refresh was in flight" is
    /// not observable from outside the process.**
    ///
    /// So it is asserted where it can be: `PostDetailViewModelTests`'s
    /// `aCommentsRefreshInFlightStillHoldsTheCommentsItIsReplacing` reads
    /// `model.comments` while the repository call is held open, which is the
    /// same property one layer down. That is unit-level evidence and is
    /// recorded as unit-level evidence.
    ///
    /// What is left here is what the UI really can settle: the stall ends, the
    /// screen ends up agreeing with the answer that arrived, and nothing is
    /// left spinning.
    func testACommentRefreshInFlightDoesNotBlankTheList() throws {
        let app = launchOnSignIn(extraArguments: ["-petnote-comments-refresh-stalls-then-empties"])
        signIn(app, email: "accept-a@example.com")
        try openTheMostCommentedPost(app)

        let rows = app.staticTexts.matching(identifier: "comment.row")
        XCTAssertTrue(waitForExistence(of: rows.firstMatch, in: app, timeout: 40))
        XCTAssertFalse(labels(of: rows).isEmpty)

        let pulled = Date()
        startPullToRefresh(app)
        let heldFor = Date().timeIntervalSince(pulled)
        // Printed because it is the evidence for the paragraph above: the
        // gesture call itself spans the stall. If this ever comes back well
        // under the injected eight seconds, the quiescence argument no longer
        // holds and sampling from inside the window becomes worth revisiting.
        print(String(format: "MEASURED the pull gesture call returned after %.1fs", heldFor))

        XCTAssertTrue(
            waitForExistence(of: app.staticTexts["detail.noComments"], in: app, timeout: 30),
            "the stalled refresh never answered"
        )
        XCTAssertTrue(labels(of: rows).isEmpty,
                      "the answer was empty but rows from before it are still on screen")
        XCTAssertFalse(app.staticTexts["detail.commentsError"].exists,
                       "an answer arrived, so this is not an error state")
        XCTAssertTrue(app.textFields["composer.field"].isHittable,
                      "the screen is still usable after the stall")
    }

    private func labels(of query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.filter { $0.exists }.map { $0.label }
    }
}
