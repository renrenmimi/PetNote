import XCTest

/// A filter chosen in the composer is in the photo that is uploaded — through
/// the screens, with the upload read back from the stand-in.
///
/// The same photo is posted twice by one new account: once as picked, once
/// with B&W chosen from the strip. Each upload is read back from the stand-in
/// by this account's folder, and matched to its post on the server by URL.
/// What the stand-in records per upload is the file part's name, type and
/// **size**, not its pixels
/// (scripts/upload-standin.py), so that is what this can compare: the filtered
/// upload has to be a JPEG, and a different number of bytes from the
/// unfiltered one of the same photo. It cannot see that the pixels are grey —
/// `PhotoFilterTests` checks that on the bytes themselves.
///
/// Uploads go to the stand-in, not Cloudinary (see JourneyUITests). Needs the
/// emulators with functions, the stand-in on 8766, and at least one photo in
/// the simulator's library.
final class PhotoFilterUITests: XCTestCase {
    private static let standIn = "http://127.0.0.1:8766"

    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "filter-\(run)@petnote.test" }
    private var uid: String?
    private var petID: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let uid {
            for name in (try? JourneyAdmin.postDocumentNames(byAuthor: uid)) ?? [] {
                _ = EmulatorAdmin.deleteComment(documentName: name)
            }
            if let petID {
                JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)")
                JourneyAdmin.deleteDocument(path: "pets/\(petID)")
            }
            JourneyAdmin.removeProfile(uid: uid)
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    func testChoosingBlackAndWhiteChangesWhatIsUploaded() throws {
        XCTAssertTrue(
            JourneyAdmin.isReachable("\(Self.standIn)/health"),
            "The upload stand-in is not running on 8766. Start it with "
                + "`python3 ios-native/scripts/upload-standin.py` — this test does not skip without it."
        )
        let (app, me) = try signInAsNewAccount(email, extraArguments: ["-petnote-upload-standin", Self.standIn])
        uid = me
        petID = try addPetThroughTheScreens(app, named: "Filter \(run.prefix(6))")

        let plain = try publishTheFirstPhoto(app, caption: "TEST CONTENT filter normal \(run)", choosing: nil)
        let blackAndWhite = app.buttons["compose.filter.bw"]
        let filtered = try publishTheFirstPhoto(
            app, caption: "TEST CONTENT filter bw \(run)", choosing: blackAndWhite
        )

        let plainFile = try XCTUnwrap(plain["file"] as? [String: Any], "the stand-in recorded no file part: \(plain)")
        let filteredFile = try XCTUnwrap(filtered["file"] as? [String: Any], "the stand-in recorded no file part: \(filtered)")
        let plainBytes = try XCTUnwrap(plainFile["bytes"] as? Int)
        let filteredBytes = try XCTUnwrap(filteredFile["bytes"] as? Int)

        XCTAssertEqual(filteredFile["mime"] as? String, "image/jpeg", "a filtered photo is always re-encoded as JPEG")
        XCTAssertEqual((filteredFile["filename"] as? String)?.hasSuffix(".jpg"), true,
                       "the filtered upload kept a name that is not .jpg: \(filteredFile)")
        XCTAssertNotEqual(
            plainBytes, filteredBytes,
            "The B&W upload is exactly as large as the unfiltered one of the same photo "
                + "(\(plainBytes) bytes) — the filter did not reach the bytes."
        )
    }

    // MARK: - Steps

    /// Create tab → pick the first photo → optionally choose a filter → caption →
    /// Share. Returns what the stand-in recorded for the upload.
    private func publishTheFirstPhoto(
        _ app: XCUIApplication, caption: String, choosing filter: XCUIElement?
    ) throws -> [String: Any] {
        let uploadsBefore = try uploadsForThisAccount().count

        // Pushed screens have no tab bar; back to a tab's root first.
        popToTabRoot(app)
        let postTab = app.tabBars.buttons["Create"]
        XCTAssertTrue(waitUntilHittable(postTab, in: app, timeout: 15), "no tab bar to open the composer from")
        postTab.tap()
        let add = app.buttons["compose.addMedia"]
        XCTAssertTrue(waitUntilHittable(add, in: app, timeout: 20), "the composer did not open")
        add.tap()
        try pickFirstPhoto(app)
        XCTAssertTrue(
            waitForExistence(
                of: app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1/'")).firstMatch,
                in: app, timeout: 30
            ),
            "the picked photo never reached the composer"
        )

        // The strip is there for a picked photo without a tap, starting at
        // Normal — the web client's default.
        let normal = app.buttons["compose.filter.normal"]
        XCTAssertTrue(waitForExistence(of: normal, in: app, timeout: 20),
                      "no filter strip under the picked photo\n\(app.debugDescription)")
        XCTAssertTrue(normal.isSelected, "a newly picked photo does not start at Normal")
        // VoiceOver hears the tile's filter as its value, in the same words
        // the strip uses.
        let tile = app.buttons["compose.thumbnail"].firstMatch
        XCTAssertEqual(tile.value as? String, normal.label, "the photo tile does not say which filter is on it")

        if let filter {
            // Seventh of ten, so usually past the right edge: the strip scrolls
            // sideways until it is on screen.
            let strip = app.descendants(matching: .any).matching(identifier: "compose.filters").firstMatch
            for _ in 0..<6 where !(filter.exists && filter.isHittable) { strip.swipeLeft() }
            XCTAssertTrue(waitUntilHittable(filter, in: app, timeout: 10),
                          "the filter never came on screen\n\(app.debugDescription)")
            filter.tap()
            XCTAssertTrue(waitForSelection(of: filter, timeout: 10), "tapping the filter did not choose it")
            XCTAssertFalse(normal.isSelected, "Normal is still marked chosen next to it")
            XCTAssertEqual(tile.value as? String, filter.label, "the photo tile does not say the filter just chosen")
        }

        let captionField = app.textViews["compose.caption"]
        for _ in 0..<3 where !(captionField.exists && captionField.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(captionField, in: app, timeout: 10), "no caption field")
        captionField.tap()
        captionField.typeText(caption)
        // One pet, so it is chosen already.
        let share = app.buttons["compose.share"]
        XCTAssertTrue(waitForEnabled(share, timeout: 20), "Share never became available")
        share.tap()
        XCTAssertTrue(waitForDisappearance(of: share, timeout: 90), "the composer did not close after sharing")

        // This account's uploads only: the stand-in is shared by every test
        // that runs against it, and another's upload landing in between
        // would otherwise be read as this one.
        let uploads = try uploadsForThisAccount()
        XCTAssertEqual(uploads.count, uploadsBefore + 1, "expected one upload to reach the stand-in for this account")
        let upload = try XCTUnwrap(uploads.last)

        // And it is the photo of the post this made, on the server.
        let names = try JourneyAdmin.postDocumentNames(withText: caption)
        XCTAssertEqual(names.count, 1, "expected one post on the server, found \(names.count)")
        let post = try XCTUnwrap(try JourneyAdmin.fields(documentName: XCTUnwrap(names.first)))
        XCTAssertEqual(
            JourneyAdmin.firstMediaURL(post), upload["secureUrl"] as? String,
            "the post does not carry the URL the upload answered with"
        )
        return upload
    }

    /// What the stand-in received, signed for this account's folder — the
    /// check JourneyUITests makes on its upload.
    private func uploadsForThisAccount() throws -> [[String: Any]] {
        let uid = try XCTUnwrap(self.uid, "no account yet")
        let folder = "petnote/users/\(uid)"
        return try JourneyAdmin.standInUploads().filter { ($0["folder"] as? String) == folder }
    }

    private func waitForSelection(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [selected], timeout: timeout) == .completed
    }
}
