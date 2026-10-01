import Foundation
import Observation
import OSLog
import SwiftUI

/// What is sent to create or edit a meetup (`createMeetupCallable`,
/// `updateMeetupCallable`, functions/src/meetups.ts): its words, when and for
/// how long, and where, in one of the two shapes the app can find. A place
/// from Apple Maps goes by its identifier only; an address the organiser types
/// goes with what to call it, and makes no place (the owner's choice on
/// 2026-09-30). When only those who join may see where, everyone else sees the
/// area the organiser names. A meetup made on the web, at a place with a name,
/// address and position of its own, is sent back where it was unless the
/// organiser chooses somewhere else.
struct MeetupDraft: Equatable, Sendable {
    /// The server's limits, in its units: UTF-16, as JavaScript counts.
    static let maxTitle = 60
    static let maxDescription = 500
    static let maxAddress = 200
    static let maxLabel = 60
    static let maxArea = 100
    /// The web's choices, in minutes.
    static let durations = [30, 60, 90, 120, 180, 240]

    enum Where: Equatable, Sendable {
        case applePlace
        case address
        /// Where a meetup made on the web already is: its name, address and
        /// position, sent back as they are.
        case unchanged
    }

    /// Who may join, as the web's form sets it. `sanitizeMeetupRequirements`
    /// (functions/src/meetups.ts) keeps these, and the join callable checks
    /// them.
    struct Requirements: Equatable, Sendable {
        /// The server's limits, in its units.
        static let maxCustomPetType = 30
        static let maxNotes = 200
        /// The web's slider: none to twenty, none meaning any number.
        static let maxPetsRange = 0...20
        static let minFollowersRange = 0...100
        /// The web's choices, in its order.
        static let petTypes = ["any", "dog", "cat", "other"]

        var petType = "any"
        /// For `other`: "Birds".
        var customPetType = ""
        var dogSize = "any"
        var maxPets = 0
        var mustHavePosts = false
        var mustHavePetProfile = false
        var minFollowers = 0
        var notes = ""

        var isValid: Bool {
            (petType != "other" || MeetupDraft.length(customPetType) <= Self.maxCustomPetType)
                && MeetupDraft.length(notes) <= Self.maxNotes
        }

        init() {}

        /// What a meetup already asks, to edit.
        init(_ requirements: MeetupRequirements) {
            petType = Self.petTypes.contains(requirements.petType) ? requirements.petType
                : requirements.petType == "any_dog" ? "dog" : requirements.petType == "any_cat" ? "cat" : "any"
            customPetType = requirements.customPetType
            dogSize = MeetupRequirements.dogSizes.contains(requirements.dogSize) ? requirements.dogSize : "any"
            maxPets = min(max(requirements.maxPets, 0), Self.maxPetsRange.upperBound)
            mustHavePosts = requirements.mustHavePosts
            mustHavePetProfile = requirements.mustHavePetProfile
            minFollowers = min(max(requirements.minFollowers, 0), Self.minFollowersRange.upperBound)
            notes = requirements.notes
        }

        var payload: [String: Any] {
            var payload: [String: Any] = [
                "petType": petType,
                // A size is for dogs: one chosen before the type changed is
                // not sent, where the web sends it all the same.
                "dogSize": petType == "dog" ? dogSize : "any",
                "maxPets": maxPets,
                "mustHavePosts": mustHavePosts,
                "mustHavePetProfile": mustHavePetProfile,
                "minFollowers": minFollowers,
                "additionalNotes": MeetupDraft.trimmed(notes),
            ]
            if petType == "other" { payload["customPetType"] = MeetupDraft.trimmed(customPetType) }
            return payload
        }

        /// The web's chips.
        static func petTypeLabel(_ type: String) -> String {
            switch type {
            case "dog": String(localized: "Dogs Only")
            case "cat": String(localized: "Cats Only")
            case "other": String(localized: "Other")
            default: String(localized: "Any Pet")
            }
        }

        static func petTypeSymbol(_ type: String) -> String {
            switch type {
            case "dog": "🐕"
            case "cat": "🐱"
            case "other": "📝"
            default: "🐾"
            }
        }
    }

