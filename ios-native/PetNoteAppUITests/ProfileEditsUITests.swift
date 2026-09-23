import XCTest

/// Changing a picture, editing a pet, saving a post — through the screens,
/// read back from the emulator, including what a failed upload leaves.
///
/// Uploads go to scripts/upload-standin.py, not Cloudinary (see
/// JourneyUITests): the picker, the signed request and the callable that
/// takes the URL are real; the image itself does not exist on any CDN.
final class ProfileEditsUITests: XCTestCase {
    private static let standIn = "http://127.0.0.1:8766"
    /// Nothing listens here, so every upload fails the way a dropped network
    /// does: the request never gets an answer.
    private static let deadStandIn = "http://127.0.0.1:9"

    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "edit-\(run)@petnote.test" }
    private var uid: String?
    private var petID: String?
    private var bookmarked: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid {
            if let bookmarked { JourneyAdmin.deleteDocument(path: "users/\(uid)/bookmarks/\(bookmarked)") }
            if let petID {
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)")
                JourneyAdmin.deleteDocument(path: "pets/\(petID)")
            }
            JourneyAdmin.removeProfile(uid: uid)
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testANewPictureIsUploadedAndSavedWithTheBio() throws {
        XCTAssertTrue(JourneyAdmin.isReachable("\(Self.standIn)/health"), "the upload stand-in is not running on 8766")
        let uploadsBefore = try JourneyAdmin.standInUploads().count
        let (app, me) = try signInAsNewAccount(email, extraArguments: ["-petnote-upload-standin", Self.standIn])
        uid = me
        let bio = "TEST CONTENT picture \(run)"
        try pickPictureAndTypeBio(app, bio: bio)
        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.textViews["editProfile.bio"], timeout: 40),
                      "the edit screen did not close\n\(app.debugDescription)")

        let uploads = try JourneyAdmin.standInUploads()
        XCTAssertEqual(uploads.count, uploadsBefore + 1, "expected one avatar upload")
        let upload = try XCTUnwrap(uploads.last)
        let user = try XCTUnwrap(try JourneyAdmin.fields(path: "users/\(me)"))
        XCTAssertEqual(JourneyAdmin.string(user["avatarUrl"]), upload["secureUrl"] as? String,
                       "the profile does not point at the uploaded picture")
        XCTAssertEqual(JourneyAdmin.string(user["bio"]), bio)
        XCTAssertEqual(app.staticTexts["profile.bio"].label, bio)
    }

    /// A save whose upload fails says so, keeps the screen, and keeps what
    /// was typed — and writes nothing.
    func testAFailedUploadKeepsWhatWasTypedAndSavesNothing() throws {
        let (app, me) = try signInAsNewAccount(email, extraArguments: ["-petnote-upload-standin", Self.deadStandIn])
        uid = me
        let before = JourneyAdmin.string(try JourneyAdmin.fields(path: "users/\(me)")?["bio"]) ?? ""
        let bio = "TEST CONTENT kept \(run)"
        try pickPictureAndTypeBio(app, bio: bio)
        app.buttons["editProfile.save"].tap()

        XCTAssertTrue(waitForExistence(of: app.staticTexts["editProfile.error"], in: app, timeout: 90),
                      "a failed upload was not reported\n\(app.debugDescription)")
        let field = app.textViews["editProfile.bio"]
        XCTAssertTrue(field.exists, "the edit screen closed on a failed save")
        XCTAssertEqual(field.value as? String, bio, "what was typed was lost")
        XCTAssertEqual(JourneyAdmin.string(try JourneyAdmin.fields(path: "users/\(me)")?["bio"]) ?? "", before,
                       "a failed save wrote the bio anyway")
    }

    /// Edited on its page, and the new name is what the page, the profile's
    /// list and the server all show.
    func testEditingAPetShowsTheNewNameEverywhere() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        let petID = try addPetThroughTheScreens(app, named: "Edit \(run)")
        self.petID = petID
        let renamed = "Renamed \(run.prefix(6))"

        app.buttons["pet.menu"].tap()
        let edit = app.buttons["pet.edit"]
        XCTAssertTrue(waitUntilHittable(edit, in: app, timeout: 10), "no Edit in the pet menu")
        edit.tap()
        let name = app.textFields["petEditor.name"]
        XCTAssertTrue(waitUntilHittable(name, in: app, timeout: 30), "the editor did not open")
        replaceText(in: name, with: renamed)
        let save = app.buttons["petEditor.save"]
        for _ in 0..<6 where !(save.exists && save.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForEnabled(save, timeout: 10))
        save.tap()

        let title = app.staticTexts["pet.name"]
        let renamedTitle = expectation(for: NSPredicate(format: "label == %@", renamed), evaluatedWith: title)
        XCTAssertEqual(XCTWaiter().wait(for: [renamedTitle], timeout: 30), .completed, "the page still shows the old name")
        XCTAssertEqual(JourneyAdmin.string(try JourneyAdmin.fields(path: "pets/\(petID)")?["name"]), renamed)

        popToTabRoot(app)
        let row = app.buttons["profile.pet.\(petID)"]
        XCTAssertTrue(waitForExistence(of: row, in: app, timeout: 20))
        XCTAssertTrue(row.label.contains(renamed), "My pets still shows the old name: \(row.label)")
    }

    func testSavingAPostAndUnsavingIt() throws {
        let (app, me) = try signInAsNewAccount(email)
        uid = me
        openFirstPost(app)
        let text = app.staticTexts.matching(identifier: "post.text").firstMatch.label
        let postID = try XCTUnwrap(try JourneyAdmin.postDocumentNames(withText: text).first?.split(separator: "/").last.map(String.init))
        bookmarked = postID

        tapPostMenuItem(app, id: "post.actions.bookmark", expectedLabel: "Save")
        var saved = false
        for _ in 0..<20 {
            saved = try JourneyAdmin.fields(path: "users/\(me)/bookmarks/\(postID)") != nil
            if saved { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(saved, "the bookmark was not written")

        tapPostMenuItem(app, id: "post.actions.bookmark", expectedLabel: "Remove from saved")
        var gone = false
        for _ in 0..<20 {
            gone = try JourneyAdmin.fields(path: "users/\(me)/bookmarks/\(postID)") == nil
            if gone { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(gone, "the bookmark was not removed")
        bookmarked = nil
    }

    // MARK: - Steps

    private func pickPictureAndTypeBio(_ app: XCUIApplication, bio: String) throws {
        app.tabBars.buttons["Profile"].tap()
        let edit = app.buttons["profile.edit"]
        XCTAssertTrue(waitUntilHittable(edit, in: app, timeout: 30), "no Edit profile")
        edit.tap()
        let change = app.buttons["editProfile.changePhoto"]
        XCTAssertTrue(waitUntilHittable(change, in: app, timeout: 20), "no Change photo")
        change.tap()
        try pickFirstPhoto(app)
        XCTAssertTrue(waitForExistence(of: app.staticTexts["editProfile.pictureUnsaved"], in: app, timeout: 30),
                      "the picked picture was not taken up\n\(app.debugDescription)")
        let field = app.textViews["editProfile.bio"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 10))
        replaceText(in: field, with: bio)
    }

    /// Opens the post menu and taps an item, after checking it reads the way
    /// round the test expects — the label is the menu's own statement of
    /// whether the post is saved.
    private func tapPostMenuItem(_ app: XCUIApplication, id: String, expectedLabel: String) {
        let menu = app.buttons["post.actions"]
        XCTAssertTrue(waitUntilHittable(menu, in: app, timeout: 30), "no post menu")
        menu.tap()
        let item = app.buttons[id]
        XCTAssertTrue(waitUntilHittable(item, in: app, timeout: 10), "no \(id) in the menu")
        XCTAssertEqual(item.label, expectedLabel, "the menu reads the wrong way round")
        item.tap()
    }
}
