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
            initialValue: FeedViewModel(feed: repositories.feed, likes: repositories.likes)
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            FeedView(model: feedModel, path: $path)
                .environment(video)
                .task {
                    // Only under the probe flag: it is a diagnostic, and a
                    // per-second task in the app a person uses is waste.
                    if ProcessInfo.processInfo.arguments.contains("-petnote-video-probe") {
                        video.startPlaybackClockLogging()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            try? session.signOut()
                        } label: {
                            // Plain, deliberately. Both .frame(minHeight: 44)
                            // and vertical padding were measured here and the
                            // reported height stayed 36pt: a navigation bar is
                            // 44pt tall and lays its items out inside that, so
                            // the label cannot be made to fill it. The button is
                            // hittable — UIKit's bar extends the touch area past
                            // the label — which is why the touch-target test
                            // checks bar buttons for hittability and content
                            // controls for size. See PetNoteAppUITests.
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
