import Foundation
import Observation

/// What a screen has looked up for its places from Apple Maps.
///
/// A place added from Apple Maps stores its identifier and nothing of Apple's
/// (`docs/apple-maps-places-plan.md`), so its name, address and position are
/// asked for each time a screen shows it, through `PlaceDirectories.shared`
/// and the temporary cache behind it. A place from the web stores its own and
/// goes nowhere.
@MainActor
@Observable
final class PlaceLookups {
    enum Answer: Equatable, Sendable {
        case looking
        case found(PlaceDetails)
        /// Apple no longer knows the place: closed, moved, or merged into
        /// another. Its reviews and check-ins are still ours and still shown.
        case gone
        /// Apple could not be asked. The next look tries again.
        case failed
    }

    private(set) var answers: [String: Answer] = [:]
    private let directory: any PlaceDirectory

    init(directory: any PlaceDirectory = PlaceDirectories.shared) {
        self.directory = directory
    }

    /// Asks for every place from Apple Maps among `places` that is not found,
    /// gone or being asked for already: all at once, as a list shows them.
    func lookUp(_ places: [Place]) async {
        let ids = Set(places.compactMap(\.applePlaceID)).filter { id in
            switch answers[id] {
            case .found, .gone, .looking: false
            case .failed, nil: true
            }
        }
        guard !ids.isEmpty else { return }
        for id in ids { answers[id] = .looking }
        let directory = directory
        await withTaskGroup(of: (String, Answer).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        let found = try await directory.details(forApplePlaceID: id)
                        return (id, found.map(Answer.found) ?? .gone)
                    } catch {
                        return (id, .failed)
                    }
                }
            }
            for await (id, answer) in group { answers[id] = answer }
        }
    }

    /// What to show for `place`: what it stores, for a place from the web;
    /// what Apple said, for one from Apple Maps.
    func shown(_ place: Place) -> Answer {
        guard let id = place.applePlaceID else { return .found(place.storedDetails) }
        return answers[id] ?? .looking
    }

    /// The name to show for `place`, in words even when there is no answer:
    /// a row is never left blank.
    func name(of place: Place) -> String {
        switch shown(place) {
        case .found(let details) where !details.name.isEmpty: details.name
        case .found: String(localized: "Unnamed place")
        case .looking: String(localized: "Loading…")
        case .gone: String(localized: "No longer on Apple Maps")
        case .failed: String(localized: "Couldn't load this place")
        }
    }
}
