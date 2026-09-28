import SwiftUI

/// Every design token in one place, so a snapshot of this view fails when a
/// token changes shape. Not a screen anyone navigates to; it is the fixture
/// acceptance item 3.4 renders.
struct TokenShowcase: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Page title").font(Typography.pageTitle).foregroundStyle(Palette.primaryText)
            Text("Section").font(Typography.sectionTitle).foregroundStyle(Palette.primaryText)
            Text("Body copy that wraps onto a second line so line height is part of the snapshot.")
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
            Text("Caption").font(Typography.caption).foregroundStyle(Palette.secondaryText)
            Text("Tertiary").font(Typography.caption).foregroundStyle(Palette.tertiaryText)

            Divider().overlay(Palette.separator)

            HStack(spacing: Spacing.s) {
                statusDot(Palette.danger, "Danger")
                statusDot(Palette.success, "Success")
                statusDot(Palette.warning, "Warning")
            }

            Text("Brand")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.brandPrimary)

            Text("On brand")
                .font(Typography.body)
                .foregroundStyle(Palette.textOnBrand)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .frame(minHeight: Layout.minTouchTarget)
                .background(Palette.brandGradient, in: .rect(cornerRadius: Radius.control))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Card").font(Typography.sectionTitle).foregroundStyle(Palette.primaryText)
                Text("Cards use background colour, not shadow.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.card))
        }
        .padding(Layout.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background)
    }

    private func statusDot(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(colour).frame(width: Spacing.m, height: Spacing.m)
            Text(label).font(Typography.caption).foregroundStyle(colour)
        }
    }
}

#Preview { TokenShowcase() }
