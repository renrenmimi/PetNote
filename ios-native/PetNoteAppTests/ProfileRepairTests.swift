import Foundation
import Testing

@testable import PetNote

/// The sign-in repair the web client's profile listener performs
/// (`src/contexts/AuthContext.tsx`), checked by what reaches the server rather
/// than by what the function returns: a repair that returns a nice profile and
/// writes nothing is the failure this exists to catch.
@MainActor
struct ProfileRepairTests {
    private func profile(
        name: String = "Mochi's human", avatar: String = "https://example.test/a.png",
        onboardingComplete: Bool = true
    ) -> UserProfile {
        UserProfile(
            id: "u1", displayName: name, avatarURL: avatar, bio: "",
            onboardingComplete: onboardingComplete
        )
    }

    /// Sign-up created the Auth record and the profile write failed. Nothing
    /// else will ever write that document.
    @Test func anAccountWithNoProfileDocumentIsGivenOne() async throws {
        let users = FakeUserRepository()
        users.storedProfile = nil
        users.generatedName = "QuietOtter7"
        users.ensureResult = .success(EnsuredProfile(
            displayName: "QuietOtter7", avatarURL: UserProfile.defaultAvatarURL(forUID: "u1")
        ))

        let repaired = try await ProfileRepair.run(uid: "u1", users: users)

        #expect(users.ensureRequests.count == 1)
        let sent = try #require(users.ensureRequests.first)
        #expect(sent.displayName == "QuietOtter7")
        #expect(sent.avatarURL == UserProfile.defaultAvatarURL(forUID: "u1"))
        #expect(sent.onboardingComplete == false)
        // Not finished onboarding, so the shell shows it — which is where the
        // person gets to replace the generated name.
        #expect(repaired?.onboardingComplete == false)
        #expect(users.updateCalls.isEmpty)
    }

    /// The server's name is the one the account has, not the one asked for.
    @Test func theNameTheServerSettledOnIsTheOneReturned() async throws {
        let users = FakeUserRepository()
        users.storedProfile = nil
        users.generatedName = "QuietOtter7"
        users.ensureResult = .success(EnsuredProfile(displayName: "QuietOtter7-2", avatarURL: "x"))

        let repaired = try await ProfileRepair.run(uid: "u1", users: users)

        #expect(repaired?.displayName == "QuietOtter7-2")
    }

    @Test func aCompleteProfileIsLeftAlone() async throws {
        let users = FakeUserRepository()
        users.storedProfile = profile()

        let repaired = try await ProfileRepair.run(uid: "u1", users: users)

        #expect(repaired == profile())
        #expect(users.ensureCalls == 0)
        #expect(users.updateCalls.isEmpty)
        #expect(users.generateCalls == 0)
    }

    /// The case the independent review found: onboarding's `finish()` can
    /// create a document holding nothing but `onboardingComplete`, and ensure
    /// never fills in a document that exists. Only an update reaches it.
    @Test func aDocumentWithNoNameIsGivenOneThroughAnUpdate() async throws {
        let users = FakeUserRepository()
        users.storedProfile = profile(name: "", onboardingComplete: true)
        users.generatedName = "QuietOtter7"

        let repaired = try await ProfileRepair.run(uid: "u1", users: users)

        #expect(users.ensureCalls == 0)
        #expect(users.updateCalls.count == 1)
        let sent = try #require(users.updateCalls.first)
        #expect(sent.displayName == "QuietOtter7")
        // Only the missing half is sent. The picture it already has is not a
        // change and is not re-sent as one.
        #expect(sent.avatarURL == nil)
        #expect(sent.bio == nil)
        #expect(repaired?.displayName == "QuietOtter7")
    }

    @Test func aDocumentWithNoPictureIsGivenTheDefaultOneAndKeepsItsName() async throws {
        let users = FakeUserRepository()
        users.storedProfile = profile(avatar: "")

        _ = try await ProfileRepair.run(uid: "u1", users: users)

        let sent = try #require(users.updateCalls.first)
        #expect(sent.displayName == nil)
        #expect(sent.avatarURL == UserProfile.defaultAvatarURL(forUID: "u1"))
        #expect(users.generateCalls == 0)
    }

