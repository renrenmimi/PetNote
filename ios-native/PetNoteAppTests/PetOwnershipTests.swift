import Foundation
import Testing

@testable import PetNote

/// The shared-owner contract, which is the part of this batch most likely to
/// be got wrong quietly.
///
/// PetNote's premise is one pet with several **equal** human owners, but the
/// data model was built around a privileged creator: `pets/{id}.ownerId` and
/// `.primaryOwnerId` were the creator's uid forever. The fix *redefined* those
/// fields rather than removing them — they now name the pet's **current**
/// primary owner and they move — and put the authority in
/// `pets/{id}/family/{uid}`.
///
/// So `pet.ownerId == myUid` is now wrong in both directions, and each
/// direction gets its own test below: it refuses a co-owner who may edit, and
/// it admits somebody who was removed but whose uid is still sitting in a
/// stale field.
///
/// Every expectation here is read off `getPetFamilyAuthority` in
/// functions/src/pets.ts. If the two disagree, the server wins and this file
/// is the bug.
struct PetOwnershipTests {
    // MARK: - Additive rights are equal

    @Test func aCoOwnerWhoIsNotNamedOnThePetMayStillEditIt() {
        let pet = PetFixture.pet(ownerID: "alice")
        let family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]

        let ownership = PetOwnership.resolve(pet: pet, family: family, viewerID: "bob")

        #expect(ownership.isMember)
        #expect(ownership.canEdit, """
            A co-owner could not edit the pet. That was the visible half of the \
            pet having a privileged creator, and it is the thing the family \
            authority exists to fix.
            """)
        #expect(!ownership.isPrimary)
        #expect(ownership.memberCount == 2)
    }

    /// The role is a *family* fact. A stale `primaryOwnerId` must not confer
    /// it, or the one asymmetry the model keeps could be taken rather than
    /// given.
    @Test func thePrimaryRoleComesFromTheFamilyDocumentAndNotFromThePetFields() {
        let pet = PetFixture.pet(ownerID: "bob", primaryOwnerID: "bob")
        let family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob", role: .member),
        ]

        let ownership = PetOwnership.resolve(pet: pet, family: family, viewerID: "bob")

        #expect(ownership.isMember)
        #expect(!ownership.isPrimary, "a stale primaryOwnerId handed out the primary role")
        #expect(!ownership.canManageOtherOwners)
    }

    // MARK: - A stale owner field is not a way back in

    @Test func aRemovedOwnerIsNotLetBackInByAStaleOwnerField() {
        // Carol created the pet, so her uid is still in `ownerId`; she has
        // since been removed from the family.
        let pet = PetFixture.pet(ownerID: "carol", primaryOwnerID: "carol")
        let family = [PetFixture.member("alice", role: .primary)]

        let ownership = PetOwnership.resolve(pet: pet, family: family, viewerID: "carol")

        #expect(!ownership.isMember, """
            A family subcollection that exists and does not list you means you \
            were removed. Trusting ownerId there is how a removed owner keeps \
            editing a pet.
            """)
        #expect(!ownership.canEdit)
        #expect(!ownership.canDelete)
    }

    @Test func theLegacyFallbackAppliesOnlyWhenTheFamilyIsCompletelyEmpty() {
        let pet = PetFixture.pet(ownerID: "carol", primaryOwnerID: "carol")

        let fallback = PetOwnership.resolve(pet: pet, family: [], viewerID: "carol")
        #expect(fallback.isMember)
        #expect(fallback.isPrimary)
        #expect(fallback.legacyOwnerFallback)
        #expect(fallback.memberCount == 1, """
            A pet with no family subcollection has exactly one owner — the \
            person the fallback just recognised — and memberCount is what \
            decides whether it may be deleted.
            """)
    }

    @Test func eitherOwnerFieldSatisfiesTheLegacyFallback() {
        // Legacy data where only one of the two fields was ever written.
        let onlyPrimary = Pet(
            id: "pet-1", ownerID: "", primaryOwnerID: "dana", name: "Mochi",
            species: .cat, breed: "", gender: .unknown, bio: "", avatarURL: nil,
            birthday: nil, birthdayMonth: nil, birthdayDay: nil,
            followerCount: 0, postCount: 0, createdAt: nil
        )

        let ownership = PetOwnership.resolve(pet: onlyPrimary, family: [], viewerID: "dana")

        #expect(ownership.isMember)
        #expect(ownership.isPrimary)
    }

    // MARK: - Destructive rights converge

    @Test func deletingThePetNeedsToBeTheLastOwnerLeft() {
        let pet = PetFixture.pet(ownerID: "alice")
        let shared = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]

        let whileShared = PetOwnership.resolve(pet: pet, family: shared, viewerID: "alice")
        #expect(whileShared.canEdit)
        #expect(!whileShared.canDelete, """
            Deleting destroys a history belonging to everyone attached to the \
            pet, so the primary owner alone is not enough — being the only \
            owner left is.
            """)

        let alone = PetOwnership.resolve(
            pet: pet, family: [PetFixture.member("alice", role: .primary)], viewerID: "alice"
        )
        #expect(alone.canDelete)
    }

    @Test func onlyThePrimaryMayManageTheOtherOwners() {
        let pet = PetFixture.pet(ownerID: "alice")
        let family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]

        #expect(PetOwnership.resolve(pet: pet, family: family, viewerID: "alice").canManageOtherOwners)
        #expect(!PetOwnership.resolve(pet: pet, family: family, viewerID: "bob").canManageOtherOwners)
    }

    // MARK: - Viewers who are nobody

    @Test func aSignedOutViewerIsNeverAnOwner() {
        let pet = PetFixture.pet(ownerID: "alice")

        let ownership = PetOwnership.resolve(pet: pet, family: [], viewerID: nil)

        #expect(!ownership.isMember)
        #expect(!ownership.canEdit)
        #expect(!ownership.canDelete)
    }

    /// A malformed document with an empty `ownerId` must not match a viewer
    /// whose id is also empty — which is what an uninitialised session looks
    /// like.
    @Test func anEmptyViewerIdDoesNotMatchAnEmptyOwnerField() {
        let orphan = Pet(
            id: "pet-1", ownerID: "", primaryOwnerID: "", name: "Mochi",
            species: .other, breed: "", gender: .unknown, bio: "", avatarURL: nil,
            birthday: nil, birthdayMonth: nil, birthdayDay: nil,
            followerCount: 0, postCount: 0, createdAt: nil
        )

        let ownership = PetOwnership.resolve(pet: orphan, family: [], viewerID: "")

        #expect(!ownership.isMember)
        #expect(!ownership.canDelete)
    }

    // MARK: - The moderator override

    /// The server grants it (`caller.role === "admin"`) on both update and
    /// delete, so the client has to know about it or it would hide a control
    /// the server would honour.
    @Test func anAdminMayEditAndDeleteWithoutBeingInTheFamily() {
        let pet = PetFixture.pet(ownerID: "alice")
        let family = [
            PetFixture.member("alice", role: .primary),
            PetFixture.member("bob"),
        ]

        let ownership = PetOwnership.resolve(
            pet: pet, family: family, viewerID: "moderator", isAdmin: true
        )

        #expect(!ownership.isMember, "an admin is not an owner; they are an override")
        #expect(ownership.canEdit)
        #expect(ownership.canDelete, "the admin override survives the pet having other owners")
    }
}
