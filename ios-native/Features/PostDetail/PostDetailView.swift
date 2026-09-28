import SwiftUI

/// So a URL can drive `.fullScreenCover(item:)`.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// A post and its comments, with the composer pinned above the keyboard.
struct PostDetailView: View {
    @State private var model: PostDetailViewModel
    @State private var fullImageURL: URL?
    @Environment(SessionStore.self) private var session

    /// What the comment count scrolls to. A constant rather than a literal at
    /// two call sites, because a typo in either would fail silently — a
    /// `scrollTo` with an id nothing carries does nothing and says nothing.
    private static let commentsAnchor = "detail.commentsAnchor"

    init(model: PostDetailViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("detail.loading")
            case .failed(let message):
                FeedErrorView(message: message) { Task { await model.load() } }
            case .deleted:
                deletedState
            case .loaded(let post):
                loaded(post)
            }
        }
        .background(Palette.background)
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        // Where the person is, told to the session as they arrive. If a
        // session ends while this screen is up, this is the place §6.9 gives
        // back after signing in again.
        .onAppear { session.noteCurrentRoute(.postDetail(postID: model.postID)) }
        .onDisappear { session.noteCurrentRoute(.feed) }
        // The server said this caller is not authenticated. Rather than telling
        // a signed-in person to sign in, ask whether the session is still real;
        // if it is not, SessionStore ends it and the app returns to sign-in
        // with this screen remembered.
        .onChange(of: model.sendFailure) { _, failure in
            guard failure?.needsReauthentication == true else { return }
            Task { await session.revalidate() }
        }
        .fullScreenCover(item: $fullImageURL) { url in
            FullImageView(url: url)
        }
        .overlay(alignment: .bottom) { likeFailureBanner }
    }

    /// A like that could not be applied, or could not be confirmed.
    ///
    /// It has somewhere to go, which is the point: the model sets this on a
    /// failed or timed-out write, and state nothing renders is state nobody
    /// can act on.
    @ViewBuilder
    private var likeFailureBanner: some View {
        if let message = model.likeFailureMessage {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                Text(message)
                    .font(Typography.caption)
                    .accessibilityIdentifier("detail.likeError")
                Spacer(minLength: Spacing.s)
                Button {
                    model.likeFailureMessage = nil
                } label: {
                    Text("Dismiss")
                        .font(Typography.caption)
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("detail.likeErrorDismiss")
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, Layout.pageInset)
            .background(Palette.secondaryBackground)
        }
    }

    private var deletedState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "trash")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            Text("This post has been deleted")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("detail.deleted")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    private func loaded(_ post: Post) -> some View {
        // safeAreaInset rather than a VStack: with a stacked composer the
        // scroll view has no idea the bar is there, so the last thing in the
        // post — the like and comment row — ends up underneath it. An inset
        // makes the composer part of the safe area, so content scrolls clear of
        // it and the keyboard still pushes it up.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                        // No line clamp here: a post has to be readable in full
                        // somewhere, and the feed is where the clamp belongs.
                        // The like state is the model's, not a hardcoded false —
                        // an inert control that always reads "not liked" is worse
                        // than no control.
                        PostCard(
                            post: post
                                .withLikeCount(model.likeCount)
                                .withCommentCount(model.commentCount),
                            isLiked: model.isLiked,
                            onLike: { model.toggleLike() },
                            // Not an empty closure. The card reported an enabled
                            // button here, took the tap and dropped it — a dead
                            // control, which a person cannot tell from a broken
                            // one.
                            //
                            // It puts the comments under your eye, which is what
                            // the count is an invitation to look at. The first
                            // two attempts put the cursor in the composer
                            // instead, and **both were measured not to work**:
                            // `composerFocused = true` from the button's action,
                            // and the same assignment deferred one turn of the
                            // main actor, each left the keyboard down across
                            // nineteen and twenty consecutive reads. Rather than
                            // ship a third guess at the same effect, the action
                            // became one whose result can be seen and measured —
                            // the list moves, and a test can say by how much.
                            onOpenComments: { proxy.scrollTo(Self.commentsAnchor, anchor: .top) },
                            textLineLimit: nil,
                            mediaSize: .large,
                            onOpenImage: { fullImageURL = $0 }
                        )

                        // Where the comment count scrolls to. On the divider
                        // rather than on `commentsSection`, which is a
                        // `@ViewBuilder` producing several views and has no
                        // single element to carry an id.
                        Divider()
                            .overlay(Palette.separator)
                            .id(Self.commentsAnchor)

                        commentsSection
                    }
                .padding(.vertical, Spacing.m)
            }
            .refreshable { await model.loadComments(reset: true) }
            // Without this there is no way off the keyboard on this screen at all:
            // the composer is a vertical-axis TextField, so its return key inserts
            // a newline rather than submitting, and there is no toolbar and no
            // background to tap.
            //
            // `.immediately` rather than `.interactively`, and the reason is the
            // `.refreshable` directly above. Interactive dismissal follows a
            // *downward* drag, which at the top of the list is the same gesture
            // pull-to-refresh claims — so it never engaged, and the keyboard
            // stayed up. Measured: with `.interactively` the keyboard was still
            // present ten seconds after the drag.
            //
            // No fixed delay anywhere, here or below: the web client's 320ms wait
            // for the keyboard to "settle" is what the Chinese candidate bar
            // walked straight past.
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    /// Split on "is there anything to show" first, and on the load state
    /// second — rather than the other way round.
    ///
    /// The other way round is what shipped: a `.failed` comments state drew
    /// the error and nothing else, so losing *page three* took pages one and
    /// two off the screen with it. What the person was reading disappeared to
    /// report a page they had not got to yet. The three states still have to
    /// stay apart (§6.5) — "could not load", "none yet" and "still loading"
    /// are different facts — and they do: with nothing on screen each gets the
    /// whole area, and with something on screen the failure is a line under
    /// the comments it failed to add to.
    ///
    /// This used to be read off the code and not off a screen, because
    /// `FirestoreCommentRepository`'s fault injection covered `create` only
    /// and there was no way from a test to make page three fail while pages
    /// one and two were up. `ReadFault.failNextPageOnce` is that way, and
    /// `CommentUITests.testALostCommentPageKeepsTheCommentsAlreadyReadAndThe-
    /// RetryAddsThem` is the run: page one stays on screen, the failure is a
    /// line under it, and the retry brings page two in.
    @ViewBuilder
    private var commentsSection: some View {
        if model.comments.isEmpty {
            switch model.commentsState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading comments")
            case .failed(let message):
                commentsFailure(message)
            default:
                Text("No comments yet")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, Layout.pageInset)
                    .accessibilityIdentifier("detail.noComments")
            }
        } else {
            // A failed *refresh* goes above the rows, not after them. The
            // person pulled down at the top; that is where they are looking,
            // and on a post with a long comment list "after the last row" is
            // far enough down that SwiftUI had not built it — so the notice
            // was neither visible nor in the accessibility tree, and the only
            // thing that told us was a test that could not find it.
            if case .failed(let message) = model.commentsState,
               model.commentsFailureCameFromARefresh {
                commentsFailure(message)
            }
            ForEach(model.comments) { comment in
                CommentRow(comment: comment)
                    .task { await model.loadMoreCommentsIfNeeded(currentItem: comment) }
            }
            // …and a page that failed to arrive stays at the bottom, where the
            // reader was heading when it did not turn up.
            if case .failed(let message) = model.commentsState,
               !model.commentsFailureCameFromARefresh {
                commentsFailure(message)
            } else if model.hasMoreComments {
                // `hasMoreComments` is set false on failure, so this cannot
                // draw a "loading more" spinner underneath a refresh that just
                // failed above.
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading more comments")
            }
        }
    }

    private func commentsFailure(_ message: String) -> some View {
        VStack(spacing: Spacing.s) {
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("detail.commentsError")
            Button {
                Task { await model.retryComments() }
            } label: {
                Text("Try again")
                    .font(Typography.body)
                    .foregroundStyle(Palette.brandPrimary)
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("detail.commentsRetry")
        }
        .padding(.horizontal, Layout.pageInset)
    }

    private var composer: some View {
        VStack(spacing: Spacing.s) {
            if let failure = model.sendFailure {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(
                        systemName: failure.tone == .resolved
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .accessibilityHidden(true)
                    Text(failure.message)
                        .accessibilityIdentifier("composer.error")
                    Spacer(minLength: Spacing.s)
                    // Only when repeating the request is worth something. It is
                    // deliberately absent while an outcome is unknown: the
                    // callable has no idempotency key, so a button to press by
                    // reflex there is a button that posts the comment twice.
                    if failure.canRetry {
                        Button {
                            guard case .signedIn(let user) = session.state else { return }
                            Task { await model.send(authorID: user.uid, authorName: user.email) }
                        } label: {
                            Text("Try again")
                                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityIdentifier("composer.retry")
                    }
                    Button {
                        model.dismissFailure()
                    } label: {
                        Text("Dismiss")
                            .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("composer.dismiss")
                }
                .font(Typography.caption)
                // A success reported in the colour of a failure is its own
                // small lie.
                .foregroundStyle(failure.tone == .resolved ? Palette.success : Palette.danger)
                .padding(.horizontal, Layout.pageInset)
            }

            HStack(alignment: .bottom, spacing: Spacing.s) {
                // Grows with the text and then scrolls internally, so a long
                // comment never hides what is already typed.
                TextField("Add a comment", text: $model.draft, axis: .vertical)
                    .font(Typography.body)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .frame(minHeight: Layout.minTouchTarget)
                    .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.control))
                    .accessibilityIdentifier("composer.field")
                    // `.disabled(model.isSending)` stays, and it stays because
                    // the case against it did not survive being measured.
                    // Disabling a focused text field resigns first responder,
                    // which reads as "every send takes the keyboard away", so
                    // it was going to be removed. It does not: a send against
                    // the local emulator kept the keyboard up across eight
                    // consecutive reads — `MEASURED keyboard after send:
                    // ["up" x8]`, recorded by
                    // `testSendingACommentDoesNotTakeTheKeyboardAway`.
                    // Removing it would have bought nothing observable and
                    // would have let someone type into a box whose contents
                    // `send()` overwrites when a send fails.
                    //
                    // The slow case is *not* established either way: a local
                    // send finishes well inside the time a disabled state
                    // would need to be noticed, and a send over a real
                    // network does not. Unverified, not claimed.
                    .disabled(model.isSending)

                Button {
                    guard case .signedIn(let user) = session.state else { return }
                    Task { await model.send(authorID: user.uid, authorName: user.email) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Typography.pageTitle)
                        .foregroundStyle(canSend ? Palette.brandPrimary : Palette.disabled)
                        .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .disabled(!canSend)
                .accessibilityIdentifier("composer.send")
                .accessibilityLabel("Send comment")
            }
            .padding(.horizontal, Layout.pageInset)

            // Only near the limit: a counter that is always on is noise, and
            // one that appears only after the server refuses is too late. The
            // cap is the server's (VALIDATION_LIMITS.commentText = 500).
            if model.draft.count > PostDetailViewModel.maxCommentLength - 50 {
                Text("\(model.remainingCharacters)")
                    .font(Typography.caption)
                    .foregroundStyle(model.isOverLength ? Palette.danger : Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, Layout.pageInset)
                    .accessibilityIdentifier("composer.remaining")
                    // Spoken differently from how it is drawn. "-3" is the
                    // conventional way to show being over a limit and stays;
                    // read out, "minus three characters remaining" is a
                    // sentence nobody can act on.
                    .accessibilityLabel(
                        model.isOverLength
                            ? "\(-model.remainingCharacters) characters too many"
                            : "\(model.remainingCharacters) characters remaining"
                    )
            }
        }
        // Breathing room without a dead zone: the web client once reserved
        // 176px for a tab bar that page did not show.
        .padding(.vertical, Spacing.s)
        .background(Palette.background)
        .overlay(alignment: .top) { Divider().overlay(Palette.separator) }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isSending
            && !model.isOverLength
    }
}

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(comment.authorName)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                if comment.isPending {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text("Sending…")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            Text(comment.text)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.pageInset)
        .accessibilityElement(children: .combine)
        // One element per comment, and it is addressable. Without this a test
        // counting "how many comments contain this text" also counts the inner
        // Text views and reports two comments where there is one.
        .accessibilityIdentifier("comment.row")
        // No blanket opacity. Dimming the whole row to 0.6 took the author
        // name and the body text below 4.5:1 — measured by
        // PaletteContrastTests.pendingCommentRowStaysReadable — to say
        // something the explicit "Sending…" label already says at full
        // strength, and says to VoiceOver as well.
    }
}
