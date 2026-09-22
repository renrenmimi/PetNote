import Foundation
import Observation
import OSLog

/// "Is this name free?", asked while somebody types.
///
/// One implementation, used by both screens that ask — editing a profile and
/// the first onboarding step. They asked separately in the web client and the
/// two copies already differed: one skipped the check when the name was
/// unchanged, the other also skipped it when the name was too short, and only
/// one of them treated a *failed* check as "free".
///
/// Three rules it exists to hold:
///
///   - **a failed check is not an available name.** The web client's `catch`
///     set "not taken", which turns an offline moment into a green light and a
///     save that fails. `.unknown` says what happened, and the save is left
///     available because the server takes the reservation anyway;
///   - **your own name is not taken.** Reservations are keyed on the lowercased
///     name, so re-typing your own name — or only changing its case — must not
///     be asked about. It would come back taken, by you;
///   - **a late answer about an old name is dropped.** Every keystroke bumps a
///     generation, and an answer from an older one describes a name that is no
///     longer in the field.
@MainActor
@Observable
final class DisplayNameAvailability {
    enum Status: Sendable, Equatable {
        case idle
        case checking
        case available
        case taken
        /// The check could not be made. Distinct from `available` on purpose.
        case unknown
        case invalid(DisplayNameRule.Problem)

        /// Whether this status alone should stop a save.
        ///
        /// `unknown` does not: see the type's first rule.
        var blocksSaving: Bool {
            switch self {
            case .checking, .taken, .invalid: true
            case .idle, .available, .unknown: false
            }
        }

        var message: String? {
            switch self {
            case .idle, .available: nil
            case .checking: "Checking name…"
            case .taken: "That name is already taken."
            case .unknown: "We could not check that name. You can still save."
            case .invalid(let problem): problem.message
            }
        }
    }

    private(set) var status: Status = .idle

    private let users: any UserRepository
    private let delay: Duration
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "profile")

    private var task: Task<Void, Never>?
    private var generation = 0

    /// The name the account already has, so it can be recognised as not a
    /// change. Updated after a successful save.
    var baseline: String

    init(
        users: any UserRepository,
        baseline: String = "",
        delay: Duration = .milliseconds(500)
    ) {
        self.users = users
        self.baseline = baseline
        self.delay = delay
    }

    func isUnchanged(_ name: String) -> Bool {
        DisplayNameRule.isSameName(name, baseline)
    }

    /// Arms a check for `name`, replacing any pending one.
    func check(_ name: String) {
        task?.cancel()
        generation += 1
        let generation = generation

        if let problem = DisplayNameRule.problem(with: name) {
            // An empty field is somebody mid-edit, not an error to shout
            // about. Anything else that breaks the rule is said immediately —
            // it needs no round trip.
            status = DisplayNameRule.normalize(name).isEmpty ? .idle : .invalid(problem)
            return
        }
        if isUnchanged(name) {
            status = .idle
            return
        }

        status = .checking
        let candidate = DisplayNameRule.normalize(name)
        task = Task { [weak self] in
            guard let self else { return }
            // The debounce. Cancellation is the ordinary exit — it happens on
            // every keystroke — so it is silent and not a failure.
            do { try await Task.sleep(for: self.delay) } catch { return }
            await self.ask(candidate, generation: generation)
        }
    }

    private func ask(_ candidate: String, generation: Int) async {
        do {
            let taken = try await users.isDisplayNameTaken(candidate)
            guard generation == self.generation else { return }
            status = taken ? .taken : .available
        } catch {
            guard generation == self.generation else { return }
            log.info("display-name check failed; answering unknown rather than available")
            status = .unknown
        }
    }

    /// The server has spoken: this name is not ours to take.
    ///
    /// Called when a save comes back `displayNameTaken` even though the field
    /// said otherwise — the check is advisory and the reservation is only
    /// taken inside the server's transaction.
    func markTaken() {
        generation += 1
        task?.cancel()
        status = .taken
    }

    /// After a successful save: this name is now the baseline, and nothing is
    /// pending about it.
    func settle(on name: String) {
        generation += 1
        task?.cancel()
        baseline = DisplayNameRule.normalize(name)
        status = .idle
    }

    /// Waits for a pending check. For tests, and for a save that wants the
    /// answer before it decides.
    func awaitPending() async {
        await task?.value
    }
}
