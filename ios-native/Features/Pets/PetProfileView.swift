import SwiftUI

/// A pet's page: who it is, who its owners are, what it has posted, and where
/// it has checked in.
///
/// One header rather than three cards, the shape the web client settled on
/// after identity, stats and family each had their own and the content
/// somebody came for was the fourth thing down the page.
struct PetProfileView: View {
    @Bindable var model: PetProfileViewModel

    /// What to do when the pet is gone, or when Edit is pressed. Closures
    /// rather than `Route` cases because `Core/Navigation/Route.swift` is the
    /// coordinator's file and has no pet destinations yet — see the batch
    /// report. The screen works either way; only the caller changes.
    var onEdit: ((String) -> Void)?
    var onDeleted: (() -> Void)?
    var onOpenPost: ((String) -> Void)?

    enum Tab: String, CaseIterable, Identifiable {
        case posts
        case checkins
        var id: String { rawValue }
        var title: String { self == .posts ? "Posts" : "Check-ins" }
    }
    @State private var tab: Tab = .posts

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                switch model.state {
                case .loading:
                    loading
                case .missing:
                    notice(
                        title: "This pet no longer exists.",
                        detail: "It may have been deleted by one of its owners.",
                        identifier: "pet.missing"
                    )
                case .failed(let message):
                    retryNotice(message: message, identifier: "pet.loadFailed") {
                        await model.retryPetAndFamily()
                    }
                case .loaded(let pet):
                    header(pet)
                    owners
                    tabPicker
                    switch tab {
                    case .posts: postsSection
                    case .checkins: checkinsSection
                    }
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .background(Palette.background)
        .navigationTitle("Pet")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .toolbar {
            if case .loaded(let pet) = model.state {
                ToolbarItem(placement: .topBarTrailing) {
                    petActions(pet)
                }
            }
        }
        .alert("Delete \(loadedPet?.name ?? "this pet")?", isPresented: deleteConfirmation) {
            Button("Cancel", role: .cancel) { model.cancelDelete() }
            Button("Delete", role: .destructive) {
                Task { await model.confirmDelete() }
            }
        } message: {
            Text(PetProfileViewModel.deletionConsequences)
        }
        .onChange(of: model.deleteState) { _, newValue in
            if newValue == .deleted { onDeleted?() }
        }
    }

    private var loadedPet: Pet? {
        if case .loaded(let pet) = model.state { return pet }
        return nil
    }

    /// Bound to `.confirming` only. The alert presents on that state and
    /// dismisses itself for every other one, so a delete that starts or fails
    /// does not leave the sheet up over its own result.
    private var deleteConfirmation: Binding<Bool> {
        Binding(
            get: { model.deleteState == .confirming },
            set: { isPresented in if !isPresented { model.cancelDelete() } }
        )
    }

    // MARK: - Header

