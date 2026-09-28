import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// What a failed follow, unfollow or read turns into.
///
/// The line that matters most is between "never sent", "sent and unanswered"
/// and "answered with a refusal": it decides whether the screen may say
/// "nothing happened", must read to find out, or must say why it was refused.
/// Messages are taken from functions/src/pets.ts, notifications.ts and
/// shared.ts.
struct SocialCallableErrorTests {
    private func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
        NSError(
            domain: FunctionsErrorDomain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    // MARK: - Classification

    @Test func aRequestThatNeverLeftIsNotAnUnknownOutcome() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(CallableFailure.classify(offline) == .neverSent)
        #expect(FirestoreSocialRepository.mapCallable(offline) == .offline)
    }

    /// A timeout may have been delivered. Treating it as "nothing happened"
    /// would let the screen claim a state the server may not be in.
    @Test func aTimeoutIsAnUnknownOutcome() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(CallableFailure.classify(timedOut) == .unknownOutcome)
        #expect(FirestoreSocialRepository.mapCallable(timedOut) == .outcomeUnknown)
        let deadline = functionsError(.deadlineExceeded, "deadline-exceeded")
        #expect(FirestoreSocialRepository.mapCallable(deadline) == .outcomeUnknown)
    }

    @Test func thePlaintextTokenRefusalIsNotASignInProblem() {
        let refused = functionsError(
            .unauthenticated, "Refusing to send auth token over plaintext connection"
        )
        #expect(FirestoreSocialRepository.mapCallable(refused) == .callablesUnavailable)
        let signedOut = functionsError(.unauthenticated, "Must be logged in.")
        #expect(FirestoreSocialRepository.mapCallable(signedOut) == .notSignedIn)
    }

    // MARK: - followPetCallable's refusals

    @Test func followingYourOwnPetIsItsOwnCase() {
        let error = functionsError(.failedPrecondition, "You can't follow your own pet.")
        #expect(FirestoreSocialRepository.mapCallable(error) == .ownPet)
    }

    /// `assertCallerAccountActive` and `assertActorNotDeleting` share the code
    /// with the own-pet refusal, and must be recognised first.
    @Test func aDeletedAccountIsNotReportedAsOwningThePet() {
        let deleted = functionsError(.failedPrecondition, "This account has been deleted.")
        let deleting = functionsError(.failedPrecondition, "Account deletion is in progress.")
        #expect(FirestoreSocialRepository.mapCallable(deleted) == .accountDeleted)
        #expect(FirestoreSocialRepository.mapCallable(deleting) == .accountDeleted)
    }

    @Test func theOtherRefusalsKeepTheirMeaning() {
        #expect(FirestoreSocialRepository.mapCallable(
            functionsError(.permissionDenied, "Banned users cannot follow pets.")
        ) == .banned)
        #expect(FirestoreSocialRepository.mapCallable(
            functionsError(.notFound, "Pet not found.")
        ) == .petNotFound)
        #expect(FirestoreSocialRepository.mapCallable(
            functionsError(.resourceExhausted, "Too many requests. Please wait a moment and try again.")
        ) == .rateLimited)
    }

    // MARK: - Reads

    @Test func aRefusedReadIsDeniedAndAnUnreachableOneIsOffline() {
        let denied = NSError(
            domain: FirestoreErrorDomain, code: FirestoreErrorCode.Code.permissionDenied.rawValue
        )
        let unavailable = NSError(
            domain: FirestoreErrorDomain, code: FirestoreErrorCode.Code.unavailable.rawValue
        )
        #expect(FirestoreSocialRepository.mapFirestore(denied) == .denied)
        #expect(FirestoreSocialRepository.mapFirestore(unavailable) == .offline)
    }
}

/// The documents behind the social screens, decoded without Firebase.
struct SocialDecoderTests {
    @Test func aFollowedPetFallsBackToAPlaceholderName() {
        let pet = SocialDecoder.followedPet(
            id: "pet-1", from: ["petName": "  ", "petAvatar": "file:///etc/passwd"]
        )
        #expect(pet?.petName == "Pet")
        #expect(pet?.petAvatarURL == nil, "a non-http(s) avatar must not reach the image loader")
    }

    @Test func aFollowerKeepsTheirUidAsTheirIdentity() {
        let follower = SocialDecoder.follower(
            id: "uid-9", from: ["userName": "Bob", "userAvatar": "https://res.cloudinary.com/x.jpg"]
        )
        #expect(follower?.id == "uid-9")
        #expect(follower?.userName == "Bob")
        #expect(follower?.userAvatarURL?.host == "res.cloudinary.com")
        #expect(SocialDecoder.follower(id: "", from: [:]) == nil)
    }

    /// Absent and zero are different for the person themself — the web page
    /// falls back to their list's length only when the field is missing.
    @Test func aMissingFollowingCountIsNotZero() {
        let without = SocialDecoder.profile(id: "u1", from: ["displayName": "Ann"])
        let with = SocialDecoder.profile(id: "u1", from: ["followingPetsCount": -3])
        #expect(without.followingPetsCount == nil)
        #expect(with.followingPetsCount == 0, "a trigger race must not show a negative count")
    }

    @Test func aProfileReadsItsLocation() {
        let profile = SocialDecoder.profile(
            id: "u1", from: ["location": ["city": "Boston", "state": "MA"], "bio": " Hi "]
        )
        #expect(profile.city == "Boston")
        #expect(profile.state == "MA")
        #expect(profile.bio == "Hi")
    }

    /// Only the literal "primary" promotes; a corrupted value must not.
    @Test func aProfilePetsRoleIsReadPositively() {
        let pet = SocialFixture.pet("p1")
        let primary = SocialDecoder.profilePet(pet: pet, family: ["role": "primary"])
        let garbage = SocialDecoder.profilePet(pet: pet, family: ["role": "PRIMARY"])
        let custom = SocialDecoder.profilePet(
            pet: pet, family: ["relationship": "other", "customRelationship": "Walker"]
        )
        #expect(primary.role == .primary)
        #expect(garbage.role == .member)
        #expect(custom.customRelationship == "Walker")
    }

    @Test func idsAreBatchedInTensWithoutDuplicates() {
        let ids = (1...23).map { "p\($0)" } + ["p1", ""]
        let batches = IDBatches.make(ids)
        #expect(batches.map(\.count) == [10, 10, 3])
        #expect(Set(batches.flatMap { $0 }).count == 23)
        #expect(IDBatches.make([]).isEmpty)
    }

    /// The server's default avatar is an SVG, which `UIImage` cannot draw.
    @Test func theDefaultSvgAvatarIsDrawnAsAnInitial() {
        #expect(!SocialAvatar.isDrawable(URL(string: "https://api.dicebear.com/7.x/thumbs/svg?seed=u1")))
        #expect(!SocialAvatar.isDrawable(URL(string: "https://example.com/a.svg")))
        #expect(SocialAvatar.isDrawable(URL(string: "https://res.cloudinary.com/demo/image/upload/a.jpg")))
        #expect(SocialAvatar.initial(of: "  mochi") == "M")
        #expect(SocialAvatar.initial(of: "") == "?")
    }
}
