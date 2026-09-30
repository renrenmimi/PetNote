import PhotosUI
import SwiftUI

/// The add-a-pet and edit-a-pet form.
///
/// One screen for both, because the fields and their limits are identical and
/// two copies drift. What differs is in `PetEditorViewModel.Mode`.
struct PetEditorView: View {
    @Bindable var model: PetEditorViewModel

    /// Where to go once it is saved. A closure for the same reason as on
    /// `PetProfileView`: the pet routes are the coordinator's to add.
    var onSaved: ((String) -> Void)?
    var onCancel: (() -> Void)?

    @State private var photoSelection: PhotosPickerItem?
    @State private var photoPreview: Image?
    @State private var photoProblem: String?

    var body: some View {
        Form {
            switch model.loadState {
            case .loading:
                ProgressView().accessibilityIdentifier("petEditor.loading")
            case .missing:
                message(
                    String(localized: "This pet no longer exists."),
                    detail: "It may have been deleted by one of its owners.",
                    identifier: "petEditor.missing"
                )
            case .notPermitted(let text):
                message(
                    text,
                    detail: "Only this pet's owners can change its profile.",
                    identifier: "petEditor.notPermitted"
                )
            case .failed(let text):
                Section {
                    Text(text)
                        .font(Typography.body)
                        .foregroundStyle(Palette.primaryText)
                    Button("Try again") { Task { await model.loadIfEditing() } }
                        .accessibilityIdentifier("petEditor.retry")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("petEditor.loadFailed")
            case .ready:
                photoSection
                detailsSection
                if !model.mode.isEdit { relationshipSection }
                saveSection
            }
        }
        .navigationTitle(model.mode.isEdit ? "Edit pet" : "Add pet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { onCancel?() }
                    .accessibilityIdentifier("petEditor.cancel")
            }
        }
        .task { await model.loadIfEditing() }
        .onChange(of: model.saveState) { _, newValue in
            if case .saved(let petID) = newValue { onSaved?(petID) }
        }
        .onChange(of: photoSelection) { _, item in
            Task { await loadChosenPhoto(item) }
        }
    }

    // MARK: - Photo

