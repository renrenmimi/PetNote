import PhotosUI
import SwiftUI

/// Changing the name, the picture and the bio.
struct EditProfileView: View {
    @State private var model: EditProfileModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    private let onDone: () -> Void

    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case name
        case bio
    }

    init(
        uid: String,
        users: any UserRepository,
        uploader: any AvatarUploading,
        onDone: @escaping () -> Void
    ) {
        _model = State(initialValue: EditProfileModel(uid: uid, users: users, uploader: uploader))
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                switch model.loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xxl)
                        .accessibilityIdentifier("editProfile.loading")
                case .failed(let message):
                    loadFailure(message)
                case .loaded:
                    avatarSection
                    nameSection
                    bioSection
                    outcomeBanner
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDone)
                    .accessibilityIdentifier("editProfile.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("editProfile.save")
                .accessibilityLabel(model.isSaving ? "Saving" : "Save")
            }
        }
        .task { await model.load() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await adopt(item) }
        }
    }

    // MARK: Picture

    private var avatarSection: some View {
        VStack(spacing: Spacing.m) {
            Group {
                if let pickedImage {
                    // The picked photo, shown before it is uploaded. Nothing
                    // has been saved yet and the screen says so with the
                    // "not saved yet" line rather than by looking unchanged.
                    Image(uiImage: pickedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    RemoteImage(
                        url: URL(string: model.currentAvatarURL),
                        aspectRatio: 1,
                        cornerRadius: Self.avatarSize / 2,
                        size: .thumbnail
                    )
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(.circle)
            .accessibilityIdentifier("editProfile.avatar")
            .accessibilityLabel("Profile picture")

            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text("Change photo")
                    .font(Typography.body)
                    .foregroundStyle(Palette.brandPrimary)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: Layout.minTouchTarget)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(Palette.separator)
                    )
            }
            .accessibilityIdentifier("editProfile.changePhoto")

            if model.hasUnsavedPicture {
                HStack(spacing: Spacing.m) {
                    Text("Not saved yet")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.warning)
                        .accessibilityIdentifier("editProfile.pictureUnsaved")
                    Button("Remove") {
                        model.clearPickedImage()
                        pickedImage = nil
                        pickerItem = nil
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.brandPrimary)
                    .frame(minHeight: Layout.minTouchTarget)
                    .accessibilityIdentifier("editProfile.removePicture")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func adopt(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        model.pickImage(data: data)
        pickedImage = UIImage(data: data)
    }

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Display name")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                Spacer()
                Text("\(model.displayName.count)/\(EditProfileModel.maxNameLength)")
                    .font(Typography.caption)
                    .foregroundStyle(
                        model.nameRemaining < 0 ? Palette.danger : Palette.tertiaryText
                    )
                    .accessibilityIdentifier("editProfile.nameCount")
            }
            TextField("Display name", text: $model.displayName)
                .font(Typography.body)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .name)
                .frame(minHeight: Layout.minTouchTarget)
                .accessibilityIdentifier("editProfile.name")

            if let message = model.name.status.message {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Self.tone(for: model.name.status))
                    .accessibilityIdentifier("editProfile.nameStatus")
            }
        }
    }

    /// `.unknown` reads as a caution, not as a failure: the save is still
    /// available and the server is the one that decides.
    private static func tone(for status: DisplayNameAvailability.Status) -> Color {
        switch status {
        case .taken, .invalid: Palette.danger
        case .unknown: Palette.warning
        case .checking, .idle, .available: Palette.secondaryText
        }
    }

    // MARK: Bio

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Bio")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                Spacer()
                Text("\(model.bio.count)/\(EditProfileModel.maxBioLength)")
                    .font(Typography.caption)
                    .foregroundStyle(
                        model.bioRemaining < 0 ? Palette.danger : Palette.tertiaryText
                    )
                    .accessibilityIdentifier("editProfile.bioCount")
            }
            // No `maxLength` clamp on the field. A hard stop mid-word while
            // somebody is pasting looks like the app breaking; the counter
            // turns red, the Save button refuses, and the reason is on screen.
            TextEditor(text: $model.bio)
                .font(Typography.body)
                .frame(minHeight: Self.bioHeight)
                .padding(Spacing.s)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control).stroke(Palette.separator)
                )
                .focused($focused, equals: .bio)
                .accessibilityIdentifier("editProfile.bio")
        }
    }

    // MARK: Results

    @ViewBuilder
    private var outcomeBanner: some View {
        if let outcome = model.outcome {
            switch outcome {
            case .saved:
                EmptyView()
            case .savedWithWarning(let message):
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
                    .accessibilityIdentifier("editProfile.warning")
            case .failed(let message):
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("editProfile.error")
            }
        }
    }

    @ViewBuilder
    private func loadFailure(_ message: String) -> some View {
        VStack(spacing: Spacing.m) {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("editProfile.loadError")
            Button { Task { await model.load() } } label: {
                Text("Try again")
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
                .font(Typography.body)
                .foregroundStyle(Palette.brandPrimary)
                .accessibilityIdentifier("editProfile.loadRetry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    private func save() {
        guard model.canSave else { return }
        focused = nil
        Task {
            await model.save()
            // Only a clean save closes the screen. A warning is about
            // something the person should read, and a failure leaves
            // everything they typed exactly where it is.
            if model.outcome == .saved { onDone() }
        }
    }

    private static let avatarSize: CGFloat = 112
    private static let bioHeight: CGFloat = 96
}

#if DEBUG
#Preview {
    NavigationStack {
        EditProfileView(
            uid: "preview-uid",
            users: PreviewUserRepository(),
            uploader: PreviewAvatarUploader(),
            onDone: {}
        )
    }
}
#endif
