import SwiftUI

/// The feed.
///
/// `List` rather than `LazyVStack` in a `ScrollView`: it reuses rows, and §2
/// says to measure before reaching for the UIKit bridge. If stage 7 misses the
/// scroll budget and Instruments points here, `UICollectionView` is the next
/// step — but not before a measurement says so.
struct FeedView: View {
    @State private var model: FeedViewModel
    @Binding private var path: [Route]

    init(model: FeedViewModel, path: Binding<[Route]>) {
        _model = State(initialValue: model)
        _path = path
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loadingFirstPage:
                loading
            case .failed(let kind):
                FeedErrorView(message: kind.message) { Task { await model.reload() } }
            case .loaded:
                if model.posts.isEmpty { emptyState } else { list }
            }
        }
        .navigationTitle("PetNote")
        .navigationBarTitleDisplayMode(.inline)
        .background(Palette.background)
        .task { await model.loadFirstPageIfNeeded() }
        .refreshable { await model.reload() }
        .overlay(alignment: .bottom) { likeFailureBanner }
    }

    private var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .accessibilityIdentifier("feed.loading")
            .accessibilityLabel("Loading posts")
    }

    /// Empty is not failure. The web client rendered "no data" as a product
    /// slogan, which read like a feature rather than an empty state.
    private var emptyState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "pawprint")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.tertiaryText)
                .accessibilityHidden(true)
            Text("No posts yet")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("feed.empty")
            Text("Posts from pets you follow will appear here.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(Layout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    private var list: some View {
        List {
            ForEach(model.posts) { post in
                PostCard(
                    post: post.withLikeCount(model.displayLikeCount(for: post)),
                    isLiked: model.isLiked(post),
                    onLike: { model.toggleLike(post) },
                    onOpenComments: { path.append(.postDetail(postID: post.id)) }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Palette.background)
                .contentShape(.rect)
                .onTapGesture { path.append(.postDetail(postID: post.id)) }
                .task { await model.loadMoreIfNeeded(currentItem: post) }
            }

            // A lost page is shown where it happened, with its own retry. A
            // modal would interrupt reading to report something that did not
            // affect what is already on screen.
            if let failure = model.pagingFailure {
                pagingFailureRow(failure)
            } else if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().accessibilityLabel("Loading more posts")
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Palette.background)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("feed.list")
    }

    private func pagingFailureRow(_ failure: FeedViewModel.FailureKind) -> some View {
        VStack(spacing: Spacing.s) {
            Text(failure.message)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("feed.pagingError")
            Button {
                Task { await model.retryPaging() }
            } label: {
                Text("Try again")
                    .font(Typography.body)
                    .foregroundStyle(Palette.brandPrimary)
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("feed.pagingRetry")
        }
        .padding(.vertical, Spacing.m)
        .listRowSeparator(.hidden)
        .listRowBackground(Palette.background)
    }

    @ViewBuilder
    private var likeFailureBanner: some View {
        if let message = model.likeFailureMessage {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                Text(message).font(Typography.caption)
                Spacer(minLength: Spacing.s)
                Button {
                    model.likeFailureMessage = nil
                } label: {
                    Text("Dismiss")
                        .font(Typography.caption)
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("feed.likeErrorDismiss")
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, Layout.pageInset)
            .background(Palette.secondaryBackground)
            .accessibilityIdentifier("feed.likeError")
        }
    }
}

struct FeedErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("feed.errorMessage")

            // Frame, background and contentShape all on the LABEL. On the
            // Button they change where it sits without changing what can be
            // tapped — the same mistake that shipped a 20pt sign-out control.
            Button(action: retry) {
                Text("Try again")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textOnBrand)
                    .padding(.horizontal, Spacing.xl)
                    .frame(minHeight: Layout.minTouchTarget)
                    .background(Palette.brandGradient, in: .rect(cornerRadius: Radius.control))
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("feed.retry")
        }
        .padding(Layout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        // No identifier on this container: it would overwrite feed.retry on the
        // button inside it, the way root.signedIn once overwrote every element
        // on that screen.
    }
}
