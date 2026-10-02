import Foundation
import Observation
import OSLog
import SwiftUI

/// What is sent to add a place found on Apple Maps: its identifier and our
/// own words about it, and nothing of Apple's. `sanitizeApplePlaceDraft`
/// (functions/src/places.ts) refuses a name, an address or a position, since
/// Apple's terms let a place keep only the identifier
/// (docs/apple-maps-places-plan.md).
struct ApplePlaceDraft: Equatable, Sendable {
    /// The server's limit, in its units: UTF-16, as JavaScript counts.
    static let maxDescription = 500
    /// The web's features, in the web's order.
    static let featureKeys = [
        "off_leash", "fenced", "water_access", "waste_bags", "parking", "restrooms",
        "seating", "shade", "lighting", "beach_access", "trails", "food_nearby",
    ]

    var applePlaceID: String
    var category: PlaceCategory
    var description: String
    var features: Set<String>
    /// Uploaded already: the server keeps these addresses with a new place.
    var photos: [URL] = []

    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var descriptionLength: Int { trimmedDescription.utf16.count }

    /// The web asks for a description, and the server takes 500 at most.
    var canSubmit: Bool {
        !applePlaceID.isEmpty && !trimmedDescription.isEmpty && descriptionLength <= Self.maxDescription
    }

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "applePlaceId": applePlaceID,
            "category": category.rawValue,
            "description": trimmedDescription,
            "features": Self.featureKeys.filter(features.contains),
        ]
        if !photos.isEmpty { payload["photos"] = photos.map(\.absoluteString) }
        return payload
    }
}

/// What the server did: added the place, or found it there already.
struct AddedPlace: Equatable, Sendable {
    let placeID: String
    let alreadyExisted: Bool
}

protocol PlaceAdding: Sendable {
    func addPlace(_ draft: ApplePlaceDraft) async throws -> AddedPlace
}

/// Adding a place: find it on Apple Maps, choose it, and say what it is like
/// for pets. A place someone has added already is opened instead of added
/// twice.
@MainActor
@Observable
final class AddPlaceModel {
    enum Outcome: Equatable {
        /// Added, or there already; `rated` when a rating went with it.
        case added(AddedPlace, rated: Bool)
        /// The place is there and the rating did not go, in the server's words.
        case notRated(AddedPlace, String)
        case failed(String)
    }

    /// Apple Maps, searched for the place, with the ones added here marked.
    let finder: ApplePlaceFinder
    var category: PlaceCategory = .dogPark
    var description = ""
    private(set) var features: Set<String> = []
    /// The place being added, once chosen from what Apple found.
    private(set) var chosen: PlaceSearchHit?
    private(set) var isSaving = false
    private(set) var outcome: Outcome?

    /// The server's limit, and the web's.
    static let maxPhotos = 5

    /// Picked to go with the place, and sent before it.
    let photos = PickedPhotos(limit: AddPlaceModel.maxPhotos)

    /// The web's optional rating, sent as a review once the place is in.
    var rating = 0
    var space = 0
    var safety = 0
    var cleanliness = 0

