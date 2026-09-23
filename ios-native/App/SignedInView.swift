import SwiftUI

/// Everything behind a session.
///
/// Three tabs, in the web client's order (`BottomNav.tsx`: home, places,
/// create, meetups, profile) with the two that have not been migrated left out
/// rather than shown as empty tabs — a tab that says "coming soon" is a dead
/// button, and an unfinished feature must not become a new entry point. They
/// go back in where they belong when their screens exist.
///
/// The home tab's navigation stack is the one that was here before tabs, kept
/// intact: returning to it restores the same list instance, which is what
/// makes "come back to where you were" (5B.3) a property of the navigation
/// rather than something the feed has to reconstruct.
struct SignedInView: View {
    let user: UserSession

    @Environment(SessionStore.self) private var session
    @State private var path: [Route] = []
    @State private var profilePath: [Route] = []
    @State private var selectedTab: AppTab = .home
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
    /// The editor on screen, if any. One slot, because two editors open at
    /// once is not a state this app has.
    @State private var editor: Editor?
    /// Bumped when a pet is created, edited or deleted, so the screens that
    /// show pets re-read the server rather than trusting what was typed.
    @State private var petsChanged = 0
    /// Bumped when a post is edited, so an open detail screen re-reads it.
    @State private var postsEdited = 0
    /// The web client's `onboardingDismissed`: closing onboarding hides it for
    /// this session only. It comes back next time until it is completed,
    /// because an account without a name is not one other people can find.
    @State private var onboardingDismissed = false
    @State private var needsOnboarding = false
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
        TabView(selection: tabSelection) {
            homeTab
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
                .accessibilityIdentifier("tab.home")
            // Never shown: selecting it opens the composer and leaves the
            // selection where it was, which is how a "create" tab behaves in
            // the apps people already know.
            Color.clear
                .tabItem { Label("Post", systemImage: "plus.square") }
                .tag(AppTab.create)
                .accessibilityIdentifier("tab.create")
            profileTab
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
                .accessibilityIdentifier("tab.profile")
        }
        .tint(Palette.brandPrimary)
        .sheet(item: $editor) { editor in
            editorView(editor)
        }
        // An account *switch* keeps this view's identity — SwiftUI sees the
        // same SignedInView in the same place — so every piece of @State here
        // survives it, and all of it is the previous person's. Signing out is
        // not this case: it replaces the whole session scope and gets fresh
        // state for free.
        .task(id: user.uid) {
            // `.task(id:)` fires on first appearance as well as on a change,
            // and the first appearance is not a switch. Left unguarded, this
            // cleared the route that had just been restored from a cold launch
            // — §6.9 looked like the session store failing to save a
            // destination when in fact it had saved it, pushed it, and then had
            // it wiped a moment later. A probe read `resume=restored path=0`.
            guard let previous = boundAccountID else {
                boundAccountID = user.uid
                await checkOnboarding()
                return
            }
            boundAccountID = user.uid
            guard previous != user.uid else { return }

            // Ordered deliberately: the feed first, because it owns the like
            // state whose stale offset is the one that shows the wrong number
            // to the wrong person.
            feedModel.prepare(for: user.uid)
            path = []
            profilePath = []
            editor = nil
            selectedTab = .home
            onboardingDismissed = false
            petsChanged += 1
            video.releaseAll(reason: "account switched")
            await checkOnboarding()
        }
        // Leaving the home tab leaves the feed's videos behind a screen nobody
        // is looking at. Released for the same reason navigating away is
        // (§5D.6): decoding behind something else is a leak and a battery cost
        // nobody can see.
        .onChange(of: selectedTab) { _, tab in
            if tab != .home { video.releaseAll(reason: "left the home tab") }
        }
    }

    // MARK: - Tabs

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                if tab == .create {
                    editor = .compose
                } else {
                    selectedTab = tab
                }
            }
        )
    }

    private var homeTab: some View {
        NavigationStack(path: $path) {
            FeedView(model: feedModel, path: $path)
                .environment(video)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !user.isEmailVerified {
                        EmailVerificationBanner(
                            auth: repositories.auth,
                            // The shared instance: it is the one sign-up left
                            // its notice on. A new one here would always be
                            // empty and the notice would never be shown.
                            setup: .live,
                            onVerified: { session.noteEmailVerified() }
                        )
                    }
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
                                // that text this size needs.
                                .foregroundStyle(Palette.secondaryText)
                                .accessibilityIdentifier("env.badge")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // The web client's navbar search, one tap from the
                        // feed. Pushed on this stack so back returns to the
                        // same place in the list.
                        Button {
                            path.append(.search(tag: nil))
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Search")
                        .accessibilityIdentifier("feed.search")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // The bar holds the *entry*, not the action: ending a
                        // session is a row in a menu we lay out ourselves,
                        // where its hit region can be stated as a number.
                        AccountMenuButton(isPresented: $isAccountMenuOpen)
                    }
                }
                .sheet(isPresented: $isAccountMenuOpen) {
                    guard signOutWhenMenuCloses else { return }
                    signOutWhenMenuCloses = false
                    try? session.signOut()
                } content: {
                    AccountMenuView(
                        email: user.email,
                        onSignOut: {
                            // Two statements, one action: close, then end the
                            // session once the closing has finished.
                            signOutWhenMenuCloses = true
                            isAccountMenuOpen = false
                        },
                        onClose: { isAccountMenuOpen = false }
                    )
                    // The second detent is somewhere for the largest
                    // accessibility type sizes to go, since clamping Dynamic
                    // Type is what AccessibilityGuardTests forbids.
                    .presentationDetents([.height(AccountMenuView.preferredHeight), .large])
                    .presentationDragIndicator(.visible)
                }
                .navigationDestination(for: Route.self) { route in
                    destination(route, stack: $path)
                }
                // Navigating away releases every player. Without this the feed
                // keeps decoding behind the detail screen, which is both the
                // leak §5D.6 forbids and a waste of battery nobody can see.
                .onChange(of: path) { _, newPath in
                    video.releaseAll(reason: newPath.isEmpty ? "returned to feed" : "navigated away")
                }
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView(
                uid: user.uid,
                users: repositories.users,
                onComplete: {
                    onboardingDismissed = true
                    needsOnboarding = false
                },
                onDismiss: { onboardingDismissed = true }
            )
        }
    }

    private var profileTab: some View {
        NavigationStack(path: $profilePath) {
            ProfileView(
                uid: user.uid,
                email: user.email,
                users: repositories.users,
                uploader: repositories.avatars,
                accessory: AnyView(
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        MyPetsSection(
                            uid: user.uid,
                            source: repositories.petChoices,
                            reloadToken: petsChanged,
                            onOpenPet: { profilePath.append(.pet(petID: $0)) },
                            onAddPet: { editor = .createPet }
                        )
                        ProfileLinks(
                            onJoinFamily: { profilePath.append(.joinFamily) },
                            onFollowing: { profilePath.append(.followingPets) }
                        )
                    }
                )
            )
            .navigationDestination(for: Route.self) { route in
                destination(route, stack: $profilePath)
            }
        }
    }

    // MARK: - Destinations

    /// One builder for both stacks, so a pet page or a post opened from the
    /// profile behaves exactly as the same screen opened from the feed.
    private func destination(_ route: Route, stack: Binding<[Route]>) -> some View {
        destinationContent(route, stack: stack)
            .toolbar(Self.showsTabBar(on: route) ? .visible : .hidden, for: .tabBar)
    }

    /// The web client's rule (`App.tsx`, `showBottomNav`): the bottom bar is on
    /// the top-level pages — feed, search, profile, and later places, meetups
    /// and notifications — and gone on everything pushed from them.
    ///
    /// Not only parity. The detail screen's comment composer was laid out and
    /// verified on a device with nothing below it; under a tab bar it left a
    /// 99pt dead strip beneath itself, which `AccessibilityUITests` caught.
    static func showsTabBar(on route: Route) -> Bool {
        switch route {
        case .feed, .search: return true
        case .postDetail, .pet, .user, .petFollowers, .followingPets, .family, .joinFamily: return false
        }
    }

    @ViewBuilder
    private func destinationContent(_ route: Route, stack: Binding<[Route]>) -> some View {
        switch route {
        case .feed:
            FeedView(model: feedModel, path: stack).environment(video)
        case .postDetail(let postID):
            PostDetailView(
                model: PostDetailViewModel(
                    postID: postID,
                    feed: repositories.feed,
                    comments: repositories.comments,
                    likes: repositories.likes,
                    // So the feed underneath is already right when this screen
                    // closes. Measured on a device: without it, a comment was
                    // written, the server said 1, and the feed still read
                    // "0 comments" until a manual refresh.
                    onCommentCountChanged: { id, delta in
                        feedModel.recordCommentChange(postID: id, delta: delta)
                    }
                ),
                reloadToken: postsEdited
            )
            .environment(video)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PostDetailActions(
                        postID: postID,
                        user: user,
                        repositories: repositories,
                        onEdit: { editor = .editPost(postID: $0) },
                        onDeleted: { id in
                            feedModel.removePost(id: id)
                            // Off the deleted post's screen: staying on it
                            // would leave a person looking at "this post was
                            // deleted" about their own action.
                            if stack.wrappedValue.last == .postDetail(postID: id) {
                                stack.wrappedValue.removeLast()
                            }
                        }
                    )
                }
            }
        case .pet(let petID):
            PetProfileHost(
                petID: petID,
                repository: repositories.pets,
                viewerID: user.uid,
                reloadToken: petsChanged,
                onEdit: { editor = .editPet(petID: $0) },
                onDeleted: {
                    petsChanged += 1
                    if stack.wrappedValue.last == .pet(petID: petID) {
                        stack.wrappedValue.removeLast()
                    }
                },
                onOpenPost: { stack.wrappedValue.append(.postDetail(postID: $0)) },
                socialRow: { pet, ownership in
                    AnyView(PetSocialActions(
                        pet: pet,
                        viewerID: user.uid,
                        ownership: ownership,
                        repository: repositories.social,
                        onOpenFollowers: {
                            stack.wrappedValue.append(.petFollowers(petID: pet.id, petName: pet.name))
                        },
                        onOpenFamily: { stack.wrappedValue.append(.family(petID: pet.id)) }
                    ))
                }
            )
        case .user(let userID):
            UserProfileView(
                userID: userID,
                viewerID: user.uid,
                social: repositories.social,
                onOpenPet: { stack.wrappedValue.append(.pet(petID: $0)) },
                onOpenFollowing: { stack.wrappedValue.append(.followingPets) }
            )
        case .search(let tag):
            SearchView(
                viewerID: user.uid,
                search: repositories.search,
                social: repositories.social,
                initialTag: tag,
                onOpenPet: { stack.wrappedValue.append(.pet(petID: $0)) },
                onOpenUser: { stack.wrappedValue.append(.user(userID: $0)) },
                onOpenPost: { stack.wrappedValue.append(.postDetail(postID: $0)) }
            )
        case .petFollowers(let petID, let petName):
            PetFollowersView(
                petID: petID,
                petName: petName,
                social: repositories.social,
                onOpenUser: { stack.wrappedValue.append(.user(userID: $0)) }
            )
        case .followingPets:
            FollowingPetsView(
                viewerID: user.uid,
                social: repositories.social,
                onOpenPet: { stack.wrappedValue.append(.pet(petID: $0)) }
            )
        case .family(let petID):
            FamilyView(
                petID: petID,
                viewerID: user.uid,
                pets: repositories.pets,
                family: repositories.family,
                onOpenUser: { stack.wrappedValue.append(.user(userID: $0)) },
                onLeft: {
                    // No longer an owner: the family screen and the pet page
                    // under it were both drawn for one. Back past both, and
                    // re-read the pet lists.
                    petsChanged += 1
                    stack.wrappedValue.removeAll { $0 == .family(petID: petID) || $0 == .pet(petID: petID) }
                }
            )
        case .joinFamily:
            JoinFamilyView(
                viewerID: user.uid,
                family: repositories.family,
                onOpenPet: { petID in
                    // Joined: the join screen is done, the pet is now one of
                    // theirs, and its page is where to go.
                    petsChanged += 1
                    if stack.wrappedValue.last == .joinFamily { stack.wrappedValue.removeLast() }
                    stack.wrappedValue.append(.pet(petID: petID))
                }
            )
        }
    }

    // MARK: - Editors

    @ViewBuilder
    private func editorView(_ editor: Editor) -> some View {
        switch editor {
        case .compose:
            ComposeHost(
                user: user,
                repositories: repositories,
                onPublished: { _ in
                    self.editor = nil
                    // Back to the feed and re-read, so the post someone just
                    // published is the first thing they see — the way the web
                    // client navigates to "/" after a publish.
                    selectedTab = .home
                    path = []
                    Task { await feedModel.reload() }
                },
                onClose: { self.editor = nil }
            )
        case .createPet:
            PetEditorHost(
                mode: .create,
                repository: repositories.pets,
                uploader: repositories.media,
                viewerID: user.uid,
                onSaved: { petID in
                    self.editor = nil
                    petsChanged += 1
                    profilePath.append(.pet(petID: petID))
                },
                onCancel: { self.editor = nil }
            )
        case .editPet(let petID):
            PetEditorHost(
                mode: .edit(petID: petID),
                repository: repositories.pets,
                uploader: repositories.media,
                viewerID: user.uid,
                onSaved: { _ in
                    self.editor = nil
                    petsChanged += 1
                },
                onCancel: { self.editor = nil }
            )
        case .editPost(let postID):
            EditPostHost(
                postID: postID,
                uid: user.uid,
                repositories: repositories,
                onSaved: {
                    self.editor = nil
                    // The detail screen underneath, and the feed under that:
                    // both are showing the text that was just replaced.
                    postsEdited += 1
                    Task { await feedModel.reload() }
                },
                onClose: { self.editor = nil }
            )
        }
    }

    // MARK: - Onboarding

    /// Only over the feed itself, as on the web: `OnboardingFlow` is rendered
    /// by `Feed.tsx`, so a person restored to a post, or on another tab, is not
    /// interrupted there — it is offered when they are back on the feed.
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { needsOnboarding && !onboardingDismissed && selectedTab == .home && path.isEmpty },
            set: { if !$0 { onboardingDismissed = true } }
        )
    }

    /// The web client's rule, from `Feed.tsx`: signed in, profile loaded, and
    /// `onboardingComplete` not set. A read that fails shows nothing rather
    /// than guessing — offering onboarding to someone who has already done it
    /// is worse than not offering it once.
    private func checkOnboarding() async {
        // Repair before deciding: a sign-up whose profile write failed has no
        // document at all, and without this it would never get one — and so
        // never be shown the onboarding that lets it pick a name.
        let account = user.uid
        let profile = try? await ProfileRepair.run(uid: account, users: repositories.users)
        // An answer about the previous account decides nothing for this one:
        // the task for the account now signed in will set it.
        guard boundAccountID == account else { return }
        needsOnboarding = profile.map { !$0.onboardingComplete } ?? false
    }
}

