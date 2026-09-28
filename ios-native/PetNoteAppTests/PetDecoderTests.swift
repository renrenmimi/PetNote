import Foundation
import Testing

@testable import PetNote

/// `PetDecoder` is the whole normalization contract for pets, and it is a pure
/// function over a dictionary so the contract is checkable without Firebase
/// behind it.
struct PetDecoderTests {
    // MARK: - The pet document

    @Test func decodesAFullPetDocument() throws {
        let pet = try #require(PetDecoder.pet(id: "pet-1", from: [
            "ownerId": "alice",
            "primaryOwnerId": "alice",
            "name": "Mochi",
            "species": "dog",
            "breed": "Shiba",
            "gender": "female",
            "bio": "TEST CONTENT bio",
            "avatarUrl": "https://res.cloudinary.com/demo/image/upload/a.jpg",
            "birthdayMonth": 6,
            "birthdayDay": 1,
            "followerCount": 12,
            "postCount": 4,
        ]))

        #expect(pet.name == "Mochi")
        #expect(pet.species == .dog)
        #expect(pet.gender == .female)
        #expect(pet.breed == "Shiba")
        #expect(pet.birthdayMonth == 6)
        #expect(pet.birthdayDay == 1)
        #expect(pet.followerCount == 12)
        #expect(pet.postCount == 4)
    }

    @Test func refusesADocumentWithNoUsableName() {
        #expect(PetDecoder.pet(id: "pet-1", from: ["ownerId": "alice"]) == nil)
        #expect(PetDecoder.pet(id: "pet-1", from: ["ownerId": "alice", "name": "   "]) == nil)
    }

    /// Both counts are trigger-maintained, and a create→delete race inside
    /// trigger latency can drive one negative. "-1 followers" must not reach
    /// the screen.
    @Test func clampsNegativeCountsAtZero() throws {
        let pet = try #require(PetDecoder.pet(id: "pet-1", from: [
            "name": "Mochi", "followerCount": -3, "postCount": -1,
        ]))

        #expect(pet.followerCount == 0)
        #expect(pet.postCount == 0)
    }

    @Test func degradesAnUnknownSpeciesAndGenderRatherThanDroppingThePet() throws {
        let pet = try #require(PetDecoder.pet(id: "pet-1", from: [
            "name": "Mochi", "species": "axolotl", "gender": "?",
        ]))

        #expect(pet.species == .other)
        #expect(pet.gender == .unknown)
    }

    /// A document field must not be able to point the client at a
    /// non-web scheme.
    @Test func acceptsOnlyHttpAvatarURLs() throws {
        let hostile = try #require(PetDecoder.pet(id: "pet-1", from: [
            "name": "Mochi", "avatarUrl": "file:///etc/passwd",
        ]))
        #expect(hostile.avatarURL == nil)

        let fine = try #require(PetDecoder.pet(id: "pet-1", from: [
            "name": "Mochi", "avatarUrl": "https://res.cloudinary.com/demo/image/upload/a.jpg",
        ]))
        #expect(fine.avatarURL != nil)
    }

    /// Mirrors the server's own bounds check in `deriveBirthdayMonthDay`. A
    /// month of 0 or 13 is not a birthday and must not become one.
    @Test func rejectsOutOfRangeBirthdayComponents() throws {
        let pet = try #require(PetDecoder.pet(id: "pet-1", from: [
            "name": "Mochi", "birthdayMonth": 13, "birthdayDay": 0,
        ]))

        #expect(pet.birthdayMonth == nil)
        #expect(pet.birthdayDay == nil)
    }

    /// Legacy data where only one of the two owner fields was written. Each
    /// falls back to the other so `PetOwnership`'s narrow fallback still has
    /// something to compare against.
    @Test func fillsInAMissingOwnerFieldFromTheOtherOne() throws {
        let pet = try #require(PetDecoder.pet(id: "pet-1", from: [
            "name": "Mochi", "primaryOwnerId": "dana",
        ]))

        #expect(pet.ownerID == "dana")
        #expect(pet.primaryOwnerID == "dana")
    }

    // MARK: - The family document

    @Test func readsThePrimaryRoleOnlyFromTheLiteralValue() throws {
        let primary = try #require(PetDecoder.familyMember(id: "alice", from: ["role": "primary"]))
        #expect(primary.role == .primary)

        // Read positively on purpose: a corrupted value must not be able to
        // promote somebody.
        let corrupted = try #require(PetDecoder.familyMember(id: "bob", from: ["role": "PRIMARY"]))
        #expect(corrupted.role == .member)

        let missing = try #require(PetDecoder.familyMember(id: "carol", from: [:]))
        #expect(missing.role == .member)
    }

    @Test func keepsACustomRelationshipOnlyForOther() throws {
        let other = try #require(PetDecoder.familyMember(id: "alice", from: [
            "relationship": "other", "customRelationship": "Dog walker",
        ]))
        #expect(other.customRelationship == "Dog walker")

        let mom = try #require(PetDecoder.familyMember(id: "bob", from: [
            "relationship": "mom", "customRelationship": "Dog walker",
        ]))
        #expect(mom.relationship == .mom)
        #expect(mom.customRelationship == nil, """
            The server only stores a custom label for `other`; showing one on \
            any other relationship would be showing a value the server throws \
            away.
            """)
    }

    /// Dropping a row understates `memberCount`, and `memberCount` is what
    /// decides whether the pet may be deleted.
    @Test func keepsAFamilyMemberWhoseNameIsMissing() throws {
        let member = try #require(PetDecoder.familyMember(id: "alice", from: [:]))

        #expect(member.id == "alice")
        #expect(member.userName.isEmpty)
    }

    // MARK: - Check-ins

    @Test func rebuildsACheckinDateFromTheMillisTheCallableSends() throws {
        let checkin = try #require(PetDecoder.checkin(from: [
            "id": "c1",
            "locationId": "loc-1",
            "petId": "pet-1",
            "petName": "Mochi",
            "caption": "TEST CONTENT caption",
            "createdAtMillis": 1_700_000_000_000,
        ]))

        #expect(checkin.locationID == "loc-1")
        #expect(checkin.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func dropsACheckinRowWithNoId() {
        #expect(PetDecoder.checkin(from: ["locationId": "loc-1"]) == nil)
    }

    // MARK: - Birthdays

    /// The canonical month/day pair exists precisely so this question is not
    /// answered by converting a timestamp in the viewer's zone. A pet stored
    /// as 2020-06-01T00:00:00Z has to be recognised on 1 June everywhere, not
    /// on 31 May for everybody west of Greenwich.
    @Test func usesTheCanonicalMonthAndDayWhateverTheViewersTimeZoneIs() throws {
        let pet = PetFixture.pet(birthdayMonth: 6, birthdayDay: 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))  // UTC+14
        let june1 = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))
        )

        #expect(pet.isBirthday(on: june1, calendar: calendar))

        var western = Calendar(identifier: .gregorian)
        western.timeZone = try #require(TimeZone(identifier: "Pacific/Honolulu"))  // UTC-10
        let alsoJune1 = try #require(
            western.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))
        )
        #expect(pet.isBirthday(on: alsoJune1, calendar: western))
    }

    /// A pet written before the canonical pair existed still has to answer,
    /// and has to answer the way the server would derive it — from the
    /// timestamp's **UTC** fields.
    @Test func fallsBackToTheLegacyTimestampReadInUTC() throws {
        let storedAtUTCMidnight = Date(timeIntervalSince1970: 1_590_969_600)  // 2020-06-01T00:00:00Z
        let pet = PetFixture.pet(birthday: storedAtUTCMidnight)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        let june1 = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))
        )

        #expect(pet.isBirthday(on: june1, calendar: calendar), """
            Read in a negative-UTC zone the stored instant is 31 May, which is \
            exactly the day the legacy path must not answer with.
            """)
    }

    @Test func aPetWithNoBirthdayNeverHasOne() {
        #expect(!PetFixture.pet().isBirthday(on: Date()))
    }
}
