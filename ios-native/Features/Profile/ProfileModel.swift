import Foundation
import Observation

/// The signed-in person's own profile, as shown.
///
/// Reads `users/{uid}` straight from Firestore — a read, so it does not go
/// through a callable.
///
/// **Identity only.** The web client's Profile page also carries the pets,
/// saved posts and check-ins tabs; those read collections owned by other lines
/// and are not invented here. What this screen owes is the name, the picture,
/// the bio, the address, and a way to change them.
@MainActor
@Observable
final class ProfileModel {
    enum State: Sendable, Equatable {
        case loading
        case loaded(UserProfile)
        /// Distinct from a loaded profile with nothing in it: "we could not
        /// find out" and "there is nothing here" must not look the same.
        case failed(message: String, isRetryable: Bool)
    }

    private(set) var state: State = .loading

    /// The signed-in address. Not part of the profile document — it lives on
    /// the Auth record — and shown because "which account is this" is the
    /// question a profile screen is most often opened to answer.
    let email: String

    private let uid: String
    private let users: any UserRepository

    init(uid: String, email: String, users: any UserRepository) {
        self.uid = uid
        self.email = email
        self.users = users
    }

    var profile: UserProfile? {
        if case .loaded(let profile) = state { return profile }
        return nil
    }

    /// What to show where a name goes, while there is not one.
    ///
    /// A profile mid-repair legitimately has an empty name — the server fills
    /// it in — and an empty line looks like a broken screen.
    var displayedName: String {
        guard let profile, !profile.displayName.isEmpty else { return String(localized: "Your profile") }
        return profile.displayName
    }

    func load() async {
        // Not resetting to `.loading` on a refresh: replacing a profile that
        // is on screen with a spinner to fetch the same profile is a flicker
        // with nothing behind it.
        if case .loaded = state {} else { state = .loading }
        do {
            guard let profile = try await users.profile(uid: uid) else {
                // The document has not been written yet. A real, temporary
                // state right after signing up — not an error, and not an
                // empty profile either: what is shown is the default face and
                // the placeholder name until it lands.
                state = .loaded(UserProfile(
                    id: uid, displayName: "", avatarURL: "", bio: "", onboardingComplete: false
                ))
                return
            }
            state = .loaded(profile)
        } catch {
            let profileError = (error as? ProfileError) ?? .transport("load")
            state = .failed(message: profileError.message, isRetryable: profileError.isRetryable)
        }
    }

    /// Takes the result of an edit without another round trip.
    func apply(displayName: String, avatarURL: String, bio: String) {
        guard case .loaded(var profile) = state else { return }
        profile.displayName = displayName
        profile.avatarURL = avatarURL
        profile.bio = bio
        state = .loaded(profile)
    }
}
