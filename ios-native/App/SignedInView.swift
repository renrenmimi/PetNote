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
    /// Which account the state above currently belongs to, so a first
    /// appearance can be told from a switch. Nil until the first binding.
    @State private var boundAccountID: String?
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
                    // `.task(id:)` fires on first appearance as well as on a
                    // change, and the first appearance is not a switch. Left
                    // unguarded, this cleared the route that had just been
                    // restored from a cold launch — §6.9 looked like the
                    // session store failing to save a destination when in fact
                    // it had saved it, pushed it, and then had it wiped a
                    // moment later. A probe read `resume=restored path=0`.
                    //
                    // prepare(for:) was already safe, because the model is
                    // constructed bound to this account. The other two were
                    // not, and one of three being guarded is what made the
                    // bug survive review.
                    guard let previous = boundAccountID else {
                        boundAccountID = user.uid
                        return
                    }
                    boundAccountID = user.uid
                    guard previous != user.uid else { return }

                    // Ordered deliberately: the feed first, because it owns
                    // the like state whose stale offset is the one that shows
                    // the wrong number to the wrong person.
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
                            // This button's reported frame is 36pt tall and
                            // cannot be made taller: .frame(minHeight:) and
                            // padding were both measured and neither moved it.
                            //
                            // Not a property of navigation bars, though —
                            // that generalisation was here and is wrong. The
                            // system back button in the same bar reports
                            // 44.165 x 44.060 on iOS 27. The difference is
                            // what makes it: UIKit synthesises its own back
                            // button, and this is a SwiftUI Button inside a
                            // ToolbarItem. Measured at the same y, the back
                            // button activates and this one does not.
                            //
                            // Padding plus an explicit .contentShape was tried
                            // here and did nothing: the hit region starts at
                            // y≈62 while this label's frame starts at 66, so
                            // the bar has already stretched it to its own
                            // content box and there is no margin left to add.
                            //
                            // Measured height of the hit region: somewhere in
                            // [43.438, 44.062). §6.4 asks for 44, and tapping
                            // cannot settle it — proving 44 would mean landing
                            // inside a 0.063pt window, under a fifth of a
                            // pixel at this scale. Recorded as unmet rather
                            // than rounded up. The fix is to move this control
                            // somewhere we lay out ourselves, like the like
                            // button, which measures 56 x 68.
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
