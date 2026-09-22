import Foundation
import Testing

@testable import PetNote

/// Creating an account, and the three operations behind it.
///
/// The behaviour every case here is defending: **only the account creation
/// failing means there is no account.** The web client collapsed all three
/// into "threw or didn't", so a failed profile write was reported as a failed
/// sign-up — after which the person tried again and hit
/// `email-already-in-use` on the account they had just made. That is the
/// specific trap, and it is not visible from the outside: both outcomes show
/// an error and neither says which.
@MainActor
struct AuthSignUpTests {

    private func makeService(
        auth: FakeAccountAuth = FakeAccountAuth(),
        users: FakeUserRepository = FakeUserRepository()
    ) -> (AccountSetupService, FakeAccountAuth, FakeUserRepository) {
        (AccountSetupService(auth: auth, users: users), auth, users)
    }

    // MARK: What may be submitted

    @Test func nothingIsSubmittableUntilEveryConditionHolds() {
        let (service, _, _) = makeService()
        let model = SignUpModel(setup: service)
        #expect(!model.canSubmit, "an empty form is submittable")

        model.email = "someone@example.com"
        #expect(!model.canSubmit, "an address with no password is submittable")

        model.password = "Passw0rd!"
        #expect(!model.canSubmit, "a password with no confirmation is submittable")

        model.confirmPassword = "Passw0rd!"
        #expect(model.canSubmit)
    }

    @Test func twoPasswordsThatDoNotMatchCannotBeSubmitted() {
        let (service, _, _) = makeService()
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!!"
        #expect(!model.canSubmit)
        #expect(model.showsMismatch)
    }

    /// While the confirmation is empty the person is still typing it, and
    /// telling them it does not match is telling them off for being mid-word.
    @Test func theMismatchWarningWaitsUntilThereIsSomethingToCompare() {
        let (service, _, _) = makeService()
        let model = SignUpModel(setup: service)
        model.password = "Passw0rd!"
        #expect(!model.showsMismatch)
        model.confirmPassword = "P"
        #expect(model.showsMismatch)
    }

    @Test func aPasswordTheClientRuleRefusesNeverReachesTheServer() async {
        let (service, auth, _) = makeService()
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "password"      // no uppercase, no digit, no symbol
        model.confirmPassword = "password"
        #expect(!model.canSubmit)

        await model.submit()
        #expect(auth.createdAccounts.isEmpty, "a refused password was sent anyway")
    }

    // MARK: The happy path

    @Test func aSuccessfulSignUpCreatesTheAccountTheProfileAndTheEmail() async {
        let (service, auth, users) = makeService()
        let model = SignUpModel(setup: service)
        model.email = "  someone@example.com  "
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()
        let outcome = await service.awaitSetup()

        // The address is trimmed before it is used, so a space picked up from
        // a paste does not become part of the account.
        #expect(auth.createdAccounts.map(\.email) == ["someone@example.com"])
        #expect(users.ensureCalls == 1)
        #expect(auth.verificationSends == 1)
        #expect(outcome?.profileCreated == true)
        #expect(outcome?.verificationSent == true)
        #expect(model.notice == nil)
        #expect(model.didCreateAccount)
        // Nothing to carry forward: all three worked.
        #expect(service.pendingNotice == nil)
    }

    /// The account exists from the moment Auth answers, so the name has to be
    /// one nobody is using before the profile is written — the same thing
    /// `generateUniqueUsername` does on the web.
    @Test func theNewProfileAsksForANameNobodyIsUsing() async {
        let (service, _, users) = makeService()
        users.generatedName = "SparklyHedgehog77"
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()
        _ = await service.awaitSetup()
        #expect(users.generateCalls == 1)
    }

    // MARK: The two failures that are not failed sign-ups

    @Test func aProfileWriteThatFailsIsNotReportedAsAFailedSignUp() async {
        let (service, auth, users) = makeService()
        users.ensureResult = .failure(ProfileError.offline)
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()
        let outcome = await service.awaitSetup()

        // This is the whole point: the account exists, so the form must not
        // invite a second attempt that would collide with it.
        #expect(model.didCreateAccount)
        #expect(model.notice == nil, "a finished sign-up reported an error")
        #expect(outcome?.profileCreated == false)
        // The verification email still goes out — it does not depend on the
        // profile document.
        #expect(auth.verificationSends == 1)
        #expect(service.pendingNotice == .profileSetupIncomplete)
    }

