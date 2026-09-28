import Foundation

/// The words and marks a pet is shown with.
///
/// Separate from the model so the model stays free of presentation, and so the
/// labels are in one place rather than spelled out at each call site — which
/// is how "Best Friend" and "Best friend" end up on two screens.
///
/// Every label is `String(localized:)`, so the String Catalog translates it;
/// the raw values sent to the server never change. The web client carries a
/// Chinese table for the relationships (`relationshipLabelMapZh`), which is
/// where the zh-Hans entries should come from.
enum PetDisplay {
    static func label(for species: PetSpecies) -> String {
        switch species {
        case .dog: return String(localized: "Dog")
        case .cat: return String(localized: "Cat")
        case .bird: return String(localized: "Bird")
        case .rabbit: return String(localized: "Rabbit")
        case .hamster: return String(localized: "Hamster")
        case .fish: return String(localized: "Fish")
        case .reptile: return String(localized: "Reptile")
        case .other: return String(localized: "Other", comment: "Pet species")
        }
    }

    /// Shown in place of a photo. Decoration standing in for a missing image,
    /// so it is hidden from VoiceOver at the call site and the species is read
    /// from the text beside it.
    static func emoji(for species: PetSpecies) -> String {
        switch species {
        case .dog: return "🐕"
        case .cat: return "🐱"
        case .bird: return "🐦"
        case .rabbit: return "🐰"
        case .hamster: return "🐹"
        case .fish: return "🐠"
        case .reptile: return "🦎"
        case .other: return "🐾"
        }
    }

    /// The gender as **words**, not as a coloured symbol.
    ///
    /// The web client draws ♂ in blue and ♀ in pink and nothing else, which
    /// makes colour the only carrier of the difference — the thing §5 forbids
    /// outright, and unreadable to a person who cannot distinguish the two
    /// hues. The symbol is still drawn next to this, as decoration.
    static func label(for gender: PetGender) -> String {
        switch gender {
        case .male: return String(localized: "Male")
        case .female: return String(localized: "Female")
        case .unknown: return String(localized: "Unspecified")
        }
    }

    static func symbol(for gender: PetGender) -> String {
        switch gender {
        case .male: return "♂"
        case .female: return "♀"
        case .unknown: return "—"
        }
    }

    /// What this person is to the pet.
    ///
    /// A custom label wins when the relationship is `.other` and one was
    /// given, exactly as `getRelationshipLabel` does — that is the whole
    /// reason `customRelationship` exists.
    static func label(
        for relationship: PetFamilyRelationship, custom: String? = nil
    ) -> String {
        if relationship == .other,
           let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        switch relationship {
        case .mom: return String(localized: "Mom")
        case .dad: return String(localized: "Dad")
        case .brother: return String(localized: "Brother")
        case .sister: return String(localized: "Sister")
        case .grandma: return String(localized: "Grandma")
        case .grandpa: return String(localized: "Grandpa")
        case .auntie: return String(localized: "Auntie")
        case .uncle: return String(localized: "Uncle")
        case .bestFriend: return String(localized: "Best Friend")
        case .caretaker: return String(localized: "Caretaker")
        case .other: return String(localized: "Family", comment: "Relationship to a pet when no other label was given")
        }
    }

    /// "Born: 1 Jun 2020", in the viewer's locale.
    static func bornLine(_ birthday: Date?) -> String? {
        guard let birthday else { return nil }
        return String(localized: "Born: \(birthday.formatted(date: .abbreviated, time: .omitted))")
    }

    /// Pluralised counts, so a profile does not say "1 posts".
    static func postCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 post") : String(localized: "\(count) posts")
    }

    static func followerCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 follower") : String(localized: "\(count) followers")
    }

    static func ownerCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 owner") : String(localized: "\(count) owners")
    }
}
