import SwiftUI

/// One choice among a few, as a chip: the brand fill and white text when
/// chosen, the system's quiet fill when not. For short option sets where a
/// menu picker makes a person tap twice and read a long list to choose one
/// word — a pet's species, a relationship, a review's tags.
///
/// The capsule is drawn at its content's height and the touch area is the
/// full 44pt (`Layout.minTouchTarget`), so a wrapped set of them reads as
/// tight rows and is still easy to hit. The touch area also keeps a few
/// points round the capsule, so that lines of chips never touch once large
/// text makes a capsule taller than 44pt. The symbol is decoration:
/// VoiceOver reads the title, and a chosen chip says it is selected, not
/// only shows it.
struct ChoiceChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol {
                    Text(verbatim: symbol).accessibilityHidden(true)
                }
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .font(Typography.caption)
            .foregroundStyle(isSelected ? Palette.textOnBrand : Palette.primaryText)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(isSelected ? Palette.chipChosenFill : Palette.chipFill, in: .capsule)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
