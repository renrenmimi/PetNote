import CryptoKit
import XCTest

/// One new person's whole first session, through the screens, against the
/// emulator: sign up → onboarding → verify email → edit profile → add a pet →
/// pick a photo → publish → find it in the feed → open it → edit it → delete it.
///
/// **Every step is a tap or a keystroke.** Nothing here calls a view model or
/// a repository. The emulator is read after each step that writes, because a
/// screen that shows the change proves the screen drew it, and the
/// acceptance criterion is that it was written.
///
/// **Two stand-ins, said plainly.**
///   - *Email verification* is flipped on the Auth emulator, then the banner's
///     "I've verified" button is pressed. No email is sent or opened. What this
///     proves is that the app re-reads the real verification state and acts on
///     it — not that a verification email arrives.
///   - *The photo upload* goes to `scripts/upload-standin.py`, not Cloudinary
///     (`-petnote-upload-standin`, emulator builds only). The picker, the
///     signed multipart request and the hand-off to `createPostCallable` are
///     real; the functions emulator's URL checks run for real; Cloudinary is
///     not involved, and the image URL does not exist on the real CDN, so the
///     picture itself does not load.
///
/// Needs, before the run: the emulators with functions
/// (`firebase emulators:start --only firestore,auth,functions`), the upload
/// stand-in on 8766, and at least one photo in the simulator's library. A
/// missing stand-in fails the test at the start rather than skipping it.
final class JourneyUITests: XCTestCase {
    private static let standIn = "http://127.0.0.1:8766"

