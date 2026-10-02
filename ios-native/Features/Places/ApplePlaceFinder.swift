import Foundation
import Observation
import OSLog
import SwiftUI

/// Finding a place on Apple Maps to choose: how adding a place and creating a
/// meetup both start. Apple is asked on Return, once per search. When asked
/// to, the places someone has added here already are marked, by the
/// identifier each keeps; and street addresses are found as well, for a
/// meetup, which can be at one where a place of ours cannot.
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
    /// The street addresses the last search found, when it looks for them;
    /// none while a search is under way.
    private(set) var addresses: [PlaceDetails] = []
    /// What the last search was for, as typed: what a meetup can take as its
    /// address when Apple has nothing that fits.
    private(set) var searched = ""
    /// Whether a search finds street addresses too.
    let findsAddresses: Bool

    private let directory: any PlaceDirectory
    private let places: any PlacesReading
    private let marksAdded: Bool
    /// Bumped by each search, so an older answer does not replace a newer one.
    private var searches = 0
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        query: String = "", places: any PlacesReading, marksAdded: Bool, findsAddresses: Bool = false,
        directory: any PlaceDirectory = PlaceDirectories.shared
    ) {
        self.query = query
        self.places = places
        self.marksAdded = marksAdded
        self.findsAddresses = findsAddresses
        self.directory = directory
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searches += 1
        let mine = searches
        state = .searching
        addresses = []
        searched = text
        // At the same time as the places, not after them.
        async let streets = streetAddresses(for: text)
        do {
            let hits = try await directory.search(text)
            let ours = marksAdded && !hits.isEmpty ? try await places.places(applePlaceIDs: hits.map(\.applePlaceID)) : []
            let found = await streets
            guard mine == searches else { return }
            let added = Dictionary(
                ours.compactMap { place in place.applePlaceID.map { ($0, place.id) } },
                uniquingKeysWith: { first, _ in first }
            )
            addresses = found
            state = .found(hits.map { Found(hit: $0, placeID: added[$0.applePlaceID]) })
        } catch {
            guard mine == searches else { return }
            log.error("Apple Maps search failed: \(String(describing: error), privacy: .public)")
            state = .failed(String(localized: "Couldn't search Apple Maps. Try again."))
        }
    }

    /// None when a search does not look for them, and none when Apple could
    /// not be asked: the places it found still show, and what was typed can
    /// still be used as it is.
    private func streetAddresses(for text: String) async -> [PlaceDetails] {
        guard findsAddresses else { return [] }
        do {
            return try await directory.searchAddresses(text)
        } catch {
            log.error("Apple Maps address search failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

/// In a form's section: the search field and what it found, or the place
/// chosen from it. One screen at a time shows it, so its identifiers are the
/// same on each.
///
/// For a meetup, which can be at an address, what Apple found comes in two
/// groups, places and addresses, and the words searched for can be taken as
/// the address as they are: one search for wherever it is, as Apple Maps and
/// the event apps have it, rather than a choice of kind before it.
struct ApplePlacePicker: View {
    @Bindable var finder: ApplePlaceFinder
    let chosen: PlaceSearchHit?
    let onSelect: (ApplePlaceFinder.Found) -> Void
    let onChange: () -> Void
    /// An address Apple found, with what it said about it, or the words as
    /// typed with nothing: for a finder that finds addresses.
    var onChooseAddress: (String, PlaceDetails?) -> Void = { _, _ in }

    var body: some View {
        if let chosen {
            ApplePlaceCard(hit: chosen, onChange: onChange)
        } else {
            TextField(prompt, text: $finder.query)
                .submitLabel(.search)
                // Street names, which a dictionary would "correct".
                .autocorrectionDisabled(finder.findsAddresses)
                .onSubmit { Task { await finder.search() } }
                .accessibilityIdentifier("applePlace.search")
            results
        }
    }

    private var prompt: String {
        finder.findsAddresses ? String(localized: "Search for a place or an address") : String(localized: "Search Apple Maps")
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
            if finder.findsAddresses { asTyped }
        case .found(let found) where finder.findsAddresses:
            if found.isEmpty, finder.addresses.isEmpty {
                Text("Nothing on Apple Maps matches that.")
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("applePlace.nothingFound")
            }
            if !found.isEmpty {
                heading(String(localized: "Places"))
                ForEach(found) { placeRow($0) }
            }
            if !finder.addresses.isEmpty {
                heading(String(localized: "Addresses"))
                ForEach(Array(finder.addresses.enumerated()), id: \.offset) { index, address in
                    addressRow(address, index: index)
                }
            }
            asTyped
        case .found(let found) where found.isEmpty:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Nothing on Apple Maps by that name.")
                    .foregroundStyle(Palette.primaryText)
                Text("A place on PetNote is a spot on Apple Maps, like a park, a café or a vet. A home or street address can't be added here, but a meetup can be at one.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("applePlace.nothingFound")
        case .found(let found):
            ForEach(found) { placeRow($0) }
        }
    }

    /// Over a group of results, as a list's section header reads.
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Palette.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func placeRow(_ result: ApplePlaceFinder.Found) -> some View {
        Button { onSelect(result) } label: {
            ResultRow(symbol: "mappin.circle.fill", tint: Palette.brandPrimary) {
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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("applePlace.result.\(result.id)")
    }

    /// Its street on the first line and all of it on the second, as Apple
    /// Maps lists an address.
    private func addressRow(_ address: PlaceDetails, index: Int) -> some View {
        Button { onChooseAddress(address.address, address) } label: {
            ResultRow(symbol: "house.circle.fill", tint: Palette.secondaryText) {
                Text(address.name.isEmpty ? address.address : address.name)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                if !address.name.isEmpty, address.name != address.address {
                    Text(address.address)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("applePlace.address.\(index)")
    }

    /// For an address Apple does not know, or knows by other words.
    @ViewBuilder
    private var asTyped: some View {
        if !finder.searched.isEmpty {
            Button { onChooseAddress(finder.searched, nil) } label: {
                ResultRow(symbol: "pencil.circle.fill", tint: Palette.secondaryText) {
                    Text("Use “\(finder.searched)” as the address")
                        .font(Typography.body)
                        .foregroundStyle(Palette.primaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("applePlace.asTyped")
        }
    }

    static func name(of hit: PlaceSearchHit) -> String {
        hit.details.name.isEmpty ? String(localized: "Unnamed place") : hit.details.name
    }
}

/// One result: what kind it is, as a symbol, then its lines.
private struct ResultRow<Lines: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let lines: Lines

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            // Decoration: the group's heading and the lines say what it is.
            Image(systemName: symbol)
                .font(Typography.sectionTitle)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) { lines }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
        .contentShape(.rect)
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
