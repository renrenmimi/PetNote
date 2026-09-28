import Foundation
import Testing

@testable import PetNote

// Doubles and sample data for the social, family, search and profile suites.
//
// Their own, rather than borrowing `FakePetRepository` from the pets suite, so
// a change to another line's fixtures cannot turn these red — or, worse,
// green for the wrong reason.
//
// Classes marked `@unchecked Sendable`, the same arrangement as the other
// fakes in this target: the protocols are `Sendable`, and every field is set
// by the test before the call it answers.

/// Suspends a fake call until the test lets it go, so "a second tap while the
/// first is in flight" can be arranged rather than hoped for.
final class SocialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

/// Yields until `condition` holds, failing the test if it never does.
@MainActor
func socialEventually(
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventuallyTrue(condition) { return }
    Issue.record("the condition never became true", sourceLocation: sourceLocation)
}

final class FakeSocialRepository: SocialRepository, @unchecked Sendable {
    /// Every record below is taken under this lock. The models that use
    /// these fakes read with `async let`, so the calls arrive on several
    /// threads at once; an unlocked append crashed a CI run (SIGSEGV in
    /// `posts(since:limit:)`, run 35905119437, 2026-09-23).
    private let lock = NSLock()
    var followError: Error?
    var unfollowError: Error?
    /// When set, `follow` waits on it before answering.
    var followGate: SocialGate?
    var following: Set<String> = []
    var isFollowingError: Error?
    var followedBatchError: Error?
    var familyMemberships: Set<String> = []
    var familyMembershipError: Error?
    var memberIDsError: Error?
    var followedPetsList: [FollowedPet] = []
    var followedPetsError: Error?
    var followerPages: [[PetFollower]] = []
    var followersError: Error?
    /// Fails the read of this page index only.
    var followersErrorOnPage: Int?
    var profiles: [String: PublicProfile] = [:]
    var profileError: Error?
    var petsByUser: [String: [ProfilePet]] = [:]
    var petsError: Error?
    var blocked: Set<String> = []
    var blockedError: Error?
    var unblockError: Error?

    private(set) var followCalls: [String] = []
    private(set) var unfollowCalls: [String] = []
    private(set) var isFollowingReads = 0
    private(set) var batchReads: [[String]] = []
    private(set) var memberIDReads = 0
    private(set) var followerCursors: [PageCursor?] = []
    private(set) var profileReads = 0
    private(set) var petReads = 0
    private(set) var blockedReads = 0
    private(set) var unblocked: [String] = []
    private var issued: [PageCursor] = []

    func follow(petID: String) async throws {
        lock.withLock { followCalls.append(petID) }
        if let followGate { await followGate.wait() }
        if let followError { throw followError }
        lock.withLock { _ = following.insert(petID) }
    }

    func unfollow(petID: String) async throws {
        lock.withLock { unfollowCalls.append(petID) }
        if let unfollowError { throw unfollowError }
        lock.withLock { _ = following.remove(petID) }
    }

    func isFollowing(petID: String, viewerID: String) async throws -> Bool {
        lock.withLock { isFollowingReads += 1 }
        if let isFollowingError { throw isFollowingError }
        return lock.withLock { following.contains(petID) }
    }

    func followedPetIDs(among petIDs: [String], viewerID: String) async throws -> Set<String> {
        lock.withLock { batchReads.append(petIDs) }
        if let followedBatchError { throw followedBatchError }
        return lock.withLock { following.intersection(petIDs) }
    }

    func followedPets(viewerID: String, limit: Int) async throws -> [FollowedPet] {
        if let followedPetsError { throw followedPetsError }
        return followedPetsList
    }