    private var photoSection: some View {
        Section("Photo") {
            HStack(spacing: Spacing.l) {
                preview
                PhotosPicker(
                    selection: $photoSelection, matching: .images, photoLibrary: .shared()
                ) {
                    Text(model.avatarURL.isEmpty && model.pendingAvatar == nil
                         ? "Choose a photo" : "Change photo")
                        .font(Typography.body)
                        .foregroundStyle(Palette.brandPrimary)
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("petEditor.choosePhoto")
            }
            if model.pendingAvatar != nil {
                Button("Remove the chosen photo") {
                    model.discardChosenPhoto()
                    photoSelection = nil
                    photoPreview = nil
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("petEditor.discardPhoto")
            }
            if let photoProblem {
                Text(photoProblem)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("petEditor.photoProblem")
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let photoPreview {
            photoPreview
                .resizable()
                .scaledToFill()
                .frame(width: Layout.avatarSize, height: Layout.avatarSize)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else if let url = URL(string: model.avatarURL), !model.avatarURL.isEmpty {
            RemoteImage(
                url: url, aspectRatio: 1,
                cornerRadius: Layout.avatarSize / 2, size: .avatar
            )
            .frame(width: Layout.avatarSize, height: Layout.avatarSize)
        } else {
            Text(PetDisplay.emoji(for: model.species ?? .other))
                .font(Typography.pageTitle)
                .frame(width: Layout.avatarSize, height: Layout.avatarSize)
                .background(Palette.secondaryBackground)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
    }

    /// Reads the chosen image into memory.
    ///
    /// Nothing is uploaded here. The upload happens on Save, so a person who
    /// changes their mind — or whose Save is refused — has not left an asset
    /// behind on Cloudinary that nothing refers to.
    private func loadChosenPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        photoProblem = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                photoProblem = String(localized: "That photo could not be read. Try another one.")
                return
            }
            model.choosePhoto(data, filename: "pet-avatar.jpg")
            if let uiImage = UIImage(data: data) {
                photoPreview = Image(uiImage: uiImage)
            }
        } catch {
            photoProblem = String(localized: "That photo could not be read. Try another one.")
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        Section(String(localized: "petEditor.about", defaultValue: "About", comment: "The pet editor's section for name, species and the rest")) {
            TextField("Name", text: $model.name)
                .accessibilityIdentifier("petEditor.name")
            // Chips, not a menu: eight short words a person should see at
            // once and choose with one tap. None is chosen until someone
            // chooses — a create with no species is refused by the server, and
            // defaulting it here would make the choice on somebody's behalf.
            choices("Species", identifier: "petEditor.species") {
                ForEach(PetSpecies.allCases, id: \.self) { value in
                    ChoiceChip(
                        title: PetDisplay.label(for: value), symbol: PetDisplay.emoji(for: value),
                        isSelected: model.species == value
                    ) { model.species = value }
                    .accessibilityIdentifier("petEditor.species.\(value.rawValue)")
                }
            }

            TextField("Breed", text: $model.breed)
                .accessibilityIdentifier("petEditor.breed")

            genderRow

            birthdayRow

            TextField("Bio", text: $model.bio, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("petEditor.bio")
            Text("\(model.bio.count)/\(PetValidation.bioLimit)")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("petEditor.bioCount")
        }
    }

    /// Three options, so a segmented control, the row's full width, under the
    /// same small heading as the species. Beside a name on one line, the three
    /// words did not fit a phone's width even at the default text size.
    private var genderRow: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            heading("Gender")
            Picker("Gender", selection: $model.gender) {
                ForEach(PetGender.allCases, id: \.self) { value in
                    Text(PetDisplay.label(for: value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("petEditor.gender")
        }
        .padding(.vertical, Spacing.xs)
    }

    /// Chips that wrap, for choosing one of a few short words, as the species
    /// and the relationship are — under a heading unless the section's own
    /// header already names them.
    private func choices<Chips: View>(
        _ title: LocalizedStringKey?, identifier: String, @ViewBuilder chips: () -> Chips
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let title { heading(title) }
            FlowLayout { chips() }
        }
        .padding(.vertical, Spacing.xs)
        // A row's separator starts where its first text does, which with no
        // heading is the first chip's emoji, inside the capsule: it was set
        // in further than every other separator on the form.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// The small grey heading over a row's control, so every row that is a
    /// choice among a few reads the same, chips or segments.
    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(Palette.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    /// A date plus an explicit way to remove it.
    ///
    /// The "Remove" button is the whole point: a `DatePicker` has no empty
    /// state, so without it a birthday set once could never be unset — which
    /// is the bug the server grew `clearBirthday` to fix, and it stays fixed
    /// only if the client can express it.
    @ViewBuilder
    private var birthdayRow: some View {
        if let birthday = model.birthday {
            DatePicker(
                "Birthday",
                selection: Binding(
                    get: { birthday },
                    set: { model.birthday = $0 }
                ),
                displayedComponents: .date
            )
            .accessibilityIdentifier("petEditor.birthday")
            Button("Remove birthday") { model.birthday = nil }
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("petEditor.clearBirthday")
        } else {
            Button("Add a birthday") {
                // Local midnight today, which is what the picker would hand
                // back anyway — and local, not UTC, is what keeps the
                // canonical month/day equal to the day a person chose.
                model.birthday = Calendar.current.startOfDay(for: Date())
            }
            .accessibilityIdentifier("petEditor.addBirthday")
        }
    }

    private var relationshipSection: some View {
        Section("Your relationship") {
            // Chips for the same reason as the species; none until chosen,
            // because a create needs one and it is this person's to say.
            choices(nil, identifier: "petEditor.relationship") {
                ForEach(PetFamilyRelationship.allCases, id: \.self) { value in
                    ChoiceChip(
                        title: PetDisplay.choiceLabel(for: value), symbol: PetDisplay.emoji(for: value),
                        isSelected: model.relationship == value
                    ) { model.relationship = value }
                    .accessibilityIdentifier("petEditor.relationship.\(value.rawValue)")
                }
            }
            if model.relationship == .other {
                TextField("Describe it", text: $model.customRelationship)
                    .accessibilityIdentifier("petEditor.customRelationship")
            }
            Text("A label for the family list. It does not decide what you can do.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    // MARK: - Save

    private var saveSection: some View {
        Section {
            switch model.saveState {
            case .saving:
                ProgressView().accessibilityIdentifier("petEditor.saving")
            case .uncertain(let text):
                // No Save button in this state, on purpose. None of the pet
                // callables is idempotent, and a second create makes a second
                // pet out of a second one of the five slots.
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(text)
                        .font(Typography.body)
                        .foregroundStyle(Palette.primaryText)
                    Button("I have checked") { model.acknowledgeUncertainOutcome() }
                        .accessibilityIdentifier("petEditor.acknowledgeUncertain")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("petEditor.uncertain")
            default:
                Button(model.mode.isEdit ? "Save" : "Add pet") {
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("petEditor.save")
            }

            if let problem = model.validationProblem {
                Text(problem)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("petEditor.validation")
            }
            if case .failed(let text) = model.saveState {
                Text(text)
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("petEditor.saveFailed")
            }
        }
    }

    private func message(_ title: String, detail: LocalizedStringKey, identifier: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier(identifier)
    }
}
