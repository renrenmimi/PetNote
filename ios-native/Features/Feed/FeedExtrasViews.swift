import SwiftUI

// The rows the feed draws above its posts. The state behind them is
// `FeedExtrasModel`; these only draw it and report taps.
//
// Both are rows of the feed's own `List`, not an inset or an overlay above
// it: they scroll away with the posts, as the web client's do
// (src/pages/Feed.tsx renders them inside the same <main>), and they never
// cover a post. They are there whatever the posts are doing — loading,
// failed, empty — because the web draws them above all three
// (Feed.tsx:517-519). They do push every post down, which is why the
// spotlight row is as short as it is — see `PetSpotlightRow`.

/// The web client's `BirthdayCelebration` (src/components/BirthdayCelebration.tsx).
///
/// The same three parts: who is having a birthday (and how old), the ✕, and
/// "Share a birthday post", which opens the composer with the pet already
/// chosen — the web's `/create?petId=`. The banner itself is not a button,
/// because the web's is not: its only actions are those two.
///
/// Its surface is the page's secondary background rather than the web's
/// amber-to-purple wash: `Palette.brandGradient` is "kept for identity —
/// never as a large background area", and a banner is one. The gradient
/// survives as the ring around the pet, which is the size the palette allows.
struct BirthdayBannerRow: View {
    let banner: BirthdayBanner
    let onShare: () -> Void
    let onDismiss: () -> Void

    private static let avatarSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.m) {
                avatar
                VStack(alignment: .leading, spacing: Spacing.xs / 2) {
                    Text(banner.title)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("birthday.title")
                    if let ageLine = banner.ageLine {
                        Text(ageLine)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .accessibilityIdentifier("birthday.age")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Not the default style, here or below: inside a List that
                // makes the whole row one button, and a tap on the words
                // would dismiss the banner or open the composer.
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("birthday.dismiss")
            }

            // The web's white pill with the warm text. Brand text on the page
            // background is the pairing `PaletteContrastTests` measures.
            Button(action: onShare) {
                Text("Share a birthday post")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.brandPrimary)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: Layout.minTouchTarget)
                    .background(Palette.background, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("birthday.share")
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.s)
        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.card))
        // `.contain` before the identifier: on a plain stack the identifier
        // would replace the buttons' and the texts' own.
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
/// post in the feed, and every pixel of it moves the first card's actions
/// towards the tab bar. So the heading sits beside the tiles rather than
/// above them and the pictures are the 44pt a control needs, which puts the
/// row at about 66pt. At the accessibility text sizes the heading goes back
/// above the tiles (`SocialAdaptiveStack`), because beside them it would be a
/// letter wide.
///
/// **One height in all three states.** Placeholders, tiles and the empty line
/// are the same height at a given text size, so the posts below do not jump
/// when the read answers: the placeholders are tiles with nothing in them,
/// every name line is as tall as the placeholders' (`nameLine`), and the
/// empty line is laid over an invisible placeholder tile.
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
            // Five, as the web draws, running off the edge the way the tiles
            // do — cut by the edge of a sideways row, which is what the tiles
            // will be too, rather than by the edge of the screen.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(0..<FeedExtras.placeholderCount, id: \.self) { _ in
                        placeholderTile
                    }
                }
                .padding(.trailing, Layout.pageInset)
            }
            .scrollDisabled(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading popular pets")
        case .empty:
            ZStack(alignment: .leading) {
                placeholderTile
                    .hidden()
                    .accessibilityHidden(true)
                Text("Share your pet to get featured! 🐾")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.trailing, Layout.pageInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("spotlight.empty")
            }
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
                nameLine(item.label, tone: item.isSeen ? Palette.secondaryText : Palette.primaryText)
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

    /// The name under a tile, on a line exactly as tall as a placeholder's.
    ///
    /// The height comes from a hidden "Pet" in the same font — the word the
    /// placeholders draw — and the name is drawn over it. Left to its own
    /// height, a name in Chinese or with an emoji in it sets a taller line
    /// than "Pet" does, and the row, and every post under it, would move by
    /// that much when the tiles replaced the placeholders.
    private func nameLine(_ name: String, tone: Color) -> some View {
        Text("Pet", comment: "Stand-in name for a pet whose name is missing")
            .font(Typography.caption)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay {
                Text(name)
                    .font(Typography.caption)
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
    }

    /// The post's first picture in a ring: the brand gradient while unseen,
    /// a plain separator once opened — the web tile's two rings.
    private func picture(_ item: SpotlightItem) -> some View {
        Group {
            if let url = FeedExtras.spotlightPictureURL(for: item.post.media.first) {
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

    /// Still, not pulsing: `RemoteImage` explains what a pulse that never
    /// stopped cost the web client. The name line is a redacted word in the
    /// real font, so the tile is the height a real one will be.
    private var placeholderTile: some View {
        VStack(spacing: Spacing.xs / 2) {
            RoundedRectangle(cornerRadius: Radius.control + Self.ringInset)
                .fill(Palette.secondaryBackground)
                .frame(width: Self.pictureSize, height: Self.pictureSize)
            Text("Pet", comment: "Stand-in name for a pet whose name is missing")
                .font(Typography.caption)
                .redacted(reason: .placeholder)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.tileWidth)
        .frame(minHeight: Layout.minTouchTarget)
    }
}