    @Test func aVerificationEmailThatDoesNotSendIsSaidOutLoud() async {
        let (service, auth, _) = makeService()
        auth.verificationSendError = .networkUnavailable
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()
        let outcome = await service.awaitSetup()

        #expect(model.didCreateAccount)
        #expect(outcome?.verificationSent == false)
        // Without this the person has no reason to press Resend: a send that
        // failed looks exactly like one that worked and never arrived.
        #expect(service.pendingNotice == .verificationEmailNotSent(email: "someone@example.com"))
        #expect(service.pendingNotice?.message.contains("someone@example.com") == true)
    }

    /// When both go wrong, the one the person has to act on wins. An
    /// unfinished profile repairs itself; an email that never went out does
    /// not.
    @Test func theEmailFailureIsTheOneReportedWhenBothFail() async {
        let (service, auth, users) = makeService()
        users.ensureResult = .failure(ProfileError.offline)
        auth.verificationSendError = .networkUnavailable
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()
        _ = await service.awaitSetup()
        #expect(service.pendingNotice == .verificationEmailNotSent(email: "someone@example.com"))
    }

    /// The notice is handed over exactly once, or the banner shows it again on
    /// every redraw for the rest of the session.
    @Test func theCarriedNoticeIsHandedOverOnce() async {
        let (service, auth, _) = makeService()
        auth.verificationSendError = .unknown
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"
        await model.submit()
        _ = await service.awaitSetup()

        #expect(service.consumeNotice() != nil)
        #expect(service.consumeNotice() == nil)
    }

    // MARK: The failure that does mean there is no account

    @Test func anAddressThatAlreadyHasAnAccountOffersTheWayIn() async {
        let (service, auth, users) = makeService()
        auth.createResult = .failure(.emailAlreadyInUse)
        let model = SignUpModel(setup: service)
        model.email = "taken@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()

        #expect(model.notice == .emailAlreadyInUse(email: "taken@example.com"))
        #expect(!model.didCreateAccount)
        // Nothing after the account creation may run: there is no account.
        #expect(users.ensureCalls == 0)
        #expect(auth.verificationSends == 0)
    }

    /// Making somebody retype a password because a request failed is its own
    /// small punishment, and it defeats the password manager.
    @Test func afailedAttemptKeepsEverythingThatWasTyped() async {
        let (service, auth, _) = makeService()
        auth.createResult = .failure(.networkUnavailable)
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        await model.submit()

        #expect(model.email == "someone@example.com")
        #expect(model.password == "Passw0rd!")
        #expect(model.confirmPassword == "Passw0rd!")
        #expect(model.canSubmit, "the form could not be submitted again")
    }

    @Test func eachFailureGetsWordsThatAreNotTheSdksOwn() {
        #expect(SignUpModel.notice(for: .emailAlreadyInUse, email: "a@b.test")
            == .emailAlreadyInUse(email: "a@b.test"))
        #expect(SignUpModel.notice(for: .weakPassword, email: "a@b.test")
            == .message(AuthError.weakPassword.message))
        #expect(SignUpModel.notice(for: .signUpNotAllowed, email: "a@b.test")
            == .message(AuthError.signUpNotAllowed.message))
        // Never a raw "Firebase: Error (auth/...)" string.
        for error in [AuthError.unknown, .networkUnavailable, .tooManyAttempts] {
            #expect(!error.message.lowercased().contains("firebase"))
        }
    }

    // MARK: Submitting twice

    /// A disabled button is a hint. A second tap, or a second Return, arrives
    /// before the redraw that disables it — and two accounts is not something
    /// that can be undone from the app.
    @Test func twoTapsInTheSameTurnCreateOneAccount() async {
        let (service, auth, _) = makeService()
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"

        async let first: Void = model.submit()
        async let second: Void = model.submit()
        _ = await (first, second)
        _ = await service.awaitSetup()

        #expect(auth.createdAccounts.count == 1, "the form created two accounts")
    }

    @Test func aFinishedSignUpCannotBeSubmittedAgain() async {
        let (service, auth, _) = makeService()
        let model = SignUpModel(setup: service)
        model.email = "someone@example.com"
        model.password = "Passw0rd!"
        model.confirmPassword = "Passw0rd!"
        await model.submit()
        await model.submit()
        #expect(auth.createdAccounts.count == 1)
    }
}
