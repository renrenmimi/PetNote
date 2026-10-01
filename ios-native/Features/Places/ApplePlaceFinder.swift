import Foundation
import Observation
import OSLog
import SwiftUI

/// Finding a place on Apple Maps to choose: how adding a place and creating a
/// meetup both start. Apple is asked on Return, once per search. When asked
/// to, the places someone has added here already are marked, by the
/// identifier each keeps.
@MainActor
@Observable
final class ApplePlaceFinder {
    /// A place Apple Maps found, with ours for it when someone added it and
    /// the finder was asked to look.
    struct Found: Identifiable, Equatable {
        let hit: PlaceSearchHit
        let placeID: String?
        var id: String { hit.applePlaceID }
    }

    enum State: Equatable {
        case idle
        case searching
        case found([Found])
        case failed(String)
    }

    var query: String
    private(set) var state: State = .idle

    private let directory: any PlaceDirectory
    private let places: any PlacesReading
    private let marksAdded: Bool
    /// Bumped by each search, so an older answer does not replace a newer one.
    private var searches = 0
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        query: String = "", places: any PlacesReading, marksAdded: Bool,
        directory: any PlaceDirectory = PlaceDirectories.shared
    ) {
        self.query = query
        self.places = places
        self.marksAdded = marksAdded
        self.directory = directory
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searches += 1
        let mine = searches
        state = .searching
        do {
            let hits = try await directory.search(text)
            let ours = marksAdded && !hits.isEmpty ? try await places.places(applePlaceIDs: hits.map(\.applePlaceID)) : []
            guard mine == searches else { return }
            let added = Dictionary(
                ours.compactMap { place in place.applePlaceID.map { ($0, place.id) } },
                uniquingKeysWith: { first, _ in first }
            )
            state = .found(hits.map { Found(hit: $0, placeID: added[$0.applePlaceID]) })
        } catch {
            guard mine == searches else { return }
            log.error("Apple Maps search failed: \(String(describing: error), privacy: .public)")
            state = .failed(String(localized: "Couldn't search Apple Maps. Try again."))
        }
    }
}

/// In a form's section: the search field and what it found, or the place
/// chosen from it. One screen at a time shows it, so its identifiers are the
/// same on each.
struct ApplePlacePicker: View {
    @Bindable var finder: ApplePlaceFinder
    let chosen: PlaceSearchHit?
    let onSelect: (ApplePlaceFinder.Found) -> Void
    let onChange: () -> Void

    var body: some View {
        if let chosen {
            ApplePlaceCard(hit: chosen, onChange: onChange)
        } else {
            TextField("Search Apple Maps", text: $finder.query)
                .submitLabel(.search)
                .onSubmit { Task { await finder.search() } }
                .accessibilityIdentifier("applePlace.search")
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        switch finder.state {
        case .idle:
            EmptyView()
        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("applePlace.searching")
        case .failed(let message):
            Text(message)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("applePlace.searchError")
        case .found(let found) where found.isEmpty:
            Text("Nothing found on Apple Maps.")
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("applePlace.nothingFound")
        case .found(let found):
            ForEach(found) { result in
                Button { onSelect(result) } label: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(Self.name(of: result.hit))
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.primaryText)
                        if !result.hit.details.address.isEmpty {
                            Text(result.hit.details.address)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        if result.placeID != nil {
                            Text("Already on PetNote")
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(Palette.brandPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("applePlace.result.\(result.id)")
            }
        }
    }

    static func name(of hit: PlaceSearchHit) -> String {
        hit.details.name.isEmpty ? String(localized: "Unnamed place") : hit.details.name
    }
}

/// The chosen place as Apple Maps has it, on Apple's map, as its terms ask
/// wherever its address is shown.
struct ApplePlaceCard: View {
    let hit: PlaceSearchHit
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(ApplePlacePicker.name(of: hit))
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                if !hit.details.address.isEmpty {
                    Text(hit.details.address)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("applePlace.chosen")
            if hit.details.directionsURL != nil {
                PlaceMap(details: hit.details)
            }
            Button(action: onChange) {
                Text("Choose another place")
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("applePlace.change")
        }
    }
}
