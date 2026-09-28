import Foundation
import Testing

@testable import PetNote

/// Looking at your own profile.
///
/// One rule carries most of the weight: **"we could not find out" and "there is
/// nothing here" must not look the same.** A failed read that renders as an
/// empty profile is a screen telling somebody their bio is gone.
/// Somewhere to put a state sampled from inside an open read.
@MainActor
final class StateProbe {
    var state: ProfileModel.State?
}

@MainActor
struct ProfileOverviewTests {

    private func makeModel(_ users: FakeUserRepository) -> ProfileModel {
        ProfileModel(uid: "u1", email: "someone@example.com", users: users)
    }

    @Test func aloadedProfileShowsWhatTheDocumentSays() async {
        let users = FakeUserRepository()
        users.storedProfile = UserProfile(
            id: "u1", displayName: "HappyOtter42",
            avatarURL: "https://res.cloudinary.test/image/upload/a.jpg",
            bio: "Two cats.", onboardingComplete: true
        )
        let model = makeModel(users)
        await model.load()

        #expect(model.profile?.displayName == "HappyOtter42")
        #expect(model.displayedName == "HappyOtter42")
        #expect(model.profile?.bio == "Two cats.")
        #expect(model.email == "someone@example.com")
    }

    @Test func afailedReadIsNotShownAsAnEmptyProfile() async {
        let users = FakeUserRepository()
        users.profileError = ProfileError.offline
        let model = makeModel(users)
        await model.load()

        #expect(model.profile == nil)
        #expect(model.state == .failed(message: ProfileError.offline.message, isRetryable: true))
    }

    /// Only a failure worth repeating gets a retry. Offering one for a refusal
    /// invites somebody to press it until they give up.
    @Test func onlyArepeatableFailureOffersARetry() async {
        let users = FakeUserRepository()
        users.profileError = ProfileError.banned
        let model = makeModel(users)
        await model.load()

        #expect(model.state == .failed(message: ProfileError.banned.message, isRetryable: false))
    }

    /// Right after signing up the account exists and its document does not.
    /// That is a moment, not an error.
    @Test func amissingDocumentIsAMomentAndNotAFailure() async {
        let users = FakeUserRepository()
        users.storedProfile = nil
        let model = makeModel(users)
        await model.load()

        #expect(model.profile != nil)
        #expect(model.displayedName == "Your profile")
        #expect(model.profile?.resolvedAvatarURL == UserProfile.defaultAvatarURL(forUID: "u1"))
    }

    /// A profile mid-repair has an empty name. An empty line where a name goes
    /// looks like the screen is broken.
    @Test func aprofileWithNoNameYetStillHasSomethingToShow() async {
        let users = FakeUserRepository()
        users.storedProfile = UserProfile(
            id: "u1", displayName: "", avatarURL: "", bio: "", onboardingComplete: false
        )
        let model = makeModel(users)
        await model.load()

        #expect(model.displayedName == "Your profile")
    }

    /// Replacing a profile that is already on screen with a spinner, to fetch
    /// the same profile, is a flicker with nothing behind it.
    ///
    /// Sampled **inside** the second read rather than before or after it: from
    /// the outside, a state that was `.loading` for the duration of the
    /// request and `.loaded` again afterwards is indistinguishable from one
    /// that never changed.
    @Test func arefreshDoesNotBlankTheScreenItIsRefreshing() async {
        let users = FakeUserRepository()
        users.storedProfile = UserProfile(
            id: "u1", displayName: "HappyOtter42", avatarURL: "", bio: "", onboardingComplete: true
        )
        let model = makeModel(users)
        await model.load()

        let probe = StateProbe()
        users.storedProfile?.displayName = "SparklyKoala19"
        users.whileReading = { @MainActor @Sendable in probe.state = model.state }
        await model.load()

        #expect(probe.state != nil, "the window was never opened, so this proves nothing")
        #expect(probe.state != .loading, "a refresh replaced the profile with a spinner")
        #expect(model.profile?.displayName == "SparklyKoala19")
    }

    /// And the first read *does* show a spinner, so the case above is about
    /// refreshes rather than about the state never being set at all.
    @Test func thefirstReadDoesShowThatItIsLoading() async {
        let users = FakeUserRepository()
        users.storedProfile = UserProfile(
            id: "u1", displayName: "HappyOtter42", avatarURL: "", bio: "", onboardingComplete: true
        )
        let model = makeModel(users)
        let probe = StateProbe()
        users.whileReading = { @MainActor @Sendable in probe.state = model.state }

        await model.load()

        #expect(probe.state == .loading)
    }

    @Test func aneditResultIsTakenWithoutAnotherRoundTrip() async {
        let users = FakeUserRepository()
        users.storedProfile = UserProfile(
            id: "u1", displayName: "HappyOtter42", avatarURL: "", bio: "", onboardingComplete: true
        )
        let model = makeModel(users)
        await model.load()

        model.apply(
            displayName: "SparklyKoala19",
            avatarURL: "https://res.cloudinary.test/image/upload/new.jpg",
            bio: "Three cats now."
        )

        #expect(model.profile?.displayName == "SparklyKoala19")
        #expect(model.profile?.bio == "Three cats now.")
        #expect(users.profileReads.count == 1, "applying an edit cost a second read")
    }
}
