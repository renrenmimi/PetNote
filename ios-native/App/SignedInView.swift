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
                        FeedView(model: feedModel, path: $path)
                    case .postDetail(let postID):
                        PostDetailView(
                            model: PostDetailViewModel(
                                postID: postID,
                                feed: repositories.feed,
                                comments: repositories.comments
                            )
                        )
                    }
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
