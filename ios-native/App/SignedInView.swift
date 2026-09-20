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
    /// Whether the account menu is on screen. Opening it is all the
    /// navigation-bar control does.
    @State private var isAccountMenuOpen = false
    /// Sign-out is deferred to the menu's dismissal rather than run from the
    /// row's action.
    ///
    /// Not timing superstition: `signOut()` replaces the whole session scope,
    /// which tears down this view and everything presented from it. Doing that
    /// from inside the presented sheet's own button action asks UIKit to
    /// dismiss a presentation whose presenter is being removed in the same
    /// turn. Closing first and acting in `onDismiss` keeps the two in order,
    /// and costs nothing a person can perceive.
    @State private var signOutWhenMenuCloses = false
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
                    // `#if DEBUG` and not the runtime check alone. The check
                    // is still here — a debug build should not log unless
                    // asked — but on its own it only decides whether the
                    // branch *runs*. The flag name, the branch, and
                    // everything it reaches stay in a Release binary where
                    // `strings` finds them and where anything able to set a
                    // launch argument can reach them. The candidate package
                    // carries no test switch, and only the compiler can make
                    // that true.
                    #if DEBUG
                    // Only under the probe flag: it is a diagnostic, and a
                    // per-second task in the app a person uses is waste.
                    if ProcessInfo.processInfo.arguments.contains("-petnote-video-probe") {
                        video.startPlaybackClockLogging()
                    }
                    #endif
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
                        // The bar holds the *entry* now, not the action.
                        //
                        // What used to be here was a "Sign out" button whose
                        // hit region the bar owned: .frame(minHeight:),
                        // padding and .contentShape were all tried at this
                        // call site and none of them moved it, and its
                        // measured height came out as the interval
                        // [43.438, 44.062) — straddling the 44pt requirement
                        // with no tap able to settle which side it is on.
                        // Rather than keep re-measuring an unmeasurable
                        // control, the action moved to a surface we lay out
                        // ourselves (AccountMenuView), where the region is
                        // set by a .contentShape on the label and can be
                        // stated as a number.
                        //
                        // Opening a menu and ending a session are now two
                        // separate taps on two separate controls, which is
                        // the other half of why this moved.
                        AccountMenuButton(isPresented: $isAccountMenuOpen)
                    }
                }
                .sheet(isPresented: $isAccountMenuOpen) {
                    guard signOutWhenMenuCloses else { return }
                    signOutWhenMenuCloses = false
                    try? session.signOut()
                } content: {
                    AccountMenuView(email: user.email) {
                        // Two statements, one action: close, then end the
                        // session once the closing has finished.
                        signOutWhenMenuCloses = true
                        isAccountMenuOpen = false
                    }
                    // The resting height fits the header and the one row. The
                    // second detent is not a feature: it is somewhere for the
                    // largest accessibility type sizes to go, since clamping
                    // Dynamic Type is what AccessibilityGuardTests forbids.
                    .presentationDetents([.height(AccountMenuView.preferredHeight), .large])
                    .presentationDragIndicator(.visible)
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
