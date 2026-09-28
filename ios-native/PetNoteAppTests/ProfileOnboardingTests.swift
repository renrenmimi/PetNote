import Foundation
import Testing

@testable import PetNote

/// First-run setup: the name step, and the write that ends the flow.
///
/// `completeOnboarding` is the one write on this line that goes straight to
/// Firestore rather than through a callable, because the rules allow the owner
/// to write `onboardingComplete` on their own document and there is no callable
/// for it. That makes the *failure* path the interesting one: a flow that
/// claims to be finished on a write that never landed is a flow the person
/// never gets asked again.
@MainActor
struct ProfileOnboardingTests {

    private func makeModel(
        users: FakeUserRepository, delay: Duration = .zero
    ) -> OnboardingModel {
        OnboardingModel(uid: "u1", users: users, nameCheckDelay: delay)
    }

    private func repository(withName name: String?) -> FakeUserRepository {
        let users = FakeUserRepository()
        if let name {
            users.storedProfile = UserProfile(
                id: "u1", displayName: name, avatarURL: "", bio: "", onboardingComplete: false
            )
        }
        return users
    }

    // MARK: Starting

    /// A brand-new account already has a name — the server assigns one, and so
    /// does sign-up. So this step offers a change rather than demanding an
    /// invention, which is what makes Skip an honest option.
    @Test func theFieldOpensOnTheNameTheAccountAlreadyHas() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()

