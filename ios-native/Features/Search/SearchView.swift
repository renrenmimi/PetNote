import SwiftUI

/// Search and discovery: the web client's Search tab.
///
/// Empty field → discovery (tags in use, trending posts, pets to follow, pets
/// with the most posts). Anything typed → people, pets, tags and posts, with a
/// leading `#` meaning "posts with this tag".
struct SearchView: View {
    @State private var search: SearchModel
    @State private var explore: ExploreModel
    private let onOpenPet: (String) -> Void
    private let onOpenUser: (String) -> Void
    private let onOpenPost: (String) -> Void

    init(
        search: SearchModel,
        explore: ExploreModel,
        onOpenPet: @escaping (String) -> Void,
        onOpenUser: @escaping (String) -> Void,
        onOpenPost: @escaping (String) -> Void
    ) {
        _search = State(initialValue: search)
        _explore = State(initialValue: explore)
        self.onOpenPet = onOpenPet
        self.onOpenUser = onOpenUser
        self.onOpenPost = onOpenPost
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                if search.hasQuery {
                    results
                } else {
                    discovery
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .background(Palette.background)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $search.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search people, pets, tags"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onChange(of: search.query) { search.queryChanged() }
        .onSubmit(of: .search) { Task { await search.searchNow() } }
        .task {
            await explore.load()
        }
        .task {
            // A tag handed in from outside (a tag on a post) searches at once.
            if search.hasQuery, search.state == .idle { await search.searchNow() }
        }
        .refreshable {
            if search.hasQuery {
                await search.searchNow()
            } else {
                await explore.load()
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        switch search.state {
        case .idle:
            EmptyView()
        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .accessibilityLabel("Searching")
                .accessibilityIdentifier("search.searching")
        case .failed:
            SocialRetryNotice(
                message: String(localized: "Search could not run. Check your connection and try again."),
                identifier: "search.failed"
            ) { await search.searchNow() }
        case .loaded where !search.hasAnyResult:
            SocialNotice(
                title: "No results for \u{201C}\(search.searchedQuery)\u{201D}",
                detail: "Try different keywords.",
                identifier: "search.empty"
            )
        case .loaded:
            peopleSection
            petsSection
            tagsSection
            postsSection
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        if !search.visiblePeople.isEmpty {
            section(
                String(localized: "People"),
                expand: search.canExpandPeople ? (search.showAllPeople ? String(localized: "Show less") : String(localized: "See all people")) : nil,
                onExpand: { search.showAllPeople.toggle() }
            ) {
                ForEach(search.visiblePeople) { person in
                    PersonRow(
                        name: person.displayName.isEmpty ? String(localized: "PetNote User") : person.displayName,
                        avatarURL: person.avatarURL,
                        detail: personDetail(person),
                        trailing: person.id == search.viewerID ? String(localized: "You", comment: "Marks the signed-in person's own row in search results") : nil
                    ) { onOpenUser(person.id) }
                    // Every result row is named by the server's id, so a test
                    // can hold the results against the query that produced
                    // them rather than against names two accounts can share.
                    .accessibilityIdentifier("search.person.\(person.id)")
                }
            }
        }
    }

    private func personDetail(_ person: PublicProfile) -> String {
        let bio = person.bio.isEmpty ? String(localized: "Pet lover") : person.bio
        guard let count = search.petCounts[person.id] else { return bio }
        return "\(bio) · \(count == 1 ? String(localized: "1 pet") : String(localized: "\(count) pets"))"
    }

    @ViewBuilder
    private var petsSection: some View {
        if !search.visiblePets.isEmpty {
            section(
                String(localized: "Pets"),
                expand: search.canExpandPets ? (search.showAllPets ? String(localized: "Show less") : String(localized: "See all pets")) : nil,
                onExpand: { search.showAllPets.toggle() }
            ) {
                ForEach(search.visiblePets) { pet in
                    PersonRow(
                        name: pet.name,
                        avatarURL: pet.avatarURL,
                        detail: pet.breed.isEmpty ? PetDisplay.label(for: pet.species) : pet.breed
                    ) { onOpenPet(pet.id) }
                    .accessibilityIdentifier("search.pet.\(pet.id)")
                }
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if !search.visibleTags.isEmpty {
            section(String(localized: "Tags")) {
                ForEach(search.visibleTags) { tag in
                    Button { Task { await search.select(tag: tag.name) } } label: {
                        HStack {
                            Text("#\(tag.name)")
                                .font(Typography.body.weight(.semibold))
                                .foregroundStyle(Palette.brandPrimary)
                                .lineLimit(2)
                            Spacer(minLength: Spacing.s)
                            Text(SearchLogic.postCountLabel(tag.postCount))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize()
                        }
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("search.tag.\(tag.name)")
                }
            }
        }
    }

    @ViewBuilder
    private var postsSection: some View {
        if !search.visiblePosts.isEmpty {
            section(String(localized: "Posts")) {
                ForEach(search.visiblePosts) { post in
                    PostSearchRow(post: post) { onOpenPost(post.id) }
                        .accessibilityIdentifier("search.post.\(post.id)")
                }
            }
        }
    }

    // MARK: - Discovery

    @ViewBuilder
    private var discovery: some View {
        tagsModule
        trendingModule
        discoverModule
        popularModule
    }

    @ViewBuilder
    private var tagsModule: some View {
        if explore.failed.contains(.tags), explore.tags.isEmpty {
            SocialRetryNotice(message: String(localized: "Could not load tags."), identifier: "explore.tagsFailed") {
                await explore.retry(.tags)
            }
        } else if !explore.tags.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                sectionTitle(explore.tagHeading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(explore.tags) { tag in
                            Button { Task { await search.select(tag: tag.name) } } label: {
                                Text("#\(tag.name) · \(SearchLogic.postCountLabel(tag.postCount))")
                                    .lineLimit(1)
                            }
                            .buttonStyle(SocialButtonStyle(kind: .secondary))
                            .accessibilityLabel("Tag \(tag.name), \(SearchLogic.postCountLabel(tag.postCount))")
                            .accessibilityIdentifier("explore.tag.\(tag.name)")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explore.tags")
        }
    }

    @ViewBuilder
    private var trendingModule: some View {
        let posts = explore.visibleTrendingPosts
        if explore.failed.contains(.trendingPosts), posts.isEmpty {
            SocialRetryNotice(message: String(localized: "Could not load trending posts."), identifier: "explore.trendingFailed") {
                await explore.retry(.trendingPosts)
            }
        } else if explore.loading.contains(.trendingPosts), posts.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                sectionTitle(String(localized: "Trending Posts"))
                ProgressView().frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
            }
        } else if !posts.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                sectionTitle(String(localized: "Trending Posts"))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 3),
                    spacing: Spacing.xs
                ) {
                    ForEach(posts) { post in
                        Button { onOpenPost(post.id) } label: {
                            PostThumbnail(post: post)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PostThumbnail.label(for: post))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("explore.post.\(post.id)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explore.trending")
        }
    }

    @ViewBuilder
    private var discoverModule: some View {
        if explore.failed.contains(.discoverPets), explore.discoverPets.isEmpty {
            SocialRetryNotice(message: String(localized: "Could not load pet suggestions."), identifier: "explore.discoverFailed") {
                await explore.retry(.discoverPets)
            }
        } else if !explore.discoverPets.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                sectionTitle(String(localized: "Discover pets"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        ForEach(explore.discoverPets) { pet in
                            petCard(
                                pet,
                                detail: PetDisplay.followerCount(
                                    explore.followModels[pet.id]?.displayedFollowerCount(base: pet.followerCount)
                                        ?? pet.followerCount
                                ),
                                follow: explore.followModels[pet.id]
                            )
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explore.discover")
        }
    }

    @ViewBuilder
    private var popularModule: some View {
        if explore.failed.contains(.popularPets), explore.popularPets.isEmpty {
            SocialRetryNotice(message: String(localized: "Could not load active pets."), identifier: "explore.popularFailed") {
                await explore.retry(.popularPets)
            }
        } else if explore.showsAlsoActive {
            VStack(alignment: .leading, spacing: Spacing.s) {
                sectionTitle(String(localized: "Most posts"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        ForEach(explore.alsoActivePets) { ranked in
                            petCard(ranked.pet, detail: SearchLogic.postCountLabel(ranked.postCount), follow: nil)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explore.popular")
        }
    }

    private func petCard(_ pet: Pet, detail: String, follow: FollowModel?) -> some View {
        VStack(spacing: Spacing.s) {
            Button { onOpenPet(pet.id) } label: {
                VStack(spacing: Spacing.xs) {
                    SocialAvatar(url: pet.avatarURL, name: pet.name, size: SocialLayout.cardAvatar)
                    Text(pet.name)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            // Unique within a module: "Most posts" leaves out every pet that
            // "Discover pets" already shows (`SearchLogic.alsoActive`).
            .accessibilityIdentifier("explore.pet.\(pet.id)")

            if let follow {
                PetFollowButton(model: follow)
            }
        }
        .padding(Spacing.m)
        .frame(width: SocialLayout.discoverCardWidth)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Typography.sectionTitle)
            .foregroundStyle(Palette.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func section<Content: View>(
        _ title: String,
        expand: String? = nil,
        onExpand: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                sectionTitle(title)
                Spacer(minLength: Spacing.s)
                if let expand {
                    Button(expand, action: onExpand)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.brandPrimary)
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
            }
            content()
        }
    }
}

/// A post as a result row: its picture, its words, who posted it. Opens the
/// post, where it can be liked and commented on.
///
/// Not the feed's `PostCard`: that card carries a like button, and a like
/// button here would need this screen to own like state the feed already
/// owns. A control that looks live and is not would be worse than none.
struct PostSearchRow: View {
    let post: Post
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.m) {
                PostThumbnail(post: post)
                    .frame(width: SocialLayout.rowThumbnail, height: SocialLayout.rowThumbnail)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(byline)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                    if !post.text.isEmpty {
                        Text(post.text)
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    if !post.tags.isEmpty {
                        Text(post.tags.prefix(4).map { "#\($0)" }.joined(separator: " "))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.brandPrimary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var byline: String {
        let author = post.authorName.isEmpty ? String(localized: "PetNote User") : post.authorName
        if let pet = post.petName, !pet.isEmpty { return "\(pet) · \(author)" }
        return author
    }
}

/// A post's first picture, square, with a mark for more photos or a video.
struct PostThumbnail: View {
    let post: Post

    var body: some View {
        let media = post.media.first
        ZStack(alignment: .topTrailing) {
            if let url = Self.imageURL(for: media) {
                RemoteImage(url: url, aspectRatio: 1, cornerRadius: Radius.control, size: .thumbnail)
            } else {
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(Palette.secondaryBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Text(post.text)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(4)
                            .padding(Spacing.xs)
                    }
            }
            if media?.kind == .video {
                badge("play.fill")
            } else if post.media.count > 1 {
                badge("square.on.square")
            }
        }
        .accessibilityHidden(true)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Typography.caption)
            .foregroundStyle(Palette.textOnBrand)
            .padding(Spacing.xs)
            .controlScrim()
            .padding(Spacing.xs)
    }

    static func imageURL(for media: MediaItem?) -> URL? {
        guard let media else { return nil }
        switch media.kind {
        case .image: return media.url
        case .video: return media.thumbnailURL ?? CloudinaryURL.videoPoster(media.url, size: .thumbnail)
        }
    }

    static func label(for post: Post) -> String {
        var parts: [String] = []
        if let media = post.media.first {
            parts.append(media.kind == .video ? String(localized: "Video") : (post.media.count > 1 ? String(localized: "\(post.media.count) photos") : String(localized: "Photo")))
        } else {
            parts.append(String(localized: "Post", comment: "Noun: a post with no picture, read by VoiceOver"))
        }
        let author = post.authorName.isEmpty ? String(localized: "PetNote User") : post.authorName
        parts.append(String(localized: "by \(post.petName ?? author)"))
        if !post.text.isEmpty { parts.append(post.text) }
        return parts.joined(separator: ", ")
    }
}

extension SocialLayout {
    static let rowThumbnail: CGFloat = 64
}

#if DEBUG
#Preview("Search") {
    let social = PreviewSocialRepository()
    let blocks = BlockList(viewerID: "me", social: social)
    return NavigationStack {
        SearchView(
            search: SearchModel(viewerID: "me", search: PreviewSearchRepository(), blockList: blocks),
            explore: ExploreModel(
                viewerID: "me", search: PreviewSearchRepository(), social: social, blockList: blocks
            ),
            onOpenPet: { _ in }, onOpenUser: { _ in }, onOpenPost: { _ in }
        )
    }
}
#endif