enum AppTab: Hashable {
    case home
    case create
    case profile
}

/// A screen that is finished or cancelled rather than navigated back through.
enum Editor: Identifiable, Hashable {
    case compose
    case createPet
    case editPet(petID: String)
    case editPost(postID: String)

    var id: String {
        switch self {
        case .compose: "compose"
        case .createPet: "createPet"
        case .editPet(let id): "editPet:\(id)"
        case .editPost(let id): "editPost:\(id)"
        }
    }
}

/// The session-scoped dependencies. One struct so the whole set can be replaced
/// in tests, and so sign-out drops them together.
struct Repositories {
    let feed: any FeedRepository
    let likes: any LikeRepository
    let comments: any CommentRepository
    let users: any UserRepository
    let pets: any PetRepository
    let postWrites: any PostWriteRepository
    let petChoices: any PetChoiceProviding
    let pins: any PinnedPostReading
    let media: any MediaUploading
    let avatars: any AvatarUploading
    let auth: any AccountAuthenticating
    let social: any SocialRepository
    let family: any FamilyRepository
    let search: any SearchRepository

    static var live: Repositories {
        Repositories(
            feed: FirestoreFeedRepository(),
            likes: FirestoreLikeRepository(),
            comments: FirestoreCommentRepository(),
            users: FirestoreUserRepository(),
            pets: FirestorePetRepository(),
            postWrites: FirestorePostWriteRepository(),
            petChoices: FirestorePetChoiceSource(),
            pins: FirestorePinnedPostSource(),
            media: CloudinaryUploadClient(),
            avatars: CloudinaryAvatarUploader(),
            auth: LiveAccountAuth(),
            social: FirestoreSocialRepository(),
            family: FirestoreFamilyRepository(),
            search: FirestoreSearchRepository()
        )
    }
}
