import Foundation

/// The words and marks a pet is shown with.
///
/// Separate from the model so the model stays free of presentation, and so the
/// labels are in one place rather than spelled out at each call site — which
/// is how "Best Friend" and "Best friend" end up on two screens.
///
/// English only, like the rest of the native client so far. The web client
/// carries a Chinese table for these (`relationshipLabelMapZh`); porting it
/// belongs with whatever brings localisation to this app, not with this batch,
/// and is named in the batch report so it is not forgotten.
enum PetDisplay {
    static func label(for species: PetSpecies) -> String {
        switch species {
        case .dog: return "Dog"
        case .cat: return "Cat"
        case .bird: return "Bird"
        case .rabbit: return "Rabbit"
        case .hamster: return "Hamster"
        case .fish: return "Fish"
        case .reptile: return "Reptile"
        case .other: return "Other"
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
        case .male: return "Male"
        case .female: return "Female"
        case .unknown: return "Unspecified"
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
        case .mom: return "Mom"
        case .dad: return "Dad"
        case .brother: return "Brother"
        case .sister: return "Sister"
        case .grandma: return "Grandma"
        case .grandpa: return "Grandpa"
        case .auntie: return "Auntie"
        case .uncle: return "Uncle"
        case .bestFriend: return "Best Friend"
        case .caretaker: return "Caretaker"
        case .other: return "Family"
        }
    }

    /// "Born: 1 Jun 2020", in the viewer's locale.
    static func bornLine(_ birthday: Date?) -> String? {
        guard let birthday else { return nil }
        return "Born: " + birthday.formatted(date: .abbreviated, time: .omitted)
    }

    /// Pluralised counts, so a profile does not say "1 posts".
    static func postCount(_ count: Int) -> String {
        count == 1 ? "1 post" : "\(count) posts"
    }

    static func followerCount(_ count: Int) -> String {
        count == 1 ? "1 follower" : "\(count) followers"
    }

    static func ownerCount(_ count: Int) -> String {
        count == 1 ? "1 owner" : "\(count) owners"
    }
}
