import SwiftUI

/// Everything behind a session.
///
/// Five tabs, in the web client's order (`BottomNav.tsx`: home, places,
/// create, meetups, profile). Places and meetups came last, and only once
/// their screens existed: a tab that says "coming soon" is a dead button.
///
/// The home tab's navigation stack is the one that was here before tabs, kept
/// intact: returning to it restores the same list instance, which is what
/// makes "come back to where you were" (5B.3) a property of the navigation
/// rather than something the feed has to reconstruct.
struct SignedInView: View {
    let user: UserSession

    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []
    @State private var profilePath: [Route] = []
    @State private var placesPath: [Route] = []
    @State private var meetupsPath: [Route] = []
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
    /// The web client's `isBanned`, which drives its `SuspendedBanner`.
    @State private var isSuspended = false
    /// The dot on the bell: anything unread. Read when the feed appears and
    /// when the app comes back, as the rest of this app reads rather than
    /// listens.
    @State private var hasUnreadNotifications = false
    private let repositories: Repositories
    /// The feed the model reads, less blocked authors. In `@State` with the
    /// model, from the same initialisation: this initialiser runs on every
    /// redraw of the parent, and a filter made fresh each time would not be
    /// the one the model holds — invalidating it would change nothing.
    @State private var filteringFeed: BlockFilteringFeed

    init(user: UserSession, repositories: Repositories = .live) {
        self.user = user
        self.repositories = repositories
        let filtering = BlockFilteringFeed(
            base: repositories.feed, social: repositories.social, viewerID: user.uid
        )
        _filteringFeed = State(initialValue: filtering)
        _feedModel = State(
            initialValue: FeedViewModel(
                feed: filtering, likes: repositories.likes, accountID: user.uid
            )
        )
        // Unselected tab items stay the system's colour. On iOS 26 the glass
        // tab bar ignores both `unselectedItemTintColor` and the item
        // appearance's normal colours — measured on 09-25, the labels and
        // icons came out 14,14,14 either way — so the web's grey is kept for
        // the icons we draw ourselves and not faked here.
    }

    /// After a block or an unblock: the next read filters by the new list.
    /// An outline SF Symbol for a tab item, as a UIKit image so the bar
    /// cannot substitute the `.fill` variant (see the note on `body`).
    private func tabSymbol(_ name: String) -> Image {
        Image(uiImage: UIImage(systemName: name) ?? UIImage())
    }

    private func refilterFeed() {
        Task {
            await filteringFeed.invalidate()
            await feedModel.reload()
        }
    }

