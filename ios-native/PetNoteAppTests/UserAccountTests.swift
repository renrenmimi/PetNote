import Foundation
import Testing

@testable import PetNote

// MARK: - Doubles shared by the account and profile suites
//
// At file scope rather than nested, because three suites need them and three
// copies of a fake repository is three chances for them to disagree about what
// the real one does. Kept in a `User…Tests` file so they sit with the type they
// stand in for.

/// Stands in for `FirestoreUserRepository`.
///
/// `@unchecked Sendable` and plain mutable state, matching `FeedViewModelTests`'
/// fakes: the protocol is `Sendable` and nonisolated, the tests drive it from
/// one task at a time, and a lock here would only make the recordings harder to
/// read.
final class FakeUserRepository: UserRepository, @unchecked Sendable {
    /// What `profile(uid:)` answers. Nil means "no document", which is a real
    /// state rather than a failure.
    var storedProfile: UserProfile?
    var profileError: Error?

    /// Names this fake considers taken, compared case-insensitively the way the
    /// server's `displayNameLower` reservation does.
    var takenNames: Set<String> = []
    var nameCheckError: Error?

    var ensureResult: Result<EnsuredProfile, Error> = .success(
        EnsuredProfile(displayName: "ServerName", avatarURL: "https://example.test/a.png")
    )
    var updateResult: Result<ProfileUpdateResult, Error> = .success(
        ProfileUpdateResult(authMirrored: true)
    )
    var completeOnboardingError: Error?
    var generatedName = "GeneratedOtter42"

    private(set) var profileReads: [String] = []
    private(set) var nameChecks: [String] = []
    private(set) var ensureCalls = 0
    private(set) var updateCalls: [(displayName: String?, avatarURL: String?, bio: String?)] = []
    private(set) var completeOnboardingCalls: [String] = []
    private(set) var generateCalls = 0

    /// Runs inside an open `updateProfile`, after the call has been recorded
    /// and before it answers. How a test puts a second tap in the window the
    /// first one is still in, without a sleep.
    var whileUpdating: (@Sendable () async -> Void)?

    /// The same window for a read: it runs while `profile(uid:)` is still
    /// open, which is the only moment at which "what is on screen *during* a
    /// refresh" can be sampled. One-shot, so a hook that reads again does not
    /// recurse.
    var whileReading: (@Sendable () async -> Void)?

    func profile(uid: String) async throws -> UserProfile? {
        profileReads.append(uid)
        if let hook = whileReading {
            whileReading = nil
            await hook()
        }
        if let profileError { throw profileError }
        return storedProfile
    }

    func ensureProfile(
        displayName: String?, avatarURL: String?, bio: String?, onboardingComplete: Bool
    ) async throws -> EnsuredProfile {
        ensureCalls += 1
        return try ensureResult.get()
    }

    func isDisplayNameTaken(_ displayName: String) async throws -> Bool {
        nameChecks.append(displayName)
        if let nameCheckError { throw nameCheckError }
        return takenNames.contains { $0.lowercased() == displayName.lowercased() }
    }

    func updateProfile(
        displayName: String?, avatarURL: String?, bio: String?
    ) async throws -> ProfileUpdateResult {
        updateCalls.append((displayName, avatarURL, bio))
        if let hook = whileUpdating {
            whileUpdating = nil
            await hook()
        }
        return try updateResult.get()
    }

    func completeOnboarding(uid: String) async throws {
        completeOnboardingCalls.append(uid)
        if let completeOnboardingError { throw completeOnboardingError }
    }

    func generateUniqueDisplayName() async -> String {
        generateCalls += 1
        return generatedName
    }
}

/// Stands in for `LiveAccountAuth`.
final class FakeAccountAuth: AccountAuthenticating, @unchecked Sendable {
    var account: AccountSnapshot?
    var createResult: Result<String, AuthError> = .success("new-uid")
    var verificationSendError: AuthError?
    var resetSendError: AuthError?
    /// What each successive `refreshVerification()` answers. The queue is what
    /// lets a test show "checked, still not verified" followed by "checked, now
    /// verified" without a timer.
    var verificationAnswers: [Result<Bool, AuthError>] = []

    private(set) var createdAccounts: [(email: String, password: String)] = []
    private(set) var verificationSends = 0
    private(set) var resetSends: [String] = []
    private(set) var refreshes = 0

