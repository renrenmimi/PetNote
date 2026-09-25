import Foundation

// MARK: - TEMPORARY LOCATION
//
// Everything in this file is *shared-layer* material: `Pet` and its enums
// belong in `Core/Model/Pet.swift`, and `PetDecoder` next to `PostDecoder`.
// They live here because `Core/Model` is the coordinator's, and this batch
// needed them before they existed. Moving the file is a cut-and-paste — no
// call site refers to its path.
//
// Listed in the batch report as a request, not left as a surprise.

/// A pet, already normalized. Anything holding a `Pet` can assume the counts
/// are non-negative and that `avatarURL` is an http(s) URL — that is what
/// decoding through `PetDecoder` buys.
struct Pet: Sendable, Equatable, Identifiable {
    let id: String

    /// **The pet's *current* primary owner — not its creator.**
    ///
    /// This is the field the migration is most likely to get wrong, so it is
    /// spelled out here rather than only in the server. `pets/{id}.ownerId`
    /// and `.primaryOwnerId` were the creator's uid forever and every
    /// management check compared against them; they have been *redefined* to
    /// name whoever currently holds the primary role, and they move when that
    /// person leaves or hands it on (functions/src/family.ts
    /// `releasePetMembership`, `transferPetPrimaryCallable`).
    ///
    /// **Nothing in the app may decide a permission from this field alone.**
    /// Authority comes from `pets/{id}/family/{uid}`; see `PetOwnership`.
    let ownerID: String
    /// Kept separate because the documents carry both. They are held in sync
    /// by the server, and the one place the two can disagree is legacy data,
    /// which `PetOwnership` handles by treating either as the fallback.
    let primaryOwnerID: String

    let name: String
    let species: PetSpecies
    let breed: String
    let gender: PetGender
    let bio: String
    let avatarURL: URL?

    /// The legacy display timestamp ("Born: 1 Jun 2020").
    let birthday: Date?
    /// The canonical, timezone-safe birthday. Written by the callable
    /// alongside `birthday` precisely so "is it their birthday today?" is not
    /// answered by converting two timestamps in two different zones.
    let birthdayMonth: Int?
    let birthdayDay: Int?

    let followerCount: Int
    let postCount: Int
    let createdAt: Date?
}

/// The species the server accepts (`allowedPetSpecies`, functions/src/pets.ts).
///
/// A raw value outside the set decodes to `.other` rather than failing, which
/// is what the server does with an unrecognised value on write.
enum PetSpecies: String, Sendable, Equatable, CaseIterable {
    case dog, cat, bird, rabbit, hamster, fish, reptile, other
}

/// `allowedPetGenders`. Unrecognised decodes to `.unknown`, as the server
/// defaults it.
enum PetGender: String, Sendable, Equatable, CaseIterable {
    case male, female, unknown
}

/// How one human describes their relationship to the pet.
///
/// Self-declared and carrying **no authority** — the server's comment on
/// `pickSuccessor` says so explicitly, and it is worth repeating at the point
/// somebody might be tempted to read "mom" as a permission. Only `role`
/// decides anything.
enum PetFamilyRelationship: String, Sendable, Equatable, CaseIterable {
    case mom, dad, brother, sister, grandma, grandpa
    case auntie, uncle
    case bestFriend = "best_friend"
    case caretaker
    case other
}

/// The one asymmetry the equal-ownership model keeps.
///
/// `primary` is not "the owner" — every member is an owner. It is who may
/// remove *somebody else*, and it is transferable.
enum PetFamilyRole: String, Sendable, Equatable {
    case primary
    case member
}

/// One human in a pet's family. The authority record.
struct PetFamilyMember: Sendable, Equatable, Identifiable {
    /// The document id, which is the uid.
    let id: String
    let userName: String
    let userAvatarURL: URL?
    let relationship: PetFamilyRelationship
    let customRelationship: String?
    let role: PetFamilyRole
    let joinedAt: Date?
}

/// One row of a pet's check-in history, as `getPetCheckinsCallable` returns it.
///
/// Deliberately carries no user identity: the callable does not send
/// userId/userName/userAvatar, because leaving the `checkins` collection group
/// open turned any uid into a movement timeline and the pet page never
/// rendered those fields anyway.
struct PetCheckin: Sendable, Equatable, Identifiable {
    let id: String
    let locationID: String
    let petID: String
    let petName: String
    let photoURL: URL?
    let caption: String
    let createdAt: Date?
}

// MARK: - Ownership

