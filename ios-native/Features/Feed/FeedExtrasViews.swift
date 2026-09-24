import SwiftUI

// The rows the feed draws above its posts. The state behind them is
// `FeedExtrasModel`; these only draw it and report taps.
//
// Both are rows of the feed's own `List`, not an inset or an overlay above
// it: they scroll away with the posts, as the web client's do
// (src/pages/Feed.tsx renders them inside the same <main>), and they never
// cover a post. They do push every post down, which is why the spotlight row
// is as short as it is — see `PetSpotlightRow`.

/// The web client's `BirthdayCelebration` (src/components/BirthdayCelebration.tsx).
///
/// Its surface is the page's secondary background rather than the web's
/// amber-to-purple wash: `Palette.brandGradient` is "kept for identity —
/// never as a large background area", and a banner is one. The gradient
/// survives as the ring around the pet, which is the size the palette allows.
///
/// The web banner's "Share a birthday post" button is not here. Tapping the
/// banner opens the pet's page instead, which is where a person decides what
/// to do about the birthday.
struct BirthdayBannerRow: View {
    let banner: BirthdayBanner
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private static let avatarSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.xs) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.m) {
                    avatar
                    VStack(alignment: .leading, spacing: Spacing.xs / 2) {
                        Text(banner.title)
                            .font(Typography.sectionTitle)
                            .foregroundStyle(Palette.primaryText)
                            .multilineTextAlignment(.leading)
                        if let ageLine = banner.ageLine {
                            Text(ageLine)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // On the label, with the shape, so the whole banner is the
                // target and not only its words.
                .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
                .contentShape(.rect)
            }
            // Not the default style: inside a List that makes the whole row
            // one button, and the ✕ beside this one would open the pet too.
            .buttonStyle(.plain)
            .accessibilityHint("Opens the pet's page")
            .accessibilityIdentifier("birthday.open")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("birthday.dismiss")
        }
        .padding(.leading, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.card))
        // `.contain` before the identifier: on a plain stack the identifier
        // would replace the two buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.birthday")
    }

    /// The pet's photo, or its species mark when there is none — the web
    /// banner's `meta.emoji` fallback. Decoration: the name is in the title.
    private var avatar: some View {
        Group {
            if banner.avatarURL != nil {
                RemoteImage(
                    url: banner.avatarURL, aspectRatio: 1,
                    cornerRadius: Self.avatarSize / 2, size: .avatar
                )
            } else {
                Text(PetDisplay.emoji(for: banner.species))
                    .font(Typography.sectionTitle)
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .background(Palette.background, in: Circle())
            }
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .padding(Spacing.xs / 2)
        .background(Palette.brandGradient, in: Circle())
        .accessibilityHidden(true)
    }
}

/// The web client's `PetSpotlight` (src/components/PetSpotlight.tsx): "⭐
/// Popular Pets", one tile per post, sideways.
///
/// **Compact on purpose, and that is the one real departure from the web.**
/// The web section is a card: a heading line, then 62pt tiles with names
/// under them — about 120pt before the first post. This row sits above every
/// post in the feed, and the suites that measure the feed find the first
/// card's like, comments and share buttons without scrolling; at 120pt the
/// first card's action row goes under the tab bar on a 6.1-inch phone. So the
/// heading sits beside the tiles rather than above them and the pictures are
/// the 44pt a control needs, which puts the row at about 67pt. At the
/// accessibility text sizes the heading goes back above the tiles
/// (`SocialAdaptiveStack`), because beside them it would be a letter wide.
struct PetSpotlightRow: View {
    let phase: SpotlightPhase
    let onOpen: (String) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Wide enough for the name under a tile: eight characters and the "…".
    private static let tileWidth: CGFloat = 64
    /// A picture no smaller than the target it is part of.
    private static let pictureSize: CGFloat = Layout.minTouchTarget
    /// The gap between the ring and the picture inside it.
    private static let ringInset: CGFloat = 3
    /// "⭐ Popular Pets" on two lines beside the tiles.
    private static let headingWidth: CGFloat = 72
    /// As many as fit beside the heading on the narrowest iPhone. A
    /// placeholder cut off at the edge of the screen reads as a layout fault
    /// rather than as "loading".
    private static let placeholderCount = 3