    var title = ""
    var description = ""
    var date: Date
    var duration = 60
    var whereKind: Where = .applePlace
    /// For `.applePlace`: the place chosen from what Apple Maps found.
    var place: PlaceSearchHit?
    /// For `.address`: the organiser's own words.
    var address = ""
    var label = ""
    /// The web's default: only those who join see where.
    var isAddressPrivate = true
    var area = ""
    var requirements = Requirements()
    /// For `.unchanged`: the web's place, as the meetup keeps it.
    var unchangedPlace: MeetupPlace?
    /// On the guest list with the organiser from the start, as the web sends
    /// it; none, and the organiser goes alone. Only for a new meetup.
    var organizerPetID: String?

    init(date: Date) {
        self.date = date
    }

    /// A meetup as it is, to edit. `place` is where it is as its organiser
    /// sees it, the private copy for a participants-only meetup; `details` is
    /// what Apple says about a place from Apple Maps, so it shows as chosen.
    init(editing meetup: Meetup, place: MeetupPlace?, details: PlaceDetails?) {
        self.date = meetup.date ?? Date()
        title = meetup.title
        description = meetup.description
        duration = meetup.durationMinutes
        isAddressPrivate = meetup.isAddressPrivate
        if isAddressPrivate { area = meetup.place.area }
        requirements = Requirements(meetup.requirements)
        guard let place else { return }
        switch place.shape {
        case .apple(let id):
            whereKind = .applePlace
            self.place = PlaceSearchHit(
                applePlaceID: id,
                details: details ?? PlaceDetails(name: "", address: "", latitude: 0, longitude: 0)
            )
        case .typed:
            whereKind = .address
            address = place.address
            label = place.label
        case .stored:
            whereKind = .unchanged
            unchangedPlace = place
        }
    }

