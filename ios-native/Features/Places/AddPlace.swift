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

    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var descriptionLength: Int { trimmedDescription.utf16.count }

    /// The web asks for a description, and the server takes 500 at most.
    var canSubmit: Bool {
        !applePlaceID.isEmpty && !trimmedDescription.isEmpty && descriptionLength <= Self.maxDescription
    }

    var payload: [String: Any] {
        [
            "applePlaceId": applePlaceID,
            "category": category.rawValue,
            "description": trimmedDescription,
            "features": Self.featureKeys.filter(features.contains),
        ]
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
        case added(AddedPlace)
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

    private let adder: any PlaceAdding
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        query: String = "", places: any PlacesReading, adder: any PlaceAdding,
        directory: any PlaceDirectory = PlaceDirectories.shared
    ) {
        self.finder = ApplePlaceFinder(query: query, places: places, marksAdded: true, directory: directory)
        self.adder = adder
    }

    var draft: ApplePlaceDraft? {
        chosen.map {
            ApplePlaceDraft(applePlaceID: $0.applePlaceID, category: category, description: description, features: features)
        }
    }

    var descriptionLength: Int { draft?.descriptionLength ?? 0 }

    var canSave: Bool {
        guard draft?.canSubmit == true, !isSaving else { return false }
        if case .added = outcome { return false }
        return true
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
    func save() async {
        guard canSave, let draft else { return }
        isSaving = true
        outcome = nil
        defer { isSaving = false }
        do {
            outcome = .added(try await adder.addPlace(draft))
        } catch {
            log.error("add place failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to add place.")))
        }
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
            Section("Place") {
                ApplePlacePicker(
                    finder: model.finder, chosen: model.chosen,
                    onSelect: { found in
                        if let placeID = found.placeID { open(placeID) } else { model.choose(found) }
                    },
                    onChange: { model.changePlace() }
                )
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
                Button(model.isSaving ? String(localized: "Adding…") : String(localized: "Add")) {
                    Task { await model.save() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("addPlace.save")
            }
        }
        .alert(
            "This place is already on PetNote",
            // Closed only by its button, which opens the place.
            isPresented: Binding(get: { alreadyThere != nil }, set: { _ in })
        ) {
            Button("Open it") { openAlreadyThere() }
        } message: {
            Text("Someone added it while you were writing, so what you wrote was not added. You can review it instead.")
        }
        .onChange(of: model.outcome) { _, outcome in
            if case .added(let place) = outcome, !place.alreadyExisted { open(place.placeID) }
        }
        // Opened from a search that found nothing: Apple Maps is asked for
        // the same words straight away.
        .task {
            if case .idle = model.finder.state, !model.finder.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await model.finder.search()
            }
        }
    }

    /// Added already by someone else, in the moments since the search said it
    /// was not: the server keeps theirs and ignores this.
    private var alreadyThere: String? {
        if case .added(let place) = model.outcome, place.alreadyExisted { return place.placeID }
        return nil
    }

    private func openAlreadyThere() {
        guard let placeID = alreadyThere else { return }
        model.clearOutcome()
        open(placeID)
    }

    private func open(_ placeID: String) {
        dismiss()
        onOpen(placeID)
    }
}