    init(account: AccountSnapshot? = nil) {
        self.account = account
    }

    var currentAccount: AccountSnapshot? { account }

    func createAccount(email: String, password: String) async throws(AuthError) -> String {
        createdAccounts.append((email, password))
        switch createResult {
        case .success(let uid): return uid
        case .failure(let error): throw error
        }
    }

    func sendVerificationEmail() async throws(AuthError) {
        verificationSends += 1
        if let verificationSendError { throw verificationSendError }
    }

    func sendPasswordResetEmail(to email: String) async throws(AuthError) {
        resetSends.append(email)
        if let resetSendError { throw resetSendError }
    }

    func refreshVerification() async throws(AuthError) -> Bool {
        refreshes += 1
        guard !verificationAnswers.isEmpty else { return account?.isEmailVerified ?? false }
        switch verificationAnswers.removeFirst() {
        case .success(let verified): return verified
        case .failure(let error): throw error
        }
    }
}

/// Stands in for `CloudinaryAvatarUploader`.
final class FakeAvatarUploader: AvatarUploading, @unchecked Sendable {
    var result: Result<UploadedAvatar, Error> = .success(
        UploadedAvatar(url: "https://res.cloudinary.test/image/upload/new.jpg", publicID: "new")
    )
    private(set) var uploads = 0
    private(set) var discarded: [UploadedAvatar] = []

    func upload(imageData: Data) async throws -> UploadedAvatar {
        uploads += 1
        return try result.get()
    }

    func discard(_ avatar: UploadedAvatar) async {
        discarded.append(avatar)
    }
}

/// The canonical gRPC status codes, which is what `FunctionsErrorCode` is.
///
/// Written out rather than imported: the test target does not link
/// FirebaseFunctions. The numbers are fixed by the gRPC specification, and the
/// *domain* comes from the SDK through
/// `FirestoreUserRepository.callableErrorDomain`, so the half that could drift
/// is the half that is not hardcoded.
enum GRPCStatus {
    static let cancelled = 1
    static let invalidArgument = 3
    static let deadlineExceeded = 4
    static let alreadyExists = 6
    static let permissionDenied = 7
    static let resourceExhausted = 8
    static let failedPrecondition = 9
    static let unavailable = 14
    static let unauthenticated = 16
}

