import Foundation
import Observation
import OSLog
import SwiftUI

/// What is sent to create a meetup (`createMeetupCallable`,
/// functions/src/meetups.ts): its words, when and for how long, and where, in
/// one of the two shapes the app can find. A place from Apple Maps goes by its
/// identifier only; an address the organiser types goes with what to call it,
/// and makes no place (the owner's choice on 2026-09-30). When only those who
/// join may see where, everyone else sees the area the organiser names.
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
    /// On the guest list with the organiser from the start, as the web sends
    /// it; none, and the organiser goes alone.
    var organizerPetID: String?

    /// Tomorrow at ten: a time a meetup could be, which a person changes.
    static func defaultDate(now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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
              date > now else { return false }
        if isAddressPrivate, Self.length(area) > Self.maxArea { return false }
        switch whereKind {
        case .applePlace:
            return place != nil
        case .address:
            let address = Self.length(address)
            return address > 0 && address <= Self.maxAddress && Self.length(label) <= Self.maxLabel
        }
    }

    var payload: [String: Any] {
        var location: [String: Any]
        switch whereKind {
        case .applePlace:
            location = ["kind": "applePlace", "applePlaceId": place?.applePlaceID ?? ""]
        case .address:
            location = ["kind": "address", "address": Self.trimmed(address), "label": Self.trimmed(label)]
        }
        if isAddressPrivate { location["area"] = Self.trimmed(area) }
        var payload: [String: Any] = [
            "title": Self.trimmed(title),
            "description": Self.trimmed(description),
            "dateMillis": Int((date.timeIntervalSince1970 * 1000).rounded()),
            "duration": duration,
            "location": location,
            "locationVisibility": isAddressPrivate ? "participants_only" : "everyone",
            // Who may join comes next; until then, the server's defaults:
            // any pet, any number.
            "requirements": [String: Any](),
        ]
        if let organizerPetID { payload["organizerPetId"] = organizerPetID }
        return payload
    }
}

protocol MeetupCreating: Sendable {
    /// The new meetup's id.
    func createMeetup(_ draft: MeetupDraft) async throws -> String
}

/// Creating a meetup: the web's Create Meetup, with where found on Apple Maps
/// or typed, as the app can now keep it.
@MainActor
@Observable
final class CreateMeetupModel {
    enum Outcome: Equatable {
        case created(String)
        case failed(String)
    }

    var draft: MeetupDraft
    /// Apple Maps, searched for the place. Any place can hold a meetup, so
    /// none is marked.
    let finder: ApplePlaceFinder
    private(set) var isSaving = false
    private(set) var outcome: Outcome?

    private let uid: String
    private let creator: any MeetupCreating
    private let pets: any PetChoiceProviding
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "meetups")

    init(
        uid: String, creator: any MeetupCreating, places: any PlacesReading, pets: any PetChoiceProviding,
        directory: any PlaceDirectory = PlaceDirectories.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uid = uid
        self.creator = creator
        self.pets = pets
        self.now = now
        self.draft = MeetupDraft(date: MeetupDraft.defaultDate(now: now()))
        self.finder = ApplePlaceFinder(places: places, marksAdded: false, directory: directory)
    }

    var canSave: Bool {
        guard draft.canSubmit(now: now()), !isSaving else { return false }
        if case .created = outcome { return false }
        return true
    }

    /// Something a swipe down would lose.
    var hasInput: Bool {
        !draft.title.isEmpty || !draft.description.isEmpty || draft.place != nil || !draft.address.isEmpty
    }

    /// The web brings the organiser's first pet (`pets[0]`).
    func loadPets() async {
        guard draft.organizerPetID == nil else { return }
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
    /// refuses: an unverified email, a time that has passed, too many at once.
    func create() async {
        guard canSave else { return }
        isSaving = true
        outcome = nil
        defer { isSaving = false }
        do {
            outcome = .created(try await creator.createMeetup(draft))
        } catch {
            log.error("create meetup failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to create meetup.")))
        }
    }
}

struct CreateMeetupSheet: View {
    /// The web's tips, shown open as the web shows them.
    static let safetyTips = [
        String(localized: "Always choose a public, well-lit location — dog parks, community parks, or pet-friendly cafés"),
        String(localized: "Avoid hosting meetups at private residences, especially with people you haven't met before"),
        String(localized: "Let a friend or family member know where and when the meetup is happening"),
        String(localized: "Remind participants to bring fresh water and waste bags for their pets"),
        String(localized: "Ensure all attending pets are up to date on vaccinations"),
    ]

    @State private var model: CreateMeetupModel
    @State private var showsSafetyTips = true
    @Environment(\.dismiss) private var dismiss
    private let onOpen: (String) -> Void

    init(model: CreateMeetupModel, onOpen: @escaping (String) -> Void) {
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
                    ForEach(MeetupDraft.durations, id: \.self) { minutes in
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
                    Text("A place").tag(MeetupDraft.Where.applePlace)
                    Text("An address").tag(MeetupDraft.Where.address)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("createMeetup.where")
                switch model.draft.whereKind {
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
            if case .failed(let message) = model.outcome {
                Section {
                    Text(message)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("createMeetup.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Create Meetup")
        .navigationBarTitleDisplayMode(.inline)
        // Only Cancel closes it once something is written or chosen.
        .interactiveDismissDisabled(model.hasInput)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("createMeetup.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isSaving ? String(localized: "Creating…") : String(localized: "Create")) {
                    Task { await model.create() }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("createMeetup.save")
            }
        }
        .task { await model.loadPets() }
        .onChange(of: model.outcome) { _, outcome in
            if case .created(let meetupID) = outcome {
                dismiss()
                onOpen(meetupID)
            }
        }
    }

    private func counter(_ count: Int, of limit: Int) -> some View {
        Text(verbatim: "\(count)/\(limit)")
            .foregroundStyle(count > limit ? Palette.danger : Palette.secondaryText)
    }
}
