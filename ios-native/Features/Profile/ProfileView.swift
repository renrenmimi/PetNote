import SwiftUI

/// The signed-in person's own profile.
///
/// Identity only: the name, the picture, the bio and the address, plus the way
/// to change them. The web client's pets / saved / check-ins tabs read
/// collections other lines own and are not reinvented here.
struct ProfileView: View {
    @State private var model: ProfileModel
    private let users: any UserRepository
    private let uploader: any AvatarUploading
    private let uid: String

    @State private var isEditing = false

    init(
        uid: String,
        email: String,
        users: any UserRepository,
        uploader: any AvatarUploading
    ) {
        self.uid = uid
        self.users = users
        self.uploader = uploader
        _model = State(initialValue: ProfileModel(uid: uid, email: email, users: users))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                switch model.state {
                case .loading:
                    ProgressView()
                        .padding(.vertical, Spacing.xxl)
                        .accessibilityIdentifier("profile.loading")
                case .loaded(let profile):
                    identity(profile)
                    bio(profile)
                    editButton
                case .failed(let message, let isRetryable):
                    failure(message: message, isRetryable: isRetryable)
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .sheet(isPresented: $isEditing) {
            // Reloaded on dismissal rather than trusted: the edit screen
            // writes through a callable whose server-side normalisation can
            // differ from what was typed (a trimmed name, a rejected avatar
            // host), and showing the typed version would be showing something
            // that is not in the database.
            Task { await model.load() }
        } content: {
            NavigationStack {
                EditProfileView(uid: uid, users: users, uploader: uploader) {
                    isEditing = false
                }
            }
        }
    }

    private func identity(_ profile: UserProfile) -> some View {
        VStack(spacing: Spacing.m) {
            RemoteImage(
                url: URL(string: profile.resolvedAvatarURL),
                aspectRatio: 1,
                cornerRadius: Self.avatarSize / 2,
                size: .thumbnail
            )
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .accessibilityIdentifier("profile.avatar")
            .accessibilityLabel("Profile picture")

            Text(model.displayedName)
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("profile.name")

            Text(model.email)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("profile.email")
        }
    }

    @ViewBuilder
    private func bio(_ profile: UserProfile) -> some View {
        if !profile.bio.isEmpty {
            Text(profile.bio)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("profile.bio")
        }
    }

    private var editButton: some View {
        Button {
            isEditing = true
        } label: {
            Text("Edit profile")
                .font(Typography.body)
                .foregroundStyle(Palette.textOnBrand)
                .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                .background(Palette.brandGradient, in: .rect(cornerRadius: Radius.control))
        }
        .accessibilityIdentifier("profile.edit")
    }

    /// Says the read failed. Deliberately not an empty profile: "we could not
    /// find out" and "there is nothing here" must not look the same, and an
    /// empty profile is also something somebody might then try to save over.
    private func failure(message: String, isRetryable: Bool) -> some View {
        VStack(spacing: Spacing.m) {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.danger)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("profile.error")
            if isRetryable {
                Button("Try again") { Task { await model.load() } }
                    .font(Typography.body)
                    .foregroundStyle(Palette.brandPrimary)
                    .frame(minHeight: Layout.minTouchTarget)
                    .accessibilityIdentifier("profile.retry")
            }
        }
        .padding(.vertical, Spacing.xxl)
    }

    private static let avatarSize: CGFloat = 112
}

#if DEBUG
#Preview {
    NavigationStack {
        ProfileView(
            uid: "preview-uid",
            email: "someone@example.com",
            users: PreviewUserRepository(),
            uploader: PreviewAvatarUploader()
        )
    }
}
#endif
