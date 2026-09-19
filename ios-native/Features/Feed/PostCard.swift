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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            identity
            if !post.text.isEmpty { text }
            if let media = post.media.first { MediaView(item: media, size: mediaSize) }
            actions
        }
        .padding(.vertical, Spacing.m)
        .background(Palette.background)
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
