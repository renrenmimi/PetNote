import XCTest

/// "Continue with Google", with Google's own page stood in for and everything
/// after it real.
///
/// The Auth emulator accepts an unsigned JSON identity as a Google ID token,
/// so the Firebase half runs for real: the credential sign-in, the profile a
/// new account gets, signing out and back in, and what Firebase does with an
/// address that already has a password account. Google's page itself cannot
/// be driven by a test with a real account and is not; that part waits for
/// the device session with a person.
///
/// The emulator links a Google identity to an existing account only when the
/// identity says its address is verified, like production does for Gmail;
/// production's Workspace-address case (an error) is not modelled by it.
final class GoogleSignInUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "google-\(run)@petnote.test" }
    private var created: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        for uid in created {
            JourneyAdmin.removeProfile(uid: uid)
            EmulatorAdmin.deleteAccount(uid: uid)
        }
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    private func identity(verified: Bool = true, name: String = "Gee Tester") -> String {
        let object: [String: Any] = ["sub": "g-\(run)", "email": email, "email_verified": verified, "name": name]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func launch(standIn: String) -> XCUIApplication {
        launchOnSignIn(extraArguments: ["-petnote-google-standin", standIn])
    }

    private func tapGoogle(_ app: XCUIApplication) {
        let google = app.buttons["auth.google"]
        XCTAssertTrue(waitUntilHittable(google, in: app, timeout: 30), "no Continue with Google\n\(app.debugDescription)")
        google.tap()
    }

    func testANewGoogleAccountGetsAProfileAndSignsBackInAsItself() throws {
        let app = launch(standIn: identity())
        tapGoogle(app)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "a Google sign-in did not reach the feed")

        let account = try XCTUnwrap(try Self.account(email: email), "no account was created")
        created.append(account.uid)
        XCTAssertTrue(account.providers.contains("google.com"), "signed in, but not with Google: \(account.providers)")
        var profile: [String: Any]?
        for _ in 0..<30 {
            profile = try JourneyAdmin.fields(path: "users/\(account.uid)")
            if profile != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertNotNil(profile, "the new Google account got no profile")

        // Out, and in again: the same account, not a second one.
        signOutFromAccountMenu(app)
        tapGoogle(app)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "signing back in with Google did not reach the feed")
        let again = try XCTUnwrap(try Self.account(email: email))
        XCTAssertEqual(again.uid, account.uid, "signing back in made a second account")
    }

    func testBackingOutOfGoogleLeavesTheScreenAsItWas() {
        let app = launch(standIn: "cancel")
        tapGoogle(app)
        XCTAssertTrue(waitUntilHittable(app.buttons["auth.google"], in: app, timeout: 10), "the button did not come back")
        XCTAssertFalse(app.staticTexts["auth.googleError"].exists, "backing out was reported as a failure")
        XCTAssertTrue(app.textFields["login.email"].exists, "backing out left the sign-in screen")
    }

    func testAGoogleFailureSaysSoAndCanBeTriedAgain() {
        let app = launch(standIn: "fail")
        tapGoogle(app)
        let error = app.staticTexts["auth.googleError"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 15), "a failure said nothing")
        XCTAssertEqual(error.label, "No connection. Check your network and try again.")
        XCTAssertTrue(waitUntilHittable(app.buttons["auth.google"], in: app, timeout: 10), "the button stayed disabled")
    }

    /// The same address, already a password account, and a Google identity
    /// that does not vouch for it: Firebase refuses, the app says the web's
    /// words, and **nothing is linked** — the account still has only its
    /// password.
    func testAnAddressWithAPasswordAccountIsNotJoinedByTheApp() throws {
        let uid = try EmulatorAdmin.createVerifiedAccount(email: email, password: "Passw0rd!x")
        let app = launch(standIn: identity(verified: false))
        tapGoogle(app)
        let error = app.staticTexts["auth.googleError"]
        XCTAssertTrue(waitForExistence(of: error, in: app, timeout: 20), "no answer\n\(app.debugDescription)")
        XCTAssertEqual(error.label, "This email is set up with another sign-in method. Use that one, or reset your password.")
        let account = try XCTUnwrap(try Self.account(email: email))
        XCTAssertEqual(account.uid, uid)
        XCTAssertEqual(account.providers, ["password"], "the accounts were joined")
    }

    /// The same, with a Google identity that does vouch for the address.
    /// Firebase — not the app — links Google to the existing account: one
    /// account, same uid, both methods. Recorded because it is what a person
    /// will see, and because only the owner can change it (by allowing
    /// several accounts per address, a project setting).
    func testFirebaseItselfLinksAVouchedGoogleAddressToTheExistingAccount() throws {
        let uid = try EmulatorAdmin.createVerifiedAccount(email: email, password: "Passw0rd!x")
        let app = launch(standIn: identity(verified: true))
        tapGoogle(app)
        dismissOnboardingIfShown(app)
        XCTAssertTrue(reachedFeed(app), "the vouched Google sign-in did not reach the feed")
        let account = try XCTUnwrap(try Self.account(email: email))
        XCTAssertEqual(account.uid, uid, "Firebase made a second account instead of linking")
        XCTAssertEqual(Set(account.providers), ["password", "google.com"])
    }

    // MARK: - Emulator reads

    private struct Account { let uid: String; let providers: [String] }

    private static func account(email: String) throws -> Account? {
        let listed = try EmulatorAdmin.post(
            "\(EmulatorAdmin.auth)/identitytoolkit.googleapis.com/v1/projects/\(EmulatorAdmin.projectID)/accounts:query?key=fake",
            body: [:], owner: true
        )
        let users = listed["userInfo"] as? [[String: Any]] ?? []
        guard let user = users.first(where: { ($0["email"] as? String) == email }),
              let uid = user["localId"] as? String else { return nil }
        let providers = (user["providerUserInfo"] as? [[String: Any]] ?? []).compactMap { $0["providerId"] as? String }
        return Account(uid: uid, providers: providers.sorted())
    }
}
