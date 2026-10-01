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

    /// What is asked: a place by its Apple identifier, or an address someone
    /// typed.
    private enum Question: Hashable, Sendable {
        case apple(String)
        case address(String)
    }

    private var answers: [Question: Answer] = [:]
    private let directory: any PlaceDirectory

    init(directory: any PlaceDirectory = PlaceDirectories.shared) {
        self.directory = directory
    }

    /// Asks for every place from Apple Maps among `places` that is not found,
    /// gone or being asked for already: all at once, as a list shows them.
    func lookUp(_ places: [Place]) async {
        await ask(places.compactMap { $0.applePlaceID.map(Question.apple) })
    }

    /// The same for where meetups are: a place from Apple Maps by its
    /// identifier, and a typed address for its position on a map.
    func lookUp(meetupPlaces: [MeetupPlace]) async {
        await ask(meetupPlaces.compactMap { place in
            switch place.shape {
            case .apple(let id): .apple(id)
            case .typed: .address(place.address)
            case .stored: nil
            }
        })
    }

    /// The identifiers of the places Apple Maps finds for `text`, most
    /// relevant first. What Apple said about each is kept as its answer, so
    /// the rows they become are named without asking again.
    func search(_ text: String) async throws -> [String] {
        let hits = try await directory.search(text)
        for hit in hits { answers[.apple(hit.applePlaceID)] = .found(hit.details) }
        return hits.map(\.applePlaceID)
    }

    private func ask(_ questions: [Question]) async {
        let pending = Set(questions).filter { question in
            switch answers[question] {
            case .found, .gone, .looking: false
            case .failed, nil: true
            }
        }
        guard !pending.isEmpty else { return }
        for question in pending { answers[question] = .looking }
        let directory = directory
        await withTaskGroup(of: (Question, Answer).self) { group in
            for question in pending {
                group.addTask {
                    do {
                        let found: PlaceDetails?
                        switch question {
                        case .apple(let id): found = try await directory.details(forApplePlaceID: id)
                        case .address(let text): found = try await directory.locate(address: text)
                        }
                        return (question, found.map(Answer.found) ?? .gone)
                    } catch {
                        return (question, .failed)
                    }
                }
            }
            for await (question, answer) in group { answers[question] = answer }
        }
    }

    /// What to show for `place`: what it stores, for a place from the web;
    /// what Apple said, for one from Apple Maps.
    func shown(_ place: Place) -> Answer {
        guard let id = place.applePlaceID else { return .found(place.storedDetails) }
        return answers[.apple(id)] ?? .looking
    }

    /// What to show for where a meetup is. A typed address shows the
    /// organiser's words straight away, whatever Apple says; the position
    /// Apple finds for them is what puts them on a map.
    func shown(_ place: MeetupPlace) -> Answer {
        switch place.shape {
        case .stored:
            return .found(place.storedDetails)
        case .apple(let id):
            return answers[.apple(id)] ?? .looking
        case .typed:
            let words = place.storedDetails
            guard case .found(let located) = answers[.address(place.address)] else { return .found(words) }
            return .found(PlaceDetails(
                name: words.name, address: words.address,
                latitude: located.latitude, longitude: located.longitude
            ))
        }
    }

    /// The name to show for `place`, in words even when there is no answer:
    /// a row is never left blank.
    func name(of place: Place) -> String { Self.words(for: shown(place)) }

    /// The same for where a meetup is.
    func name(of place: MeetupPlace) -> String { Self.words(for: shown(place)) }

    private static func words(for answer: Answer) -> String {
        switch answer {
        case .found(let details) where !details.name.isEmpty: details.name
        case .found: String(localized: "Unnamed place")
        case .looking: String(localized: "Loading…")
        case .gone: String(localized: "No longer on Apple Maps")
        case .failed: String(localized: "Couldn't load this place")
        }
    }
}
