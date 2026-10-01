import Foundation
import Observation
import OSLog
import PhotosUI
import SwiftUI

/// What is sent to check in at a place (`checkInCallable`,
/// functions/src/places.ts): its photo, uploaded already, and the person's
/// words and pet, both optional.
struct CheckinDraft: Equatable, Sendable {
    /// The server's limit, in its units: UTF-16, as JavaScript counts.
    static let maxCaption = 150

    let placeID: String
    var photoURL: URL
    var caption: String
    var petID: String?

    var trimmedCaption: String { caption.trimmingCharacters(in: .whitespacesAndNewlines) }

    var payload: [String: Any] {
        var payload: [String: Any] = ["locationId": placeID, "photoUrl": photoURL.absoluteString]
        if !trimmedCaption.isEmpty { payload["caption"] = trimmedCaption }
        if let petID { payload["petId"] = petID }
        return payload
    }

    /// The server's day, UTC's (`new Date().toISOString().slice(0, 10)`): a
    /// person checks in at a place once in it.
    static func dayKey(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Where the server keeps a person's check-in of that day.
    static func checkinID(uid: String, on date: Date) -> String { "\(uid)_\(dayKey(date))" }
}

protocol PlaceCheckingIn: Sendable {
    func checkIn(_ draft: CheckinDraft) async throws
    /// Whether this person has checked in here on the server's day.
    func hasCheckedIn(placeID: String, uid: String, on date: Date) async throws -> Bool
}

/// The web's Check In: a photo from the place, which it needs, then the
/// person's words and which of their pets is with them, if they say.
@MainActor
@Observable
final class CheckInModel {
    enum Outcome: Equatable {
        case checkedIn
        case failed(String)
    }

    /// The photo chosen, uploaded when the check-in is sent; its preview made
    /// once, as it is chosen. Once uploaded, its address is kept, so trying
    /// again after the server refused does not send it twice.
    struct Photo: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let filename: String
        let preview: UIImage?
        fileprivate(set) var uploaded: URL?
    }

    let placeID: String
    let placeName: String
    /// The server checks in only a verified email, and the web says so before
    /// anything is chosen.
    let isEmailVerified: Bool
    var caption = ""
    private(set) var petID: String?
    private(set) var pets: [Pet] = []
    private(set) var photo: Photo?
    private(set) var isSaving = false
    private(set) var outcome: Outcome?