func callableFailure(_ code: Int, message: String = "refused") -> NSError {
    NSError(
        domain: FirestoreUserRepository.callableErrorDomain,
        code: code,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

// MARK: - The document, the rule, and the failures

/// What a `users/{uid}` document means, what a display name may be, and what a
/// failure from the server turns into on screen.
///
/// All three are pure, and all three are places where being wrong is invisible
/// from the outside: a profile that decodes to an empty name looks the same as
/// one mid-repair, and a failure mapped to the wrong case shows the wrong
/// sentence and offers the wrong recovery.
struct UserAccountTests {

    // MARK: Decoding

    @Test func aProfileDocumentDecodesTheFieldsTheAppReads() {
        let profile = UserProfile.decode(id: "u1", from: [
            "displayName": "  Fluffy Panda  ",
            "avatarUrl": "https://res.cloudinary.test/image/upload/a.jpg",
            "bio": "Two cats.",
            "onboardingComplete": true,
            "followerCount": 12,
        ])
        #expect(profile.id == "u1")
        // Trimmed: a name stored with padding is the same name, and the
        // reservation the server keeps is on the trimmed form.
        #expect(profile.displayName == "Fluffy Panda")
        #expect(profile.avatarURL == "https://res.cloudinary.test/image/upload/a.jpg")
        #expect(profile.bio == "Two cats.")
        #expect(profile.onboardingComplete)
    }

    /// A profile mid-repair legitimately has no name and no avatar. Decoding
    /// must not fail on it — the web client's profile listener repairs exactly
    /// this document — so the screens are the ones that decide what to show.
    @Test func aHalfWrittenProfileDecodesRatherThanFailing() {
        let profile = UserProfile.decode(id: "u2", from: [:])
        #expect(profile.displayName.isEmpty)
        #expect(profile.bio.isEmpty)
        // Absent means false: a document written before the field existed
        // describes an account that has not been through onboarding.
        #expect(profile.onboardingComplete == false)
    }

    @Test func aProfileWithNoPictureFallsBackToTheSameFaceTheServerWouldPick() {
        let profile = UserProfile.decode(id: "abc123", from: ["displayName": "Someone"])
        #expect(profile.avatarURL.isEmpty)
        #expect(profile.resolvedAvatarURL == "https://api.dicebear.com/7.x/thumbs/svg?seed=abc123")
        #expect(profile.resolvedAvatarURL == UserProfile.defaultAvatarURL(forUID: "abc123"))
    }

    // MARK: The display-name rule

    @Test(arguments: [
        // (name, is it too short?)
        ("a", true), ("ab", false), (" ab ", false), ("喵", true), ("  ", true),
    ])
    func theShortEndOfTheNameRuleMatchesTheServers(_ nameAndVerdict: (String, Bool)) {
        let (name, isTooShort) = nameAndVerdict
        #expect((DisplayNameRule.problem(with: name) == .tooShort) == isTooShort,
                "\(name) was judged wrongly")
    }

    @Test func thirtyCharactersIsAllowedAndThirtyOneIsNot() {
        #expect(DisplayNameRule.problem(with: String(repeating: "a", count: 30)) == nil)
        #expect(DisplayNameRule.problem(with: String(repeating: "a", count: 31)) == .tooLong)
    }

    /// The ASCII-only rule the web client used to have was removed because it
    /// rejected names the backend accepts. Re-inventing it here would bring it
    /// back for every Chinese name.
    @Test func aNonAsciiNameIsAllowed() {
        #expect(DisplayNameRule.isValid("小豆包"))
        #expect(DisplayNameRule.isValid("Владимир"))
    }

    /// Reservations are keyed on the lowercased name, so changing only the case
    /// of your own name is not a change — and asking whether it is taken would
    /// answer yes, by you.
    @Test func yourOwnNameInADifferentCaseIsTheSameName() {
        #expect(DisplayNameRule.isSameName("HappyPanda12", "happypanda12"))
        #expect(DisplayNameRule.isSameName(" HappyPanda12 ", "HappyPanda12"))
        #expect(!DisplayNameRule.isSameName("HappyPanda12", "HappyPanda13"))
    }

    // MARK: Generated names

    @Test func aGeneratedNameIsOneTheRuleWouldAccept() {
        for _ in 0..<50 {
            let name = RandomDisplayName.make()
            #expect(DisplayNameRule.problem(with: name) == nil, "generated an unusable name")
        }
    }

    /// The last-resort name, after ten "taken" answers. It has to stay inside
    /// the limit, or the fallback for a collision is itself unusable.
    @Test func theTimeBrokenFallbackNameStillFitsTheLimit() {
        let longest = "\(RandomDisplayName.adjectives.max(by: { $0.count < $1.count }) ?? "")"
            + "\(RandomDisplayName.animals.max(by: { $0.count < $1.count }) ?? "")"
        #expect(longest.count > 0, "the word lists are empty, so this proves nothing")
        for _ in 0..<50 {
            let name = RandomDisplayName.makeWithTimeBreaker()
            #expect(name.count <= DisplayNameRule.maxLength)
            #expect(DisplayNameRule.problem(with: name) == nil)
        }
    }

    // MARK: Failure mapping

    @Test func aNameLostInsideTheServersTransactionIsReportedAsTaken() {
        // `assertDisplayNameAvailable` throws already-exists, and it is the
        // only thing that does.
        #expect(FirestoreUserRepository.map(callableFailure(GRPCStatus.alreadyExists))
            == .displayNameTaken)
    }

    @Test func aBannedAccountAndAPlainRefusalAreToldApart() {
        let banned = callableFailure(
            GRPCStatus.permissionDenied, message: "Banned users cannot update profiles."
        )
        #expect(FirestoreUserRepository.map(banned) == .banned)

        let other = callableFailure(
            GRPCStatus.permissionDenied, message: "This account is being deleted."
        )
        // The words are carried through rather than replaced: the server has
        // said something specific and there is nothing to add.
        #expect(FirestoreUserRepository.map(other) == .rejected("This account is being deleted."))
    }

    @Test(arguments: [
        (GRPCStatus.unauthenticated, ProfileError.notSignedIn),
        (GRPCStatus.resourceExhausted, ProfileError.rateLimited),
        (GRPCStatus.unavailable, ProfileError.offline),
        (GRPCStatus.deadlineExceeded, ProfileError.outcomeUnknown),
        (GRPCStatus.cancelled, ProfileError.outcomeUnknown),
    ])
    func eachCallableStatusBecomesTheCaseTheScreenCanActOn(
        _ codeAndCase: (Int, ProfileError)
    ) {
        let (code, expected) = codeAndCase
        let mapped = FirestoreUserRepository.map(callableFailure(code))
        #expect(mapped == expected, "status \(code) mapped to \(mapped)")
    }

    @Test func anInvalidArgumentKeepsTheServersOwnWords() {
        let error = callableFailure(
            GRPCStatus.invalidArgument, message: "Display name must be 2-30 characters."
        )
        #expect(FirestoreUserRepository.map(error)
            == .rejected("Display name must be 2-30 characters."))
    }

    /// Being offline and losing the answer are different facts and need
    /// different offers: one is safe to repeat, the other is not.
    @Test func aRequestThatNeverLeftAndOneThatMayHaveArrivedAreToldApart() {
        let neverLeft = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(FirestoreUserRepository.map(neverLeft) == .offline)

        // Both of these may have been delivered with only the answer lost, so
        // neither may be offered as a safe retry.
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCancelled] {
            let mapped = FirestoreUserRepository.map(NSError(domain: NSURLErrorDomain, code: code))
            #expect(mapped == .outcomeUnknown, "url code \(code) mapped to \(mapped)")
            #expect(mapped.isRetryable == false)
        }
    }

    /// `updateUserProfileCallable` has no idempotency key, and a display-name
    /// change that *did* commit would fail its own retry as "taken", by the
    /// person who made it. So the unknown case must never be offered as a
    /// retry.
    @Test func anUnknownOutcomeIsNeverOfferedAsARetry() {
        #expect(ProfileError.outcomeUnknown.isRetryable == false)
        #expect(ProfileError.displayNameTaken.isRetryable == false)
        #expect(ProfileError.offline.isRetryable)
        #expect(ProfileError.rateLimited.isRetryable)
    }

    @Test func aFirestoreRefusalIsNotReportedAsANetworkProblem() {
        let denied = NSError(domain: FirestoreUserRepository.firestoreErrorDomain, code: 7)
        #expect(FirestoreUserRepository.map(denied) == .rejected("You are not allowed to change that."))
        let unavailable = NSError(domain: FirestoreUserRepository.firestoreErrorDomain, code: 14)
        #expect(FirestoreUserRepository.map(unavailable) == .offline)
    }

    // MARK: The password rule

    /// Each rule on its own, so a failure names the rule that was dropped
    /// rather than saying "this password is invalid".
    @Test(arguments: [
        // (password, acceptable?, which rule this case is about)
        ("Passw0rd!", true, "meets every rule"),
        ("Pass0rd!", true, "exactly eight characters is enough"),
        ("Pas0rd!", false, "seven characters is one short"),
        ("passw0rd!", false, "no uppercase letter"),
        ("PASSW0RD!", false, "no lowercase letter"),
        ("Password!", false, "no digit"),
        ("Passw0rdd", false, "no special character"),
    ])
    func eachPasswordRuleIsEnforcedOnItsOwn(_ testCase: (String, Bool, String)) {
        let (password, isValid, rule) = testCase
        #expect(PasswordPolicy.isValid(password) == isValid, "\(rule): \(password)")
    }

    @Test func aPasswordOverSixtyFourCharactersIsRefused() {
        let long = String(repeating: "a", count: 61) + "A1!"
        #expect(long.count == 64)
        #expect(PasswordPolicy.isValid(long))
        #expect(!PasswordPolicy.isValid(long + "x"))
    }

    /// Including the web client's quirk: a valid password under twelve
    /// characters is "medium", not "strong". Kept deliberately — the two
    /// clients disagreeing about the same password is worse than either scale
    /// being ideal.
    @Test func theStrengthScaleMatchesTheWebClientsIncludingItsQuirk() {
        #expect(PasswordPolicy.strength(of: "abc") == .weak)
        #expect(PasswordPolicy.strength(of: "Passw0rd!") == .medium)
        #expect(PasswordPolicy.strength(of: "Passw0rd!Long") == .strong)
    }
}
