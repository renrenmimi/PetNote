import SwiftUI

// Pieces the social, search, family and profile screens share. Kept in one
// file so the four surfaces cannot drift into four different follow buttons.

/// A round picture for a person or a pet, with a lettered stand-in.
///
/// **Why not always `RemoteImage`.** Every account and pet without its own
/// photo carries the server's default, a dicebear **SVG** URL
/// (`getDefaultAvatar`, functions/src/shared.ts). `UIImage` does not decode
/// SVG, so handing that URL to the image loader draws a failed-image tile on
/// every default avatar — a broken-looking screen for the most common case.
/// The initial is what the picture was standing in for anyway.
///
/// Decorative: the name is always in the text beside it, so this is hidden
/// from VoiceOver rather than read as a second copy.
struct SocialAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = SocialLayout.rowAvatar

    static func isDrawable(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.host?.lowercased().contains("dicebear.com") == true { return false }
        return url.pathExtension.lowercased() != "svg"
    }

    var body: some View {
        Group {
            if Self.isDrawable(url) {
                RemoteImage(url: url, aspectRatio: 1, cornerRadius: size / 2, size: .avatar)
            } else {
                Text(Self.initial(of: name))
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.secondaryBackground)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func initial(of name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "?"
        }
        return String(first).uppercased()
    }
}

/// Stacks horizontally, and vertically at the accessibility text sizes, so a
/// long name and a trailing button never squeeze each other into one letter
/// per line.
struct SocialAdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = Spacing.m
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout { content() }
    }
}

/// Capsule buttons: the brand fill for the primary action, an outline for the
/// rest, and the danger colour for anything that takes something away.
struct SocialButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var fullWidth = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.l)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Layout.minTouchTarget)
            .background { background }
            .overlay {
                if kind != .primary {
                    Capsule().stroke(kind == .destructive ? Palette.danger : Palette.separator)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.5))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.textOnBrand
        case .secondary: return Palette.primaryText
        case .destructive: return Palette.danger
        }
    }

    @ViewBuilder
    private var background: some View {
        if kind == .primary {
            Capsule().fill(Palette.brandGradient)
        } else {
            Capsule().fill(Palette.background)
        }
    }
}

/// A card that says what a section is showing and why.
struct SocialNotice: View {
    let title: String
    var detail: String?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
            if let detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// A failure with its own retry. Never an empty list: "nothing here" and "we
/// could not find out" must not look the same.
struct SocialRetryNotice: View {
    let message: String
    let identifier: String
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
            Button { Task { await retry() } } label: {
                Text("Try again")
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
                .font(Typography.body)
                .foregroundStyle(Palette.brandPrimary)
                .contentShape(.rect)
                .accessibilityIdentifier("\(identifier).retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityIdentifier(identifier)
    }
}

/// The follow control for one pet.
///
/// Draws nothing for one of the pet's owners — the server would refuse, and
/// the web page shows owners their management actions in its place.
struct PetFollowButton: View {
    let model: FollowModel
    var compact = false

    var body: some View {
        if model.offersControl {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                button
                if let message = model.message {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("follow.message")
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var button: some View {
        switch model.status {
        case .unknown:
            ProgressView()
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                .accessibilityLabel("Checking whether you follow \(model.petName)")
        case .following:
            Button { Task { await model.toggle() } } label: { label("Following") }
                .buttonStyle(SocialButtonStyle(kind: .secondary, fullWidth: !compact))
                .disabled(model.isBusy)
                .accessibilityLabel("Following \(model.petName)")
                .accessibilityHint("Double-tap to unfollow.")
                .accessibilityIdentifier("follow.toggle")
        case .notFollowing, .checkFailed:
            Button { Task { await model.toggle() } } label: { label("Follow") }
                .buttonStyle(SocialButtonStyle(kind: .primary, fullWidth: !compact))
                .disabled(model.isBusy)
                .accessibilityLabel("Follow \(model.petName)")
                .accessibilityIdentifier("follow.toggle")
        case .ownPet:
            EmptyView()
        }
    }

    private func label(_ title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            if model.isBusy {
                ProgressView().tint(Palette.secondaryText)
            }
            Text(title).lineLimit(1)
        }
        .fixedSize()
    }
}

enum SocialLayout {
    static let rowAvatar: CGFloat = 44
    static let cardAvatar: CGFloat = 56
    static let headerAvatar: CGFloat = 96
    static let discoverCardWidth: CGFloat = 148
}
