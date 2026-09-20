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
    @Environment(VideoPlaybackCoordinator.self) private var video
    @Environment(SessionStore.self) private var session
    /// Read here rather than in the detail screen because the feed is the root
    /// of the signed-in stack: it stays in the hierarchy whatever is pushed on
    /// top of it, so it sees every foreground, not only the ones that happen
    /// while it is the visible screen.
    @Environment(\.scenePhase) private var scenePhase
    /// What `returnToWhereTheSessionEnded` decided, for the probe below.
    @State private var resumeDecision = "notRun"

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
        .toolbar { ToolbarItem(placement: .principal) { videoProbe } }
        .overlay(alignment: .topLeading) { sessionProbe }
        .background(Palette.background)
        .task { await model.loadFirstPageIfNeeded() }
        .task { returnToWhereTheSessionEnded() }
        .refreshable { await model.reload() }
        .overlay(alignment: .bottom) { likeFailureBanner }
        // A session can be revoked while the app is in the background, and
        // nothing about a cached ID token notices: it stays valid for an hour
        // and neither Firestore nor the callables ask whether the account
        // behind it still exists. So the question gets asked at a predictable
        // moment — coming back to the app — instead of an arbitrary one.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.revalidate() }
        }
    }

    /// Puts the person back on the screen a revoked session took them off.
    ///
    /// Only for the same account, and only once: `consumeResume` drops the
    /// stored place if a different uid signs in, because restoring the previous
    /// account's screen is exactly the leak §4.4 forbids.
    private func returnToWhereTheSessionEnded() {
        guard case .signedIn(let user) = session.state, path.isEmpty else {
            resumeDecision = "notAsked"
            return
        }
        guard let route = session.consumeResume(for: user.uid) else {
            resumeDecision = "nothingHeld"
            return
        }
        path.append(route)
        resumeDecision = "restored"
    }

    /// What the restore above decided, and what the stack holds now.
    ///
    /// Behind a launch argument and effectively invisible, like the video
    /// probe, and for the same reason: the two ways "the person did not get
    /// their screen back" can happen are indistinguishable from outside. Either
    /// nothing was held for this account — a session-store question — or a
    /// route was appended and something later emptied the path, which is a
    /// question about whoever owns the stack. One reading separates them.
    ///
    /// Gated with `#if DEBUG` rather than by the runtime check alone: a
    /// runtime check still leaves the flag name and the branch in the shipped
    /// binary, and the candidate package is required to carry no test switch
    /// at all. In a Release build this builder produces `EmptyView`.
    @ViewBuilder
    private var sessionProbe: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-petnote-session-probe") {
            Text("resume=\(resumeDecision) path=\(path.count)")
                .font(Typography.caption)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityIdentifier("session.resumeProbe")
        }
        #endif
    }

    /// Publishes the coordinator's real state for UI tests: how many players
    /// exist, which one is playing, and that player's clock.
    ///
    /// Behind a launch argument and zero-sized, so it changes nothing about the
    /// app a person sees. It exists because the alternative — asserting the
    /// coordinator's own `playingID` from a unit test — is exactly what let a
    /// video that never played look correct.
    ///
    /// Behind `#if DEBUG` for the same reason as `sessionProbe`: compiled out
    /// of a Release build entirely, rather than merely switched off in it.
    @ViewBuilder
    private var videoProbe: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-petnote-video-probe") {
            // No TimelineView, and that matters more than where it lives: a
            // periodic redraw means the app never reports itself idle, and
            // XCUITest waits for idle before every query. With a half-second
            // tick a single run spent 1070 seconds waiting and then gave up.
            // The probe redraws when the coordinator changes, which is what
            // @Observable already gives us.
            //
            // Playback time is not published here — it changes continuously by
            // definition. It is written to the log instead, where sampling it
            // costs the app nothing.
            Text(probeReading)
                .font(Typography.caption)
                .opacity(0.001)
                .accessibilityIdentifier("video.probe")
        }
        #endif
    }

    private var probeReading: String {
        "players=\(video.livePlayerCount) playing=\(video.playingID ?? "none")"
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
        // ScrollViewReader so returning from a detail screen can put the same
        // row back under the reader's eye. §4 says not to rely on the system's
        // own restoration: the list is rebuilt when the stack pops, and what it
        // restores is a content offset, which is wrong as soon as a row above
        // has changed height (an image arriving, a like count widening).
        // Anchoring to an identity survives that.
        ScrollViewReader { proxy in
            List {
                ForEach(model.posts) { post in
                PostCard(
                    post: post.withLikeCount(model.displayLikeCount(for: post)),
                    isLiked: model.isLiked(post),
                    onLike: { model.toggleLike(post) },
                    onOpenComments: { open(post) },
                    // The gesture is inside the card, on its content only. A
                    // row-level tap gesture swallowed every button in the card.
                    onOpenPost: { open(post) }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Palette.background)
                .task { await model.loadMoreIfNeeded(currentItem: post) }
                .id(post.id)
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
            .onChange(of: path.isEmpty) { _, isAtFeed in
                // Popped back to the feed: put the row we left from back where
                // it was. `anchor: .center` rather than .top because the row
                // the person tapped was somewhere in the middle of the screen,
                // not pinned to its edge.
                guard isAtFeed, let anchor = model.scrollAnchor else { return }
                proxy.scrollTo(anchor, anchor: .center)
                model.clearScrollAnchor()
            }
        }
    }

    /// Remember where we were before leaving, so coming back is a restore
    /// rather than a guess.
    private func open(_ post: Post) {
        model.rememberScrollAnchor(post.id)
        path.append(.postDetail(postID: post.id))
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