    private let adder: any PlaceAdding
    private let reviewer: any PlaceReviewing
    private let uploader: any MediaUploading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        query: String = "", places: any PlacesReading, adder: any PlaceAdding, reviewer: any PlaceReviewing,
        uploader: any MediaUploading, directory: any PlaceDirectory = PlaceDirectories.shared
    ) {
        self.finder = ApplePlaceFinder(query: query, places: places, marksAdded: true, directory: directory)
        self.adder = adder
        self.reviewer = reviewer
        self.uploader = uploader
    }

    var draft: ApplePlaceDraft? {
        chosen.map {
            ApplePlaceDraft(applePlaceID: $0.applePlaceID, category: category, description: description, features: features)
        }
    }

    var descriptionLength: Int { draft?.descriptionLength ?? 0 }

    var canSave: Bool {
        guard draft?.canSubmit == true, !isSaving else { return false }
        switch outcome {
        case .added, .notRated: return false
        case .failed, nil: return true
        }
    }

    /// For a place nobody has added yet: the view opens the others.
    func choose(_ found: ApplePlaceFinder.Found) {
        guard found.placeID == nil else { return }
        chosen = found.hit
        outcome = nil
    }

    func changePlace() {
        chosen = nil
        outcome = nil
    }

    /// Once what the server said has been acted on.
    func clearOutcome() {
        outcome = nil
    }

    func toggle(feature: String) {
        if features.contains(feature) { features.remove(feature) } else { features.insert(feature) }
    }

    /// One submission at a time, taken before any suspension, as a review is.
    /// The server's words are what is shown when it refuses: an unverified
    /// email, a ban, too many places at once.
    ///
    /// With a rating, the web's order: the place, then the rating as a review
    /// of it, which goes to a place someone else added meanwhile too. A
    /// rating that fails leaves the place added, as it is.
    func save() async {
        guard canSave, var draft else { return }
        isSaving = true
        photos.isLocked = true
        outcome = nil
        defer {
            isSaving = false
            photos.isLocked = false
        }
        // The web's order: the photos first, so a place is never added
        // without the ones that were meant to come with it.
        do {
            draft.photos = try await photos.upload(with: uploader)
        } catch {
            log.error("photos for a new place failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(Self.photoWording(for: error))
            return
        }
        let added: AddedPlace
        do {
            added = try await adder.addPlace(draft)
        } catch {
            log.error("add place failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to add place.")))
            return
        }
        guard rating > 0 else {
            outcome = .added(added, rated: false)
            return
        }
        var review = PlaceReviewDraft(placeID: added.placeID, meetupID: nil)
        review.rating = rating
        review.space = space
        review.safety = safety
        review.cleanliness = cleanliness
        do {
            try await reviewer.submitReview(review)
            outcome = .added(added, rated: true)
        } catch {
            log.error("rating a place just added failed: \(String(describing: error), privacy: .public)")
            outcome = .notRated(added, GatheringWords.message(for: error, fallback: String(localized: "Failed to submit review.")))
        }
    }

    /// The pet editor's words for a photo that did not go, with the place in
    /// them where those name the pet: nothing was added.
    static func photoWording(for error: Error) -> String {
        if let upload = error as? UploadError {
            switch upload {
            case .timedOut: return String(localized: "The photo upload timed out. The place was not added.")
            case .transport: return String(localized: "The photo could not be uploaded. The place was not added.")
            default: break
            }
        } else if !(error is UploadPreparation.PreparationError) {
            return String(localized: "The photo could not be uploaded. The place was not added.")
        }
        return PetEditorViewModel.photoWording(for: error)
    }
}

/// The web's Add a Place page, with the place chosen from Apple Maps where
/// the web takes a name and an address.
struct AddPlaceSheet: View {
    @State private var model: AddPlaceModel
    @Environment(\.dismiss) private var dismiss
    /// Opens a place: the one just added, or one found that is here already.
    private let onOpen: (String) -> Void

    init(model: AddPlaceModel, onOpen: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpen = onOpen
    }