    private func header(_ pet: Pet) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.l) {
                avatar(pet)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(pet.name)
                        .font(Typography.pageTitle)
                        .foregroundStyle(Palette.primaryText)
                        .accessibilityIdentifier("pet.name")
                    Text(descriptors(pet))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier("pet.descriptors")
                    if pet.isBirthday() {
                        // Words, not a cake with no label: the birthday is a
                        // fact about the pet and has to survive being read
                        // aloud.
                        Text("🎂 Birthday today")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.brandPrimary)
                            .accessibilityIdentifier("pet.birthdayToday")
                    }
                }
            }

            if !pet.bio.isEmpty {
                Text(pet.bio)
                    .font(Typography.body)
                    .foregroundStyle(Palette.primaryText)
                    .accessibilityIdentifier("pet.bio")
            }

            Text(stats(pet))
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("pet.stats")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    private func avatar(_ pet: Pet) -> some View {
        Group {
            if pet.avatarURL != nil {
                RemoteImage(
                    url: pet.avatarURL, aspectRatio: 1,
                    cornerRadius: Layout.avatarSize / 2, size: .avatar
                )
                .frame(width: Layout.avatarSize, height: Layout.avatarSize)
            } else {
                // Decoration standing in for a missing photo. Hidden from
                // VoiceOver because the species is already in the line of text
                // beside it, and reading "dog face" there would be a second
                // copy of the same fact.
                Text(PetDisplay.emoji(for: pet.species))
                    .font(Typography.pageTitle)
                    .frame(width: Layout.avatarSize, height: Layout.avatarSize)
                    .background(Palette.secondaryBackground)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
        }
    }

    /// Breed, species, gender and birthday on one line.
    ///
    /// Gender reads as a word rather than only as a coloured symbol — see
    /// `PetDisplay.label(for:)`.
    private func descriptors(_ pet: Pet) -> String {
        var parts: [String] = []
        if !pet.breed.isEmpty { parts.append(pet.breed) }
        parts.append(PetDisplay.label(for: pet.species))
        if pet.gender != .unknown {
            parts.append("\(PetDisplay.symbol(for: pet.gender)) \(PetDisplay.label(for: pet.gender))")
        }
        if let born = PetDisplay.bornLine(pet.birthday) { parts.append(born) }
        return parts.joined(separator: " · ")
    }

    private func stats(_ pet: Pet) -> String {
        [PetDisplay.postCount(pet.postCount), PetDisplay.followerCount(pet.followerCount)]
            .joined(separator: " · ")
    }

    // MARK: - Owners

    /// Every owner, equally.
    ///
    /// Not "the owner" and one name: this pet may have several, they are equal
    /// where it counts, and the page has to show that or it reproduces the
    /// assumption the server spent a migration removing. The primary is marked
    /// because it is a real difference — it is who may remove somebody else —
    /// and marked as a role rather than as rank.
    @ViewBuilder
    private var owners: some View {
        switch model.familyState {
        case .loading:
            Text("Loading owners…")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        case .failed(let message):
            retryNotice(message: message, identifier: "pet.ownersFailed") {
                await model.retryPetAndFamily()
            }
        case .loaded where model.family.isEmpty:
            EmptyView()
        case .loaded:
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(PetDisplay.ownerCount(model.family.count))
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                    .accessibilityIdentifier("pet.ownerCount")
                ForEach(model.family) { member in
                    HStack(spacing: Spacing.s) {
                        Text(member.userName.isEmpty ? "PetNote user" : member.userName)
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                        Text(PetDisplay.label(for: member.relationship, custom: member.customRelationship))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                        if member.role == .primary {
                            Text("Primary")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.brandPrimary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Tabs

    private var tabPicker: some View {
        Picker("Section", selection: $tab) {
            ForEach(Tab.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("pet.tabs")
    }

    @ViewBuilder
    private var postsSection: some View {
        switch model.postsState {
        case .loading where model.posts.isEmpty:
            loading
        case .failed(let message):
            retryNotice(message: message, identifier: "pet.postsFailed") {
                await model.retryPosts()
            }
        case .loaded where model.posts.isEmpty:
            notice(
                title: "No posts yet.",
                detail: "Anything posted about this pet shows up here.",
                identifier: "pet.postsEmpty"
            )
        default:
            ForEach(model.posts) { post in
                PostCard(
                    post: post,
                    isLiked: false,
                    onLike: {},
                    onOpenComments: { onOpenPost?(post.id) },
                    onOpenPost: { onOpenPost?(post.id) }
                )
                .task { await model.loadMorePostsIfNeeded(currentItem: post) }
            }
        }
    }

    @ViewBuilder
    private var checkinsSection: some View {
        switch model.checkinsState {
        case .loading:
            loading
        case .failed(let message):
            // A tab, not the page. Its own failure and its own retry — with
            // all four reads sharing one, a pet whose profile was entirely
            // readable rendered as "could not load this pet" whenever the
            // functions emulator was not running.
            retryNotice(message: message, identifier: "pet.checkinsFailed") {
                await model.retryCheckins()
            }
        case .loaded where model.checkins.isEmpty:
            notice(
                title: "No check-ins yet.",
                detail: "Places this pet has visited show up here.",
                identifier: "pet.checkinsEmpty"
            )
        case .loaded:
            ForEach(model.checkins) { checkin in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if checkin.photoURL != nil {
                        RemoteImage(
                            url: checkin.photoURL, aspectRatio: 1,
                            cornerRadius: Radius.card, size: .thumbnail
                        )
                        .frame(height: Layout.checkinThumbnail)
                    }
                    if !checkin.caption.isEmpty {
                        Text(checkin.caption)
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                    }
                    if let createdAt = checkin.createdAt {
                        Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(Palette.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Actions

    /// Edit and Delete, each shown only when the viewer may actually do it.
    ///
    /// `model.permissions` degrades to offering nothing when the family read
    /// failed — see `PetProfileViewModel.permissions`. A control that appears
    /// because a read did not happen is worse than one that is missing.
    @ViewBuilder
    private func petActions(_ pet: Pet) -> some View {
        Menu {
            if model.permissions.canEdit {
                Button("Edit") { onEdit?(pet.id) }
                    .accessibilityIdentifier("pet.edit")
            }
            if model.permissions.canDelete {
                Button("Delete", role: .destructive) { model.askToDelete() }
                    .accessibilityIdentifier("pet.delete")
            }
        } label: {
            Label("Pet options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("pet.menu")
        .disabled(!model.permissions.canEdit && !model.permissions.canDelete)
        .overlay(alignment: .bottom) {
            if case .failed(let message) = model.deleteState {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("pet.deleteFailed")
            }
        }
    }

    // MARK: - Shared pieces

    private var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("pet.loading")
    }

    private func notice(title: String, detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
            Text(detail)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func retryNotice(
        message: String, identifier: String, retry: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
            Button("Try again") { Task { await retry() } }
                .font(Typography.body)
                .foregroundStyle(Palette.brandPrimary)
                .frame(minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
                .accessibilityIdentifier("\(identifier).retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityIdentifier(identifier)
    }
}

extension Layout {
    /// Pet-page measurements. They live here rather than as numbers in the
    /// view so a second pet surface cannot invent a different avatar size.
    ///
    /// In `Features/Pets` and not `DesignSystem/Spacing.swift`, which is the
    /// coordinator's file — named in the batch report as something to fold in
    /// if a second feature wants the same sizes.
    static let avatarSize: CGFloat = 88
    static let checkinThumbnail: CGFloat = 180
}
