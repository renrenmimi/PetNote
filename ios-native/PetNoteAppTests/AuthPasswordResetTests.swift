import Foundation
import Testing

@testable import PetNote

/// Password recovery over Firebase's own emailed link.
///
/// Two properties are load-bearing and pull in opposite directions, which is
/// why they are pinned separately:
///
///   - **nothing here may say whether an address has an account.** Firebase's
///     Email Enumeration Protection makes `sendPasswordReset` succeed silently
///     for an address nobody owns, and the copy says "if" for that reason;
///   - **a failure about *this request* must still be reported as one.** The
///     first version showed the neutral "if an account exists" line for every
///     error, so sending with no connection looked exactly like success — and
///     the person waited for an email that was never sent.
@MainActor
struct AuthPasswordResetTests {

    /// The OTP path is off in production: the flag is false and the three
    /// secrets the callables need do not exist there.
    ///
    /// `CallableNameTests.theNumericCodeResetIsNotWiredUp` pins the same two
    /// names out of the shared registry. This one is the other half and is not
    /// a duplicate of it: the registry can only stop a name being *listed*,
    /// and the way this would actually come back is a call site with the
    /// string written out by hand. So this reads the source the app compiles.
    @Test func theNativeClientNeverNamesTheOtpResetCallables() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbidden = ["requestPasswordResetCodeCallable", "confirmPasswordResetCodeCallable"]
        var offenders: [String] = []

