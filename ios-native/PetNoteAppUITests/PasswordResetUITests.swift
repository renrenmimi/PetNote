import XCTest

/// Forgot password, the link flow, through the screens: from sign-in, ask for
/// a reset, then read the Auth emulator to see whether one was actually issued
/// and for whom.
///
/// **The email itself is not followed.** The Auth emulator sends no mail; it
/// records the out-of-band code it would have sent, and that record is what
/// is read here. Opening the link and setting a new password is the real-mail
/// check in ios-native/docs/auth-email-and-google-test-plan.md §B, and is not
/// attempted in a browser from here.
///
/// **The code flow is not here, on purpose.** `ForgotPasswordModel` says why it
/// is not wired (production has neither the flag nor the secrets), and
/// `AuthPasswordResetTests` pins that the app never names its callables.
///
/// **Words.** The web page's (`src/pages/ForgotPassword.tsx`,
/// `forgot.*` in src/i18n/messages.ts) are the reference. The spam hint and
/// "Use a different email" are the same text. Three lines are not, and are
/// asserted as the app has them so a change to either side is noticed:
/// "Reset link sent. Check your email." (web: "…sent! Check…"), "Send the
/// link again in 57s" (web: "Resend in 57s"), and the neutral line's "we have
/// sent" / "use Google Sign-In" (web: "we've sent" / "please use").
final class PasswordResetUITests: XCTestCase {
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private var email: String { "reset-\(run)@petnote.test" }
    /// Never created: the address with no account behind it.
    private var stranger: String { "reset-nobody-\(run)@petnote.test" }

    private static let sentLine = "Reset link sent. Check your email."
    private static let neutralLine = """
        If an account exists with this email, we have sent a reset link. \
        If you signed up with Google, use Google Sign-In instead.
        """

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // The account is all these tests create. The codes the Auth emulator
        // issued stay in its memory — it has no call to remove one — but they
        // name an account that no longer exists, so nothing can use them.
        EmulatorAdmin.cleanUpCreatedAccounts()
        super.tearDown()
    }

    /// A reset for a real account: the screen says it was sent, the resend
    /// waits out the cooldown, and the Auth emulator holds exactly one
    /// PASSWORD_RESET code for that address.
    func testAResetFromSignInIssuesOneResetCodeForThatAddressAndSaysSo() throws {
        try EmulatorAdmin.createVerifiedAccount(email: email, password: "Passw0rd!x")
        XCTAssertTrue(try ServerFixtures.oobCodes(for: email).isEmpty,
                      "a new account already has a code, so the check below could not tell")

        let app = launchOnSignIn()
        openForgotPassword(app)
        send(app, to: email)

        let status = app.staticTexts["forgot.status"]
        XCTAssertTrue(waitForExistence(of: status, in: app, timeout: 30),
                      "nothing was said after sending\n\(app.debugDescription)")
        XCTAssertEqual(status.label, Self.sentLine)
        let hint = app.staticTexts["forgot.spamHint"]
        XCTAssertTrue(hint.exists, "no spam-folder hint after a successful send")
        XCTAssertEqual(hint.label, "Not there after a minute? Check your spam or junk folder.")

        // The server: one password-reset code, for this address.
        var codes: [ServerFixtures.OobCode] = []
        let issued = try serverEventually {
            codes = try ServerFixtures.oobCodes(for: email)
            return !codes.isEmpty
        }
        XCTAssertTrue(issued, "the screen said sent, and the Auth emulator issued nothing for \(email)")
        XCTAssertEqual(codes.map(\.requestType), ["PASSWORD_RESET"],
                       "expected one password-reset code and nothing else")
        XCTAssertFalse(codes[0].code.isEmpty, "the code the emulator recorded is empty")

        // The cooldown, as the screen shows it and as the server sees it.
        let resend = app.buttons["forgot.resend"]
        XCTAssertTrue(waitForExistence(of: resend, in: app, timeout: 10), "no way to send the link again")
        XCTAssertTrue(resend.label.hasPrefix("Send the link again in "),
                      "the resend does not count down: \(resend.label)")
        XCTAssertFalse(resend.isEnabled, "the resend is available inside the cooldown")
        let submit = app.buttons["forgot.submit"]
        XCTAssertFalse(submit.isEnabled, "Send is available again inside the cooldown")
        XCTAssertTrue(app.buttons["forgot.changeEmail"].exists, "no Use a different email")
        // A press on the disabled button must reach nothing. Given time to
        // land, as a second comment is in assertServerCommentCount.
        submit.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(try ServerFixtures.oobCodes(for: email).count, 1,
                       "a second reset went out inside the cooldown")
    }

    /// An address nobody has: the screen says nothing about whether an account
    /// exists, and no code is issued.
    ///
    /// Which of the two neutral lines appears depends on the emulator, not
    /// the app: with enumeration protection Firebase reports success for an
    /// unknown address, without it the emulator answers EMAIL_NOT_FOUND,
    /// which the app shows as the "if an account exists" line. The web page
    /// does the same in both cases. What neither may do is say there is no
    /// account — the web page's old `forgot.noAccount` line.
    func testAnAddressWithNoAccountIsToldNothingAboutItAndNoCodeIsIssued() throws {
        EmulatorAdmin.deleteAccount(email: stranger)
        let app = launchOnSignIn()
        openForgotPassword(app)
        send(app, to: stranger)

        let status = app.staticTexts["forgot.status"]
        XCTAssertTrue(waitForExistence(of: status, in: app, timeout: 30),
                      "nothing was said after sending\n\(app.debugDescription)")
        XCTAssertTrue([Self.sentLine, Self.neutralLine].contains(status.label),
                      "not one of the two neutral lines: \(status.label)")
        for leak in ["no account", "not found", "does not exist", "doesn't exist", "not registered"] {
            XCTAssertFalse(status.label.lowercased().contains(leak), "the screen told a stranger: \(status.label)")
        }

        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(try ServerFixtures.oobCodes(for: stranger).isEmpty,
                      "a code was issued for an address with no account")
    }

    // MARK: - Steps

    private func openForgotPassword(_ app: XCUIApplication) {
        let forgot = app.buttons["login.forgotPassword"]
        XCTAssertTrue(waitUntilHittable(forgot, in: app), "no Forgot your password? on sign-in")
        forgot.tap()
        XCTAssertTrue(waitForExistence(of: app.staticTexts["forgot.title"], in: app, timeout: 20),
                      "the reset screen did not open\n\(app.debugDescription)")
    }

    private func send(_ app: XCUIApplication, to address: String) {
        let field = app.textFields["forgot.email"]
        XCTAssertTrue(waitUntilHittable(field, in: app), "no email field on the reset screen")
        field.tap()
        field.typeText(address)
        XCTAssertEqual(field.value as? String, address, "the field did not receive the address")
        let submit = app.buttons["forgot.submit"]
        XCTAssertTrue(waitForEnabled(submit, timeout: 10), "Send reset link never became available")
        submit.tap()
    }
}