    /// Tomorrow at ten: a time a meetup could be, which a person changes.
    static func defaultDate(now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// The web's choices, and one a meetup already has that is not among
    /// them (the server takes five minutes to a day), so it shows as chosen.
    static func durationChoices(including current: Int) -> [Int] {
        durations.contains(current) ? durations : (durations + [current]).sorted()
    }

    /// The web's words for each duration.
    static func durationLabel(_ minutes: Int) -> String {
        switch minutes {
        case 30: String(localized: "30 min")
        case 60: String(localized: "1 hour")
        case 90: String(localized: "1.5 hours")
        case 120: String(localized: "2 hours")
        case 180: String(localized: "3 hours")
        case 240: String(localized: "Half day")
        default: String(localized: "\(minutes) min")
        }
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func length(_ text: String) -> Int { trimmed(text).utf16.count }

    /// The web's rules — a title, a description, a time still to come and a
    /// place — and the server's limits.
    func canSubmit(now: Date) -> Bool {
        let title = Self.length(title), description = Self.length(description)
        guard title > 0, title <= Self.maxTitle, description > 0, description <= Self.maxDescription,
              date > now, requirements.isValid else { return false }
        if isAddressPrivate, Self.length(area) > Self.maxArea { return false }
        switch whereKind {
        case .applePlace:
            return place != nil
        case .address:
            let address = Self.length(address)
            return address > 0 && address <= Self.maxAddress && Self.length(label) <= Self.maxLabel
        case .unchanged:
            return unchangedPlace != nil
        }
    }

    var payload: [String: Any] {
        var location: [String: Any]
        switch whereKind {
        case .applePlace:
            location = ["kind": "applePlace", "applePlaceId": place?.applePlaceID ?? ""]
        case .address:
            location = ["kind": "address", "address": Self.trimmed(address), "label": Self.trimmed(label)]
        case .unchanged:
            // The web's shape, which the server still takes as it always has.
            let kept = unchangedPlace
            location = [
                "name": kept?.name ?? "", "address": kept?.address ?? "",
                "lat": kept?.latitude ?? 0, "lng": kept?.longitude ?? 0,
                "city": kept?.city ?? "", "state": kept?.state ?? "",
            ]
        }
        if isAddressPrivate, whereKind != .unchanged { location["area"] = Self.trimmed(area) }
        var payload: [String: Any] = [
            "title": Self.trimmed(title),
            "description": Self.trimmed(description),
            "dateMillis": Int((date.timeIntervalSince1970 * 1000).rounded()),
            "duration": duration,
            "location": location,
            "locationVisibility": isAddressPrivate ? "participants_only" : "everyone",
            "requirements": requirements.payload,
        ]
        if let organizerPetID { payload["organizerPetId"] = organizerPetID }
        return payload
    }
}

protocol MeetupCreating: Sendable {
    /// The new meetup's id.
    func createMeetup(_ draft: MeetupDraft) async throws -> String
}

protocol MeetupEditing: Sendable {
    /// Organiser or admin only, as the server checks.
    func updateMeetup(id: String, _ draft: MeetupDraft) async throws
}

/// Creating or editing a meetup: the web's Create Meetup and Edit Meetup,
/// with where found on Apple Maps or typed, as the app can now keep it.
@MainActor
@Observable
final class MeetupFormModel {
    enum Purpose: Equatable {
        case create
        case edit(meetupID: String)
    }

    enum Outcome: Equatable {
        case created(String)
        case saved
        case failed(String)
    }

    let purpose: Purpose

    var draft: MeetupDraft
    /// Apple Maps, searched for the place. Any place can hold a meetup, so
    /// none is marked.
    let finder: ApplePlaceFinder
    private(set) var isSaving = false
    private(set) var outcome: Outcome?

    private let uid: String
    private let creator: (any MeetupCreating)?
    private let editor: (any MeetupEditing)?
    private let pets: (any PetChoiceProviding)?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "meetups")

    /// A new meetup.
    init(
        uid: String, creator: any MeetupCreating, places: any PlacesReading, pets: any PetChoiceProviding,
        directory: any PlaceDirectory = PlaceDirectories.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.purpose = .create
        self.uid = uid
        self.creator = creator
        self.editor = nil
        self.pets = pets
        self.now = now
        self.draft = MeetupDraft(date: MeetupDraft.defaultDate(now: now()))
        self.finder = ApplePlaceFinder(places: places, marksAdded: false, directory: directory)
    }

    /// A meetup that is, as its organiser sees it.
    init(
        editing meetup: Meetup, place: MeetupPlace?, details: PlaceDetails?,
        editor: any MeetupEditing, places: any PlacesReading,
        directory: any PlaceDirectory = PlaceDirectories.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.purpose = .edit(meetupID: meetup.id)
        self.uid = meetup.organizerID
        self.creator = nil
        self.editor = editor
        self.pets = nil
        self.now = now
        self.draft = MeetupDraft(editing: meetup, place: place, details: details)
        self.finder = ApplePlaceFinder(places: places, marksAdded: false, directory: directory)
    }

    var canSave: Bool {
        guard draft.canSubmit(now: now()), !isSaving else { return false }
        switch outcome {
        case .created, .saved: return false
        case .failed, nil: return true
        }
    }

    /// Something a swipe down would lose. An edit has it from the start.
    var hasInput: Bool {
        if case .edit = purpose { return true }
        return !draft.title.isEmpty || !draft.description.isEmpty || draft.place != nil || !draft.address.isEmpty
    }

    /// The web brings the organiser's first pet (`pets[0]`) to a new meetup.
    func loadPets() async {
        guard purpose == .create, draft.organizerPetID == nil, let pets else { return }
        do {
            draft.organizerPetID = try await pets.pets(ownedBy: uid).first?.id
        } catch {
            log.error("pets for a new meetup failed: \(String(describing: error), privacy: .public)")
        }
    }

    func choose(_ found: ApplePlaceFinder.Found) {
        draft.place = found.hit
    }

    func changePlace() {
        draft.place = nil
    }

    /// One at a time, taken before any suspension. The server's words when it
    /// refuses: an unverified email, a time that has passed, too many at once,
    /// someone who is not the organiser.
    func submit() async {
        guard canSave else { return }
        isSaving = true
        outcome = nil
        defer { isSaving = false }
        do {
            switch purpose {
            case .create:
                guard let creator else { return }
                outcome = .created(try await creator.createMeetup(draft))
            case .edit(let meetupID):
                guard let editor else { return }
                try await editor.updateMeetup(id: meetupID, draft)
                outcome = .saved
            }
        } catch {
            log.error("saving a meetup failed: \(String(describing: error), privacy: .public)")
            let fallback = purpose == .create
                ? String(localized: "Failed to create meetup.") : String(localized: "Failed to update meetup.")
            outcome = .failed(GatheringWords.message(for: error, fallback: fallback))
        }
    }
}

struct MeetupFormSheet: View {
    /// The web's tips, shown open as the web shows them.
    static let safetyTips = [
        String(localized: "Always choose a public, well-lit location — dog parks, community parks, or pet-friendly cafés"),
        String(localized: "Avoid hosting meetups at private residences, especially with people you haven't met before"),
        String(localized: "Let a friend or family member know where and when the meetup is happening"),
        String(localized: "Remind participants to bring fresh water and waste bags for their pets"),
        String(localized: "Ensure all attending pets are up to date on vaccinations"),
    ]

