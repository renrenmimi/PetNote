import Foundation
import OSLog
import Observation

/// Creating an account, and the two things that have to happen afterwards.
///
/// **Three operations against two systems, which fail independently.** This is
/// the distinction src/contexts/AuthContext.tsx arrived at the hard way and
/// wrote `SignUpOutcome` to hold:
///
///   1. `createAccount` — the only one whose failure means *there is no
///      account*;
///   2. `ensureUserProfileCallable` — the profile document;
///   3. the verification email.
///
/// Collapsing them into "threw or didn't" is what made a failed profile write
/// look like a failed sign-up. The person then tried again and hit
/// `email-already-in-use` **on the account they had just created**, with no way
/// to tell that from the address genuinely being taken.
///
/// ## Why this outlives the screen
///
/// Step 1 signs the new account in, and the app follows the session: `RootView`
/// switches to the signed-in tree the moment Firebase's listener fires, which
/// is *before* steps 2 and 3 have run. A model owned by the sign-up screen is
/// being torn down while its own work is still in flight. So the work is owned
/// here, by an object that lives as long as the process, and what the person
/// needs to be told is left in `pendingNotice` for the signed-in tree to pick
/// up.
@MainActor
@Observable
final class AccountSetupService {
    /// Something the person has to be told, on a screen that exists after the
    /// sign-up screen is gone.
    ///
    /// Neither case is a failed sign-up. Both name the thing to do next,
    /// because "something went wrong" with no next step is how people end up
    /// signing up twice.
    enum Notice: Sendable, Equatable {
        /// The account exists and no verification email went out. Without this
        /// a delivery failure is indistinguishable from a delivered email that
        /// never arrived — and the person has no reason to press Resend.
        case verificationEmailNotSent(email: String)
        /// The account exists and its profile document does not. Recoverable
        /// without the person doing anything; still said out loud, because
        /// "finishing your setup" is a different sentence from "sign-up
        /// failed".
        case profileSetupIncomplete

        var message: String {
            switch self {
            case .verificationEmailNotSent(let email):
                String(localized: "Account created, but we could not send the verification email to \(email). Use Resend below.")
            case .profileSetupIncomplete:
                String(localized: "Account created. We are still finishing your profile setup.")
            }
        }
    }

    /// What actually happened, for the caller that is still alive to see it.
    struct Outcome: Sendable, Equatable {
        let uid: String
        let profileCreated: Bool
        let verificationSent: Bool
    }

    private(set) var pendingNotice: Notice?
    /// Whose sign-up the notice is about. The service is one per process and
    /// outlives any account, so without this the next person to sign in on the
    /// device would be told that "we could not send the verification email to"
    /// somebody else's address.
    private var noticeOwner: String?

    /// The finishing work, held so it cannot be cancelled by the screen that
    /// started it going away.
    private var finishing: Task<Outcome, Never>?

    private let auth: any AccountAuthenticating
    private let users: any UserRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "auth")

    init(auth: any AccountAuthenticating, users: any UserRepository) {
        self.auth = auth
        self.users = users
    }

    /// Creates the account. Throws only when there is no account.
    ///
    /// Returns as soon as the account exists; the profile document and the
    /// verification email are still in flight, and `awaitSetup()` is how a test
    /// — or a caller that wants to wait — joins them.
    @discardableResult
    func createAccount(email: String, password: String) async throws(AuthError) -> String {
        let uid = try await auth.createAccount(email: email, password: password)
        log.info("account created: \(uid.prefix(6), privacy: .public)")
        finishing = Task { [weak self] in
            guard let self else {
                return Outcome(uid: uid, profileCreated: false, verificationSent: false)
            }
            return await self.finishSetup(uid: uid, email: email)
        }
        return uid
    }

    /// Everything after the account exists. Never throws: past this point a
    /// failure is a "finish setting up" problem, not a failed sign-up.
    private func finishSetup(uid: String, email: String) async -> Outcome {
        var profileCreated = false
        do {
            // A name nobody is using, and the same default avatar the server
            // would pick. The server may still answer with a different name —
            // it appends a numeric suffix when the reservation is taken — and
            // that answer is the one the account has.
            let displayName = await users.generateUniqueDisplayName()
            _ = try await users.ensureProfile(
                displayName: displayName,
                avatarURL: UserProfile.defaultAvatarURL(forUID: uid),
                bio: "",
                onboardingComplete: false
            )
            profileCreated = true
        } catch {
            log.error("profile setup failed: \(String(describing: error), privacy: .public)")
        }

        var verificationSent = false
        do {
            try await auth.sendVerificationEmail()
            verificationSent = true
        } catch {
            log.error("verification email failed: \(String(describing: error), privacy: .public)")
        }

        // The verification email is the one the person has to act on, so it
        // wins when both failed. An unfinished profile is repaired the next
        // time the signed-in tree appears (`ProfileRepair`); an email that
        // never went out is not.
        if !verificationSent {
            pendingNotice = .verificationEmailNotSent(email: email)
            noticeOwner = uid
        } else if !profileCreated {
            pendingNotice = .profileSetupIncomplete
            noticeOwner = uid
        }

        return Outcome(uid: uid, profileCreated: profileCreated, verificationSent: verificationSent)
    }

    /// Waits for the finishing work started by `createAccount`.
    ///
    /// Nil when no sign-up has happened in this process.
    func awaitSetup() async -> Outcome? {
        guard let finishing else { return nil }
        return await finishing.value
    }

    /// Hands the notice over once, and only to the account it is about. Read
    /// by the banner in the signed-in tree.
    func consumeNotice(for uid: String) -> Notice? {
        guard noticeOwner == uid, let notice = pendingNotice else { return nil }
        pendingNotice = nil
        noticeOwner = nil
        return notice
    }
}

extension AccountSetupService {
    /// The one the app uses.
    ///
    /// A single instance for the process, and that is the whole point: SwiftUI
    /// rebuilds `LoginView` whenever the signed-out state redraws, so a service
    /// constructed in a view's initialiser would be a *new* service each time —
    /// and `pendingNotice`, whose entire job is to survive from the sign-up
    /// screen to the screen after it, would be thrown away on the redraw that
    /// happens the instant the account is created.
    ///
    /// Lazily initialised, as every Swift `static let` is, so nothing here
    /// touches Firebase in a unit-test host that never reads it.
    @MainActor
    static let live = AccountSetupService(
        auth: LiveAccountAuth(), users: FirestoreUserRepository()
    )
}
