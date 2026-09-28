import Foundation
import Observation
import OSLog

/// First-run setup: pick a name, then mark onboarding done.
///
/// ## What this covers, and what it does not
///
/// The web client's flow has three steps — a username, a pet or an invitation
/// code, and pets to follow. **Only the first is here**, plus the completion
/// that ends the flow. The other two read and write pets, invitations and
/// follows, which belong to other lines; inventing a second way to create a
/// pet here would be exactly the duplicate the ownership split exists to
/// prevent. `Step` is ordered so those slot in between without this type
/// changing shape, and `finish()` stays the last thing that happens.
///
/// ## Why the name step matters
///
/// A brand-new account already has a name: the server assigns one, and so does
/// sign-up. So this step is not "choose a name or you cannot continue" — it is
/// "here is the name you have; change it if you want to". That is why Skip
/// exists and why it is not a failure path.
@MainActor
@Observable
final class OnboardingModel {
    /// Ordered. Line B's pet and follow steps belong between `.name` and
    /// `.finished`.
    enum Step: Sendable, Equatable {
        case name
        case finished
    }

    enum LoadState: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var step: Step = .name
    private(set) var loadState: LoadState = .loading
    private(set) var isSavingName = false
    private(set) var isFinishing = false
    private(set) var errorMessage: String?
    /// True once `completeOnboarding` has committed. The gate above this
    /// screen watches it.
    private(set) var isComplete = false

    var displayName = "" {
        didSet {
            guard displayName != oldValue, loadState == .ready else { return }
            name.check(displayName)
        }
    }

    let name: DisplayNameAvailability

    private let uid: String
    private let users: any UserRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "profile")

    init(uid: String, users: any UserRepository, nameCheckDelay: Duration = .milliseconds(500)) {
        self.uid = uid
        self.users = users
        self.name = DisplayNameAvailability(users: users, delay: nameCheckDelay)
    }

    var canContinue: Bool {
        guard !isSavingName, loadState == .ready else { return false }
        guard DisplayNameRule.isValid(displayName) else { return false }
        // An unchanged name needs no save and no check — Continue just moves
        // on. That is why `.idle` passes here as well as `.available`.
        return !name.status.blocksSaving
    }

    /// Seeds the field with the name the account already has, or with one
    /// nobody is using.
    func start() async {
        loadState = .loading
        do {
            let profile = try await users.profile(uid: uid)
            let existing = profile?.displayName ?? ""
            if existing.isEmpty {
                // No profile document yet, or one mid-repair. Generating here
                // rather than leaving the field empty means the person can
                // press Continue without inventing anything.
                displayName = await users.generateUniqueDisplayName()
            } else {
                displayName = existing
            }
            // The assignments above go through `didSet`; `loadState` is still
            // `.loading` there, so no check was armed.
            //
            // The baseline is the name **the server has**, not the one in the
            // field. For a generated name those differ — the account has no
            // name, which is why one was generated — and settling on the
            // generated one made Continue treat it as unchanged and write
            // nothing. `finish()` then created a `users/{uid}` holding only
            // `onboardingComplete`, and `ensureUserProfileCallable` never
            // repairs a document that exists (functions/src/users.ts:309-321).
            name.settle(on: existing)
            loadState = .ready
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    /// Saves the name, then moves on.
    ///
    /// A name that has not changed is not written: the callable would take the
    /// reservation it already holds, which works, but spends a rate-limited
    /// write on a no-op.
    func continueFromName() async {
        guard canContinue else { return }
        errorMessage = nil

        if name.isUnchanged(displayName) {
            advance()
            return
        }

        isSavingName = true
        defer { isSavingName = false }
        do {
            _ = try await users.updateProfile(
                displayName: DisplayNameRule.normalize(displayName), avatarURL: nil, bio: nil
            )
            name.settle(on: displayName)
            advance()
        } catch {
            if (error as? ProfileError) == .displayNameTaken { name.markTaken() }
            log.error("onboarding name save failed: \(String(describing: error), privacy: .public)")
            errorMessage = Self.message(for: error)
        }
    }

    /// Moves on without saving. The account keeps the name it already has.
    func skipName() {
        errorMessage = nil
        advance()
    }

    private func advance() {
        // One place that knows the order. Line B's steps go here.
        switch step {
        case .name: step = .finished
        case .finished: break
        }
    }

    /// Marks onboarding complete.
    ///
    /// This is the one write on this line that goes straight to Firestore. The
    /// rules allow the owner to write `onboardingComplete` and nothing else on
    /// their own document (`isAllowedUserUpdate`), there is no callable for it,
    /// and the web client does exactly this. See
    /// `FirestoreUserRepository.completeOnboarding`.
    func finish() async {
        guard !isFinishing, !isComplete else { return }
        isFinishing = true
        errorMessage = nil
        defer { isFinishing = false }
        do {
            try await users.completeOnboarding(uid: uid)
            isComplete = true
        } catch {
            // Left incomplete on purpose: claiming it finished would hide the
            // flow for good on a write that never landed, and it is shown
            // again from the profile document on the next launch.
            log.error("completeOnboarding failed: \(String(describing: error), privacy: .public)")
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        (error as? ProfileError)?.message ?? ProfileError.transport("onboarding").message
    }
}

/// Whether the first-run flow should be on screen.
///
/// Its own type because the decision has three inputs and getting it wrong is
/// invisible: showing it to somebody who has finished is annoying, and *not*
/// showing it to somebody who has not is the silent half — they never get
/// asked, and nobody finds out.
///
/// Matches the web client's gate in Feed.tsx: signed in, the profile has
/// loaded, `onboardingComplete` is not true, and it has not been dismissed in
/// this session. A profile that has not loaded yet shows nothing — the web
/// client's `profileLoading` guard — because defaulting to "not complete"
/// while the read is in flight flashes the flow at everybody on every launch.
struct OnboardingGate: Sendable, Equatable {
    var isSignedIn: Bool
    var isProfileLoaded: Bool
    var onboardingComplete: Bool
    var dismissedThisSession: Bool

    var shouldShow: Bool {
        isSignedIn && isProfileLoaded && !onboardingComplete && !dismissedThisSession
    }
}
