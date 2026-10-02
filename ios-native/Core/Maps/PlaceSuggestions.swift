import Foundation
import MapKit

/// What Apple Maps suggests while someone types, before Return: a place, or
/// for a meetup a street address. Only its words, to be shown. Choosing one
/// searches for it, and what that finds is what is chosen.
struct PlaceSuggestion: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case place
        case address
    }

    let kind: Kind
    /// Its name, or for an address its street.
    let title: String
    /// Where it is, as Apple writes it under the title.
    let subtitle: String

    var id: String { "\(kind)\n\(title)\n\(subtitle)" }

    /// The words it is searched for by once chosen.
    var searchText: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
}

/// Where suggestions come from: Apple Maps in the app, a table in UI tests,
/// a fake in unit tests.
@MainActor
protocol PlaceSuggesting: AnyObject {
    /// Apple's suggestions for what has been typed so far: places, then
    /// addresses when asked for them. None for nothing typed, and none when
    /// Apple could not be asked: they are a help, and Return still searches.
    func suggestions(for fragment: String, addresses: Bool) async -> [PlaceSuggestion]
}

enum PlaceSuggesters {
    /// A new one for each search field: the stand-in table in the emulator
    /// build, as `PlaceDirectories.shared` is, and Apple Maps otherwise.
    @MainActor
    static func make() -> any PlaceSuggesting {
        #if PETNOTE_FAULT_INJECTION
        if !ProcessInfo.processInfo.arguments.contains("-petnote-maps-live") {
            return StandInPlaceSuggester()
        }
        #endif
        return MapKitPlaceSuggester()
    }
}

/// Apple's suggestions as someone types, from `MKLocalSearchCompleter`, which
/// is made for it: a search on every key could be throttled (Attachment 6,
/// 2.7). One completer for places and one for addresses, so each
/// suggestion's kind is known without asking Apple again.
@MainActor
final class MapKitPlaceSuggester: NSObject, PlaceSuggesting {
    private let places = MKLocalSearchCompleter()
    private let addresses = MKLocalSearchCompleter()
    /// Who is waiting on each completer's next answer. A newer question to
    /// the same completer answers the older one with none.
    private var waiting: [ObjectIdentifier: CheckedContinuation<[PlaceSuggestion], Never>] = [:]

    override init() {
        super.init()
        places.resultTypes = .pointOfInterest
        addresses.resultTypes = .address
        places.delegate = self
        addresses.delegate = self
    }

    func suggestions(for fragment: String, addresses findsAddresses: Bool) async -> [PlaceSuggestion] {
        let text = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        // Both at once: each completer answers on its own.
        async let found = ask(.place, text)
        async let streets = findsAddresses ? ask(.address, text) : []
        return await found + streets
    }

    private func ask(_ kind: PlaceSuggestion.Kind, _ text: String) async -> [PlaceSuggestion] {
        let completer = kind == .address ? addresses : places
        let key = ObjectIdentifier(completer)
        waiting.removeValue(forKey: key)?.resume(returning: [])
        // The same words again: the completer does not answer twice.
        if completer.queryFragment == text { return suggestions(from: completer) }
        return await withCheckedContinuation { continuation in
            waiting[key] = continuation
            completer.queryFragment = text
        }
    }

    private func suggestions(from completer: MKLocalSearchCompleter) -> [PlaceSuggestion] {
        let kind: PlaceSuggestion.Kind = completer === addresses ? .address : .place
        return completer.results.map { PlaceSuggestion(kind: kind, title: $0.title, subtitle: $0.subtitle) }
    }

    /// The completer's answer, as its words: the completer itself stays where
    /// MapKit called with it.
    fileprivate func answer(_ key: ObjectIdentifier, with found: [(title: String, subtitle: String)]) {
        let kind: PlaceSuggestion.Kind = key == ObjectIdentifier(addresses) ? .address : .place
        let suggestions = found.map { PlaceSuggestion(kind: kind, title: $0.title, subtitle: $0.subtitle) }
        waiting.removeValue(forKey: key)?.resume(returning: suggestions)
    }
}

extension MapKitPlaceSuggester: MKLocalSearchCompleterDelegate {
    // MapKit answers on the main thread, where the completers were made.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let key = ObjectIdentifier(completer)
        let found = completer.results.map { (title: $0.title, subtitle: $0.subtitle) }
        MainActor.assumeIsolated { answer(key, with: found) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        let key = ObjectIdentifier(completer)
        MainActor.assumeIsolated { answer(key, with: []) }
    }
}

#if PETNOTE_FAULT_INJECTION
/// Suggestions from the stand-in's table, in the emulator build only: its
/// places with every word typed in their name or address, and an address for
/// words with a street number, as `StandInPlaceDirectory` finds them once
/// chosen.
@MainActor
final class StandInPlaceSuggester: PlaceSuggesting {
    func suggestions(for fragment: String, addresses: Bool) async -> [PlaceSuggestion] {
        let text = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.lowercased().split { $0.isWhitespace || $0 == "," }
        guard !words.isEmpty else { return [] }
        let found = StandInPlaceDirectory.places
            .filter { _, details in
                let said = "\(details.name) \(details.address)".lowercased()
                return words.allSatisfy { said.contains($0) }
            }
            .sorted { $0.key < $1.key }
            .map { PlaceSuggestion(kind: .place, title: $0.value.name, subtitle: $0.value.address) }
        guard addresses, text.contains(where: \.isNumber) else { return found }
        let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let street = PlaceSuggestion(
            kind: .address, title: parts[0], subtitle: parts.count > 1 ? parts[1] : "Medford, MA 02155"
        )
        return found + [street]
    }
}
#endif
