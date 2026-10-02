import CoreLocation
import Foundation
import MapKit

/// A place as Apple Maps describes it right now: looked up to be shown, and
/// never written anywhere.
///
/// Apple's terms let the app keep a place's identifier but not what comes with
/// it: names, addresses and coordinates may be cached only "on a temporary and
/// limited basis" (Apple Developer Program License Agreement, Attachment 6,
/// 2.2 and 2.5). So a place or meetup stores the identifier, and this is what
/// the identifier turns into each time the app shows it.
struct PlaceDetails: Sendable, Equatable {
    let name: String
    /// One line, as Apple Maps writes it.
    let address: String
    let latitude: Double
    let longitude: Double
}

/// A place Apple Maps found for a search: its identifier, which is all a
/// place of ours keeps, and what Apple says about it now.
struct PlaceSearchHit: Sendable, Equatable {
    let applePlaceID: String
    let details: PlaceDetails
}

/// Where the app looks places up: Apple Maps in the app, a fixed table in UI
/// tests, a counting fake in unit tests.
protocol PlaceDirectory: Sendable {
    /// The place an Apple Maps identifier names, or nil when Apple no longer
    /// knows it. Throws only when Apple could not be asked.
    func details(forApplePlaceID id: String) async throws -> PlaceDetails?
    /// Where an address someone typed is, or nil when Apple cannot find it.
    func locate(address: String) async throws -> PlaceDetails?
    /// The places Apple Maps finds for `text`, most relevant first. Only
    /// those with an identifier: a place of ours can keep nothing else.
    func search(_ text: String) async throws -> [PlaceSearchHit]
    /// The street addresses Apple Maps finds for `text`, most relevant first:
    /// where a meetup can be, as a place of ours cannot. A meetup keeps only
    /// the words of the one chosen, as if they had been typed.
    func searchAddresses(_ text: String) async throws -> [PlaceDetails]
    /// Drops everything looked up so far, at sign-out: the terms' "temporary",
    /// and nothing of one person's browsing left for the next.
    func forget() async
}

extension PlaceDirectory {
    /// None, for a directory that has no addresses to find: the unit tests'
    /// own. The app's two find them.
    func searchAddresses(_ text: String) async throws -> [PlaceDetails] { [] }
}

