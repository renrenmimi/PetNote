import SwiftUI

// The rows the feed draws above its posts. The state behind them is
// `FeedExtrasModel`; these only draw it and report taps.
//
// Both are rows of the feed's own `List`, not an inset or an overlay above
// it: they scroll away with the posts, as the web client's do
// (src/pages/Feed.tsx renders them inside the same <main>), and they never
// cover a post. They are there whatever the posts are doing — loading,
// failed, empty — because the web draws them above all three
// (Feed.tsx:517-519). They do push every post down; `PetSpotlightRow` says
// what that costs and why it is paid.

/// The web client's `BirthdayCelebration` (src/components/BirthdayCelebration.tsx).
///
/// The same three parts: who is having a birthday (and how old), the ✕, and
/// "Share a birthday post", which opens the composer with the pet already
/// chosen — the web's `/create?petId=`. The banner itself is not a button,
/// because the web's is not: its only actions are those two.
///
/// Its surface is a card like the posts' under it, not the web's
/// amber-to-purple wash. The web writes white on that wash, and white on its
/// amber end is about 1.7:1, well under the 4.5:1 body text needs; and
/// `Palette.brandGradient` is "kept for identity — never as a large
/// background area". The gradient survives as the ring around the pet.
///
/// A card since the feed became cards. Its surface was the page's secondary
/// background, which on the grouped background the feed has had since the
/// cards came in (09-26) is the same grey as the page: the banner had no edge
/// at all, and its words sat on the page as if nothing held them.
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

            // The web's pill, in the page's colour so it shows on the white
            // card. Brand text on it works out at about 5.0:1 in light mode
            // (5.5:1 on white, the pairing `PaletteContrastTests` measures)
            // and 7.5:1 in dark.
            Button(action: onShare) {
                Text("Share a birthday post")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.brandPrimary)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: Layout.minTouchTarget)
                    .background(Palette.groupedBackground, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("birthday.share")
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.s)
        // `PostCard`'s card: the same surface, edge and shadow.
        .background(Palette.cardBackground)
        .clipShape(.rect(cornerRadius: Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(Palette.separator, lineWidth: 0.5)
                .accessibilityHidden(true)
        }
        .shadow(color: Palette.cardShadow, radius: 12, y: 6)
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

/// The old iPhone app's `PetSpotlight` (`feature/ios-polish-round2`,
/// src/components/PetSpotlight.tsx), which is what the owner's phone showed:
/// a small grey "POPULAR PETS" over a sideways strip of hearts, the pet's name
/// under each, one tile per pet.
///
/// **Drawn as that version, not as main's web card.** Main's web still has
/// the earlier card — "⭐ Popular Pets" in a white panel, rounded squares —
/// and the first version of this row was a compact take on it, with the
/// heading beside 44pt tiles to spend less height above the posts. The owner
/// has asked, screen by screen, for the look the phone had; this row was
/// never in a candidate they saw, so it is brought to that look before it is.
/// It is taller: 107.5pt on an iPhone 17 at the default text size (measured
/// 2026-09-28), against about 66 for the compact row.
///
/// **One difference, on purpose: the placeholders.** The old app draws
/// nothing until the tiles arrive, so the posts below jump down when they do.
/// Here five still hearts hold the row's place while it loads — the height
/// the tiles will have — and only an empty or failed read takes the row away,
/// which the feed does by not drawing it (`FeedView`).
struct PetSpotlightRow: View {
    let phase: SpotlightPhase
    let onOpen: (String) -> Void

    /// `style={{ width: 72 }}`: room for the name under a heart.
    private static let tileWidth: CGFloat = 72
    /// `h-[62px] w-[62px]`.
    private static let heartSize: CGFloat = 62
    /// `inset-[2.5px]`: the brand-coloured edge, then the white.
    private static let edgeWidth: CGFloat = 2.5
    /// `inset-[4px]`: the picture, inside the white.
    private static let pictureInset: CGFloat = 4
    /// `<PawPrint size={22} />`, for a post with no picture.
    private static let pawSize: CGFloat = 22

    var body: some View {
        // Nothing at all for an empty or failed read, heading included. The
        // feed leaves the row out as well, so no empty cell holds its place.
        if phase != .empty {
            row
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Popular Pets")
                .font(Typography.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, Layout.pageInset)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.spotlight")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            // Five, running off the edge the way the tiles do — cut by the
            // edge of a sideways row, which is what the tiles will be too.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(0..<FeedExtras.placeholderCount, id: \.self) { _ in
                        placeholderTile
                    }
                }
                .padding(.horizontal, Layout.pageInset)
            }
            .scrollDisabled(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading popular pets")
        case .empty:
            // Not reached: `body` draws nothing for it.
            EmptyView()
        case .items(let items):
            // Scrolls to the screen's edge, so the next tile shows there is
            // more; the heading above it stays put.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(items) { item in
                        tile(item)
                    }
                }
                .padding(.horizontal, Layout.pageInset)
            }
        }
    }

    private func tile(_ item: SpotlightItem) -> some View {
        Button {
            onOpen(item.post.id)
        } label: {
            VStack(spacing: Spacing.xs + 2) {
                heart(item)
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
                    .font(Typography.caption.weight(.medium))
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
    }

    /// The web tile's `PawAvatar`: the whole square cut to a heart, so what
    /// shows of the brand gradient — or of the grey, once the post has been
    /// opened — is the edge where the heart meets the square, then a white
    /// line, then the post's first picture.
    private func heart(_ item: SpotlightItem) -> some View {
        ZStack {
            if item.isSeen {
                Rectangle().fill(Palette.separator)
            } else {
                Rectangle().fill(LinearGradient(
                    colors: [Palette.brandGradientStart, Palette.brandGradientEnd],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            Rectangle()
                .fill(Palette.background)
                .padding(Self.edgeWidth)
            picture(item)
                .padding(Self.pictureInset)
                .opacity(item.isSeen ? 0.7 : 1)
        }
        .frame(width: Self.heartSize, height: Self.heartSize)
        .clipShape(ChubbyHeart())
        .accessibilityHidden(true)
    }

    /// The picture, over the old app's stand-in for a post without one: a paw
    /// on a pale brand tint. It used to be the ring's gradient, which inside a
    /// heart "read as a broken image rather than an empty one"; and a picture
    /// that fails leaves the stand-in showing, rather than a retry button in a
    /// tile whose whole face is already a button.
    private func picture(_ item: SpotlightItem) -> some View {
        ZStack {
            Palette.brandPrimary.opacity(0.12)
            // Sized to the heart, not to the text: the heart is a fixed 62pt
            // at every text size, and a paw that grew with it would fill it.
            Image(systemName: "pawprint")
                .resizable()
                .scaledToFit()
                .frame(width: Self.pawSize, height: Self.pawSize)
                .foregroundStyle(Palette.brandPrimary)
            if let url = FeedExtras.spotlightPictureURL(for: item.post.media.first) {
                RemoteImage(url: url, aspectRatio: 1, size: .spotlight, retriesOnFailure: false)
            }
        }
    }

    /// Still, not pulsing: `RemoteImage` explains what a pulse that never
    /// stopped cost the web client. The name line is a redacted word in the
    /// real font, so the tile is the height a real one will be.
    private var placeholderTile: some View {
        VStack(spacing: Spacing.xs + 2) {
            ChubbyHeart()
                .fill(Palette.secondaryBackground)
                .frame(width: Self.heartSize, height: Self.heartSize)
            Text("Pet", comment: "Stand-in name for a pet whose name is missing")
                .font(Typography.caption)
                .redacted(reason: .placeholder)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.tileWidth)
        .frame(minHeight: Layout.minTouchTarget)
    }
}

/// The old app's `chubbyHeartClip`, point for point: the same path in the
/// same unit square, scaled to whatever frame it is given.
private struct ChubbyHeart: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: at(0.5, 0.93))
        path.addCurve(to: at(0, 0.3), control1: at(0.1, 0.7), control2: at(0, 0.45))
        path.addCurve(to: at(0.35, 0), control1: at(0, 0.12), control2: at(0.15, 0))
        path.addCurve(to: at(0.5, 0.25), control1: at(0.48, 0), control2: at(0.5, 0.15))
        path.addCurve(to: at(0.65, 0), control1: at(0.5, 0.15), control2: at(0.52, 0))
        path.addCurve(to: at(1, 0.3), control1: at(0.85, 0), control2: at(1, 0.12))
        path.addCurve(to: at(0.5, 0.93), control1: at(1, 0.45), control2: at(0.9, 0.7))
        path.closeSubpath()
        return path
    }
}
