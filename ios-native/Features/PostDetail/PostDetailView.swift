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
        .fullScreenCover(item: $fullImageURL) { url in
            FullImageView(url: url)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    // No line clamp here: a post has to be readable in full
                    // somewhere, and the feed is where the clamp belongs.
                    // The like state is the model's, not a hardcoded false —
                    // an inert control that always reads "not liked" is worse
                    // than no control.
                    PostCard(
                        post: post.withLikeCount(model.likeCount),
                        isLiked: model.isLiked,
                        onLike: { model.toggleLike() },
                        onOpenComments: {},
                        textLineLimit: nil,
                        mediaSize: .large,
                        onOpenImage: { fullImageURL = $0 }
                    )

                    Divider().overlay(Palette.separator)

                    commentsSection
                }
            .padding(.vertical, Spacing.m)
        }
        .refreshable { await model.loadComments(reset: true) }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    }

    @ViewBuilder
    private var commentsSection: some View {
        switch model.commentsState {
        case .loading where model.comments.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading comments")

        case .failed(let message):
            // Not an empty list: "could not load" and "none yet" are different
            // facts and must not look the same (§6.5).
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

        default:
            if model.comments.isEmpty {
                Text("No comments yet")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, Layout.pageInset)
                    .accessibilityIdentifier("detail.noComments")
            } else {
                ForEach(model.comments) { comment in
                    CommentRow(comment: comment)
                        .task { await model.loadMoreCommentsIfNeeded(currentItem: comment) }
                }
                if model.hasMoreComments {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Loading more comments")
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: Spacing.s) {
            if let failure = model.sendFailure {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                    Text(failure.message)
                        .accessibilityIdentifier("composer.error")
                    Spacer(minLength: Spacing.s)
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
                .foregroundStyle(Palette.danger)
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
                    .accessibilityLabel("\(model.remainingCharacters) characters remaining")
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
                    Text("Sending…")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.tertiaryText)
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
        .opacity(comment.isPending ? 0.6 : 1)
    }
}
