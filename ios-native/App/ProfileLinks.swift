import SwiftUI

/// The two ways off the profile that are not about one's own pets: joining a
/// pet's family with a code someone sent, and the pets one follows.
///
/// The web client puts the first on its Add Pet page ("Join existing") and the
/// second in the profile's following section. Here both sit under the pets
/// list, because a person holding an invitation code is looking for "my pets",
/// not for "add a pet".
struct ProfileLinks: View {
    let onJoinFamily: () -> Void
    let onFollowing: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(
                title: "Join a pet's family",
                detail: "Use an invitation code from one of its owners",
                systemImage: "person.2.badge.plus",
                identifier: "profile.joinFamily",
                action: onJoinFamily
            )
            Divider().overlay(Palette.separator)
            row(
                title: "Pets you follow",
                detail: nil,
                systemImage: "heart.text.square",
                identifier: "profile.following",
                action: onFollowing
            )
        }
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    private func row(
        title: String, detail: String?, systemImage: String, identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .font(Typography.body)
                    .foregroundStyle(Palette.brandPrimary)
                    .frame(width: Layout.minTouchTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(Palette.primaryText)
                    if let detail {
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
