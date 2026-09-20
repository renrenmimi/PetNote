import SwiftUI

/// Everything behind a session: the feed, and what it navigates to.
///
/// The path is held here rather than inside the feed so returning to it
/// restores the same list instance — which is what makes "come back to where
/// you were" (5B.3) a property of the navigation rather than something the
/// feed has to reconstruct.
struct SignedInView: View {
    let user: UserSession

    @Environment(SessionStore.self) private var session
    @State private var path: [Route] = []
    @State private var feedModel: FeedViewModel
    /// One coordinator for the whole signed-in tree: the player ceiling and
    /// "only the most visible one plays" are global properties, and a per-view
    /// owner could not enforce either.
    @State private var video = VideoPlaybackCoordinator()
    private let repositories: Repositories

    init(user: UserSession, repositories: Repositories = .live) {
        self.user = user
        self.repositories = repositories
        _feedModel = State(
            initialValue: FeedViewModel(
                feed: repositories.feed, likes: repositories.likes, accountID: user.uid
            )
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            FeedView(model: feedModel, path: $path)
                .environment(video)
                // An account *switch* keeps this view's identity — SwiftUI sees
                // the same SignedInView in the same place — so every piece of
                // @State here survives it, and all three of them are the
                // previous person's. Signing out is not this case: it replaces
                // the whole session scope and gets a fresh model for free.
                //
                // Ordered deliberately: the feed first, because it owns the
                // like state whose stale offset is the one that shows the
                // wrong number to the wrong person.
                .task(id: user.uid) {
                    feedModel.prepare(for: user.uid)
                    path = []
                    video.releaseAll(reason: "account switched")
                }
                .task {
                    // Only under the probe flag: it is a diagnostic, and a
                    // per-second task in the app a person uses is waste.
                    if ProcessInfo.processInfo.arguments.contains("-petnote-video-probe") {
                        video.startPlaybackClockLogging()
                    }
                }
                .toolbar {
                    // A screenshot from a device has to say for itself which
                    // backend produced it. Without this, "verified on device"
                    // and "verified against production by mistake" look
                    // identical in a photo. Hidden in production builds, where
                    // it would just be clutter for a real user.
                    if AppEnvironment.current.backend != .production {
                        ToolbarItem(placement: .topBarLeading) {
                            // Text, not a Button: it must not add a control to
                            // the bar, and the touch-target audit enumerates
                            // app.buttons.
                            Text(EnvironmentGuard.displayLabel)
                                .font(.caption2)
                                .monospaced()
                                // Palette.secondaryText, not SwiftUI's
                                // .secondary. Measured from screenshot pixels,
                                // .secondary renders this badge at 3.02:1 in
                                // light and 3.19:1 in dark — below the 4.5:1
                                // that text this size needs. The palette token
                                // exists precisely so that is not a per-view
                                // decision, and I got it wrong the first time.
                                .foregroundStyle(Palette.secondaryText)
                                .accessibilityIdentifier("env.badge")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            try? session.signOut()
                        } label: {
                            // Plain, deliberately. Both .frame(minHeight: 44)
                            // and vertical padding were measured here and the
                            // reported height stayed 36pt: a navigation bar is
                            // 44pt tall and lays its items out inside that, so
                            // the label cannot be made to fill it.
                            //
                            // The reported frame is therefore not the hit area.
                            // All four directions have now been measured on the
                            // simulator, and the result contradicts what was
                            // inferred from the first one: upwards a tap 22pt
                            // from centre activates, downwards 22pt does not —
                            // the lower boundary is between 21 and 22. So the
                            // region is not symmetric, and "22pt above works,
                            // therefore it is at least 44pt tall" was not a
                            // valid step. The span happens to be ~43-44pt,
                            // which meets the requirement, but by measurement
                            // rather than by that argument.
                            // See PetNoteAppUITests/TouchTargetUITests.
                            Text("Sign out")
                        }
                        .accessibilityIdentifier("session.signOut")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .feed:
                        FeedView(model: feedModel, path: $path).environment(video)
                    case .postDetail(let postID):
                        PostDetailView(
                            model: PostDetailViewModel(
                                postID: postID,
                                feed: repositories.feed,
                                comments: repositories.comments,
                                likes: repositories.likes
                            )
                        )
                        .environment(video)
                    }
                }
                // Navigating away releases every player. Without this the feed
                // keeps decoding behind the detail screen, which is both the
                // leak §5D.6 forbids and a waste of battery nobody can see.
                .onChange(of: path) { _, newPath in
                    video.releaseAll(reason: newPath.isEmpty ? "returned to feed" : "navigated away")
                }
        }
    }
}

/// The session-scoped dependencies. One struct so the whole set can be replaced
/// in tests, and so sign-out drops them together.
struct Repositories {
    let feed: any FeedRepository
    let likes: any LikeRepository
    let comments: any CommentRepository

    static var live: Repositories {
        Repositories(
            feed: FirestoreFeedRepository(),
            likes: FirestoreLikeRepository(),
            comments: FirestoreCommentRepository()
        )
    }
}
