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

/// Where the app looks places up: Apple Maps in the app, a fixed table in UI
/// tests, a counting fake in unit tests.
protocol PlaceDirectory: Sendable {
    /// The place an Apple Maps identifier names, or nil when Apple no longer
    /// knows it. Throws only when Apple could not be asked.
    func details(forApplePlaceID id: String) async throws -> PlaceDetails?
    /// Where an address someone typed is, or nil when Apple cannot find it.
    func locate(address: String) async throws -> PlaceDetails?
    /// Drops everything looked up so far, at sign-out: the terms' "temporary",
    /// and nothing of one person's browsing left for the next.
    func forget() async
}

/// Apple Maps, through MapKit, with the temporary cache the terms allow.
///
/// A place a screen shows twice is asked for once, and two rows asking for
/// the same place at the same moment share one request. Apple may limit how
/// many requests an app makes (Attachment 6, 2.7) without saying how many: a
/// list of twenty places asked at once was fine on 2026-09-30, measured on a
/// Mac, with the slowest answer in 0.26s.
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
