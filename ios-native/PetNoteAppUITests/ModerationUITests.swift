import XCTest

/// Blocking and Contact us, through the screens, read back from the emulator.
///
/// Block: from a post's menu, as on the web (the only place it is offered).
/// Afterwards the feed has none of that person's posts, the block is listed
/// under Blocked people, and unblocking brings the posts back — the pages
/// agree with each other and with users/{me}/blockedUsers.
///
/// Contact us: the entry, the form, its limits and the confirmation. What it
/// sends goes to the local emulator and nowhere else.
final class ModerationUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "mod-\(run)@petnote.test" }
    private var uid: String?
    private var blocked: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid {
            if let blocked { JourneyAdmin.deleteDocument(path: "users/\(uid)/blockedUsers/\(blocked)") }
            for name in (try? JourneyAdmin.documentNames(in: "feedback", field: "userId", equals: uid)) ?? [] {
                EmulatorAdmin.deleteComment(documentName: name)
            }
            JourneyAdmin.removeProfile(uid: uid)
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testBlockingAnAuthorHidesTheirPostsUntilTheyAreUnblocked() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me

        // The first post's author is the one blocked.
        openFirstPost(app)
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch.label
        let names = try JourneyAdmin.postDocumentNames(withText: text)
        let post = try XCTUnwrap(try JourneyAdmin.fields(documentName: XCTUnwrap(names.first)))
        let author = try XCTUnwrap(JourneyAdmin.string(post["authorId"]))
        blocked = author

        app.buttons["post.actions"].tap()
        let block = app.buttons["post.actions.block"]
        XCTAssertTrue(waitUntilHittable(block, in: app, timeout: 10), "someone else's post offers no Block")
        block.tap()
        let confirm = app.sheets.buttons["Block"].exists
            ? app.sheets.buttons["Block"]
            : app.buttons.matching(NSPredicate(format: "label == 'Block'")).firstMatch
        XCTAssertTrue(waitUntilHittable(confirm, in: app, timeout: 10), "no block confirmation")
        confirm.tap()

        // Off the blocked person's post, onto a feed without them.
        XCTAssertTrue(reachedFeed(app), "blocking did not return to the feed")
        XCTAssertNotNil(try JourneyAdmin.fields(path: "users/\(me)/blockedUsers/\(author)"), "the block was not written")
        XCTAssertFalse(feedShows(app, text), "the blocked author's post is still in the feed")
        // And not an empty feed: the other author's posts are still there.
        for _ in 0..<8 { app.swipeDown() }
        let first = app.staticTexts.matching(identifier: "post.text").firstMatch
        XCTAssertTrue(waitForExistence(of: first, in: app, timeout: 30), "the feed is empty after blocking one person")
        let firstAuthor = try JourneyAdmin.postDocumentNames(withText: first.label).first
            .flatMap { try JourneyAdmin.fields(documentName: $0) }
            .flatMap { JourneyAdmin.string($0["authorId"]) }
        XCTAssertNotNil(firstAuthor, "could not read the first post's author")
        XCTAssertNotEqual(firstAuthor, author, "the feed still leads with the blocked person")

        // Listed, and undone from the list.
        app.tabBars.buttons["Profile"].tap()
        let list = app.buttons["profile.blocked"]
        for _ in 0..<4 where !(list.exists && list.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(list, in: app, timeout: 20), "no Blocked people on the profile")
        list.tap()
        let unblock = app.buttons["blocked.unblock.\(author)"]
        XCTAssertTrue(waitUntilHittable(unblock, in: app, timeout: 20), "the blocked person is not listed\n\(app.debugDescription)")
        unblock.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["blocked.empty"], in: app, timeout: 20), "the list did not empty")
        var stillBlocked = true
        for _ in 0..<20 {
            stillBlocked = try JourneyAdmin.fields(path: "users/\(me)/blockedUsers/\(author)") != nil
            if !stillBlocked { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(stillBlocked, "the unblock was not written")
        blocked = nil

        popToTabRoot(app, then: "Home")
        XCTAssertTrue(feedShows(app, text), "the post did not come back after unblocking")
    }

    func testContactUsOffersTheFormAndConfirmsWhatWasSent() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        app.tabBars.buttons["Profile"].tap()
        let entry = app.buttons["profile.contact"]
        for _ in 0..<4 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(entry, in: app, timeout: 20), "no Contact us on the profile")
        entry.tap()

        // The four kinds of the web page, Bug Report chosen to begin with.
        for kind in ["bug", "feature", "complaint", "other"] {
            XCTAssertTrue(waitForExistence(of: app.buttons["contact.type.\(kind)"], in: app, timeout: 10), "no \(kind)")
        }
        // Send is the form's last row, below the fold on a phone, and a Form
        // only builds the rows on screen — so it is scrolled to each time,
        // the way a person would reach it.
        let send = app.buttons["contact.send"]
        reveal(send, in: app)
        XCTAssertFalse(send.isEnabled, "Send is available with nothing written")
        let subject = app.textFields["contact.subject"]
        reveal(subject, in: app, downwards: false)
        app.buttons["contact.type.feature"].tap()
        subject.tap()
        subject.typeText("TEST CONTENT \(run)")
        reveal(send, in: app)
        XCTAssertFalse(send.isEnabled, "Send is available without a message")
        let message = app.textFields["contact.message"]
        reveal(message, in: app, downwards: false)
        message.tap()
        message.typeText("TEST CONTENT sent to the emulator only")
        reveal(send, in: app)
        XCTAssertTrue(waitForEnabled(send, timeout: 10), "Send never became available")
        send.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["contact.sent"], in: app, timeout: 30),
                      "no confirmation\n\(app.debugDescription)")
        let sent = try JourneyAdmin.documentNames(in: "feedback", field: "userId", equals: me)
        XCTAssertEqual(sent.count, 1, "expected one feedback document in the emulator")
        let doc = try XCTUnwrap(try JourneyAdmin.fields(documentName: XCTUnwrap(sent.first)))
        XCTAssertEqual(JourneyAdmin.string(doc["type"]), "feature")
        XCTAssertEqual(JourneyAdmin.string(doc["subject"]), "TEST CONTENT \(run)")
    }

    /// Scrolls until the element is on screen, or gives up after a few tries
    /// and leaves the assertion that follows to say what is missing.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, downwards: Bool = true) {
        for _ in 0..<5 where !(element.exists && element.isHittable) {
            if downwards { app.swipeUp() } else { app.swipeDown() }
        }
    }

    /// Whether a post with this exact text is anywhere in the first screens of
    /// the feed, after a refresh.
    private func feedShows(_ app: XCUIApplication, _ text: String) -> Bool {
        pullToRefreshFeed(app)
        let target = app.staticTexts.matching(identifier: "post.text")
            .matching(NSPredicate(format: "label == %@", text)).firstMatch
        for _ in 0..<6 {
            if target.exists { return true }
            app.swipeUp()
        }
        return target.exists
    }
}
