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

    /// The pet's photo over its species mark — the web banner's `meta.emoji`
    /// fallback — so a photo that fails to load leaves the mark rather than a
    /// retry button inside the ring. Decoration: the name is in the title.
    private var avatar: some View {
        ZStack {
            Palette.background
            Text(PetDisplay.emoji(for: banner.species))
                .font(Typography.sectionTitle)
            if banner.avatarURL != nil {
                RemoteImage(url: banner.avatarURL, aspectRatio: 1, size: .avatar, retriesOnFailure: false)
            }
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .clipShape(Circle())
        .padding(Spacing.xs / 2)
        .background(Palette.brandGradient, in: Circle())
        .accessibilityHidden(true)
    }
}

/// "Popular Pets": a small grey heading over a sideways strip of round
/// pictures, each in a ring, the pet's name under each, one tile per pet —
/// the shape Instagram's stories made the one everybody reads as "tap to see".
///
/// **Circles, not the old app's hearts.** The row first came back as the old
/// iPhone app drew it (`feature/ios-polish-round2`'s `PetSpotlight`), a heart
/// cut from the post's picture. On 2026-09-29 the owner asked for another
/// shape: a heart crops a pet's head at its two lobes and its point, which is
/// exactly where ears and chins are. A circle keeps the middle of the picture
/// and cuts evenly all round. The rules stayed: one tile per pet, a paw on a
/// pale brand tint for a post with no picture, no row at all when there is
/// nothing to show.
///
/// **The ring says whether it has been opened.** The brand gradient, with a
/// gap of the page's own colour inside it, while unseen; a hairline grey once
/// opened, the picture a little dimmer — so a strip of seen and unseen pets
/// reads at a glance, as a story tray does.
///
/// **Placeholders hold the row's place while it loads**, five still circles
/// the height the tiles will have, so the posts below do not jump when the
/// tiles arrive; only an empty or failed read takes the row away, which the
/// feed does by not drawing it (`FeedView`).
struct PetSpotlightRow: View {
    let phase: SpotlightPhase
    let onOpen: (String) -> Void

    /// Room for the name under a picture: eight characters and the "…".
    private static let tileWidth: CGFloat = 72
    /// The picture and its ring together.
    private static let circleSize: CGFloat = 64
    /// The unseen ring, and the gap of page colour between it and the picture.
    private static let ringWidth: CGFloat = 2.5
    private static let ringGap: CGFloat = 2.5
    /// For a post with no picture.
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
                ringed(item)
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

    /// The post's first picture as a circle in its ring: the brand gradient
    /// while unseen, a hairline grey once opened. The gap between ring and
    /// picture is left clear, so it is the page's own colour in either mode.
    private func ringed(_ item: SpotlightItem) -> some View {
        ZStack {
            if item.isSeen {
                Circle().strokeBorder(Palette.separator, lineWidth: 1)
            } else {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [Palette.brandGradientStart, Palette.brandGradientEnd],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: Self.ringWidth
                )
            }
            picture(item)
                .clipShape(Circle())
                .padding(Self.ringWidth + Self.ringGap)
                .opacity(item.isSeen ? 0.7 : 1)
        }
        .frame(width: Self.circleSize, height: Self.circleSize)
        .accessibilityHidden(true)
    }

    /// The picture, over the stand-in for a post without one: a paw on a pale
    /// brand tint. Not the ring's gradient, which inside the shape "read as a
    /// broken image rather than an empty one" in the old app; and a picture
    /// that fails leaves the stand-in showing, rather than a retry button in a
    /// tile whose whole face is already a button.
    private func picture(_ item: SpotlightItem) -> some View {
        ZStack {
            Palette.standInFill
            // Sized to the circle, not to the text: the circle is a fixed size
            // at every text size, and a paw that grew with the text would fill it.
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

    /// The loading circles' surface: the cards' own, white on the feed's grey
    /// in light mode and dark grey on black in dark. It was the page's
    /// secondary background, which is the very grey the feed has had since it
    /// went onto the grouped background (09-26), so on a phone on 2026-09-29
    /// the placeholders were not there at all — a heading over five floating
    /// bars.
    static let placeholderFill = Palette.cardBackground

    /// Still, not pulsing: `RemoteImage` explains what a pulse that never
    /// stopped cost the web client. The name line is a redacted word in the
    /// real font, so the tile is the height a real one will be. The circle has
    /// the cards' hairline edge as well as their surface.
    private var placeholderTile: some View {
        VStack(spacing: Spacing.xs + 2) {
            Circle()
                .fill(Self.placeholderFill)
                .overlay {
                    Circle()
                        .strokeBorder(Palette.separator, lineWidth: 0.5)
                        .accessibilityHidden(true)
                }
                .frame(width: Self.circleSize, height: Self.circleSize)
            Text("Pet", comment: "Stand-in name for a pet whose name is missing")
                .font(Typography.caption)
                .redacted(reason: .placeholder)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.tileWidth)
        .frame(minHeight: Layout.minTouchTarget)
    }
}