    func followers(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<PetFollower> {
        lock.withLock { followerCursors.append(cursor) }
        if cursor == nil { issued.removeAll() }
        let index: Int
        if let cursor, let position = issued.firstIndex(of: cursor) {
            index = position + 1
        } else {
            index = 0
        }
        if let followersError, followersErrorOnPage == nil || followersErrorOnPage == index {
            throw followersError
        }
        guard index < followerPages.count else { return .empty }
        var next: PageCursor?
        if index + 1 < followerPages.count {
            let token = PageCursor()
            lock.withLock { issued.append(token) }
            next = token
        }
        return Page(items: followerPages[index], next: next)
    }

    func isFamilyMember(petID: String, userID: String) async throws -> Bool {
        if let familyMembershipError { throw familyMembershipError }
        return familyMemberships.contains(petID)
    }

    func pets(ofUser userID: String) async throws -> [ProfilePet] {
        lock.withLock { petReads += 1 }
        if let petsError { throw petsError }
        return petsByUser[userID] ?? []
    }

    func memberPetIDs(userID: String) async throws -> Set<String> {
        lock.withLock { memberIDReads += 1 }
        if let memberIDsError { throw memberIDsError }
        return familyMemberships
    }

    func profile(userID: String) async throws -> PublicProfile? {
        lock.withLock { profileReads += 1 }
        if let profileError { throw profileError }
        return profiles[userID]
    }

    func blockedUserIDs(viewerID: String) async throws -> Set<String> {
        lock.withLock { blockedReads += 1 }
        if let blockedError { throw blockedError }
        return lock.withLock { blocked }
    }

    var blockError: Error?
    private(set) var blockedNow: [String] = []

    func block(userID: String, viewerID: String) async throws {
        lock.withLock { blockedNow.append(userID) }
        if let blockError { throw blockError }
        lock.withLock { _ = blocked.insert(userID) }
    }

    func unblock(userID: String, viewerID: String) async throws {
        lock.withLock { unblocked.append(userID) }
        if let unblockError { throw unblockError }
        lock.withLock { _ = blocked.remove(userID) }
    }
}

/// `PetRepository`'s reads, for the family screen.
final class FakeFamilyPets: PetRepository, @unchecked Sendable {
    var pet: Pet?
    var petError: Error?
    var family: [PetFamilyMember] = []
    /// Per pet, for tests that look at more than one; falls back to `family`.
    var familiesByPet: [String: [PetFamilyMember]] = [:]
    var familyError: Error?
    private(set) var familyReads = 0

    func pet(id: String) async throws -> Pet? {
        if let petError { throw petError }
        return pet
    }

    func family(petID: String) async throws -> [PetFamilyMember] {
        familyReads += 1
        if let familyError { throw familyError }
        return familiesByPet[petID] ?? family
    }

    func posts(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Post> { .empty }
    func checkins(petID: String, limit: Int) async throws -> [PetCheckin] { [] }
    func create(_ draft: PetDraft) async throws -> String { "unused" }
    func update(petID: String, changes: PetChanges) async throws {}
    func delete(petID: String) async throws -> PetDeletion { PetDeletion(resumed: false) }
}

final class FakeFamilyRepository: FamilyRepository, @unchecked Sendable {
    var active: Invitation?
    var activeError: Error?
    var createResult: Result<Invitation, Error> = .success(SocialFixture.invitation())
    /// Applied to `active` when a create that "failed" actually landed.
    var createLandsDespiteError = false
    var revokeError: Error?
    var checkResult: Result<InvitationCheck, Error> = .success(.valid(petID: "pet-1", petName: "Mochi"))
    var redeemResults: [Result<JoinedPet, Error>] = [.success(JoinedPet(petID: "pet-1", petName: "Mochi"))]
    var removeResult: Result<FamilyRemoval, Error> = .success(.memberRemoved)
    var transferResult: Result<Bool, Error> = .success(false)
    var members: Set<String> = []
    var isMemberError: Error?
    /// Called after a removal or transfer "reaches the server", so a test can
    /// change what the next family read returns.
    var onMutation: (@Sendable () -> Void)?

