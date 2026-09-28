import Foundation
import Testing

@testable import PetNote

/// Coming back from the verification link.
///
/// The hard part is that **nothing tells the app the link was followed**. It is
/// opened in Safari, in Mail's web view, or on another device; Firebase's
/// auth-state listener does not fire for it; and the ID token's
/// `email_verified` claim keeps saying false for up to an hour, so the
/// callables that gate posting go on refusing even after the link has been
/// used. Hence an explicit check that does both halves — reload *and* a forced
/// token refresh — and hence these cases.
@MainActor
struct AuthEmailVerificationTests {

    private func unverified(email: String = "someone@example.com") -> FakeAccountAuth {
        FakeAccountAuth(account: AccountSnapshot(
            uid: "u1", email: email, isEmailVerified: false
        ))
    }

    // MARK: Who sees it

    @Test func aSignedOutVisitorIsNeverToldToVerifyTheirEmail() {
        let model = EmailVerificationModel(auth: FakeAccountAuth(account: nil))
        // The web client's banner checked verification before checking for a
        // user, and told signed-out visitors to verify an email they had not
        // given.
        #expect(!model.isVisible)
    }

    @Test func averifiedAccountSeesNothing() {
        let auth = FakeAccountAuth(account: AccountSnapshot(
            uid: "u1", email: "someone@example.com", isEmailVerified: true
        ))
        #expect(!EmailVerificationModel(auth: auth).isVisible)
    }

    @Test func anUnverifiedAccountIsToldWhichAddressTheLinkWentTo() {
        let model = EmailVerificationModel(auth: unverified(email: "typo@exmaple.com"))
        #expect(model.isVisible)
        // A mistyped address was invisible while the banner said only "check
        // your inbox": the person kept watching an inbox that would never get
        // it.
        #expect(model.address == "typo@exmaple.com")
    }

    @Test func dismissingItHidesIt() {
        let model = EmailVerificationModel(auth: unverified())
        model.isDismissed = true
        #expect(!model.isVisible)
    }

    // MARK: "I verified my email"

    @Test func checkingAfterFollowingTheLinkClearsTheBannerAndTellsTheSession() async {
        let auth = unverified()
        auth.verificationAnswers = [.success(true)]
        var sessionWasTold = false
        let model = EmailVerificationModel(auth: auth) { sessionWasTold = true }

        let verified = await model.checkNow()

        #expect(verified)
        #expect(!model.isVisible)
        #expect(auth.refreshes == 1)
        // Without this the banner goes away and every other gate in the app
        // keeps reading the session's stale `isEmailVerified == false`.
        #expect(sessionWasTold, "the session was not told the account is verified")
    }

    @Test func checkingBeforeFollowingTheLinkSaysSoInsteadOfDoingNothing() async {
        let auth = unverified()
        auth.verificationAnswers = [.success(false)]
        var sessionWasTold = false
        let model = EmailVerificationModel(auth: auth) { sessionWasTold = true }

        let verified = await model.checkNow()

        #expect(!verified)
        #expect(model.isVisible)
        // The difference between "you have not pressed this" and "you pressed
        // it and you are still not verified" is the whole value of the button.
        #expect(model.checkedAndStillUnverified)
        #expect(!sessionWasTold)
    }

    @Test func asecondCheckClearsTheStillUnverifiedLineBeforeAnswering() async {
        let auth = unverified()
        auth.verificationAnswers = [.success(false), .success(true)]
        let model = EmailVerificationModel(auth: auth)

        await model.checkNow()
        #expect(model.checkedAndStillUnverified)

        await model.checkNow()
        #expect(!model.checkedAndStillUnverified)
        #expect(!model.isVisible)
    }

    @Test func acheckThatCannotBeMadeIsNotReportedAsStillUnverified() async {
        let auth = unverified()
        auth.verificationAnswers = [.failure(.networkUnavailable)]
        let model = EmailVerificationModel(auth: auth)

        await model.checkNow()

        // "We could not ask" and "we asked and the answer was no" need
        // different words: the second tells somebody to go open the email,
        // and doing that a second time will not help if the request never
        // went out.
        #expect(!model.checkedAndStillUnverified)
        #expect(model.sendState == .failed("Could not check just now. Try again in a moment."))
        #expect(model.isVisible)
    }

    // MARK: Resending

    @Test func resendingSendsOneEmailAndStartsTheCooldown() async {
        let auth = unverified()
        let model = EmailVerificationModel(auth: auth)
        let now = Date()

        await model.resend(now: now)

        #expect(auth.verificationSends == 1)
        #expect(model.sendState == .sent)
        #expect(model.cooldownRemaining(now: now) == Int(EmailVerificationModel.resendCooldown))
        #expect(model.resendLabel(now: now) == "Resend in 60s")
    }

    /// A cooldown so that somebody tapping repeatedly gets a straight answer
    /// instead of Firebase's own rate limiter surfacing as a raw error.
    @Test func atapInsideTheCooldownDoesNotReachTheServer() async {
        let auth = unverified()
        let model = EmailVerificationModel(auth: auth)
        let start = Date()

        await model.resend(now: start)
        await model.resend(now: start.addingTimeInterval(10))

        #expect(auth.verificationSends == 1)
        #expect(!model.canResend(now: start.addingTimeInterval(10)))
        #expect(model.canResend(now: start.addingTimeInterval(60)))
    }

    @Test func asendThatFailsLooksDifferentFromOneThatWorked() async {
        let auth = unverified()
        auth.verificationSendError = .tooManyAttempts
        let model = EmailVerificationModel(auth: auth)

        await model.resend()

        #expect(model.sendState == .failed(AuthError.tooManyAttempts.message))
        // Nothing was sent, so there is nothing to wait for.
        #expect(model.cooldownRemaining() == 0)
        #expect(model.canResend())
        #expect(model.resendLabel() == "Resend email")
    }

    // MARK: What sign-up left behind

    @Test func anEmailThatNeverWentOutAtSignUpIsSaidHere() async {
        let auth = unverified()
        let users = FakeUserRepository()
        auth.verificationSendError = .networkUnavailable
        let setup = AccountSetupService(auth: auth, users: users)
        _ = try? await setup.createAccount(email: "someone@example.com", password: "Passw0rd!")
        _ = await setup.awaitSetup()

        let model = EmailVerificationModel(auth: auth)
        model.adoptNotice(from: setup)

        #expect(model.setupNotice?.contains("someone@example.com") == true)
        // Taken once: the sign-up screen is gone by now and this is the first
        // screen that exists after it.
        let second = EmailVerificationModel(auth: auth)
        second.adoptNotice(from: setup)
        #expect(second.setupNotice == nil)
    }

    /// A resend answers whatever the previous attempt said, so the carried
    /// notice must not survive it and go on accusing a send that has since
    /// worked.
    @Test func resendingClearsTheNoticeCarriedFromSignUp() async {
        let auth = unverified()
        auth.verificationSendError = .networkUnavailable
        let setup = AccountSetupService(auth: auth, users: FakeUserRepository())
        _ = try? await setup.createAccount(email: "someone@example.com", password: "Passw0rd!")
        _ = await setup.awaitSetup()

        let model = EmailVerificationModel(auth: auth)
        model.adoptNotice(from: setup)
        #expect(model.setupNotice != nil)

        auth.verificationSendError = nil
        await model.resend()

        #expect(model.setupNotice == nil)
        #expect(model.sendState == .sent)
    }
}