    var body: some View {
        Form {
            Section {
                ApplePlacePicker(
                    finder: model.finder, chosen: model.chosen,
                    onSelect: { found in
                        if let placeID = found.placeID { open(placeID) } else { model.choose(found) }
                    },
                    onChange: { model.changePlace() }
                )
            } header: {
                Text("Place")
            } footer: {
                // Not under "nothing found", which says it at more length.
                if model.chosen == nil, !(model.finder.showsResults && model.finder.state == .found([])) {
                    Text("Parks, cafés, vets and other spots on Apple Maps. A home address can't be added.")
                }
            }
            if model.chosen != nil {
                Section("Category") {
                    FlowLayout {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            ChoiceChip(title: category.label, symbol: category.emoji, isSelected: model.category == category) {
                                model.category = category
                            }
                            .accessibilityIdentifier("addPlace.category.\(category.rawValue)")
                        }
                    }
                }
                Section {
                    TextField("What is it like for pets?", text: $model.description, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("addPlace.description")
                } header: {
                    Text("Description")
                } footer: {
                    Text(verbatim: "\(model.descriptionLength)/\(ApplePlaceDraft.maxDescription)")
                        .foregroundStyle(
                            model.descriptionLength > ApplePlaceDraft.maxDescription ? Palette.danger : Palette.secondaryText
                        )
                }
                photosSection
                Section("Features & Amenities") {
                    FlowLayout {
                        ForEach(ApplePlaceDraft.featureKeys, id: \.self) { key in
                            ChoiceChip(title: Place.featureLabel(key), isSelected: model.features.contains(key)) {
                                model.toggle(feature: key)
                            }
                            .accessibilityIdentifier("addPlace.feature.\(key)")
                        }
                    }
                }
                Section {
                    StarRatingRow(title: String(localized: "Rate this place"), value: $model.rating, identifier: "addPlace.rating")
                    // The scores are a rating's: shown once there is one.
                    if model.rating > 0 {
                        StarRatingRow(title: String(localized: "🐾 Space for pets"), value: $model.space, identifier: "addPlace.space")
                        StarRatingRow(title: String(localized: "🛡️ Safety"), value: $model.safety, identifier: "addPlace.safety")
                        StarRatingRow(title: String(localized: "✨ Cleanliness"), value: $model.cleanliness, identifier: "addPlace.cleanliness")
                    }
                } header: {
                    Text("Your Rating (optional)")
                }
                if case .failed(let message) = model.outcome {
                    Section {
                        Text(message)
                            .foregroundStyle(Palette.danger)
                            .accessibilityIdentifier("addPlace.error")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Add a Place")
        .navigationBarTitleDisplayMode(.inline)
        // Once something has been chosen or written, only Cancel closes it: a
        // swipe down to scroll back up would lose it.
        .interactiveDismissDisabled(model.chosen != nil || !model.description.isEmpty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("addPlace.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                // The web's words. Not "Add": the photo picker's confirm button
                // says that, over this one.
                Button(model.isSaving ? String(localized: "Submitting...") : String(localized: "Submit")) {
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("addPlace.save")
            }
        }
        .alert(
            notice?.title ?? "",
            // Closed only by its button, which opens the place.
            isPresented: Binding(get: { notice != nil }, set: { _ in })
        ) {
            Button("Open it") { openFromNotice() }
        } message: {
            Text(notice?.message ?? "")
        }
        .onChange(of: model.outcome) { _, outcome in
            if case .added(let place, let rated) = outcome, rated || !place.alreadyExisted { open(place.placeID) }
        }
        // Opened from a search that found nothing: Apple Maps is asked for
        // the same words straight away.
        .task {
            if case .idle = model.finder.state, !model.finder.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await model.finder.search()
            }
        }
    }

    /// What to say before opening the place. Added already by someone else,
    /// in the moments since the search said it was not: the server keeps
    /// theirs and ignores what was written here. Or added, with the rating
    /// refused.
    private var notice: (placeID: String, title: String, message: String)? {
        switch model.outcome {
        case .added(let place, rated: false) where place.alreadyExisted:
            return (
                place.placeID, String(localized: "This place is already on PetNote"),
                String(localized: "Someone added it while you were writing, so what you wrote was not added. You can review it instead.")
            )
        case .notRated(let place, let reason):
            return (
                place.placeID, String(localized: "The place is saved"),
                String(localized: "Your rating didn't go through: \(reason) You can rate it from the place.")
            )
        default:
            return nil
        }
    }

    private func openFromNotice() {
        guard let placeID = notice?.placeID else { return }
        model.clearOutcome()
        open(placeID)
    }

    private func open(_ placeID: String) {
        dismiss()
        onOpen(placeID)
    }

    /// The web's photos: up to five, picked from the library, sent before the
    /// place.
    private var photosSection: some View {
        Section {
            PickedPhotosRows(photos: model.photos)
        } header: {
            Text("Photos")
        } footer: {
            Text("Up to \(AddPlaceModel.maxPhotos). They help others find the place.")
        }
    }
}