        for directory in ["App", "Core", "Features", "DesignSystem", "Support"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // Prose *about* the names is how the decision is recorded;
                // only code counts.
                let code = text.components(separatedBy: .newlines)
                    .filter {
                        let line = $0.trimmingCharacters(in: .whitespaces)
                        return !line.hasPrefix("//") && !line.hasPrefix("///") && !line.hasPrefix("*")
                    }
                    .joined(separator: "\n")
                for name in forbidden where code.contains(name) {
                    offenders.append("\(url.lastPathComponent): \(name)")
                }
            }
        }
        #expect(offenders.isEmpty, """
            The OTP reset callables are not configured in production. Calling \
            them there fails as "not configured" for every real person:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: Sending

    @Test func aSuccessfulSendSaysSoAndStartsTheCooldown() async {
        let auth = FakeAccountAuth()
        let model = ForgotPasswordModel(auth: auth)
        model.email = "  someone@example.com "
        let now = Date()

        await model.send(now: now)

        #expect(auth.resetSends == ["someone@example.com"], "the address was not trimmed")
        #expect(model.status == .sent)
        #expect(model.showsSpamHint)
        #expect(model.cooldownRemaining(now: now) == Int(ForgotPasswordModel.resendCooldown))
        #expect(model.hasSentOnce)
    }

    /// The regression this screen exists for.
    @Test func sendingWithNoConnectionIsReportedAsAFailureNotAsASuccess() async {
        let auth = FakeAccountAuth()
        auth.resetSendError = .networkUnavailable
        let model = ForgotPasswordModel(auth: auth)
        model.email = "someone@example.com"

        await model.send()

        #expect(model.status == .failed)
        #expect(model.message != ForgotPasswordModel.neutralFallback,
                "an offline send showed the neutral success-shaped line")
        #expect(model.message.lowercased().contains("connection"))
        #expect(!model.showsSpamHint)
        // Nothing was sent, so nothing may be waited for: the button stays
        // available rather than sitting behind a cooldown for a send that
        // never happened.
        #expect(model.cooldownRemaining() == 0)
        #expect(model.canSend())
    }

    @Test func beingRateLimitedSaysSoRatherThanClaimingAnEmailWentOut() async {
        let auth = FakeAccountAuth()
        auth.resetSendError = .tooManyAttempts
        let model = ForgotPasswordModel(auth: auth)
        model.email = "someone@example.com"

        await model.send()
        #expect(model.status == .failed)
        #expect(model.message.lowercased().contains("too many"))
    }

    /// Anything that might be about the *account* keeps the neutral line.
    /// Which errors those are is Firebase's business, and guessing reopens
    /// enumeration.
    @Test func afailureThatMightBeAboutTheAccountStaysNeutral() async {
        for error in [AuthError.invalidCredentials, .accountDisabled, .unknown] {
            let auth = FakeAccountAuth()
            auth.resetSendError = error
            let model = ForgotPasswordModel(auth: auth)
            model.email = "someone@example.com"
            await model.send()
            #expect(model.message == ForgotPasswordModel.neutralFallback,
                    "\(error) leaked something about the account")
        }
    }

    /// A success says nothing about the account either: the same words are
    /// shown whether or not the address is known, because the server behaves
    /// that way too.
    @Test func aSuccessfulSendDoesNotClaimTheAccountExists() async {
        let model = ForgotPasswordModel(auth: FakeAccountAuth())
        model.email = "nobody@example.com"
        await model.send()
        #expect(!model.message.lowercased().contains("we found"))
        #expect(!model.message.lowercased().contains("no account"))
    }

    // MARK: The cooldown

    @Test func aSecondSendInsideTheCooldownDoesNotReachTheServer() async {
        let auth = FakeAccountAuth()
        let model = ForgotPasswordModel(auth: auth)
        model.email = "someone@example.com"
        let start = Date()

        await model.send(now: start)
        await model.send(now: start.addingTimeInterval(5))

        #expect(auth.resetSends.count == 1, "the cooldown was only a disabled button")
        #expect(!model.canSend(now: start.addingTimeInterval(5)))
    }

    @Test func theCooldownEndsWhenItSaysItDoes() async {
        let auth = FakeAccountAuth()
        let model = ForgotPasswordModel(auth: auth)
        model.email = "someone@example.com"
        let start = Date()
        await model.send(now: start)

        let justBefore = start.addingTimeInterval(ForgotPasswordModel.resendCooldown - 1)
        #expect(model.cooldownRemaining(now: justBefore) == 1)
        #expect(!model.canSend(now: justBefore))

        let after = start.addingTimeInterval(ForgotPasswordModel.resendCooldown)
        #expect(model.cooldownRemaining(now: after) == 0)
        #expect(model.canSend(now: after))

        await model.send(now: after)
        #expect(auth.resetSends.count == 2)
    }

    /// Stored as an instant, not as a ticking integer: a counter driven by a
    /// timer that stopped while the app was in the background comes back
    /// saying the same number forever.
    @Test func timeSpentInTheBackgroundStillCountsTowardsTheCooldown() async {
        let model = ForgotPasswordModel(auth: FakeAccountAuth())
        model.email = "someone@example.com"
        let start = Date()
        await model.send(now: start)
        // No ticks happened in between; the remaining time is read from the
        // clock.
        #expect(model.cooldownRemaining(now: start.addingTimeInterval(120)) == 0)
    }

    @Test func changingTheEmailDropsEverythingAboutThePreviousAttempt() async {
        let model = ForgotPasswordModel(auth: FakeAccountAuth())
        model.email = "someone@example.com"
        let start = Date()
        await model.send(now: start)

        model.useADifferentEmail()

        #expect(model.status == .idle)
        #expect(model.message.isEmpty)
        #expect(!model.hasSentOnce)
        // The cooldown belonged to the old address.
        #expect(model.canSend(now: start.addingTimeInterval(1)))
    }

    // MARK: Guards

    @Test func anEmptyAddressIsNeverSent() async {
        let auth = FakeAccountAuth()
        let model = ForgotPasswordModel(auth: auth)
        model.email = "   "
        await model.send()
        #expect(auth.resetSends.isEmpty)
    }

    @Test func twoTapsInTheSameTurnSendOneEmail() async {
        let auth = FakeAccountAuth()
        let model = ForgotPasswordModel(auth: auth)
        model.email = "someone@example.com"

        async let first: Void = model.send()
        async let second: Void = model.send()
        _ = await (first, second)

        #expect(auth.resetSends.count == 1)
    }
}