    private(set) var activeReads = 0
    private(set) var creates = 0
    private(set) var revoked: [String] = []
    private(set) var checked: [String] = []
    private(set) var redeemed: [(code: String, relationship: PetFamilyRelationship, custom: String?)] = []
    private(set) var removed: [String] = []
    private(set) var transferred: [String] = []
    private(set) var memberReads = 0

    func activeInvitation(petID: String) async throws -> Invitation? {
        activeReads += 1
        if let activeError { throw activeError }
        return active
    }

    func createInvitation(petID: String) async throws -> Invitation {
        creates += 1
        switch createResult {
        case .success(let invitation):
            active = invitation
            return invitation
        case .failure(let error):
            if createLandsDespiteError { active = SocialFixture.invitation() }
            throw error
        }
    }

    func revokeInvitation(petID: String, code: String) async throws -> Bool {
        revoked.append(code)
        if let revokeError { throw revokeError }
        active = nil
        return false
    }

    func validateInvitation(code: String) async throws -> InvitationCheck {
        checked.append(code)
        return try checkResult.get()
    }

    func redeemInvitation(
        code: String, relationship: PetFamilyRelationship, customRelationship: String?
    ) async throws -> JoinedPet {
        redeemed.append((code, relationship, customRelationship))
        let result = redeemResults.count > 1 ? redeemResults.removeFirst() : redeemResults[0]
        return try result.get()
    }

    func removeMember(petID: String, userID: String) async throws -> FamilyRemoval {
        removed.append(userID)
        onMutation?()
        return try removeResult.get()
    }

    func transferPrimary(petID: String, to userID: String) async throws -> Bool {
        transferred.append(userID)
        onMutation?()
        return try transferResult.get()
    }

    func isMember(petID: String, userID: String) async throws -> Bool {
        memberReads += 1
        if let isMemberError { throw isMemberError }
        return members.contains(userID)
    }
}

final class FakeSearchRepository: SearchRepository, @unchecked Sendable {
    /// Every record below is taken under this lock. The models that use
    /// these fakes read with `async let`, so the calls arrive on several
    /// threads at once; an unlocked append crashed a CI run (SIGSEGV in
    /// `posts(since:limit:)`, run 35905119437, 2026-09-23).
    private let lock = NSLock()
    var peopleResult: [PublicProfile] = []
    var petResult: [Pet] = []
    var tagResult: [Hashtag] = []
    var postResult: [Post] = []
    var searchError: Error?
    /// When set, the people read waits on it, so a slow search can be
    /// overtaken by a newer one.
    var peopleGate: SocialGate?
    var counts: [String: Int] = [:]
    var countsError: Error?
    var popularTagResult: [Hashtag] = []
    var popularTagError: Error?
    /// Holds the tags read open, so a test can make it answer *after* the
    /// other modules — the only order in which "one failure empties the
    /// others" is visible.
    var popularTagGate: SocialGate?
    var recentPosts: [Post] = []
    var recentError: Error?
    var byFollowers: [Pet] = []
    var byFollowersError: Error?
    var byPostCount: [Pet] = []
    var byPostCountError: Error?
    var latest: [Post] = []
    var petsByID: [String: Pet] = [:]

    private(set) var peopleQueries: [String] = []
    private(set) var postQueries: [(tag: String, limit: Int)] = []
    private(set) var countQueries: [[String]] = []
    private(set) var sinceQueries: [(date: Date, limit: Int)] = []
    private(set) var latestReads = 0

    func people(prefix: String, limit: Int) async throws -> [PublicProfile] {
        lock.withLock { peopleQueries.append(prefix) }
        let gate = lock.withLock { () -> SocialGate? in
            defer { peopleGate = nil }
            return peopleGate
        }
        if let gate { await gate.wait() }
        if let searchError { throw searchError }
        return peopleResult
    }

