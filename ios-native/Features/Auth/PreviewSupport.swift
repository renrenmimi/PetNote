#if DEBUG
import Foundation

/// Stand-ins so the SwiftUI previews in this feature can render.
///
/// `#if DEBUG` because they are development scaffolding and have no business
/// in a shipped binary. **Not a test hook**: nothing here reads a launch
/// argument, an environment variable or a defaults key, so there is no channel
/// from outside the process into any of it — which is the distinction
/// `ReleaseHygieneTests` is watching for. A preview cannot use the real types:
/// `Firestore.firestore()` needs a configured Firebase app, and the canvas has
/// none.
struct PreviewAccountAuth: AccountAuthenticating {
    var account: AccountSnapshot? = AccountSnapshot(
        uid: "preview-uid", email: "someone@example.com", isEmailVerified: false
    )

    var currentAccount: AccountSnapshot? { account }
    func createAccount(email: String, password: String) async throws(AuthError) -> String {
        "preview-uid"
    }
    func sendVerificationEmail() async throws(AuthError) {}
    func sendPasswordResetEmail(to email: String) async throws(AuthError) {}
    func refreshVerification() async throws(AuthError) -> Bool { false }
}

struct PreviewUserRepository: UserRepository {
    var stored = UserProfile(
        id: "preview-uid",
        displayName: "HappyOtter42",
        avatarURL: "",
        bio: "Two cats and a very slow tortoise.",
        onboardingComplete: false
    )

    func profile(uid: String) async throws -> UserProfile? { stored }
    func ensureProfile(
        displayName: String?, avatarURL: String?, bio: String?, onboardingComplete: Bool
    ) async throws -> EnsuredProfile {
        EnsuredProfile(displayName: stored.displayName, avatarURL: stored.resolvedAvatarURL)
    }
    func isDisplayNameTaken(_ displayName: String) async throws -> Bool { false }
    func updateProfile(
        displayName: String?, avatarURL: String?, bio: String?
    ) async throws -> ProfileUpdateResult {
        ProfileUpdateResult(authMirrored: true)
    }
    func completeOnboarding(uid: String) async throws {}
    func generateUniqueDisplayName() async -> String { "SunnyCorgi17" }
}

struct PreviewAvatarUploader: AvatarUploading {
    func upload(imageData: Data) async throws -> UploadedAvatar {
        UploadedAvatar(url: "", publicID: "preview")
    }
    func discard(_ avatar: UploadedAvatar) async {}
}

extension AccountSetupService {
    @MainActor
    static var preview: AccountSetupService {
        AccountSetupService(auth: PreviewAccountAuth(), users: PreviewUserRepository())
    }
}
#endif