    /// A failed read is not "no document". Repairing on a read error would
    /// call ensure for every account whose network blinked at sign-in.
    @Test func aProfileThatCouldNotBeReadIsNotRepaired() async {
        let users = FakeUserRepository()
        users.profileError = ProfileError.offline

        await #expect(throws: ProfileError.self) {
            _ = try await ProfileRepair.run(uid: "u1", users: users)
        }
        #expect(users.ensureCalls == 0)
        #expect(users.updateCalls.isEmpty)
    }

    /// A repair that fails leaves things as they were and says so in the log;
    /// it does not claim a name the server never accepted.
    @Test func aFailedRepairDoesNotPretendToHaveRepaired() async throws {
        let users = FakeUserRepository()
        users.storedProfile = profile(name: "")
        users.updateResult = .failure(ProfileError.outcomeUnknown)

        let repaired = try await ProfileRepair.run(uid: "u1", users: users)

        #expect(users.updateCalls.count == 1)
        #expect(repaired?.displayName == "")
    }

    @Test func aFailedCreateLeavesNoProfile() async throws {
        let users = FakeUserRepository()
        users.storedProfile = nil
        users.ensureResult = .failure(ProfileError.offline)

        let repaired = try await ProfileRepair.run(uid: "u1", users: users)

        #expect(users.ensureCalls == 1)
        #expect(repaired == nil)
    }

    // MARK: - A new Google account's name

    /// The web client names a new Google account after the Google account,
    /// when nobody holds that name. The picture stays the generated one.
    @Test func aNewGoogleAccountKeepsItsGoogleNameWhenItIsFree() async throws {
        let users = FakeUserRepository()
        users.storedProfile = nil
        users.ensureResult = .success(EnsuredProfile(displayName: "Mia Chen", avatarURL: "x"))

        _ = try await ProfileRepair.run(uid: "u1", users: users, suggestedName: "  Mia Chen ")

        let sent = try #require(users.ensureRequests.first)
        #expect(sent.displayName == "Mia Chen")
        #expect(sent.avatarURL == UserProfile.defaultAvatarURL(forUID: "u1"), "the provider's picture was used")
        #expect(users.nameChecks == ["Mia Chen"])
        #expect(users.generateCalls == 0)
    }

    @Test func aTakenOrUnusableGoogleNameGivesAGeneratedOne() async throws {
        for (suggested, taken) in [("Mia Chen", true), ("M", false), (String(repeating: "x", count: 31), false), ("   ", false)] {
            let users = FakeUserRepository()
            users.storedProfile = nil
            users.generatedName = "QuietOtter7"
            if taken { users.takenNames = ["mia chen"] }
            users.ensureResult = .success(EnsuredProfile(displayName: "QuietOtter7", avatarURL: "x"))

            _ = try await ProfileRepair.run(uid: "u1", users: users, suggestedName: suggested)

            #expect(users.ensureRequests.first?.displayName == "QuietOtter7", "kept \"\(suggested)\"")
        }
    }

    /// A name check that cannot be answered is not a "free": the generated
    /// name is the one that is always safe to ask for.
    @Test func aNameCheckThatFailsGivesAGeneratedOne() async throws {
        let users = FakeUserRepository()
        users.storedProfile = nil
        users.generatedName = "QuietOtter7"
        users.nameCheckError = URLError(.notConnectedToInternet)
        users.ensureResult = .success(EnsuredProfile(displayName: "QuietOtter7", avatarURL: "x"))

        _ = try await ProfileRepair.run(uid: "u1", users: users, suggestedName: "Mia Chen")

        #expect(users.ensureRequests.first?.displayName == "QuietOtter7")
    }

    /// A profile with no name takes the provider's name the same way.
    @Test func aNamelessProfileTakesTheGoogleName() async throws {
        let users = FakeUserRepository()
        users.storedProfile = profile(name: "")

        _ = try await ProfileRepair.run(uid: "u1", users: users, suggestedName: "Mia Chen")

        #expect(users.updateCalls.first?.displayName == "Mia Chen")
        #expect(users.generateCalls == 0)
    }
}