    /// Unique per run, so a run that died halfway leaves nothing this one
    /// could mistake for its own work.
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "journey-\(run)@petnote.test" }
    private var displayName: String { "Journey\(run)" }
    private var petName: String { "Biscuit \(run)" }
    private var caption: String { "TEST CONTENT journey \(run)" }
    private var editedCaption: String { "TEST CONTENT journey \(run) edited" }
    private var bio: String { "TEST CONTENT bio \(run)" }

    private var uid: String?
    private var petID: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // Leave the shared emulator as it was found. The post is deleted by
        // the test itself when it gets that far; everything else is removed
        // here whether or not it did.
        // By author as well as by text: a run that failed mid-edit left a post
        // whose text matched neither, and cleaning by text alone missed it.
        var posts = Set((try? JourneyAdmin.postDocumentNames(withText: caption)) ?? [])
        posts.formUnion((try? JourneyAdmin.postDocumentNames(withText: editedCaption)) ?? [])
        if let uid { posts.formUnion((try? JourneyAdmin.postDocumentNames(byAuthor: uid)) ?? []) }
        for name in posts { EmulatorAdmin.deleteComment(documentName: name) }
        if let petID {
            if let uid { JourneyAdmin.deleteDocument(path: "pets/\(petID)/family/\(uid)") }
            JourneyAdmin.deleteDocument(path: "pets/\(petID)")
        }
        if let uid {
            JourneyAdmin.deleteDocument(path: "users/\(uid)")
            JourneyAdmin.deleteDocument(path: "usernames/\(JourneyAdmin.reservationID(for: displayName))")
        }
        EmulatorAdmin.deleteAccount(email: email)
        super.tearDown()
    }

    func testANewPersonCanGoFromSignUpToManagingTheirOwnPost() throws {
        XCTAssertTrue(
            JourneyAdmin.isReachable("\(Self.standIn)/health"),
            "The upload stand-in is not running on 8766. Start it with "
                + "`python3 scripts/upload-standin.py` — this test does not skip without it."
        )
        _ = try JourneyAdmin.standInUploads()

        let app = launchOnSignIn(extraArguments: ["-petnote-upload-standin", Self.standIn])

        signUp(app)
        finishOnboarding(app)

        // Server: the profile exists, with the chosen name, marked complete.
        let uid = try XCTUnwrap(try JourneyAdmin.uid(forEmail: email), "no Auth account for \(email)")
        self.uid = uid
        let user = try XCTUnwrap(try JourneyAdmin.fields(path: "users/\(uid)"), "no users/\(uid)")
        XCTAssertEqual(JourneyAdmin.string(user["displayName"]), displayName)
        XCTAssertEqual(JourneyAdmin.bool(user["onboardingComplete"]), true)

        try verifyEmail(app)        // emulator flip, not a real email
        try editProfile(app)
        try addPet(app)
        try publish(app)            // upload goes to the stand-in, not Cloudinary
        try openAndEdit(app)
        try pinAndUnpin(app)
        try delete(app)
    }

    // MARK: - Steps

    private func signUp(_ app: XCUIApplication) {
        app.buttons["login.signUp"].tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["signup.title"], in: app, timeout: 20),
                      "sign-up screen did not open")
        let emailField = app.textFields["signup.email"]
        XCTAssertTrue(waitUntilHittable(emailField, in: app))
        emailField.tap()
        emailField.typeText(email)
        typeNewPassword("Passw0rd!x", into: app.secureTextFields["signup.password"], in: app)
        typeNewPassword("Passw0rd!x", into: app.secureTextFields["signup.confirmPassword"], in: app)
        let submit = app.buttons["signup.submit"]
        XCTAssertTrue(waitForEnabled(submit, timeout: 10),
                      "Create account never became available\n\(app.debugDescription)")
        submit.tap()
    }

    private func finishOnboarding(_ app: XCUIApplication) {
        // Onboarding appears because the new profile says it is not complete —
        // which is only true if sign-up's profile write, or the repair after
        // it, actually happened.
        XCTAssertTrue(waitForExistence(of: app.staticTexts["onboarding.title"], in: app, timeout: 60),
                      "onboarding never appeared for a new account\n\(app.debugDescription)")
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(waitUntilHittable(name, in: app))
        replaceText(in: name, with: displayName)
        XCTAssertTrue(waitForExistence(of: app.staticTexts["onboarding.nameAvailable"], in: app, timeout: 20),
                      "the chosen name was never confirmed available")
        app.buttons["onboarding.continue"].tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["onboarding.finishTitle"], in: app, timeout: 30))
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(reachedFeed(app), "did not land on the feed after onboarding")
        XCTAssertFalse(app.staticTexts["onboarding.title"].exists, "onboarding is still up")
    }

    private func verifyEmail(_ app: XCUIApplication) throws {
        let banner = app.staticTexts["verify.title"]
        XCTAssertTrue(waitForExistence(of: banner, in: app, timeout: 20),
                      "an unverified account was not shown the verification banner")
        let uid = try XCTUnwrap(uid)
        try JourneyAdmin.markEmailVerified(uid: uid)
        app.buttons["verify.check"].tap()
        XCTAssertTrue(waitForDisappearance(of: banner, timeout: 20),
                      "the banner stayed after the account was verified on the server")
    }

    private func editProfile(_ app: XCUIApplication) throws {
        app.tabBars.buttons["Profile"].tap()
        let edit = app.buttons["profile.edit"]
        XCTAssertTrue(waitUntilHittable(edit, in: app, timeout: 30), "no edit button on the profile")
        edit.tap()
        let bioField = app.textViews["editProfile.bio"]
        XCTAssertTrue(waitUntilHittable(bioField, in: app, timeout: 20), "edit profile did not open")
        bioField.tap()
        bioField.typeText(bio)
        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForDisappearance(of: bioField, timeout: 20), "edit profile did not close on save")
        let shown = app.staticTexts["profile.bio"]
        XCTAssertTrue(waitForExistence(of: shown, in: app, timeout: 20))
        XCTAssertEqual(shown.label, bio, "the profile does not show the saved bio")

        let uid = try XCTUnwrap(uid)
        let user = try XCTUnwrap(try JourneyAdmin.fields(path: "users/\(uid)"))
        XCTAssertEqual(JourneyAdmin.string(user["bio"]), bio, "the bio was not written")
    }

    private func addPet(_ app: XCUIApplication) throws {
        let add = app.buttons["profile.addPet"]
        XCTAssertTrue(waitUntilHittable(add, in: app, timeout: 30),
                      "no Add a pet on the profile\n\(app.debugDescription)")
        add.tap()
        let name = app.textFields["petEditor.name"]
        XCTAssertTrue(waitUntilHittable(name, in: app, timeout: 20), "the pet editor did not open")
        name.tap()
        name.typeText(petName)
        choose(app, picker: "petEditor.species", option: "Dog")
        // Required on create, as on the web: the family list shows it.
        choose(app, picker: "petEditor.relationship", option: "Mom")
        // Save sits at the foot of the form, below rows a Form only realises
        // once they are scrolled to.
        let save = app.buttons["petEditor.save"]
        for _ in 0..<6 where !(save.exists && save.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForEnabled(save, timeout: 10),
                      "Save never became available\n\(app.debugDescription)")
        save.tap()

        // Saving opens the new pet's page.
        let title = app.staticTexts["pet.name"]
        XCTAssertTrue(waitForExistence(of: title, in: app, timeout: 40),
                      "the new pet's page did not open\n\(app.debugDescription)")
        XCTAssertEqual(title.label, petName)

        let uid = try XCTUnwrap(uid)
        let pets = try JourneyAdmin.petDocumentNames(withName: petName)
        XCTAssertEqual(pets.count, 1, "expected exactly one pet named \(petName), found \(pets.count)")
        let petID = try XCTUnwrap(pets.first?.split(separator: "/").last.map(String.init))
        self.petID = petID
        XCTAssertNotNil(try JourneyAdmin.fields(path: "pets/\(petID)/family/\(uid)"),
                        "the creator is not in the pet's family")
    }

    private func publish(_ app: XCUIApplication) throws {
        let uploadsBefore = try JourneyAdmin.standInUploads().count
        // The pet page is a pushed screen, and pushed screens have no tab bar
        // (as on the web); back to the profile first.
        // One level deep, so one Back — and then wait for the bar rather than
        // looking again mid-transition, when the old navigation bar is still
        // in the tree and a second Back finds nothing to tap.
        let postTab = app.tabBars.buttons["Post"]
        if !(postTab.exists && postTab.isHittable) {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
        }
        XCTAssertTrue(waitUntilHittable(postTab, in: app, timeout: 15), "no tab bar after leaving the pet page")
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

        let captionField = app.textViews["compose.caption"]
        captionField.tap()
        captionField.typeText(caption)
        // One pet, so it is chosen already (the web client does the same).
        let share = app.buttons["compose.share"]
        XCTAssertTrue(waitForEnabled(share, timeout: 20), "Share never became available")
        share.tap()
        XCTAssertTrue(waitForDisappearance(of: share, timeout: 90), "the composer did not close after sharing")

        // The feed, reloaded, with the new post first.
        let posted = app.staticTexts.matching(identifier: "post.text")
            .containing(NSPredicate(format: "label == %@", caption)).firstMatch
        XCTAssertTrue(waitForExistence(of: posted, in: app, timeout: 60), "the new post is not in the feed")

        let uploads = try JourneyAdmin.standInUploads()
        XCTAssertEqual(uploads.count, uploadsBefore + 1, "expected one upload to reach the stand-in")
        let upload = try XCTUnwrap(uploads.last)
        let uid = try XCTUnwrap(uid)
        XCTAssertEqual(upload["folder"] as? String, "petnote/users/\(uid)",
                       "the upload was not signed for this account's folder")

        let names = try JourneyAdmin.postDocumentNames(withText: caption)
        XCTAssertEqual(names.count, 1, "expected one post on the server, found \(names.count)")
        let post = try XCTUnwrap(try JourneyAdmin.fields(documentName: XCTUnwrap(names.first)))
        XCTAssertEqual(JourneyAdmin.string(post["authorId"]), uid)
        XCTAssertEqual(JourneyAdmin.string(post["petId"]), petID)
        XCTAssertEqual(
            JourneyAdmin.firstMediaURL(post), upload["secureUrl"] as? String,
            "the post does not carry the URL the upload answered with"
        )
    }

    private func openAndEdit(_ app: XCUIApplication) throws {
        openPost(app, withText: caption)
        openPostMenu(app)
        tapMenuItem(app, id: "post.actions.edit", label: "Edit")
        let field = app.textViews["editPost.caption"]
        XCTAssertTrue(waitUntilHittable(field, in: app, timeout: 20), "the edit screen did not open")
        replaceText(in: field, with: editedCaption)
        app.buttons["editPost.save"].tap()
        XCTAssertTrue(waitForDisappearance(of: field, timeout: 30), "the edit screen did not close on save")

        // The detail screen underneath shows the new text without being
        // reopened.
        // The server first: if the edit was not written, the screen showing
        // the old text is correct and the failure is somewhere else.
        var names: [String] = []
        for _ in 0..<20 {
            names = try JourneyAdmin.postDocumentNames(withText: editedCaption)
            if !names.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(names.count, 1, "the edit was not written")
        let shown = app.staticTexts.containing(NSPredicate(format: "label == %@", editedCaption)).firstMatch
        XCTAssertTrue(waitForExistence(of: shown, in: app, timeout: 20),
                      "the detail screen still shows the old text\n\(app.debugDescription)")
    }

    /// Pinned from the post's menu, and the menu then offers the other way.
    private func pinAndUnpin(_ app: XCUIApplication) throws {
        let uid = try XCTUnwrap(uid)
        let postID = try XCTUnwrap(try JourneyAdmin.postDocumentNames(withText: editedCaption).first?
            .split(separator: "/").last.map(String.init))
        openPostMenu(app)
        let pin = app.buttons["post.actions.pin"]
        XCTAssertTrue(waitUntilHittable(pin, in: app, timeout: 10), "the author is not offered Pin")
        XCTAssertEqual(pin.label, "Pin to profile")
        pin.tap()
        var pinned: String?
        for _ in 0..<20 {
            pinned = JourneyAdmin.string(try JourneyAdmin.fields(path: "users/\(uid)")?["pinnedPostId"])
            if pinned == postID { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(pinned, postID, "the pin was not written")

        openPostMenu(app)
        let unpin = app.buttons["post.actions.pin"]
        XCTAssertTrue(waitUntilHittable(unpin, in: app, timeout: 10))
        XCTAssertEqual(unpin.label, "Unpin from profile", "the menu did not learn the post is pinned")
        unpin.tap()
        for _ in 0..<20 {
            pinned = JourneyAdmin.string(try JourneyAdmin.fields(path: "users/\(uid)")?["pinnedPostId"])
            if pinned == nil || pinned == "" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(pinned == nil || pinned == "", "the unpin was not written: \(pinned ?? "")")
    }

    private func delete(_ app: XCUIApplication) throws {
        openPostMenu(app)
        tapMenuItem(app, id: "post.actions.delete", label: "Delete")
        // The confirmation's own Delete, not the menu's.
        let confirm = app.sheets.buttons["Delete"].exists
            ? app.sheets.buttons["Delete"]
            : app.buttons.matching(NSPredicate(format: "label == 'Delete'")).element(boundBy: 0)
        XCTAssertTrue(waitUntilHittable(confirm, in: app, timeout: 10), "no delete confirmation")
        confirm.tap()

        XCTAssertTrue(reachedFeed(app), "deleting did not return to the feed")
        let gone = app.staticTexts.matching(identifier: "post.text")
            .containing(NSPredicate(format: "label == %@", editedCaption)).firstMatch
        XCTAssertTrue(waitForDisappearance(of: gone, timeout: 20), "the deleted post is still in the feed")

        var remaining = -1
        for _ in 0..<20 {
            remaining = try JourneyAdmin.postDocumentNames(withText: editedCaption).count
            if remaining == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(remaining, 0, "the post still exists on the server")
    }
}

/// Reads and writes on the emulators this journey needs beyond `EmulatorAdmin`.
enum JourneyAdmin {
    private static let documents =
        "\(EmulatorAdmin.firestore)/v1/projects/\(EmulatorAdmin.projectID)/databases/(default)/documents"

    static func isReachable(_ url: String) -> Bool {
        guard let target = URL(string: url) else { return false }
        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: target) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return ok
    }

    static func standInUploads() throws -> [[String: Any]] {
        let response = try EmulatorAdmin.get("http://127.0.0.1:8766/uploads", owner: false)
        guard let uploads = response["uploads"] as? [[String: Any]] else {
            throw NSError(domain: "JourneyAdmin", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the stand-in answered without an uploads list: \(response)"
            ])
        }
        return uploads
    }

    static func uid(forEmail email: String) throws -> String? {
        let listed = try EmulatorAdmin.post(
            "\(EmulatorAdmin.auth)/identitytoolkit.googleapis.com/v1/projects/\(EmulatorAdmin.projectID)/accounts:query?key=fake",
            body: [:], owner: true
        )
        let users = listed["userInfo"] as? [[String: Any]] ?? []
        return users.first { ($0["email"] as? String) == email }?["localId"] as? String
    }

    static func markEmailVerified(uid: String) throws {
        _ = try EmulatorAdmin.post(
            "\(EmulatorAdmin.auth)/identitytoolkit.googleapis.com/v1/projects/\(EmulatorAdmin.projectID)/accounts:update",
            body: ["localId": uid, "emailVerified": true], owner: true
        )
    }

    /// A document's fields, or nil when it does not exist. A 404 is an answer;
    /// every other failure is thrown, so "could not read" is never "absent".
    static func fields(path: String) throws -> [String: Any]? {
        try fields(url: "\(documents)/\(path)")
    }

    static func fields(documentName: String) throws -> [String: Any]? {
        try fields(url: "\(EmulatorAdmin.firestore)/v1/\(documentName)")
    }

    private static func fields(url: String) throws -> [String: Any]? {
        do {
            return try EmulatorAdmin.get(url, owner: true)["fields"] as? [String: Any] ?? [:]
        } catch let error as NSError where error.domain == "EmulatorAdmin" && error.code == 404 {
            return nil
        }
    }

    static func postDocumentNames(withText text: String) throws -> [String] {
        try documentNames(in: "posts", field: "text", equals: text)
    }

    static func postDocumentNames(byAuthor uid: String) throws -> [String] {
        try documentNames(in: "posts", field: "authorId", equals: uid)
    }

    static func petDocumentNames(withName name: String) throws -> [String] {
        try documentNames(in: "pets", field: "name", equals: name)
    }

    static func documentNames(in collection: String, field: String, equals value: String) throws -> [String] {
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": collection]],
                "where": ["fieldFilter": [
                    "field": ["fieldPath": field], "op": "EQUAL", "value": ["stringValue": value],
                ]],
                "limit": 10,
            ]
        ]
        let response = try EmulatorAdmin.post("\(documents):runQuery", body: body, owner: true)
        let rows = response["array"] as? [Any] ?? []
        return rows.compactMap { (($0 as? [String: Any])?["document"] as? [String: Any])?["name"] as? String }
    }

    /// A test account's profile and name reservation, which deleting the Auth
    /// account leaves behind.
    static func removeProfile(uid: String) {
        if let name = (try? fields(path: "users/\(uid)")).flatMap({ $0 }).flatMap({ string($0["displayName"]) }) {
            deleteDocument(path: "usernames/\(reservationID(for: name))")
        }
        deleteDocument(path: "users/\(uid)")
    }

    static func deleteDocument(path: String) {
        EmulatorAdmin.deleteComment(
            documentName: "projects/\(EmulatorAdmin.projectID)/databases/(default)/documents/\(path)"
        )
    }

    /// `usernames/{sha256(displayNameLower)}`, as the server reserves it.
    static func reservationID(for displayName: String) -> String {
        SHA256.hash(data: Data(displayName.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func string(_ value: Any?) -> String? {
        (value as? [String: Any])?["stringValue"] as? String
    }

    static func bool(_ value: Any?) -> Bool? {
        (value as? [String: Any])?["booleanValue"] as? Bool
    }

    static func firstMediaURL(_ post: [String: Any]) -> String? {
        let media = ((post["media"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any]
        let first = (media?.first as? [String: Any])?["mapValue"] as? [String: Any]
        return string((first?["fields"] as? [String: Any])?["url"])
    }
}
