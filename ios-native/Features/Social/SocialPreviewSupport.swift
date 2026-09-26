#if DEBUG
import Foundation

// Stand-ins so the social, family and search previews can render.
//
// `#if DEBUG` because they are development scaffolding. **Not a test hook**:
// nothing here reads a launch argument, an environment variable or a defaults
// key, so there is no channel from outside the process into any of it. A
// preview cannot use the real repositories — `Firestore.firestore()` needs a
// configured Firebase app, and the canvas has none.

enum PreviewSocialData {
    static let date = Date(timeIntervalSince1970: 1_750_000_000)

    static func pet(_ id: String, _ name: String, followers: Int = 12, posts: Int = 4) -> Pet {
        Pet(
            id: id, ownerID: "alice", primaryOwnerID: "alice", name: name,
            species: .dog, breed: "Shiba Inu", gender: .female, bio: "", avatarURL: nil,
            birthday: nil, birthdayMonth: nil, birthdayDay: nil,
            followerCount: followers, postCount: posts, createdAt: date
        )
    }

    static let pets = [
        pet("pet-1", "Mochi"),
        pet("pet-2", "A very long pet name that wraps", followers: 3, posts: 9),
        pet("pet-3", "Tofu", followers: 40, posts: 1),
    ]

    static func post(_ id: String, _ text: String) -> Post {
        Post(
            id: id, authorID: "alice", authorName: "Alice", authorAvatarURL: nil, text: text,
            media: [], petID: "pet-1", petName: "Mochi", petAvatarURL: nil, createdAt: date,
            likeCount: 3, commentCount: 1, tags: ["shiba", "walk"]
        )
    }

    static let profile = PublicProfile(
        id: "alice", displayName: "Alice", avatarURL: nil, bio: "Two dogs, one very loud.",
        city: "Boston", state: "MA", followingPetsCount: 7, createdAt: date
    )
}

struct PreviewSocialRepository: SocialRepository {
    func follow(petID: String) async throws {}
    func unfollow(petID: String) async throws {}
    func isFollowing(petID: String, viewerID: String) async throws -> Bool { false }
    func followedPetIDs(among petIDs: [String], viewerID: String) async throws -> Set<String> { ["pet-3"] }
    func followedPets(viewerID: String, limit: Int) async throws -> [FollowedPet] {
        [FollowedPet(id: "pet-1", petName: "Mochi", petAvatarURL: nil, followedAt: PreviewSocialData.date)]
    }
    func followers(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<PetFollower> {
        Page(items: [
            PetFollower(id: "bob", userName: "Bob", userAvatarURL: nil, followedAt: PreviewSocialData.date),
            PetFollower(id: "carol", userName: "Carol", userAvatarURL: nil, followedAt: PreviewSocialData.date),
        ], next: nil)
    }
    func isFamilyMember(petID: String, userID: String) async throws -> Bool { false }
    func pets(ofUser userID: String) async throws -> [ProfilePet] {
        PreviewSocialData.pets.map {
            ProfilePet(pet: $0, relationship: .mom, customRelationship: nil, role: .primary)
        }
    }
    func memberPetIDs(userID: String) async throws -> Set<String> { [] }
    func profile(userID: String) async throws -> PublicProfile? { PreviewSocialData.profile }
    func blockedUserIDs(viewerID: String) async throws -> Set<String> { [] }
    func block(userID: String, viewerID: String) async throws {}
    func unblock(userID: String, viewerID: String) async throws {}
}

struct PreviewFamilyRepository: FamilyRepository {
    func activeInvitation(petID: String) async throws -> Invitation? {
        Invitation(
            code: "ABCD2345", createdBy: "me", createdByName: "Me",
            expiresAt: Date().addingTimeInterval(47 * 3600), petID: petID
        )
    }
    func createInvitation(petID: String) async throws -> Invitation {
        try await activeInvitation(petID: petID) ?? Invitation(
            code: "ABCD2345", createdBy: "me", createdByName: "Me", expiresAt: Date(), petID: petID
        )
    }
    func revokeInvitation(petID: String, code: String) async throws -> Bool { false }
    func validateInvitation(code: String) async throws -> InvitationCheck {
        .valid(petID: "pet-1", petName: "Mochi")
    }
    func redeemInvitation(
        code: String, relationship: PetFamilyRelationship, customRelationship: String?
    ) async throws -> JoinedPet {
        JoinedPet(petID: "pet-1", petName: "Mochi")
    }
    func removeMember(petID: String, userID: String) async throws -> FamilyRemoval { .memberRemoved }
    func transferPrimary(petID: String, to userID: String) async throws -> Bool { false }
    func isMember(petID: String, userID: String) async throws -> Bool { true }
}

/// The pet reads the family screen needs, for previews only.
struct PreviewFamilyPets: PetRepository {
    func pet(id: String) async throws -> Pet? { PreviewSocialData.pet(id, "Mochi") }
    func family(petID: String) async throws -> [PetFamilyMember] {
        [
            PetFamilyMember(
                id: "me", userName: "Me", userAvatarURL: nil, relationship: .mom,
                customRelationship: nil, role: .primary, joinedAt: PreviewSocialData.date
            ),
            PetFamilyMember(
                id: "bob", userName: "Bob with a rather long display name", userAvatarURL: nil,
                relationship: .other, customRelationship: "Dog walker",
                role: .member, joinedAt: PreviewSocialData.date
            ),
        ]
    }
    func posts(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Post> { .empty }
    func checkins(petID: String, limit: Int) async throws -> [PetCheckin] { [] }
    func create(_ draft: PetDraft) async throws -> String { "pet-1" }
    func update(petID: String, changes: PetChanges) async throws {}
    func delete(petID: String) async throws -> PetDeletion { PetDeletion(resumed: false) }
}

struct PreviewSearchRepository: SearchRepository {
    func people(prefix: String, limit: Int) async throws -> [PublicProfile] { [PreviewSocialData.profile] }
    func pets(prefix: String, limit: Int) async throws -> [Pet] { PreviewSocialData.pets }
    func tags(prefix: String, limit: Int) async throws -> [Hashtag] {
        [Hashtag(name: "shiba", postCount: 12), Hashtag(name: "shibainu", postCount: 1)]
    }
    func posts(taggedWith tag: String, limit: Int) async throws -> [Post] {
        [PreviewSocialData.post("p1", "Morning walk in the snow.")]
    }
    func petCounts(forUsers userIDs: [String]) async throws -> [String: Int] { ["alice": 2] }
    func popularTags(limit: Int) async throws -> [Hashtag] {
        [Hashtag(name: "dog", postCount: 20), Hashtag(name: "cat", postCount: 8)]
    }
    func posts(since date: Date, limit: Int) async throws -> [Post] {
        (1...9).map { PreviewSocialData.post("t\($0)", "Trending post \($0)") }
    }
    func petsByFollowers(limit: Int) async throws -> [Pet] { PreviewSocialData.pets }
    func petsByPostCount(limit: Int) async throws -> [Pet] { PreviewSocialData.pets }
    func latestPosts(limit: Int) async throws -> [Post] { [] }
    func pets(ids: [String]) async throws -> [Pet] { [] }
}
#endif
