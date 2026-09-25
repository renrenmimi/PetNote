import XCTest

/// The composer's draft, through the screens: type a caption and a tag, leave,
/// come back, and the draft is offered; restored, it is what was typed; typing
/// before choosing leaves it alone; after it is discarded — or posted — it is
/// not offered again.
///
/// The draft lives on the phone (`UserDefaultsComposeDraftStore`, one per
/// account), so the screen is the only place to see it; what the server is
/// asked is whether the post a restored draft became carries the draft's
/// words. The banner's sentence is the web client's own
/// (src/pages/Create.tsx), because a draft holds text, tags and the pet and
/// not the photos picked for it.
///
/// Each test has a new account, so there is no draft from an earlier run to
/// find. The pet is a fixture — the composer only needs one to exist — and
/// the posting test's upload goes to the stand-in (see `JourneyUITests`).
final class ComposeDraftUITests: XCTestCase {
    private static let standIn = "http://127.0.0.1:8766"
    private static let draftBanner =
        "You have an unsaved draft (text, tags and pet — photos need picking again)"

    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "draft-\(run)@petnote.test" }
    private var petID: String { "ui-\(run)-draft" }
    private var petName: String { "Draft \(run)" }
    private var caption: String { "TEST CONTENT draft \(run)" }
    private var tag: String { "draft\(run)" }
    private var uid: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid {
            for name in (try? JourneyAdmin.postDocumentNames(byAuthor: uid)) ?? [] {
                EmulatorAdmin.deleteComment(documentName: name)
            }
            JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)")
            JourneyAdmin.removeProfile(uid: uid)
        }
        JourneyAdmin.deleteDocument(path: "pets/\(petID)")
        // onPostWritten counts the tag into hashtags/{tag} and takes it out
        // again when the post goes. Removed here as well, in case the post was
        // deleted before that trigger got to it.
        JourneyAdmin.deleteDocument(path: "hashtags/\(tag)")
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testADraftComesBackAfterLeavingTheComposerAndIsGoneOnceDiscarded() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        try givenAPet(ownedBy: me)

        openComposer(app)
        XCTAssertFalse(app.buttons["compose.draft.restore"].exists, "a new account was offered a draft")
        typeTagAndCaption(app)
        closeComposer(app)

        // Offered, not applied: the fields are empty until Restore.
        openComposer(app)
        XCTAssertTrue(waitForExistence(of: app.buttons["compose.draft.restore"], in: app, timeout: 10),
                      "leaving the composer lost the draft\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts[Self.draftBanner].exists,
                      "the banner does not say what a draft keeps\n\(app.debugDescription)")
        XCTAssertEqual(captionText(app), "", "the draft was applied before Restore was pressed")
        XCTAssertFalse(app.buttons["Remove tag \(tag)"].exists, "the tag was applied before Restore was pressed")
        app.buttons["compose.draft.restore"].tap()
        XCTAssertTrue(waitUntilValue(of: app.textViews["compose.caption"], equals: caption),
                      "Restore did not bring the caption back: \(captionText(app))")
        XCTAssertTrue(app.buttons["Remove tag \(tag)"].exists, "Restore did not bring the tag back")
        XCTAssertFalse(app.buttons["compose.draft.restore"].exists, "the banner stayed after restoring")
        closeComposer(app)

        // Restoring does not use the draft up — it is kept until it is posted
        // or thrown away, as on the web — so it is offered again.
        openComposer(app)
        let discard = app.buttons["compose.draft.discard"]
        XCTAssertTrue(waitForExistence(of: discard, in: app, timeout: 10), "a restored draft was not kept")
        discard.tap()
        XCTAssertTrue(waitForDisappearance(of: discard, timeout: 10), "the banner stayed after discarding")
        XCTAssertEqual(captionText(app), "", "discarding applied the draft")
        closeComposer(app)

        openComposer(app)
        XCTAssertFalse(app.buttons["compose.draft.restore"].exists, "a discarded draft came back")
        XCTAssertEqual(captionText(app), "")
        closeComposer(app)
    }

    /// Typing before choosing Restore or Discard leaves the offered draft as it
    /// was, as on the web (src/pages/Create.tsx:283 holds its autosave while
    /// the banner is up). Without that wait in `persistDraft`, the first
    /// letter typed replaces the draft — and for an interrupted post, the
    /// operation id and upload records in it.
    func testTypingBeforeChoosingLeavesTheOfferedDraftAsItWas() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        try givenAPet(ownedBy: me)

        openComposer(app)
        typeTagAndCaption(app)
        closeComposer(app)

        // Offered; typed over without choosing; left.
        openComposer(app)
        XCTAssertTrue(waitForExistence(of: app.buttons["compose.draft.restore"], in: app, timeout: 10),
                      "leaving the composer lost the draft")
        let field = app.textViews["compose.caption"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "no caption field")
        field.tap()
        field.typeText("something else \(run)")
        closeComposer(app)

        // Still the draft that was offered.
        openComposer(app)
        let restore = app.buttons["compose.draft.restore"]
        XCTAssertTrue(waitForExistence(of: restore, in: app, timeout: 10), "the draft on offer was lost")
        restore.tap()
        XCTAssertTrue(waitUntilValue(of: app.textViews["compose.caption"], equals: caption),
                      "typing before choosing replaced the offered draft: \(captionText(app))")
        XCTAssertTrue(app.buttons["Remove tag \(tag)"].exists, "the offered draft's tag is gone")
        closeComposer(app)

        // Leave nothing on the phone.
        openComposer(app)
        let discard = app.buttons["compose.draft.discard"]
        XCTAssertTrue(waitForExistence(of: discard, in: app, timeout: 10), "the restored draft was not kept")
        discard.tap()
        XCTAssertTrue(waitForDisappearance(of: discard, timeout: 10), "the banner stayed after discarding")
        closeComposer(app)
    }

    func testARestoredDraftIsWhatGetsPostedAndIsNotOfferedAgain() throws {
        XCTAssertTrue(
            JourneyAdmin.isReachable("\(Self.standIn)/health"),
            "The upload stand-in is not running on 8766. Start it with "
                + "`python3 scripts/upload-standin.py` — this test does not skip without it."
        )
        let (app, me) = try signInAsNewAccount(email, extraArguments: ["-petnote-upload-standin", Self.standIn])
        uid = me
        try givenAPet(ownedBy: me)

        openComposer(app)
        typeTagAndCaption(app)
        closeComposer(app)
        openComposer(app)
        let restore = app.buttons["compose.draft.restore"]
        XCTAssertTrue(waitForExistence(of: restore, in: app, timeout: 10), "leaving the composer lost the draft")
        restore.tap()
        XCTAssertTrue(waitUntilValue(of: app.textViews["compose.caption"], equals: caption),
                      "Restore did not bring the caption back")

        // Photos are not part of a draft, and the banner said so: picked again.
        let add = app.buttons["compose.addMedia"]
        XCTAssertTrue(waitUntilHittable(add, in: app, timeout: 20), "no way to add a photo")
        add.tap()
        try pickFirstPhoto(app)
        XCTAssertTrue(
            waitForExistence(
                of: app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1/'")).firstMatch,
                in: app, timeout: 30
            ),
            "the picked photo never reached the composer"
        )
        let share = app.buttons["compose.share"]
        XCTAssertTrue(waitForEnabled(share, timeout: 20), "Share never became available")
        share.tap()
        XCTAssertTrue(waitForDisappearance(of: share, timeout: 90), "the composer did not close after sharing")

        // The server: one post, carrying what the draft held.
        var posts: [String] = []
        let published = try serverEventually {
            posts = try JourneyAdmin.postDocumentNames(byAuthor: me)
            return !posts.isEmpty
        }
        XCTAssertTrue(published, "nothing was published")
        XCTAssertEqual(posts.count, 1, "expected one post, found \(posts.count)")
        let post = try XCTUnwrap(try JourneyAdmin.fields(documentName: XCTUnwrap(posts.first)))
        XCTAssertEqual(JourneyAdmin.string(post["text"]), caption, "the post does not carry the draft's caption")
        XCTAssertEqual(ServerFixtures.strings(post, "tags"), [tag], "the post does not carry the draft's tag")
        XCTAssertEqual(JourneyAdmin.string(post["petId"]), petID)

        // And the draft that became it is not offered again.
        openComposer(app)
        XCTAssertFalse(app.buttons["compose.draft.restore"].exists, "a draft that was posted was offered again")
        XCTAssertEqual(captionText(app), "", "the composer opened with the posted caption in it")
        closeComposer(app)
    }

    // MARK: - Steps

    /// A pet for the composer to post about. With none it shows "add a pet
    /// first" instead of the caption and tags.
    private func givenAPet(ownedBy uid: String) throws {
        try ServerFixtures.write("pets/\(petID)", [
            "name": petName, "nameLower": petName.lowercased(), "species": "dog", "gender": "unknown",
            "breed": "", "bio": "", "avatarUrl": "", "ownerId": uid, "primaryOwnerId": uid,
            "followerCount": 0, "postCount": 0, "createdAt": Date(),
        ])
        try ServerFixtures.write("pets/\(petID)/family/\(uid)", [
            "userId": uid, "relationship": "mom", "role": "primary", "joinedAt": Date(),
        ])
    }

    /// The Post tab. The composer reads the stored draft before it reads the
    /// pets, so once the pet is on screen it has decided whether to offer one.
    private func openComposer(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Create"]
        XCTAssertTrue(waitUntilHittable(tab, in: app, timeout: 20), "no Post tab")
        tab.tap()
        XCTAssertTrue(waitForExistence(of: app.buttons["compose.pet.\(petID)"], in: app, timeout: 30),
                      "the composer did not open with the pet\n\(app.debugDescription)")
    }

    private func closeComposer(_ app: XCUIApplication) {
        let cancel = app.buttons["compose.cancel"]
        XCTAssertTrue(waitUntilHittable(cancel, in: app, timeout: 10), "no Cancel on the composer")
        cancel.tap()
        XCTAssertTrue(waitForDisappearance(of: cancel, timeout: 15), "the composer did not close")
    }

    /// The tag first: its field is low on the page, where the keyboard the
    /// caption raises would cover it. Return commits a tag.
    private func typeTagAndCaption(_ app: XCUIApplication) {
        let tags = app.textFields["compose.tagInput"]
        XCTAssertTrue(waitUntilHittable(tags, in: app, timeout: 20), "no tag field")
        tags.tap()
        tags.typeText(tag + "\n")
        XCTAssertTrue(waitForExistence(of: app.buttons["Remove tag \(tag)"], in: app, timeout: 10),
                      "the tag was not taken\n\(app.debugDescription)")

        let field = app.textViews["compose.caption"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "no caption field")
        field.tap()
        field.typeText(caption)
        XCTAssertEqual(field.value as? String, caption, "the caption field does not hold what was typed")
    }

    private func captionText(_ app: XCUIApplication) -> String {
        (app.textViews["compose.caption"].value as? String) ?? ""
    }
}
