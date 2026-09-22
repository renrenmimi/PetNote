import Foundation
import OSLog

/// Gives a signed-in account the profile document every other screen assumes.
///
/// The web client does this in its profile listener
/// (`src/contexts/AuthContext.tsx`): no `users/{uid}` → create one; a document
/// with no name or no picture → fill in the missing half. Without it, an
/// account whose sign-up created the Auth record but not the profile — the
/// case `AccountSetupService` reports as "still finishing your profile setup"
/// — stays nameless for good, because nothing else ever writes that document.
///
/// **Once per sign-in, not per snapshot.** The web client repairs on every
/// listener event, guarded by an in-flight set; this client reads the profile
/// once when the signed-in tree appears, so it repairs once.
///
/// **Safe for an account being deleted.** `ensureUserProfileCallable` refuses a
/// uid with a deletion tombstone (`assertUserNotDeletionTombstoned`,
/// functions/src/users.ts), so a finished deletion cannot be resurrected from
/// here. While a deletion is still pending the document exists, and the server
/// returns it without writing.
enum ProfileRepair {
    private static let log = Logger(subsystem: "dev.local.petnote.native", category: "profile")

    /// The profile after repair, or nil when there is still none.
    ///
    /// Throws only when the profile could not be *read*. A repair that fails is
    /// logged and the profile is returned as it was: a screen that shows a
    /// nameless account is recoverable, and the next sign-in tries again.
    static func run(uid: String, users: any UserRepository) async throws -> UserProfile? {
        guard let profile = try await users.profile(uid: uid) else {
            return await create(uid: uid, users: users)
        }
        let missingName = profile.displayName.isEmpty
        let missingAvatar = profile.avatarURL.isEmpty
        guard missingName || missingAvatar else { return profile }

        var repaired = profile
        let name = missingName ? await users.generateUniqueDisplayName() : nil
        let avatar = missingAvatar ? UserProfile.defaultAvatarURL(forUID: uid) : nil
        do {
            // Only the missing keys are sent. The callable treats an absent key
            // as "leave it", and sending the name the account already has would
            // be a rename request for a name it already holds.
            _ = try await users.updateProfile(displayName: name, avatarURL: avatar, bio: nil)
            if let name { repaired.displayName = name }
            if let avatar { repaired.avatarURL = avatar }
        } catch {
            log.error("profile repair (update) failed: \(String(describing: error), privacy: .public)")
        }
        return repaired
    }

    private static func create(uid: String, users: any UserRepository) async -> UserProfile? {
        let name = await users.generateUniqueDisplayName()
        do {
            // The server may keep a different name — a suffix when the
            // reservation is taken, or the existing document's own name if the
            // sign-up's write landed first — and its answer is the one used.
            let ensured = try await users.ensureProfile(
                displayName: name,
                avatarURL: UserProfile.defaultAvatarURL(forUID: uid),
                bio: "",
                onboardingComplete: false
            )
            return UserProfile(
                id: uid,
                displayName: ensured.displayName,
                avatarURL: ensured.avatarURL,
                bio: "",
                onboardingComplete: false
            )
        } catch {
            log.error("profile repair (create) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