/// Who this viewer is to this pet, and therefore what the screen may offer.
///
/// **The contract this type exists to hold.** PetNote's premise is one pet with
/// several *equal* human owners. The data model was built around a privileged
/// creator, and the fix redefined rather than removed the two fields on the pet
/// document — so the tempting shortcut, `pet.ownerId == myUid`, is now wrong in
/// two opposite directions at once:
///
///   - it says **no** to a co-owner who joined by invitation and may edit;
///   - it says **yes** to somebody who was removed from the family but whose
///     uid is still sitting in a stale `ownerId`.
///
/// So this mirrors `getPetFamilyAuthority` (functions/src/pets.ts) exactly,
/// including the deliberately narrow legacy fallback: the pet document's
/// fields are trusted **only when the family subcollection is empty**. A
/// subcollection that exists and does not list you means you were removed, and
/// a stale `ownerId` must not let you back in.
///
/// The rights split, from the same source:
///
///   - everything **additive** is equal — edit the profile, invite, post;
///   - the two **destructive** acts converge — deleting the pet takes being
///     the last owner left, and removing another owner is the primary's alone.
struct PetOwnership: Sendable, Equatable {
    /// May contribute and manage: edit the profile, invite, revoke.
    let isMember: Bool
    /// May remove other members and transfer the role.
    let isPrimary: Bool
    /// Humans in this pet's family, counting the viewer.
    let memberCount: Int
    /// Membership was inferred from `ownerId`/`primaryOwnerId` because the
    /// family subcollection is empty. Surfaced so a screen can tell the two
    /// apart if it ever needs to; nothing in this batch branches on it.
    let legacyOwnerFallback: Bool
    /// Moderator override. The server grants it on update and delete
    /// (`caller.role === "admin"`), so the client has to know about it or the
    /// UI would hide a control the server would honour.
    let isAdmin: Bool

    /// A viewer with no relationship to the pet at all — signed out, or just
    /// somebody looking.
    static let none = PetOwnership(
        isMember: false, isPrimary: false, memberCount: 0,
        legacyOwnerFallback: false, isAdmin: false
    )

    /// Editing the profile is the least "co-owner" can mean. Restricting it to
    /// the creator was the clearest place the implementation contradicted the
    /// product, and hiding the button was the visible half of it.
    var canEdit: Bool { isMember || isAdmin }

    /// Deleting destroys a history belonging to everyone attached to the pet,
    /// so it takes being the only one left. Anyone else *leaves* instead —
    /// which hands the pet on rather than taking it away.
    ///
    /// Leaving is batch 3. Until it exists, a co-owner correctly sees no
    /// delete control and no leave control; that is a missing feature, not a
    /// wrong permission, and it is named in the batch report.
    var canDelete: Bool { (isMember && memberCount <= 1) || isAdmin }

    /// Removing *another* owner, and handing the role on. Both are batch 3;
    /// computed here because the rule belongs with the rest of the split and
    /// splitting it across batches is how the two drift apart.
    var canManageOtherOwners: Bool { isPrimary || isAdmin }

    /// The pet's family read is capped, exactly as the server caps it
    /// (`PET_FAMILY_READ_LIMIT`). A family is a handful of humans; the cap
    /// stops a corrupted subcollection turning an authorization read into an
    /// unbounded one. `canDelete` asks whether the count is ≤ 1, so the cap
    /// can never change that answer.
    static let familyReadLimit = 50

    /// The mirror of `getPetFamilyAuthority`.
    ///
    /// - Parameter viewerID: nil for a signed-out viewer, who is never a
    ///   member. Passing an empty string would otherwise match an empty
    ///   `ownerId` on a malformed document, so nil and "" are both refused.
    static func resolve(
        pet: Pet,
        family: [PetFamilyMember],
        viewerID: String?,
        isAdmin: Bool = false
    ) -> PetOwnership {
        guard let viewerID, !viewerID.isEmpty else {
            return PetOwnership(
                isMember: false, isPrimary: false, memberCount: family.count,
                legacyOwnerFallback: false, isAdmin: isAdmin
            )
        }

        let own = family.first { $0.id == viewerID }
        // Only when there is no family subcollection *at all*. This is the
        // narrowness that matters: with it, a removed co-owner whose uid is
        // still in a stale `ownerId` is correctly not a member.
        let legacyOwnerFallback =
            family.isEmpty && (pet.ownerID == viewerID || pet.primaryOwnerID == viewerID)

        return PetOwnership(
            isMember: own != nil || legacyOwnerFallback,
            isPrimary: own?.role == .primary || legacyOwnerFallback,
            memberCount: family.isEmpty && legacyOwnerFallback ? 1 : family.count,
            legacyOwnerFallback: legacyOwnerFallback,
            isAdmin: isAdmin
        )
    }
}

// MARK: - Birthday

extension Pet {
    /// Whether today is this pet's birthday, in the *viewer's* calendar.
    ///
    /// Prefers the canonical month/day the callable writes. The fallback path
    /// reads the legacy timestamp's **UTC** fields, which is what the server
    /// does when it derives the pair, so an old pet answers the same question
    /// the same way wherever it is asked — a pet stored as
    /// 2020-06-01T00:00:00Z is recognised on 6/1 everywhere, instead of 5/31
    /// for every viewer west of Greenwich.
    func isBirthday(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.dateComponents([.month, .day], from: date)
        guard let todayMonth = today.month, let todayDay = today.day else { return false }

        if let month = birthdayMonth, let day = birthdayDay {
            return month == todayMonth && day == todayDay
        }
        guard let birthday else { return false }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let legacy = utc.dateComponents([.month, .day], from: birthday)
        return legacy.month == todayMonth && legacy.day == todayDay
    }
}