        #expect(model.loadState == .ready)
        #expect(model.displayName == "HappyOtter42")
        #expect(users.generateCalls == 0, "a name was generated over one that already existed")
        #expect(users.nameChecks.isEmpty, "the account was asked whether its own name is taken")
        #expect(model.canContinue)
    }

    @Test func anAccountWithNoNameYetIsGivenOneNobodyIsUsing() async {
        let users = repository(withName: nil)
        users.generatedName = "SparklyKoala19"
        let model = makeModel(users: users)
        await model.start()

        #expect(model.displayName == "SparklyKoala19")
        #expect(users.generateCalls == 1)
        #expect(model.canContinue, "the generated name could not be continued from")
    }

    /// The case above, followed one step further. A generated name is **not**
    /// the account's name — the server has none, which is why one was
    /// generated — so continuing with it has to write it.
    ///
    /// Without the write the account stays nameless for good: `finish()`
    /// then creates `users/{uid}` holding only `onboardingComplete`
    /// (firestore.rules:248-250), and `ensureUserProfileCallable` never
    /// repairs a document that exists — it returns early without writing
    /// (functions/src/users.ts:309-321).
    @Test func aGeneratedNameIsSavedWhenThePersonContinuesWithIt() async {
        let users = repository(withName: nil)
        users.generatedName = "SparklyKoala19"
        let model = makeModel(users: users)
        await model.start()

        await model.continueFromName()

        #expect(users.updateCalls.count == 1, "the generated name was never written")
        #expect(users.updateCalls.first?.displayName == "SparklyKoala19")
        #expect(model.step == .finished)
    }

    @Test func afailedReadSaysSoAndOffersNothingToContinueFrom() async {
        let users = repository(withName: nil)
        users.profileError = ProfileError.offline
        let model = makeModel(users: users)
        await model.start()

        #expect(model.loadState == .failed(ProfileError.offline.message))
        #expect(!model.canContinue)
    }

    // MARK: The name step

    @Test func continuingWithAnUnchangedNameWritesNothing() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()

        await model.continueFromName()

        // The callable would take the reservation it already holds — which
        // works, and spends a rate-limited write on a no-op.
        #expect(users.updateCalls.isEmpty)
        #expect(model.step == .finished)
    }

    @Test func continuingWithANewNameSavesItFirst() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()
        model.displayName = "  SparklyKoala19 "
        await model.name.awaitPending()

        await model.continueFromName()

        #expect(users.updateCalls.count == 1)
        #expect(users.updateCalls.first?.displayName == "SparklyKoala19")
        // Only the name: an onboarding step must not write over a bio or an
        // avatar it never showed.
        #expect(users.updateCalls.first?.bio == nil)
        #expect(users.updateCalls.first?.avatarURL == nil)
        #expect(model.step == .finished)
    }

    @Test func anameTheServerRefusesKeepsThePersonOnTheStep() async {
        let users = repository(withName: "HappyOtter42")
        users.updateResult = .failure(ProfileError.displayNameTaken)
        let model = makeModel(users: users)
        await model.start()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        await model.continueFromName()

        #expect(model.step == .name, "the flow moved on from a name that was not saved")
        #expect(model.name.status == .taken)
        #expect(model.errorMessage == ProfileError.displayNameTaken.message)
        #expect(!model.canContinue)
    }

    @Test func anameSomebodyElseHasCannotBeContinuedFrom() async {
        let users = repository(withName: "HappyOtter42")
        users.takenNames = ["sparklykoala19"]
        let model = makeModel(users: users)
        await model.start()
        model.displayName = "SparklyKoala19"
        await model.name.awaitPending()

        #expect(model.name.status == .taken)
        #expect(!model.canContinue)

        await model.continueFromName()
        #expect(users.updateCalls.isEmpty)
        #expect(model.step == .name)
    }

    @Test func skippingMovesOnWithoutWritingAnything() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()
        model.displayName = "SomethingElse"

        model.skipName()

        #expect(users.updateCalls.isEmpty)
        #expect(model.step == .finished)
    }

    // MARK: Finishing

    @Test func finishingMarksOnboardingCompleteForThisAccount() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()
        model.skipName()

        await model.finish()

        #expect(users.completeOnboardingCalls == ["u1"])
        #expect(model.isComplete)
    }

    /// The half that matters. Claiming completion on a write that failed hides
    /// the flow for good — the person is never asked again, and nobody finds
    /// out because the screen looked like it worked.
    @Test func afailedCompletionLeavesTheFlowToComeBack() async {
        let users = repository(withName: "HappyOtter42")
        users.completeOnboardingError = ProfileError.offline
        let model = makeModel(users: users)
        await model.start()
        model.skipName()

        await model.finish()

        #expect(!model.isComplete, "onboarding claimed to finish on a write that failed")
        #expect(model.errorMessage == ProfileError.offline.message)
    }

    @Test func twoTapsInTheSameTurnFinishOnce() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()
        model.skipName()

        async let first: Void = model.finish()
        async let second: Void = model.finish()
        _ = await (first, second)

        #expect(users.completeOnboardingCalls.count == 1)
    }

    @Test func afinishedFlowIsNotWrittenAgain() async {
        let users = repository(withName: "HappyOtter42")
        let model = makeModel(users: users)
        await model.start()
        model.skipName()
        await model.finish()
        await model.finish()
        #expect(users.completeOnboardingCalls.count == 1)
    }

    // MARK: Who sees the flow at all

    /// Four inputs, and the failure that matters is the silent one: somebody
    /// who has *not* finished never being asked.
    @Test func theGateShowsTheFlowExactlyWhenItShould() {
        var gate = OnboardingGate(
            isSignedIn: true, isProfileLoaded: true,
            onboardingComplete: false, dismissedThisSession: false
        )
        #expect(gate.shouldShow)

        gate.onboardingComplete = true
        #expect(!gate.shouldShow, "a finished account was asked again")

        gate.onboardingComplete = false
        gate.dismissedThisSession = true
        #expect(!gate.shouldShow, "a dismissal did not hold for the session")

        gate.dismissedThisSession = false
        gate.isSignedIn = false
        #expect(!gate.shouldShow, "a signed-out visitor was offered onboarding")
    }

    /// A profile that has not loaded yet is not a profile that has not
    /// onboarded. Defaulting to "not complete" while the read is in flight
    /// flashes the flow at everybody on every launch.
    @Test func theFlowIsNotShownWhileTheProfileIsStillBeingRead() {
        let gate = OnboardingGate(
            isSignedIn: true, isProfileLoaded: false,
            onboardingComplete: false, dismissedThisSession: false
        )
        #expect(!gate.shouldShow)
    }
}