    private let uid: String
    private let checker: any PlaceCheckingIn
    private let uploader: any MediaUploading
    private let petSource: any PetChoiceProviding
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        placeID: String, placeName: String, uid: String, isEmailVerified: Bool,
        checker: any PlaceCheckingIn, uploader: any MediaUploading, pets: any PetChoiceProviding
    ) {
        self.placeID = placeID
        self.placeName = placeName
        self.uid = uid
        self.isEmailVerified = isEmailVerified
        self.checker = checker
        self.uploader = uploader
        self.petSource = pets
    }

    var captionLength: Int { caption.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count }

    var canSubmit: Bool {
        photo != nil && isEmailVerified && captionLength <= CheckinDraft.maxCaption && !isSaving
            && outcome != .checkedIn
    }

    /// Something a swipe down would lose.
    var hasInput: Bool { photo != nil || !caption.isEmpty || petID != nil }

    /// The pets on the person's list, as the composer offers them; the web's
    /// `userPets`.
    func loadPets() async {
        do {
            pets = try await petSource.pets(ownedBy: uid)
        } catch {
            log.error("pets for a check-in failed: \(String(describing: error), privacy: .public)")
        }
    }

    func choosePhoto(data: Data, filename: String) {
        guard !isSaving else { return }
        let preview = PickedPreview.image(from: data, covering: CheckInSheet.photoSize)
        photo = Photo(data: data, filename: filename, preview: preview)
    }

    /// The web's chips: a second tap takes the pet back.
    func toggle(petID: String) {
        guard !isSaving else { return }
        self.petID = self.petID == petID ? nil : petID
    }

    /// The web's order: the photo, then the check-in with its address. One
    /// at a time, taken before any suspension. The server's words when it
    /// refuses: a second check-in today, an unverified email.
    func submit() async {
        guard canSubmit, let photo else { return }
        isSaving = true
        outcome = nil
        defer { isSaving = false }
        let photoURL: URL
        do {
            photoURL = try await upload(photo)
        } catch {
            log.error("a check-in's photo failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(Self.photoWording(for: error))
            return
        }
        do {
            try await checker.checkIn(CheckinDraft(placeID: placeID, photoURL: photoURL, caption: caption, petID: petID))
            outcome = .checkedIn
        } catch {
            log.error("check-in failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(GatheringWords.message(for: error, fallback: String(localized: "Check-in failed. Try again.")))
        }
    }

    /// Prepared as the composer prepares a photo, off the main actor, and
    /// sent, unless it went up already. Like the composer's, nothing here
    /// deletes an upload.
    private func upload(_ photo: Photo) async throws -> URL {
        if let uploaded = photo.uploaded { return uploaded }
        let data = photo.data, filename = photo.filename
        let prepared = try await Task.detached(priority: .userInitiated) {
            try UploadPreparation.prepareImage(data, filename: filename)
        }.value
        let asset = try await uploader.upload(UploadItem(
            data: prepared.data, filename: prepared.filename, mimeType: prepared.mimeType, resourceType: .image
        ))
        // Kept with the photo it is for, for another try.
        if self.photo?.id == photo.id { self.photo?.uploaded = asset.url }
        return asset.url
    }

    /// The pet editor's words for a photo that did not go, with the check-in
    /// in them where those name the pet: nothing was sent.
    static func photoWording(for error: Error) -> String {
        if let upload = error as? UploadError {
            switch upload {
            case .timedOut: return String(localized: "The photo upload timed out. You were not checked in.")
            case .transport: return String(localized: "The photo could not be uploaded. You were not checked in.")
            default: break
            }
        } else if !(error is UploadPreparation.PreparationError) {
            return String(localized: "The photo could not be uploaded. You were not checked in.")
        }
        return PetEditorViewModel.photoWording(for: error)
    }
}

/// The web's Check In sheet (`CheckInModal.tsx`).
struct CheckInSheet: View {
    /// The photo's space: the form's row on the widest phone.
    static let photoSize = CGSize(width: 400, height: 200)

    @State private var model: CheckInModel
    @State private var selection: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss
    private let onCheckedIn: () -> Void

    init(model: CheckInModel, onCheckedIn: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onCheckedIn = onCheckedIn
    }

    var body: some View {
        Form {
            Section {
                Text(model.placeName)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                    CheckinPhotoArea(preview: model.photo?.preview)
                }
                .buttonStyle(.plain)
                .disabled(model.isSaving)
                .accessibilityLabel(model.photo == nil ? Text("Choose a photo") : Text("Change the photo"))
                .accessibilityIdentifier("checkIn.photo")
            }
            Section {
                TextField("What are you doing here? 🐾", text: $model.caption, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("checkIn.caption")
            } header: {
                Text("Caption (optional)")
            } footer: {
                Text(verbatim: "\(model.captionLength)/\(CheckinDraft.maxCaption)")
                    .foregroundStyle(model.captionLength > CheckinDraft.maxCaption ? Palette.danger : Palette.secondaryText)
            }
            if !model.pets.isEmpty {
                Section("Which pet is with you? (optional)") {
                    CheckinPetRow(pets: model.pets, chosen: model.petID) { model.toggle(petID: $0) }
                }
            }
            if !model.isEmailVerified {
                Section {
                    Text("Verify your email to check in.")
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier("checkIn.verify")
                }
            }
            if case .failed(let message) = model.outcome {
                Section {
                    Text(message)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("checkIn.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
        // Only Cancel closes it once something is chosen or written.
        .interactiveDismissDisabled(model.hasInput || model.isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("checkIn.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSaving ? String(localized: "Checking in...") : String(localized: "Check In")) {
                    Task { await model.submit() }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("checkIn.save")
            }
        }
        .task { await model.loadPets() }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.choosePhoto(data: data, filename: "checkin.jpg")
                }
                selection = nil
            }
        }
        .onChange(of: model.outcome) { _, outcome in
            guard outcome == .checkedIn else { return }
            onCheckedIn()
            dismiss()
        }
    }
}

/// The composer's row of pets, each its picture and name, with the web's
/// chips' second tap that takes the pet back. The picture tells apart two
/// pets of one name, which a chip of words would not.
private struct CheckinPetRow: View {
    let pets: [Pet]
    let chosen: String?
    let onToggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.m) {
                ForEach(pets) { pet in
                    let isChosen = chosen == pet.id
                    Button { onToggle(pet.id) } label: {
                        VStack(spacing: Spacing.xs) {
                            SocialAvatar(url: pet.avatarURL, name: pet.name, size: Layout.minTouchTarget)
                                .overlay {
                                    Circle().strokeBorder(
                                        isChosen ? Palette.brandPrimary : Palette.separator, lineWidth: isChosen ? 2 : 1
                                    )
                                }
                            Text(pet.name).font(Typography.caption).lineLimit(1)
                        }
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.primaryText)
                    .accessibilityLabel(pet.name)
                    .accessibilityAddTraits(isChosen ? [.isSelected] : [])
                    .accessibilityIdentifier("checkIn.pet.\(pet.id)")
                }
            }
        }
    }
}

/// The web's dashed box: a camera and what to do until there is a photo,
/// then the photo itself.
private struct CheckinPhotoArea: View {
    let preview: UIImage?

    var body: some View {
        ZStack {
            if let preview {
                Color.clear
                    .overlay { Image(uiImage: preview).resizable().scaledToFill() }
                    .clipShape(.rect(cornerRadius: Radius.control))
            } else {
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(Palette.separator, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.control))
                VStack(spacing: Spacing.xs) {
                    Text(verbatim: "📸").font(Typography.pageTitle)
                    Text("A photo from this place")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text("Tap to choose one")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                .multilineTextAlignment(.center)
                .padding(Spacing.m)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CheckInSheet.photoSize.height, maxHeight: CheckInSheet.photoSize.height)
        .contentShape(.rect)
    }
}