    var body: some View {
        // One icon style for the whole bar, the web client's (`BottomNav.tsx`):
        // outlines, brand purple when selected. A tab bar swaps each SF Symbol
        // for its `.fill` variant, which on 09-25 put solid black glyphs next
        // to the outline icons in the navigation bar and on every post.
        // `symbolVariants(.none)` fixed that only after the first frame — a
        // launch still flashed the filled set — so each item is handed a
        // UIKit image of the outline symbol (`tabSymbol`), which the bar draws
        // as given. The colour says which tab is current.
        //
        // The symbols are the nearest SF Symbols to the web's lucide icons:
        // house for Home; a map for Places, because the pin symbols are either
        // a hairline or a pin on an ellipse that reads as a joystick; people
        // for Meetups, since SF Symbols has no handshake; a person for
        // Profile. Create is the web's gradient circle, drawn by
        // `CreateTabIcon`.
        TabView(selection: tabSelection) {
            homeTab
                .tabItem { Label { Text("Home") } icon: { tabSymbol("house") } }
                .tag(AppTab.home)
                .accessibilityIdentifier("tab.home")
            placesTab
                .tabItem { Label { Text("Places") } icon: { tabSymbol("map") } }
                .tag(AppTab.places)
                .accessibilityIdentifier("tab.places")
            // Never shown: selecting it opens the composer and leaves the
            // selection where it was, which is how a "create" tab behaves in
            // the apps people already know.
            Color.clear
                .tabItem {
                    Label {
                        Text(String(localized: "tab.create", defaultValue: "Create", comment: "Tab that opens the composer"))
                    } icon: {
                        Image(uiImage: CreateTabIcon.image).renderingMode(.original)
                    }
                }
                .tag(AppTab.create)
                .accessibilityIdentifier("tab.create")
            meetupsTab
                .tabItem { Label { Text("Meetups") } icon: { tabSymbol("person.3") } }
                .tag(AppTab.meetups)
                .accessibilityIdentifier("tab.meetups")
            profileTab
                .tabItem { Label { Text(String(localized: "tab.profile", defaultValue: "Profile", comment: "Tab for your own profile")) } icon: { tabSymbol("person") } }
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
                await checkSuspension()
                await checkOnboarding()
                return
            }
            boundAccountID = user.uid
            guard previous != user.uid else { return }

            // Ordered deliberately: the feed first, because it owns the like
            // state whose stale offset is the one that shows the wrong number
            // to the wrong person — and its filter before it, so the first
            // read for the new account uses the new account's blocks.
            await filteringFeed.switchAccount(to: user.uid)
            feedModel.prepare(for: user.uid)
            path = []
            profilePath = []
            placesPath = []
            meetupsPath = []
            editor = nil
            selectedTab = .home
            onboardingDismissed = false
            petsChanged += 1
            video.releaseAll(reason: "account switched")
            isSuspended = false
            await checkSuspension()
            await checkOnboarding()
        }
        // The web client listens to the ban document; this app reads rather
        // than listens anywhere, so it reads again whenever it comes back to
        // the front — which is when a ban issued while it was away would
        // otherwise go unmentioned until the next launch.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await checkSuspension() }
                Task { await refreshNotificationDot() }
            }
        }
        // Leaving the home tab leaves the feed's videos behind a screen nobody
        // is looking at. Released for the same reason navigating away is
        // (§5D.6): decoding behind something else is a leak and a battery cost
        // nobody can see.
        .onChange(of: selectedTab) { _, tab in
            if tab != .home { video.releaseAll(reason: "left the home tab") }
        }
        // A link opened from outside the app (`petnote://post/<id>`): the
        // home stack shows it, as a tap on the post would. Read on appearing
        // too, for a link that arrived before sign-in had finished.
        .onChange(of: session.pendingLink, initial: true) { _, link in
            guard link != nil, let route = session.consumeLink() else { return }
            editor = nil
            selectedTab = .home
            path.append(route)
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
                .suspendedBanner(isSuspended)
                // Back from the notifications list, or anywhere else, the dot
                // is read again.
                .onAppear { Task { await refreshNotificationDot() } }
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
                    // The web client's navbar lockup (`Navbar.tsx`): the paw
                    // and the name at the leading edge, first in the bar. Not
                    // on glass: iOS 26 puts bar items on a shared glass
                    // background, and a logo inside a button-shaped capsule
                    // reads as a button.
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            FeedBrandLockup()
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            FeedBrandLockup()
                        }
                    }
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
                    // Search, then the bell, then the account: the web
                    // client's order, in the one grey its bar icons used.
                    ToolbarItem(placement: .topBarTrailing) {
                        // The web client's navbar search, one tap from the
                        // feed. Pushed on this stack so back returns to the
                        // same place in the list.
                        Button {
                            path.append(.search(tag: nil))
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Palette.iconInactive)
                                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Search")
                        .accessibilityIdentifier("feed.search")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // The web client's navbar bell, with its red dot.
                        Button {
                            path.append(.notifications)
                        } label: {
                            Image(systemName: "bell")
                                .foregroundStyle(Palette.iconInactive)
                                .overlay(alignment: .topTrailing) {
                                    if hasUnreadNotifications {
                                        Circle()
                                            .fill(Palette.danger)
                                            .frame(width: Spacing.s, height: Spacing.s)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Notifications")
                        .accessibilityValue(hasUnreadNotifications ? String(localized: "Unread") : "")
                        .accessibilityIdentifier("feed.notifications")
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

    private var placesTab: some View {
        NavigationStack(path: $placesPath) {
            PlacesView(
                model: PlacesModel(source: repositories.places),
                onOpen: { placesPath.append(.place(placeID: $0)) }
            )
            .suspendedBanner(isSuspended)
            .navigationDestination(for: Route.self) { route in
                destination(route, stack: $placesPath)
            }
        }
    }

    private var meetupsTab: some View {
        NavigationStack(path: $meetupsPath) {
            MeetupsView(
                model: MeetupsModel(uid: user.uid, source: repositories.meetups),
                onOpen: { meetupsPath.append(.meetup(meetupID: $0)) }
            )
            // Whose "My Meetups" these are: a new account gets a new list.
            .id(user.uid)
            .suspendedBanner(isSuspended)
            .navigationDestination(for: Route.self) { route in
                destination(route, stack: $meetupsPath)
            }
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
                            onSettings: { profilePath.append(.settings) },
                            onJoinFamily: { profilePath.append(.joinFamily) },
                            onFollowing: { profilePath.append(.followingPets) },
                            onSaved: { profilePath.append(.savedPosts) },
                            onCheckins: { profilePath.append(.myCheckins) },
                            onBlocked: { profilePath.append(.blockedUsers) },
                            onContact: { profilePath.append(.contactUs) }
                        )
                    }
                )
            )
            .suspendedBanner(isSuspended)
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
            // Every pushed screen, on every tab, not only the two that play
            // video on purpose: a post card anywhere asks the environment for
            // the coordinator, and a screen pushed onto a stack does not see
            // what was set on that stack's root. The pet page lists its posts
            // as cards and did not have it, so opening a pet with a video
            // post crashed the app (SwiftUI's missing-environment trap).
            .environment(video)
            .suspendedBanner(isSuspended)
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
        case .feed, .search, .notifications: return true
        case .postDetail, .pet, .user, .petFollowers, .followingPets, .savedPosts, .myCheckins, .family,
             .joinFamily, .blockedUsers, .contactUs, .settings, .place, .meetup: return false
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
                        },
                        onBlocked: { _ in
                            refilterFeed()
                            if stack.wrappedValue.last == .postDetail(postID: postID) {
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
                onOpenFollowing: { stack.wrappedValue.append(.followingPets) },
                onUnblocked: refilterFeed
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
        case .contactUs:
            ContactUsView(sender: repositories.feedback)
        case .place(let placeID):
            PlaceDetailView(
                model: PlaceDetailModel(
                    placeID: placeID, viewerID: user.uid, places: repositories.places,
                    reviewer: repositories.placeReviews, meetups: repositories.meetups
                ),
                onOpenMeetup: { stack.wrappedValue.append(.meetup(meetupID: $0)) }
            )
        case .meetup(let meetupID):
            MeetupDetailView(
                model: MeetupDetailModel(
                    meetupID: meetupID, viewerID: user.uid,
                    source: repositories.meetups, pets: repositories.petChoices,
                    reviewer: repositories.placeReviews
                ),
                onOpenPlace: { stack.wrappedValue.append(.place(placeID: $0)) }
            )
        case .notifications:
            NotificationsView(
                model: NotificationsModel(uid: user.uid, source: repositories.notifications),
                onOpen: { stack.wrappedValue.append($0) }
            )
        case .settings:
            SettingsView(
                uid: user.uid,
                email: user.email,
                store: repositories.preferences,
                security: repositories.security,
                onBlocked: { stack.wrappedValue.append(.blockedUsers) },
                onContact: { stack.wrappedValue.append(.contactUs) }
            )
        case .savedPosts:
            SavedPostsView(
                uid: user.uid,
                source: repositories.saved,
                onOpenPost: { stack.wrappedValue.append(.postDetail(postID: $0)) }
            )
        case .myCheckins:
            // A place that is gone still opens its page, which says so — the
            // web navigates to `/location/:id` either way.
            CheckinHistoryView(
                uid: user.uid,
                source: repositories.checkinHistory,
                onOpenPlace: { stack.wrappedValue.append(.place(placeID: $0)) }
            )
        case .blockedUsers:
            BlockedUsersView(
                viewerID: user.uid,
                social: repositories.social,
                onChanged: refilterFeed
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

    private func refreshNotificationDot() async {
        let account = user.uid
        guard let unread = try? await repositories.notifications.hasUnread(uid: account),
              boundAccountID == account else { return }
        hasUnreadNotifications = unread
    }

    /// A read that fails decides nothing: the banner keeps whatever the last
    /// answer was, rather than appearing or vanishing on a network error.
    private func checkSuspension() async {
        let account = user.uid
        guard let suspended = try? await repositories.suspension.isSuspended(uid: account),
              boundAccountID == account else { return }
        isSuspended = suspended
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
        let profile = try? await ProfileRepair.run(
            uid: account, users: repositories.users, suggestedName: session.providerDisplayName(for: account)
        )
        // An answer about the previous account decides nothing for this one:
        // the task for the account now signed in will set it.
        guard boundAccountID == account else { return }
        needsOnboarding = profile.map { !$0.onboardingComplete } ?? false
    }
}

enum AppTab: Hashable {
    case home
    case places
    case create
    case meetups
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
    let reports: any ContentReporting
    let feedback: any FeedbackSending
    let saved: any SavedPostsReading
    let checkinHistory: any CheckinHistoryReading
    let suspension: any SuspensionReading
    let preferences: any PreferencesStoring
    let security: any AccountSecurity
    let notifications: any NotificationsReading
    let places: any PlacesReading
    let placeReviews: any PlaceReviewing
    let meetups: any MeetupsReading

    static var live: Repositories {
        let places = FirestorePlacesSource()
        return Repositories(
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
            search: FirestoreSearchRepository(),
            reports: FirestoreContentReporter(),
            feedback: FirestoreFeedbackSender(),
            saved: FirestoreSavedPostsSource(),
            checkinHistory: FirestoreCheckinHistorySource(),
            suspension: FirestoreSuspensionSource(),
            preferences: FirestorePreferencesStore(),
            security: LiveAccountSecurity(),
            notifications: FirestoreNotificationsSource(),
            places: places,
            placeReviews: places,
            meetups: FirestoreMeetupsSource()
        )
    }
}
