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
    /// Where the post sits. The feed and a pet's page show the web client's
    /// card (`PostCard.tsx`): a rounded panel on the grouped background, with
    /// a hairline edge and a soft shadow. The detail screen is the post's own
    /// page and stays edge to edge.
    var chrome: Chrome = .page

    enum Chrome {
        case card
        case page
    }

    /// The session's saved posts. Optional on purpose: a card drawn where no
    /// session provides it (a preview) shows no save button, rather than
    /// taking the app down the way a missing required environment value does
    /// (`1a61171`).
    @Environment(PostBookmarks.self) private var bookmarks: PostBookmarks?

    var body: some View {
        switch chrome {
        case .page:
            stack
                .padding(.vertical, Spacing.m)
                .background(Palette.background)
        case .card:
            stack
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.l)
                .background(Palette.cardBackground)
                .clipShape(.rect(cornerRadius: Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card)
                        .strokeBorder(Palette.separator, lineWidth: 0.5)
                        .accessibilityHidden(true)
                }
                .shadow(color: Palette.cardShadow, radius: 12, y: 6)
        }
    }

    /// The web client's order: who, the picture, what you can do, then the
    /// words (`PostCard.tsx`). The text used to sit above the picture.
    private var stack: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            content
            actions
            if !post.text.isEmpty {
                text
                    .contentShape(.rect)
                    .onTapGesture { onOpenPost?() }
            }
        }
    }

    /// Everything that is not a control. Tappable as one piece in the feed.
    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // The card's own "tap to open" covers the identity row and the
            // text (drawn below the actions, in `stack`) — and stops there. It used to wrap the media too, and that
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
                // The pet leads when there is one; a post without a pet
                // degrades to the author rather than showing an empty row.
                Text(post.petName ?? post.authorName)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The web client's second line (`PostIdentity.tsx`): the
                // owner and the age when a pet leads, the age alone when the
                // author already does.
                HStack(spacing: Spacing.xs) {
                    if post.petName != nil {
                        Text(post.authorName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                    }
                    Text(PostAge.short(post.createdAt))
                        .fixedSize()
                        .accessibilityLabel(PostAge.spoken(post.createdAt))
                }
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
            // The web client's row (`PostActions.tsx`): outline icons in one
            // grey at the same size, and a like as a filled red heart. Only
            // the heart turns red; the count beside it is text and stays grey
            // (see `Palette.likeActive`).
            Button(action: onLike) {
                Label {
                    Text("\(post.likeCount)")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                } icon: {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .imageScale(.large)
                        .foregroundStyle(isLiked ? Palette.likeActive : Palette.iconInactive)
                }
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
                    // Round, as the web's MessageCircle is.
                    Image(systemName: "message")
                        .imageScale(.large)
                        .foregroundStyle(Palette.iconInactive)
                }
                .foregroundStyle(Palette.secondaryText)
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("post.comments")
            .accessibilityLabel("Comments")
            .accessibilityValue("\(post.commentCount)")

            // With the like and the comments, as the web's Send is; the save
            // button takes the far end, as the web's Bookmark does.
            PostShareMenu(post: post)

            Spacer(minLength: 0)

            bookmarkButton
        }
        .padding(.horizontal, Layout.pageInset)
    }

    /// The web client's Bookmark (`PostActions.tsx`): outline at rest, filled
    /// in the brand purple when saved. The state is the session's, shared with
    /// the detail screen's menu, so the two never disagree.
    ///
    /// Not disabled while a save is out — a disabled button dims, and it
    /// would flash on every tap. `PostBookmarks.toggle` ignores a second tap
    /// on the same post until the first is answered instead.
    @ViewBuilder
    private var bookmarkButton: some View {
        if let bookmarks {
            let isSaved = bookmarks.isSaved(post.id)
            Button {
                Task { await bookmarks.toggle(post.id) }
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .imageScale(.large)
                    .foregroundStyle(isSaved ? Palette.brandPrimary : Palette.iconInactive)
                    .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("post.bookmark")
            .accessibilityLabel(isSaved ? String(localized: "Remove from saved") : String(localized: "Save"))
        }
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
