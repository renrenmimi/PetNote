import SwiftUI

/// The feed.
///
/// `List` rather than `LazyVStack` in a `ScrollView`: it reuses rows, and §2
/// says to measure before reaching for the UIKit bridge. If stage 7 misses the
/// scroll budget and Instruments points here, `UICollectionView` is the next
/// step — but not before a measurement says so.
struct FeedView: View {
    @State private var model: FeedViewModel
    /// The birthday banner, the spotlight row and the cards' birthday marks.
    /// Owned by the shell with `model`, and reset with it on an account switch.
    @State private var extras: FeedExtrasModel
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
    /// Whether the person has waved away the banner for the failure that is
    /// current. Reset by `onChange(of: model.state)` when a new one arrives,
    /// so dismissing one failure does not silence the next.
    @State private var refreshFailureDismissed = false

    init(model: FeedViewModel, extras: FeedExtrasModel, path: Binding<[Route]>) {
        _model = State(initialValue: model)
        _extras = State(initialValue: extras)
        _path = path
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loadingFirstPage:
                // A refresh is not a first load. `reload()` moves the model
                // to `.loadingFirstPage` whatever was on screen, so switching
                // on that state alone hands the whole screen to the first-load
                // spinner for the length of the round trip — taking the rows
                // the person is reading and the `List` that owns the refresh
                // control they are still looking at.
                //
                // Not seen on a screen: against the local emulator the reload
                // returns faster than a UI test can resolve its first query,
                // and `testPullToRefreshDoesNotBlankTheFeed` sampled only the
                // steady state. The length of the blank is the length of the
                // round trip, which on a phone on a train is not 90ms — so
                // this is a reading of the path rather than a repair of an
                // observation, and is recorded as one.
                if model.posts.isEmpty { loading } else { list }
            case .failed(let kind):
                // Same split, for the same reason. A refresh that fails is a
                // reason to say so, not a reason to throw away a feed that is
                // still perfectly readable — see `refreshFailureBanner`, which
                // is where the saying-so happens.
                if model.posts.isEmpty {
                    FeedErrorView(message: kind.message) { Task { await model.reload() } }
                } else {
                    list
                }
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
        .task { await extras.loadIfNeeded() }
        // On the ids, so a new page or a refresh asks about the pets it
        // brought and nothing else — `checkBirthdays` skips the ones it has.
        // A task of its own rather than `.task(id:)`: that one is cancelled
        // when the ids change, and a read cancelled half way loses its answer
        // — those pets would go unmarked until some later page asked again.
        .onChange(of: model.posts.map(\.id), initial: true) { _, _ in
            Task { await extras.checkBirthdays(for: model.posts) }
        }
        .refreshable {
            // Alongside the feed's own refresh, not in front of it: the
            // spotlight's read is not a reason for the list's refresh control
            // to spin any longer.
            Task { await extras.reload() }
            await model.reload()
        }
        // An inset rather than an overlay: this one says the list underneath
        // is out of date, and a banner that covers the row it is talking
        // about is its own small problem.
        .safeAreaInset(edge: .top, spacing: 0) { refreshFailureBanner }
        .onChange(of: model.state) { _, newState in
            if case .failed = newState { refreshFailureDismissed = false }
        }
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
                // The web feed's order: the birthday banner, then the
                // spotlight, then the posts. Rows of this list rather than
                // views above it, so they scroll away with it.
                if let banner = extras.visibleBanner {
                    BirthdayBannerRow(
                        banner: banner,
                        onOpen: { openPet(banner.petID) },
                        onDismiss: { extras.dismissBanner() }
                    )
                    .listRowInsets(EdgeInsets(
                        top: Spacing.s, leading: Layout.pageInset, bottom: 0, trailing: Layout.pageInset
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Palette.background)
                }
                PetSpotlightRow(phase: extras.spotlight, onOpen: { openFromSpotlight($0) })
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Palette.background)

                ForEach(model.posts) { post in
                PostCard(
                    post: post
                        .withLikeCount(model.displayLikeCount(for: post))
                        .withCommentCount(model.displayCommentCount(for: post)),
                    isLiked: model.isLiked(post),
                    onLike: { model.toggleLike(post) },
                    onOpenComments: { open(post) },
                    // The gesture is inside the card, on its content only. A
                    // row-level tap gesture swallowed every button in the card.
                    onOpenPost: { open(post) },
                    isBirthday: extras.hasBirthday(petID: post.petID)
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
        // One push per post. `path` is an array, so two taps inside the
        // third of a second the push animation takes would append
        // `.postDetail` twice and put two copies of the same screen on the
        // stack — which, from where the person is sitting, is Back not
        // working: they tap it, the same post is underneath, and the app
        // looks like it ignored them.
        //
        // Hardening, not a repair: `testTappingAPostTwiceQuicklyOpensOne-
        // Screen` passed before this guard existed, so the synthesised
        // double tap never produced the second push on a simulator. The
        // path is open in the code and a finger is not a synthesised tap;
        // the guard costs one comparison and the claim is kept to that.
        guard !path.contains(.postDetail(postID: post.id)) else { return }
        model.rememberScrollAnchor(post.id)
        path.append(.postDetail(postID: post.id))
    }

    /// A spotlight tile: seen from now on, then the post.
    ///
    /// No scroll anchor. The post may not be a row of this list at all — the
    /// spotlight reaches back a week — and an anchor naming a row that is not
    /// there would replace the one that is.
    private func openFromSpotlight(_ postID: String) {
        extras.markSeen(postID)
        guard !path.contains(.postDetail(postID: postID)) else { return }
        path.append(.postDetail(postID: postID))
    }

    /// The birthday banner: the pet's page, once per tap for the reason
    /// `open(_:)` gives.
    private func openPet(_ petID: String) {
        guard !path.contains(.pet(petID: petID)) else { return }
        path.append(.pet(petID: petID))
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

    /// A reload that failed over a feed that still has something on it.
    ///
    /// The whole-screen `FeedErrorView` is still what an empty feed gets —
    /// there is nothing to keep, and "we could not find out" is then the only
    /// thing to say. This is the other case: the rows are still there, still
    /// readable, and the only new fact is that they are older than the person
    /// asked for. Replacing them with an error screen said that fact by
    /// deleting the answer to the question it was reporting on.
    @ViewBuilder
    private var refreshFailureBanner: some View {
        if case .failed(let kind) = model.state, !model.posts.isEmpty, !refreshFailureDismissed {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                // The identifier on the Text, never on the HStack around it:
                // an identifier on a container overwrites every descendant's.
                Text(kind.message)
                    .font(Typography.caption)
                    .accessibilityIdentifier("feed.refreshError")
                Spacer(minLength: Spacing.s)
                Button {
                    Task { await model.reload() }
                } label: {
                    Text("Try again")
                        .font(Typography.caption)
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("feed.refreshRetry")
                Button {
                    refreshFailureDismissed = true
                } label: {
                    Text("Dismiss")
                        .font(Typography.caption)
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("feed.refreshErrorDismiss")
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, Layout.pageInset)
            .background(Palette.secondaryBackground)
        }
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