    @State private var model: MeetupFormModel
    @State private var showsSafetyTips = true
    @Environment(\.dismiss) private var dismiss
    private let onOpen: (String) -> Void

    init(model: MeetupFormModel, onOpen: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpen = onOpen
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $model.draft.title)
                    .accessibilityIdentifier("createMeetup.title")
            } header: {
                Text("Title")
            } footer: {
                counter(MeetupDraft.length(model.draft.title), of: MeetupDraft.maxTitle)
            }
            Section {
                TextField("What will you do, and who is it for?", text: $model.draft.description, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("createMeetup.description")
            } header: {
                Text("Description")
            } footer: {
                counter(MeetupDraft.length(model.draft.description), of: MeetupDraft.maxDescription)
            }
            Section("When") {
                DatePicker("Starts", selection: $model.draft.date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("createMeetup.date")
                Picker("Duration", selection: $model.draft.duration) {
                    ForEach(MeetupDraft.durationChoices(including: model.draft.duration), id: \.self) { minutes in
                        Text(MeetupDraft.durationLabel(minutes)).tag(minutes)
                    }
                }
                .accessibilityIdentifier("createMeetup.duration")
            }
            Section {
                DisclosureGroup("Safety Tips for Meetup Organizers", isExpanded: $showsSafetyTips) {
                    ForEach(Self.safetyTips, id: \.self) { tip in
                        Label(tip, systemImage: "checkmark.shield")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .accessibilityIdentifier("createMeetup.safety")
            }
            Section {
                Picker("Where", selection: $model.draft.whereKind) {
                    if model.draft.unchangedPlace != nil {
                        Text("As it was").tag(MeetupDraft.Where.unchanged)
                    }
                    Text("A place").tag(MeetupDraft.Where.applePlace)
                    Text("An address").tag(MeetupDraft.Where.address)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("createMeetup.where")
                switch model.draft.whereKind {
                case .unchanged:
                    if let kept = model.draft.unchangedPlace { unchangedPlace(kept) }
                case .applePlace:
                    ApplePlacePicker(
                        finder: model.finder, chosen: model.draft.place,
                        onSelect: { model.choose($0) }, onChange: { model.changePlace() }
                    )
                case .address:
                    // Street and place names, which a dictionary would
                    // "correct".
                    TextField("Address", text: $model.draft.address)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("createMeetup.address")
                    TextField("What to call it (optional)", text: $model.draft.label)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("createMeetup.label")
                }
            } header: {
                Text("Where")
            } footer: {
                if model.draft.whereKind == .address {
                    Text("A meetup at an address is not added to Places.")
                }
            }
            Section {
                Picker("Who sees the address", selection: $model.draft.isAddressPrivate) {
                    Text("🔒 Only people who join").tag(true)
                    Text("🌍 Everyone").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("createMeetup.visibility")
                if model.draft.isAddressPrivate {
                    TextField("Area everyone sees, like Somerville", text: $model.draft.area)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("createMeetup.area")
                }
            } header: {
                Text("Who sees the address")
            } footer: {
                Text(model.draft.isAddressPrivate
                     ? "People who have not joined see only the area."
                     : "Best for public parks or community spots.")
            }
            requirementsSection
            if case .failed(let message) = model.outcome {
                Section {
                    Text(message)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("createMeetup.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(model.purpose == .create ? String(localized: "Create Meetup") : String(localized: "Edit Meetup"))
        .navigationBarTitleDisplayMode(.inline)
        // Only Cancel closes it once something is written or chosen.
        .interactiveDismissDisabled(model.hasInput)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("createMeetup.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    Task { await model.submit() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("createMeetup.save")
            }
        }
        .task { await model.loadPets() }
        .onChange(of: model.outcome) { _, outcome in
            switch (outcome, model.purpose) {
            case (.created(let meetupID), _), (.saved, .edit(let meetupID)):
                dismiss()
                onOpen(meetupID)
            default:
                break
            }
        }
    }

    private var saveTitle: String {
        switch (model.purpose, model.isSaving) {
        case (.create, false): String(localized: "Create")
        case (.create, true): String(localized: "Creating…")
        case (.edit, false): String(localized: "Save")
        case (.edit, true): String(localized: "Saving…")
        }
    }

    /// Where a meetup made on the web is, as it keeps it: its name, address
    /// and, with a position, a map.
    private func unchangedPlace(_ place: MeetupPlace) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(place.storedDetails.name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                if !place.address.isEmpty, place.address != place.storedDetails.name {
                    Text(place.address)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("createMeetup.unchanged")
            if place.storedDetails.directionsURL != nil {
                PlaceMap(details: place.storedDetails)
            }
        }
    }

    /// The web's Requirements: what the server checks when someone joins.
    private var requirementsSection: some View {
        Section {
            FlowLayout {
                ForEach(MeetupDraft.Requirements.petTypes, id: \.self) { type in
                    ChoiceChip(
                        title: MeetupDraft.Requirements.petTypeLabel(type),
                        symbol: MeetupDraft.Requirements.petTypeSymbol(type),
                        isSelected: model.draft.requirements.petType == type
                    ) { model.draft.requirements.petType = type }
                    .accessibilityIdentifier("createMeetup.petType.\(type)")
                }
            }
            if model.draft.requirements.petType == "other" {
                TextField("What kind? Birds, rabbits, hamsters…", text: $model.draft.requirements.customPetType)
                    .accessibilityIdentifier("createMeetup.customPetType")
            }
            if model.draft.requirements.petType == "dog" {
                FlowLayout {
                    ForEach(MeetupRequirements.dogSizes, id: \.self) { size in
                        ChoiceChip(
                            title: MeetupRequirements.dogSizeLabel(size),
                            isSelected: model.draft.requirements.dogSize == size
                        ) { model.draft.requirements.dogSize = size }
                        .accessibilityIdentifier("createMeetup.dogSize.\(size)")
                    }
                }
            }
            Stepper(value: $model.draft.requirements.maxPets, in: MeetupDraft.Requirements.maxPetsRange) {
                Text(Self.maxPetsLine(model.draft.requirements.maxPets))
            }
            .accessibilityIdentifier("createMeetup.maxPets")
            Toggle("Must have posted at least once", isOn: $model.draft.requirements.mustHavePosts)
                .accessibilityIdentifier("createMeetup.mustHavePosts")
            Toggle("Must have a pet profile", isOn: $model.draft.requirements.mustHavePetProfile)
                .accessibilityIdentifier("createMeetup.mustHavePetProfile")
            Stepper(value: $model.draft.requirements.minFollowers, in: MeetupDraft.Requirements.minFollowersRange) {
                Text(Self.minFollowersLine(model.draft.requirements.minFollowers))
            }
            .accessibilityIdentifier("createMeetup.minFollowers")
            TextField("Notes, like: please bring water bowls and bags", text: $model.draft.requirements.notes, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("createMeetup.notes")
        } header: {
            Text("Requirements")
        } footer: {
            counter(MeetupDraft.length(model.draft.requirements.notes), of: MeetupDraft.Requirements.maxNotes)
        }
    }

    static func maxPetsLine(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "Any number of pets")
        case 1: String(localized: "Up to 1 pet")
        default: String(localized: "Up to \(count) pets")
        }
    }

    static func minFollowersLine(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No followed pets needed")
        case 1: String(localized: "At least 1 followed pet")
        default: String(localized: "At least \(count) followed pets")
        }
    }

    private func counter(_ count: Int, of limit: Int) -> some View {
        Text(verbatim: "\(count)/\(limit)")
            .foregroundStyle(count > limit ? Palette.danger : Palette.secondaryText)
    }
}