    var body: some View {
        SocialAdaptiveStack(spacing: Spacing.m) {
            Text("⭐ Popular Pets")
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: typeSize.isAccessibilitySize ? nil : Self.headingWidth, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.leading, Layout.pageInset)
        // Top only: the first card under this row has its own top padding.
        .padding(.top, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.spotlight")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            placeholders
        case .empty:
            Text("Share your pet to get featured! 🐾")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .padding(.trailing, Layout.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("spotlight.empty")
        case .items(let items):
            // Scrolls to the screen's edge, so the next tile shows there is
            // more; the heading beside it stays put.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(items) { item in
                        tile(item)
                    }
                }
                .padding(.trailing, Layout.pageInset)
            }
        }
    }

    private func tile(_ item: SpotlightItem) -> some View {
        Button {
            onOpen(item.post.id)
        } label: {
            VStack(spacing: Spacing.xs / 2) {
                picture(item)
                // Secondary rather than the web's gray-400 for a seen tile:
                // this is still the only place the name is written, so it
                // keeps the body-text contrast. The picture carries the dimming.
                Text(item.label)
                    .font(Typography.caption)
                    .foregroundStyle(item.isSeen ? Palette.secondaryText : Palette.primaryText)
                    .lineLimit(1)
            }
            .frame(width: Self.tileWidth)
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The whole name, not the cut one the tile has room for.
        .accessibilityLabel(item.name)
        // Dimming is not the only way "you have opened this" is said.
        .accessibilityValue(item.isSeen ? String(localized: "Seen") : "")
        .accessibilityHint("Opens the post")
        .accessibilityIdentifier("spotlight.post.\(item.post.id)")
    }

    /// The post's first picture in a ring: the brand gradient while unseen,
    /// a plain separator once opened — the web tile's two rings.
    private func picture(_ item: SpotlightItem) -> some View {
        Group {
            if let url = Self.imageURL(for: item.post.media.first) {
                RemoteImage(url: url, aspectRatio: 1, cornerRadius: Radius.control, size: .spotlight)
            } else {
                // The web tile's gradient square for a post with no picture.
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Palette.brandGradient)
            }
        }
        .frame(width: Self.pictureSize - 2 * Self.ringInset, height: Self.pictureSize - 2 * Self.ringInset)
        .opacity(item.isSeen ? 0.7 : 1)
        .frame(width: Self.pictureSize, height: Self.pictureSize)
        .overlay {
            if item.isSeen {
                RoundedRectangle(cornerRadius: Radius.control + Self.ringInset)
                    .strokeBorder(Palette.separator, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: Radius.control + Self.ringInset)
                    .strokeBorder(Palette.brandGradient, lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }

    /// A photo as itself; a video as its poster, derived the way the feed's
    /// own player derives it (`MediaView.posterURL`), so the tile and the card
    /// ask the CDN for the same frame.
    private static func imageURL(for media: MediaItem?) -> URL? {
        guard let media else { return nil }
        switch media.kind {
        case .image: return media.url
        case .video: return MediaView.posterURL(for: media, size: .spotlight)
        }
    }

    /// Still, not pulsing: `RemoteImage` explains what a pulse that never
    /// stopped cost the web client. The name line is a redacted word in the
    /// real font, so the row is the height it will be once it has loaded.
    private var placeholders: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            ForEach(0..<Self.placeholderCount, id: \.self) { _ in
                VStack(spacing: Spacing.xs / 2) {
                    RoundedRectangle(cornerRadius: Radius.control + Self.ringInset)
                        .fill(Palette.secondaryBackground)
                        .frame(width: Self.pictureSize, height: Self.pictureSize)
                    Text("Pet", comment: "Stand-in name for a pet whose name is missing")
                        .font(Typography.caption)
                        .redacted(reason: .placeholder)
                }
                .frame(width: Self.tileWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading popular pets")
    }
}
