import SwiftUI

/// What stands in for a pet's missing photo, drawn on `Palette.standInFill`:
/// the species' mark, the web's emoji, or the brand's purple paw for "Other"
/// and for a species not chosen yet. The paw emoji for those is black, and on
/// the dark mode wash it all but disappears.
///
/// Decoration: the pet's name and species are always in the text beside it,
/// so it is hidden from VoiceOver where it is used.
struct PetStandInMark: View {
    let species: PetSpecies?
    let font: Font

    var body: some View {
        if let species, species != .other {
            Text(PetDisplay.emoji(for: species))
                .font(font)
        } else {
            Image(systemName: "pawprint.fill")
                .font(font)
                .foregroundStyle(Palette.brandPrimary)
        }
    }
}
