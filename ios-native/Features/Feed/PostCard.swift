import SwiftUI

/// One post in the feed.
///
/// VoiceOver structure follows §5.8: the card's *content* is one element so it
/// is not read as ten fragments, but every *action* stays independently
/// reachable. The test of that is behavioural — "with VoiceOver on and the
/// screen off, can you like this post and open its comments" — not structural.
struct PostCard: View {
    let post: Post
    let isLiked: Bool
    let onLike: () -> Void
    let onOpenComments: () -> Void
    /// Nil on the detail screen: a post has to be readable in full somewhere,
    /// and there is no "more" affordance yet. The feed clamps to keep rows a
    /// predictable height.
    var textLineLimit: Int? = 6
    /// The detail screen draws the photo edge to edge and wants the larger
    /// rendition, matching the web client's imageSize="large" there.
    var mediaSize: CloudinaryURL.Size = .medium
    /// Set on the detail screen, where tapping a photo opens it in full. Nil in
    /// the feed, where a tap opens the post.
    var onOpenImage: ((URL) -> Void)?
    /// Set in the feed: tapping the card's *content* opens the post.
    ///
    /// It lives here rather than on the List row because a row-level
    /// `.contentShape(.rect)` + `.onTapGesture` swallows the taps meant for the
    /// buttons inside it — measured: the like button could not be activated at
    /// all, by a test or by a finger, and no like ever reached the emulator.
    /// Keeping the gesture off the actions row is what makes both work.
    var onOpenPost: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            content
            actions
        }
        .padding(.vertical, Spacing.m)
        .background(Palette.background)
    }

    /// Everything that is not a control. Tappable as one piece in the feed.
    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            identity
            if !post.text.isEmpty { text }
            if let media = post.media.first {
                MediaView(item: media, size: mediaSize)
                    .onTapGesture {
                        // On the detail screen a photo opens full size; in the
                        // feed the whole card opens the post. One gesture, one
                        // meaning, depending on where you are.
                        if media.kind == .image, let onOpenImage {
                            onOpenImage(media.url)
                        } else {
                            onOpenPost?()
                        }
                    }
                if MediaView.frame(for: media.url).isCropped, onOpenImage != nil {
                    croppedHint
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture { onOpenPost?() }
    }

    private var identity: some View {
        HStack(spacing: Spacing.s) {
            Avatar(url: post.petAvatarURL ?? post.authorAvatarURL)
            VStack(alignment: .leading, spacing: Spacing.xs / 2) {
                // The pet leads when there is one; a post without a pet
                // degrades to the author rather than showing an empty row.
                Text(post.petName ?? post.authorName)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(post.createdAt, style: .relative)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: Spacing.s)
        }
        .padding(.horizontal, Layout.pageInset)
        // Author, pet and time read as one phrase.
        .accessibilityElement(children: .combine)
    }

    private var text: some View {
        Text(post.text)
            .font(Typography.body)
            .foregroundStyle(Palette.primaryText)
            .lineLimit(textLineLimit)
            .padding(.horizontal, Layout.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("post.text")
    }

    /// Says the frame is not the whole picture, and what to do about it.
    /// Shown only where there is somewhere to go.
    private var croppedHint: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .accessibilityHidden(true)
            Text("Tap photo to see all of it")
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, Layout.pageInset)
        .accessibilityIdentifier("post.croppedHint")
    }

    private var actions: some View {
        HStack(spacing: Spacing.xl) {
            Button(action: onLike) {
                Label {
                    Text("\(post.likeCount)")
                        .font(Typography.caption)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                }
                .foregroundStyle(isLiked ? Palette.brandPrimary : Palette.secondaryText)
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget, alignment: .leading)
                .contentShape(.rect)
            }
            // .borderless, and it is not cosmetic: inside a List the default
            // button style makes the whole row one target, so several buttons
            // in a row either all fire or — as happened here — none do. The
            // like button could not be activated at all and no like ever
            // reached the emulator.
            .buttonStyle(.borderless)
            .accessibilityIdentifier("post.like")
            .accessibilityLabel(isLiked ? "Unlike" : "Like")
            .accessibilityValue("\(post.likeCount) likes")

            Button(action: onOpenComments) {
                Label {
                    Text("\(post.commentCount)")
                        .font(Typography.caption)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "bubble.right")
                }
                .foregroundStyle(Palette.secondaryText)
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("post.comments")
            .accessibilityLabel("Comments")
            .accessibilityValue("\(post.commentCount)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pageInset)
    }
}

private struct Avatar: View {
    let url: URL?

    var body: some View {
        // .avatar, not the default .medium: this draws at 40pt and the web
        // client asks Cloudinary for w_100,h_100,c_fill here. Fetching w_800
        // for a 40pt circle is 60x the pixels, on every row.
        RemoteImage(url: url, aspectRatio: 1, cornerRadius: .infinity, size: .avatar)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }
}