    func pets(prefix: String, limit: Int) async throws -> [Pet] {
        if let searchError { throw searchError }
        return petResult
    }

    func tags(prefix: String, limit: Int) async throws -> [Hashtag] {
        if let searchError { throw searchError }
        return tagResult
    }

    func posts(taggedWith tag: String, limit: Int) async throws -> [Post] {
        lock.withLock { postQueries.append((tag, limit)) }
        if let searchError { throw searchError }
        return postResult
    }

    func petCounts(forUsers userIDs: [String]) async throws -> [String: Int] {
        lock.withLock { countQueries.append(userIDs) }
        if let countsError { throw countsError }
        return counts
    }

    func popularTags(limit: Int) async throws -> [Hashtag] {
        if let popularTagGate { await popularTagGate.wait() }
        if let popularTagError { throw popularTagError }
        return popularTagResult
    }

    func posts(since date: Date, limit: Int) async throws -> [Post] {
        lock.withLock { sinceQueries.append((date, limit)) }
        if let recentError { throw recentError }
        return recentPosts
    }

    func petsByFollowers(limit: Int) async throws -> [Pet] {
        if let byFollowersError { throw byFollowersError }
        return byFollowers
    }

    func petsByPostCount(limit: Int) async throws -> [Pet] {
        if let byPostCountError { throw byPostCountError }
        return byPostCount
    }

    func latestPosts(limit: Int) async throws -> [Post] {
        lock.withLock { latestReads += 1 }
        return latest
    }

    func pets(ids: [String]) async throws -> [Pet] {
        ids.compactMap { petsByID[$0] }
    }
}

enum SocialFixture {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let readFailure = SocialError.transport("test")

    static func pet(
        _ id: String,
        name: String? = nil,
        ownerID: String = "alice",
        followers: Int = 0,
        posts: Int = 0
    ) -> Pet {
        Pet(
            id: id, ownerID: ownerID, primaryOwnerID: ownerID, name: name ?? "Pet \(id)",
            species: .cat, breed: "", gender: .unknown, bio: "", avatarURL: nil,
            birthday: nil, birthdayMonth: nil, birthdayDay: nil,
            followerCount: followers, postCount: posts, createdAt: date
        )
    }

    static func member(
        _ id: String, role: PetFamilyRole = .member, joinedAt: Date? = date
    ) -> PetFamilyMember {
        PetFamilyMember(
            id: id, userName: id.capitalized, userAvatarURL: nil, relationship: .caretaker,
            customRelationship: nil, role: role, joinedAt: joinedAt
        )
    }

    static func profile(_ id: String, name: String? = nil, following: Int? = 2) -> PublicProfile {
        PublicProfile(
            id: id, displayName: name ?? id.capitalized, avatarURL: nil, bio: "",
            city: "", state: "", followingPetsCount: following, createdAt: date
        )
    }

    static func profilePet(_ pet: Pet, role: PetFamilyRole = .member) -> ProfilePet {
        ProfilePet(pet: pet, relationship: .dad, customRelationship: nil, role: role)
    }

    static func post(
        _ id: String,
        author: String = "alice",
        petID: String? = "pet-1",
        likes: Int = 0,
        createdAt: Date = date
    ) -> Post {
        Post(
            id: id, authorID: author, authorName: author.capitalized, authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: petID, petName: nil,
            petAvatarURL: nil, createdAt: createdAt, likeCount: likes, commentCount: 0, tags: []
        )
    }

    static func follower(_ id: String) -> PetFollower {
        PetFollower(id: id, userName: id.capitalized, userAvatarURL: nil, followedAt: date)
    }

    static func invitation(
        code: String = "ABCD2345", expiresIn seconds: TimeInterval = 47 * 3600
    ) -> Invitation {
        Invitation(
            code: code, createdBy: "alice", createdByName: "Alice",
            expiresAt: Date().addingTimeInterval(seconds), petID: "pet-1"
        )
    }
}
