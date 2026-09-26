import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// The pet callables report three different refusals with `failed-precondition`
/// and two with `permission-denied`, and the client has to tell them apart —
/// they need different words and different recovery.
///
/// Every expectation below is taken from functions/src/pets.ts and
/// functions/src/shared.ts. The mapper takes the *operation* as well as the
/// error precisely because the code alone cannot separate them.
struct PetCallableErrorTests {
    private func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
        NSError(
            domain: FunctionsErrorDomain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    // MARK: - failed-precondition, three meanings

    @Test func failedPreconditionOnACreateIsTheFivePetCap() {
        let error = functionsError(.failedPrecondition, "Maximum 5 pets allowed.")

        #expect(FirestorePetRepository.map(error, for: .create) == .petLimitReached)
    }

    @Test func failedPreconditionOnADeleteMeansThePetHasOtherOwners() {
        let error = functionsError(
            .failedPrecondition,
            "This pet has other owners. Leave the pet instead, or ask the other owners to leave first."
        )

        #expect(FirestorePetRepository.map(error, for: .delete) == .petHasOtherOwners)
    }

    /// `assertCallerAccountActive` raises it on every callable, so it has to be
    /// recognised before the operation is consulted — otherwise a deleted
    /// account creating a pet would be told it already has five.
    @Test func aDeletedAccountIsRecognisedOnEveryOperation() {
        let error = functionsError(.failedPrecondition, "This account has been deleted.")

        #expect(FirestorePetRepository.map(error, for: .create) == .accountDeleted)
        #expect(FirestorePetRepository.map(error, for: .delete) == .accountDeleted)
        #expect(FirestorePetRepository.map(error, for: .update) == .accountDeleted)
    }

    /// The *other* half of `assertCallerAccountActive`: before it reads the
    /// tombstone it calls `assertActorNotDeleting`, which refuses with the
    /// same code and different words (functions/src/notifications.ts:112-118).
    ///
    /// Reachable, not theoretical: `deleteUserAccount` sets `deletionPending`
    /// first and leaves it set, with Auth intact, when any cleanup step fails
    /// (functions/src/users.ts:501-508, 616-622). That account can still sign
    /// in, and until this case was recognised every pet create told it
    /// "You already have 5 pets" and every delete told it the pet had other
    /// owners.
    @Test func anAccountMidDeletionIsNotToldItHasFivePetsOrOtherOwners() {
        let error = functionsError(.failedPrecondition, "Account deletion is in progress.")

        #expect(FirestorePetRepository.map(error, for: .create) == .accountDeleted)
        #expect(FirestorePetRepository.map(error, for: .delete) == .accountDeleted)
        #expect(FirestorePetRepository.map(error, for: .update) == .accountDeleted)
    }

    // MARK: - permission-denied, two meanings

    @Test func aBannedCallerIsNotReportedAsNotBeingAnOwner() {
        let error = functionsError(.permissionDenied, "Banned users cannot delete pets.")

        #expect(FirestorePetRepository.map(error, for: .delete) == .banned)
    }

    @Test func theFamilyAuthorityRefusalReportsNotAnOwner() {
        #expect(
            FirestorePetRepository.map(
                functionsError(.permissionDenied, "Cannot update this pet."), for: .update
            ) == .notAnOwner
        )
        #expect(
            FirestorePetRepository.map(
                functionsError(.permissionDenied, "Cannot delete this pet."), for: .delete
            ) == .notAnOwner
        )
    }

    // MARK: - The rest of the gates

    @Test func mapsTheRemainingServerGates() {
        #expect(
            FirestorePetRepository.map(functionsError(.notFound, "Pet not found."), for: .update)
                == .petNotFound
        )
        #expect(
            FirestorePetRepository.map(
                functionsError(.resourceExhausted, "Too many requests."), for: .create
            ) == .rateLimited
        )
        let refusal = FirestorePetRepository.map(
            functionsError(.invalidArgument, "Pet name must be between 2 and 20 characters."),
            for: .create
        )
        guard case .rejected(let wording) = refusal else {
            Issue.record("a content refusal was reported as \(refusal), not as a rejection")
            return
        }
        #expect(!wording.isEmpty, "a rejection has to carry words that can be shown")
    }

    // MARK: - Unauthenticated means two opposite things

    /// The Functions SDK refuses to attach an auth token to a plaintext
    /// request bound for a non-loopback host and reports it as
    /// `unauthenticated` — the same code a genuinely signed-out caller gets.
    /// Reporting it as a session problem sends somebody to sign in again, over
    /// and over, for something that is not about them.
    @Test func theSdksPlaintextRefusalIsNotASignInProblem() {
        let refusal = functionsError(
            .unauthenticated,
            "Refusing to send Auth, FCM, and AppCheck tokens over HTTP to non-loopback host."
        )

        #expect(
            FirestorePetRepository.map(refusal, for: .create)
                == .transport(FirestorePetRepository.Transport.unavailable)
        )
        #expect(
            FirestorePetRepository.map(
                functionsError(.unauthenticated, "Must be logged in."), for: .create
            ) == .notSignedIn
        )
    }

    // MARK: - Certain failures and ambiguous ones

    /// A request that never left the device created nothing, so repeating it
    /// cannot duplicate anything.
    @Test func aRequestThatNeverLeftTheDeviceIsACertainFailure() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost] {
            let mapped = FirestorePetRepository.map(
                NSError(domain: NSURLErrorDomain, code: code), for: .create
            )
            #expect(mapped == .transport(FirestorePetRepository.Transport.offline))
        }
    }

    /// **The distinction the create depends on.** A connection lost mid-flight
    /// or a request that timed out may already have been delivered, and
    /// `createPetCallable` has no idempotency key — so treating either as
    /// "nothing happened" is how one lost response becomes two pets and two of
    /// the five slots.
    @Test func anAmbiguousFailureIsNeverReportedAsACertainOne() {
        let ambiguous = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]
        for error in ambiguous {
            #expect(FirestorePetRepository.map(error, for: .create) == .outcomeUnknown)
        }

        #expect(
            FirestorePetRepository.map(
                functionsError(.deadlineExceeded, "deadline exceeded"), for: .create
            ) == .outcomeUnknown
        )
        #expect(
            FirestorePetRepository.map(
                functionsError(.unavailable, "unavailable"), for: .create
            ) == .outcomeUnknown
        )
    }

    /// The mapper is called on the way out of a helper that may already have
    /// produced a `PetError`; re-mapping one would turn a precise case into
    /// `outcomeUnknown`.
    @Test func anErrorThatIsAlreadyAPetErrorIsPassedThrough() {
        #expect(FirestorePetRepository.map(PetError.petNotFound, for: .update) == .petNotFound)
    }

    // MARK: - Birthday fields on the wire

    /// The month and day are the **viewer's local** components on purpose. The
    /// picker hands back local midnight on the chosen day, and deriving the
    /// pair from UTC loses a day for anyone east of Greenwich — a UTC+14 user
    /// picking 1 June produces an instant whose UTC fields say 31 May.
    @Test func theBirthdayIsSentWithLocalMonthAndDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))  // UTC+14
        let localMidnightOnJune1 = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))
        )

        let fields = FirestorePetRepository.birthdayFields(
            for: localMidnightOnJune1, calendar: calendar
        )

        #expect(fields["birthdayMonth"] as? Int == 6)
        #expect(fields["birthdayDay"] as? Int == 1, """
            Derived from UTC this instant is 31 May, which is the day the \
            canonical pair exists to stop the server writing.
            """)
        #expect(fields["birthdayMillis"] as? Int == Int(localMidnightOnJune1.timeIntervalSince1970 * 1000))
    }
}
