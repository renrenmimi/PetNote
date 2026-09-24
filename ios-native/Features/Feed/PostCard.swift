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
    /// The post's pet has its birthday today — the web card's
    /// `initialBirthday`. Only the feed asks (`FeedExtrasModel.checkBirthdays`);
    /// the pet page says it in words of its own.
    var isBirthday = false

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
            // The card's own "tap to open" covers the identity row and the
            // text — and stops there. It used to wrap the media too, and that
            // is the third time a gesture spread over a view has eaten the
            // controls inside it:
            //
            //   1. the like button could not be activated at all (fixed with
            //      `.buttonStyle(.borderless)`);
            //   2. nothing told VoiceOver the card could be opened (fixed by
            //      putting the action on `identity`);
            //   3. **this one** — the mute control inside a playing video.
            //      A tap on the speaker opened the post: the app log reads
            //      `video: released all (navigated away)` at the moment of
            //      the tap, and the detail screen then built a second player
            //      that drew the same `video.mute`. From a test it looked
            //      like "the toggle does not work"; what happened is that
            //      the person was already on another screen.
            //
            // Removing the inner `.onTapGesture` that sat directly on
            // `MediaView` was not enough on its own — measured, the tap still
            // navigated, because this outer one reached the speaker too.
            identity
            if !post.text.isEmpty {
                text
                    .contentShape(.rect)
                    .onTapGesture { onOpenPost?() }
            }

            if let media = post.media.first {
                if media.kind == .video {
                    // Nothing of ours over a video. The player owns controls
                    // inside its own bounds and they have to be reachable;
                    // the rest of the card still opens the post.
                    mediaView(media)
                } else {
                    photo(media)
                }

                if MediaView.frame(for: media.url).isCropped, onOpenImage != nil {
                    croppedHint
                }
            }
        }
        // No identifier and no gesture on this stack. A tap gesture on a
        // container is invisible to VoiceOver — the subviews are each their
        // own element and none of them is a button — which is why the way in
        // for VoiceOver is the identity row and not this.
    }

    private func mediaView(_ media: MediaItem) -> some View {
        // An action, declared on the element that *is* the media, rather than
        // a gesture wrapped around it: a bare gesture is invisible to
        // VoiceOver, and it also swallowed the mute button underneath it.
        //
        // Which action depends on where the card is, and both screens have
        // one. The detail screen opens the photo full size. The feed opens the
        // post — a comment here previously said a photo in the feed "is not a
        // control because there is nowhere for it to go", and passing nil on
        // that reasoning left video rows with no gesture at all: tapping the
        // picture did nothing and the post could not be opened from it.
        // Both screens have an action for the media; they are different
        // actions. The detail screen opens the photo full size. The feed opens
        // the post — an earlier comment claimed a photo in the feed "is not a
        // control because there is nowhere for it to go", and passing nil on
        // that reasoning left video rows with no gesture at all.
        if let onOpenImage {
            MediaView(
                postID: post.id, item: media, size: mediaSize,
                onActivate: onOpenImage,
                activationHint: MediaView.frame(for: media.url).isCropped
                    ? "Opens the whole photo" : "Opens the photo full screen"
            )
        } else {
            MediaView(
                postID: post.id, item: media, size: mediaSize,
                onActivate: onOpenPost.map { open in { _ in open() } },
                activationHint: "Opens the post"
            )
        }
    }

    /// A photo, plus the feed's own "tapping it opens the post".
    ///
    /// Safe here and not over a video for one reason: a photo has no controls
    /// inside it to swallow. On the detail screen this adds nothing —
    /// `onOpenImage` is set there, so `MediaView` owns the gesture and this
    /// closure is nil.
    @ViewBuilder
    private func photo(_ media: MediaItem) -> some View {
        if onOpenImage == nil {
            mediaView(media)
                .contentShape(.rect)
                .onTapGesture { onOpenPost?() }
        } else {
            mediaView(media)
        }
    }

    /// The pet or author line, and the way into the post for VoiceOver.
    ///
    /// Tapping anywhere on the card opens it visually, but a tap gesture on a
    /// container is invisible to VoiceOver: every subview was its own element,
    /// none of them was a button, and nothing in the card said it could be
    /// opened. The only way in was the Comments button, and the cropped
    /// hint's "Tap photo" named an action that could not be reached at all.
    ///
    /// Here rather than on the body text for two reasons. Every post has an
    /// identity row and not every post has text. And putting `.isButton` on
    /// `post.text` changes that element's type from static text to button,
    /// which silently unmatched twenty queries across the test suite — a fix
    /// whose cost is rewriting the tests that watch it is worth looking at
    /// twice.
    ///
    /// The name and the timestamp are combined deliberately: "Mochi, 2 hours
    /// ago" is one thought, and hearing it as one utterance followed by
    /// "button" is how this reads on other feeds.
    private var identity: some View {
        HStack(spacing: Spacing.s) {
            Avatar(url: post.petAvatarURL ?? post.authorAvatarURL)
            VStack(alignment: .leading, spacing: Spacing.xs / 2) {
                HStack(spacing: Spacing.xs) {
                    // The pet leads when there is one; a post without a pet
                    // degrades to the author rather than showing an empty row.
                    Text(post.petName ?? post.authorName)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isBirthday {
                        // Fixed, so a long name truncates before the cake
                        // does. Inside the row's combined element, so it is
                        // heard as part of "Mochi, birthday today, 2 hours ago".
                        Text(FeedExtras.birthdayMark)
                            .font(Typography.caption)
                            .fixedSize()
                            .accessibilityLabel("Birthday today")
                    }
                }
                Text(post.createdAt, style: .relative)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: Spacing.s)
        }
        .padding(.horizontal, Layout.pageInset)
        // Making this row activatable also makes it a control, and controls
        // have a size to meet. It laid out at 40pt and the touch-target audits
        // failed it the first time they saw it — which is the audits working:
        // a new control appeared and was measured before anyone had to
        // remember to measure it.
        //
        // The frame and the contentShape together, because the frame alone
        // changes the layout without changing what responds to a finger. That
        // mistake shipped the sign-out button at 20pt once already.
        .frame(minHeight: Layout.minTouchTarget)
        .contentShape(.rect)
        // The tap lives on this row and on the post's text, one each, rather
        // than on a stack wrapped around the pair. A wrapper is a container,
        // and a container with a gesture on it is the shape that has cost
        // this file three defects; it also made the accessibility walk in
        // `testTheCardAdvertisesThatItCanBeOpened` lose the app mid-scan.
        // Two gestures on two leaves add no container at all.
        .onTapGesture { onOpenPost?() }
        // Author, pet and time read as one phrase.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the post")
        .accessibilityAction { onOpenPost?() }
        .accessibilityIdentifier("post.open")
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

            PostShareMenu(post: post)
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
