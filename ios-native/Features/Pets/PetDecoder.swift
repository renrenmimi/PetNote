import Foundation

// MARK: - TEMPORARY LOCATION
//
// Belongs beside `PostDecoder` in `Core/Model/`. Here for the same reason as
// `PetDomain.swift`; see the note there.

/// Turns a Firestore document into a `Pet`, a `PetFamilyMember`, or a
/// `PetCheckin`.
///
/// Pure functions over dictionaries, so the whole normalization contract is
/// testable without a Firebase app behind it — which is the only reason the
/// rules below are checkable at all.
///
/// The rules, and why each one is here rather than at a call site:
///
///   - **`followerCount` / `postCount` are clamped at 0.** Both are
///     trigger-maintained denormalized counters, and a create→delete race
///     inside trigger latency can briefly drive one negative. "-1 followers"
///     must never reach the screen.
///   - **An unknown species or gender degrades** to `.other` / `.unknown`
///     instead of dropping the pet, matching what the server writes when it
///     does not recognise a value.
///   - **`avatarUrl` is only accepted as http(s).** A document field must not
///     be able to point the client at `file://` or a custom scheme. The server
///     additionally restricts the *host* on write
///     (`TRUSTED_AVATAR_URL_HOSTS`); this is the reader's half.
///   - **`birthdayMonth`/`birthdayDay` are range-checked**, mirroring
///     `deriveBirthdayMonthDay`. A month of 0 or 13 in a document is not a
///     birthday and must not silently become one.
enum PetDecoder {
    /// - Returns: nil for a document with no usable `name`.
    ///
    ///   The server guarantees 2–20 characters on every create and every
    ///   update, so a nameless document is not a pet that lost a field — it is
    ///   something this client cannot render a profile for, and showing an
    ///   untitled page would be worse than saying the pet is not there.
    static func pet(id: String, from data: [String: Any]) -> Pet? {
        guard let name = nonEmpty(data["name"]) else { return nil }

        // Either field may be missing on legacy data; each falls back to the
        // other so `PetOwnership`'s fallback still has something to compare.
        let ownerID = (data["ownerId"] as? String) ?? ""
        let primaryOwnerID = (data["primaryOwnerId"] as? String) ?? ""

        return Pet(
            id: id,
            ownerID: ownerID.isEmpty ? primaryOwnerID : ownerID,
            primaryOwnerID: primaryOwnerID.isEmpty ? ownerID : primaryOwnerID,
            name: name,
            species: PetSpecies(rawValue: (data["species"] as? String) ?? "") ?? .other,
            breed: (data["breed"] as? String) ?? "",
            gender: PetGender(rawValue: (data["gender"] as? String) ?? "") ?? .unknown,
            bio: (data["bio"] as? String) ?? "",
            avatarURL: url(data["avatarUrl"]),
            birthday: (data["birthday"] as? PostDate)?.postDate,
            birthdayMonth: monthOrDay(data["birthdayMonth"], upperBound: 12),
            birthdayDay: monthOrDay(data["birthdayDay"], upperBound: 31),
            followerCount: count(data["followerCount"]),
            postCount: count(data["postCount"]),
            createdAt: (data["createdAt"] as? PostDate)?.postDate
        )
    }

    /// - Returns: nil when the document id is empty. Everything else degrades:
    ///   a family member with a missing name is still an owner, and dropping
    ///   the row would understate `memberCount` — which is an input to whether
    ///   the pet may be deleted.
    static func familyMember(id: String, from data: [String: Any]) -> PetFamilyMember? {
        guard !id.isEmpty else { return nil }
        let relationship =
            PetFamilyRelationship(rawValue: (data["relationship"] as? String) ?? "") ?? .other
        return PetFamilyMember(
            id: id,
            userName: (data["userName"] as? String) ?? "",
            userAvatarURL: url(data["userAvatar"]),
            relationship: relationship,
            // The server only stores a custom label for `.other`; a stray one
            // on any other relationship is ignored rather than shown.
            customRelationship: relationship == .other ? nonEmpty(data["customRelationship"]) : nil,
            // Anything that is not the literal "primary" is a member. Read
            // positively on purpose: a corrupted value must not be able to
            // promote somebody.
            role: (data["role"] as? String) == PetFamilyRole.primary.rawValue ? .primary : .member,
            joinedAt: (data["joinedAt"] as? PostDate)?.postDate
        )
    }

    /// One row of the callable's `checkins` array.
    ///
    /// Timestamps do not survive the callable boundary, so the server sends
    /// `createdAtMillis` and the `Date` is rebuilt here — the same split the
    /// web client makes in src/services/checkins.ts.
    static func checkin(from raw: [String: Any]) -> PetCheckin? {
        guard let id = nonEmpty(raw["id"]) else { return nil }
        return PetCheckin(
            id: id,
            locationID: (raw["locationId"] as? String) ?? "",
            petID: (raw["petId"] as? String) ?? "",
            petName: (raw["petName"] as? String) ?? "",
            photoURL: url(raw["photoUrl"]),
            caption: (raw["caption"] as? String) ?? "",
            createdAt: millis(raw["createdAtMillis"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - Field normalization

    static func count(_ raw: Any?) -> Int {
        // Firestore hands back NSNumber, so an Int-typed count can arrive as
        // Int64 or Double depending on how it was written.
        let value: Int
        switch raw {
        case let int as Int: value = int
        case let int64 as Int64: value = Int(int64)
        case let double as Double where double.isFinite: value = Int(double)
        default: return 0
        }
        return max(0, value)
    }

    /// 1...upperBound, or nil. Mirrors the server's own bounds check.
    static func monthOrDay(_ raw: Any?, upperBound: Int) -> Int? {
        let value: Int
        switch raw {
        case let int as Int: value = int
        case let int64 as Int64: value = Int(int64)
        case let double as Double where double.isFinite: value = Int(double)
        default: return nil
        }
        return (1...upperBound).contains(value) ? value : nil
    }

    private static func millis(_ raw: Any?) -> Double? {
        switch raw {
        case let int as Int: return Double(int)
        case let int64 as Int64: return Double(int64)
        case let double as Double where double.isFinite: return double
        default: return nil
        }
    }

    static func url(_ raw: Any?) -> URL? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