/// Apple Maps, through MapKit, with the temporary cache the terms allow.
///
/// A place a screen shows twice is asked for once, and two rows asking for
/// the same place at the same moment share one request. Apple may limit how
/// many requests an app makes (Attachment 6, 2.7) without saying how many: a
/// list of twenty places asked at once was fine on 2026-09-30, measured on a
/// Mac, with the slowest answer in 0.26s; twenty-six on an iPhone on
/// 2026-10-01 took 0.26s all told (`AppleMapsDeviceProbeTests`).
///
/// "Apple no longer knows it" is remembered too, so a list does not ask again
/// for a place that is gone. A failure is not: the next look tries again.
actor MapKitPlaceDirectory: PlaceDirectory {
    /// How one identifier or one address is looked up. MapKit in the app; a
    /// counting stand-in in the tests, which is how the cache is tested
    /// without a network.
    struct Lookups: Sendable {
        var place: @Sendable (String) async throws -> PlaceDetails?
        var address: @Sendable (String) async throws -> PlaceDetails?
        var search: @Sendable (String) async throws -> [PlaceSearchHit]
        var searchAddresses: @Sendable (String) async throws -> [PlaceDetails] = { _ in [] }
    }

    private let lookups: Lookups
    private var places: [String: PlaceDetails?] = [:]
    private var addresses: [String: PlaceDetails?] = [:]
    private var inFlight: [Question: Task<PlaceDetails?, Error>] = [:]
    /// Bumped by `forget()`, so an answer that was on its way when the cache
    /// was emptied is handed to its caller and not kept.
    private var generation = 0

    init(lookups: Lookups = .mapKit) {
        self.lookups = lookups
    }

    func details(forApplePlaceID id: String) async throws -> PlaceDetails? {
        if let known = places[id] { return known }
        return try await lookUp(.place(id))
    }

    func locate(address: String) async throws -> PlaceDetails? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let known = addresses[text] { return known }
        return try await lookUp(.address(text))
    }

    /// Asked afresh each time, since what is most relevant changes; what it
    /// says about each place is kept as that place's answer, so the rows a
    /// search turns into, and the place opened from one, need not ask again.
    func search(_ text: String) async throws -> [PlaceSearchHit] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let started = generation
        let hits = try await lookups.search(text)
        guard generation == started else { return hits }
        for hit in hits { places.updateValue(hit.details, forKey: hit.applePlaceID) }
        return hits
    }

    /// Asked afresh each time, as places are. Each address is kept as the
    /// answer for its own words, so a meetup saved at one shows its map
    /// without asking again.
    func searchAddresses(_ text: String) async throws -> [PlaceDetails] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let started = generation
        var seen = Set<String>()
        let found = try await lookups.searchAddresses(text).filter { !$0.address.isEmpty && seen.insert($0.address).inserted }
        guard generation == started else { return found }
        for details in found { addresses.updateValue(details, forKey: details.address) }
        return found
    }

    func forget() {
        places = [:]
        addresses = [:]
        generation += 1
    }

    private enum Question: Hashable {
        case place(String)
        case address(String)
    }

    private func lookUp(_ question: Question) async throws -> PlaceDetails? {
        if let running = inFlight[question] { return try await running.value }
        let lookups = self.lookups
        let task = Task {
            switch question {
            case .place(let id): try await lookups.place(id)
            case .address(let text): try await lookups.address(text)
            }
        }
        inFlight[question] = task
        let started = generation
        defer { inFlight[question] = nil }
        let found = try await task.value
        guard generation == started else { return found }
        // Kept when the answer is nil too: "Apple no longer knows it" is an
        // answer, and a list should not ask again on every row.
        switch question {
        case .place(let id): places.updateValue(found, forKey: id)
        case .address(let text): addresses.updateValue(found, forKey: text)
        }
        return found
    }
}

extension MapKitPlaceDirectory.Lookups {
    /// MapKit itself. The iOS 26 calls where they exist; the ones they replace,
    /// which iOS 26 deprecates, on iOS 18.
    static let mapKit = Self(
        place: { id in
            guard let identifier = MKMapItem.Identifier(rawValue: id) else { return nil }
            do {
                let item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
                return PlaceDetails(item)
            } catch let error as MKError where error.code == .placemarkNotFound {
                return nil
            }
        },
        address: { text in
            if #available(iOS 26.0, *) {
                guard let request = MKGeocodingRequest(addressString: text) else { return nil }
                do {
                    return try await request.mapItems.first.map(PlaceDetails.init)
                } catch let error as MKError where error.code == .placemarkNotFound {
                    return nil
                }
            } else {
                do {
                    let placemarks = try await CLGeocoder().geocodeAddressString(text)
                    guard let placemark = placemarks.first, let location = placemark.location else {
                        return nil
                    }
                    return PlaceDetails(
                        name: placemark.name ?? text,
                        address: [placemark.name, placemark.locality, placemark.administrativeArea]
                            .compactMap { $0 }.joined(separator: ", "),
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                } catch let error as CLError where error.code == .geocodeFoundNoResult {
                    return nil
                }
            }
        },
        search: { text in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            // Places, not street addresses: an address has no identifier to
            // keep.
            request.resultTypes = .pointOfInterest
            do {
                let response = try await MKLocalSearch(request: request).start()
                return response.mapItems.compactMap { item in
                    item.identifier.map { PlaceSearchHit(applePlaceID: $0.rawValue, details: PlaceDetails(item)) }
                }
            } catch let error as MKError where error.code == .placemarkNotFound {
                return []
            }
        },
        searchAddresses: { text in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            // Street addresses, which the places search leaves out: a home,
            // say, which can hold a meetup and never a place.
            request.resultTypes = .address
            do {
                return try await MKLocalSearch(request: request).start().mapItems.map(PlaceDetails.init)
            } catch let error as MKError where error.code == .placemarkNotFound {
                return []
            }
        }
    )
}

extension PlaceDetails {
    init(_ item: MKMapItem) {
        if #available(iOS 26.0, *) {
            let coordinate = item.location.coordinate
            self.init(
                name: item.name ?? "",
                address: item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                    ?? item.address?.shortAddress ?? "",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } else {
            let placemark = item.placemark
            self.init(
                name: item.name ?? "",
                address: placemark.title ?? "",
                latitude: placemark.coordinate.latitude,
                longitude: placemark.coordinate.longitude
            )
        }
    }
}

extension PlaceDetails {
    /// Apple Maps at this place. No position, no link.
    var directionsURL: URL? {
        guard latitude != 0 || longitude != 0 else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components?.url
    }
}

/// The directory the app uses: one for the whole process, as
/// `ImageLoader.shared` is, so every screen shares its cache.
/// `SessionStore` empties it at sign-out.
enum PlaceDirectories {
    static let shared: any PlaceDirectory = {
        #if PETNOTE_FAULT_INJECTION
        // The emulator's places and meetups are seeded with made-up
        // identifiers Apple has never heard of, so this build answers from a
        // table unless told to ask Apple (`-petnote-maps-live`).
        if !ProcessInfo.processInfo.arguments.contains("-petnote-maps-live") {
            return StandInPlaceDirectory()
        }
        #endif
        return MapKitPlaceDirectory()
    }()
}

#if PETNOTE_FAULT_INJECTION
/// Apple Maps as a fixed table, in the emulator build only.
///
/// The seed (`functions/scripts/seed-ios-native.mjs`) writes places and
/// meetups with these identifiers, so UI tests see the same answers every run
/// and never reach Apple. An identifier not in the table is a place Apple no
/// longer knows. The names start TEST CONTENT, like everything else seeded.
struct StandInPlaceDirectory: PlaceDirectory {
    static let places: [String: PlaceDetails] = [
        "TESTAPPLEDOGRUN01": PlaceDetails(
            name: "TEST CONTENT Fenway Dog Run", address: "1 Park Dr, Boston, MA 02215",
            latitude: 42.3434, longitude: -71.0950
        ),
        "TESTAPPLEPETSHOP1": PlaceDetails(
            name: "TEST CONTENT Corner Pet Shop", address: "20 Elm St, Somerville, MA 02144",
            latitude: 42.3967, longitude: -71.1220
        ),
    ]

    func details(forApplePlaceID id: String) async throws -> PlaceDetails? {
        Self.places[id]
    }

    /// Every typed address is found, a little north of Boston, under its own
    /// words: enough for a map and a directions link in a test.
    func locate(address: String) async throws -> PlaceDetails? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return PlaceDetails(name: text, address: text, latitude: 42.3876, longitude: -71.0995)
    }

    /// The table's places with every word of `text` somewhere in their
    /// names or addresses, whatever the case, in the table's order: a search
    /// for a place by what it is called, or by a suggestion's name and
    /// address, as `StandInPlaceSuggester` makes them.
    func search(_ text: String) async throws -> [PlaceSearchHit] {
        let words = text.lowercased().split { $0.isWhitespace || $0 == "," }
        guard !words.isEmpty else { return [] }
        return Self.places
            .filter { _, details in
                let said = "\(details.name) \(details.address)".lowercased()
                return words.allSatisfy { said.contains($0) }
            }
            .sorted { $0.key < $1.key }
            .map { PlaceSearchHit(applePlaceID: $0.key, details: $0.value) }
    }

    /// Words with a number in them are a street address, where `locate`
    /// finds it; a town is added when they name none. Words without a number,
    /// the way a place is searched for, find no address.
    func searchAddresses(_ text: String) async throws -> [PlaceDetails] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isNumber) else { return [] }
        let street = String(text.split(separator: ",").first ?? Substring(text))
        let address = text.contains(",") ? text : "\(text), Medford, MA 02155"
        return [PlaceDetails(name: street, address: address, latitude: 42.3876, longitude: -71.0995)]
    }

    func forget() async {}
}
#endif
