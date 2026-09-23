import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Observation
import OSLog

/// The words for a failed read or a refused action on the places and meetups
/// screens. No connection is said as such; a refusal the server explains is
/// shown in its words (the web shows them too); anything else gets `fallback`.
enum GatheringWords {
    static func message(for error: Error, fallback: String) -> String {
        let ns = error as NSError
        let offline = ns.domain == NSURLErrorDomain
            || (ns.domain == FirestoreErrorDomain && ns.code == FirestoreErrorCode.unavailable.rawValue)
            || (ns.domain == FunctionsErrorDomain && ns.code == FunctionsErrorCode.unavailable.rawValue)
        if offline { return String(localized: "No connection. Check your network and try again.") }
        if ns.domain == FunctionsErrorDomain,
           [FunctionsErrorCode.permissionDenied, .failedPrecondition, .notFound, .invalidArgument]
            .map(\.rawValue).contains(ns.code),
           !ns.localizedDescription.isEmpty {
            return ns.localizedDescription
        }
        return fallback
    }

    /// The web's list failure, word for word.
    static var listFailure: String {
        String(localized: "Something went wrong reaching PetNote. Check your connection and try again.")
    }
}

@MainActor
@Observable
final class PlacesModel {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The web's page size.
    static let pageSize = 20

    private(set) var items: [Place] = []
    private(set) var state: State = .loading
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    var category: PlaceCategory? {
        didSet { if category != oldValue { reload() } }
    }
    var sort: PlaceSort = .newest {
        didSet { if sort != oldValue { reload() } }
    }
    /// A name search replaces the list while it is not empty.
    private(set) var searchText = ""

    private let source: any PlacesReading
    private var loadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(source: any PlacesReading) {
        self.source = source
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    func load() async {
        if items.isEmpty { state = .loading }
        let category = category, sort = sort, search = searchText
        do {
            let found: [Place]
            if search.isEmpty {
                found = try await source.places(category: category, sort: sort, after: nil, limit: Self.pageSize)
                hasMore = found.count == Self.pageSize
            } else {
                found = try await source.search(prefix: search)
                hasMore = false
            }
            // A newer choice has been made while this one was reading.
            guard category == self.category, sort == self.sort, search == searchText else { return }
            items = found
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            log.error("places read failed: \(String(describing: error), privacy: .public)")
            if items.isEmpty { state = .failed(GatheringWords.message(for: error, fallback: GatheringWords.listFailure)) }
        }
    }

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchText else { return }
        searchText = trimmed
        items = []
        reload()
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, searchText.isEmpty, let last = items.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await source.places(category: category, sort: sort, after: last, limit: Self.pageSize)
            let known = Set(items.map(\.id))
            items += next.filter { !known.contains($0.id) }
            hasMore = next.count == Self.pageSize
        } catch {
            log.error("places page failed: \(String(describing: error), privacy: .public)")
            hasMore = false
        }
    }
}

@MainActor
@Observable
final class PlaceDetailModel {
    enum State: Equatable {
        case loading
        case loaded(Place)
        case missing
        case failed(String)
    }

    /// The web shows five check-ins until asked for more, and reads fifty
    /// reviews and meetups.
    static let checkinLimit = 20
    static let reviewLimit = 50

    private(set) var state: State = .loading
    private(set) var reviews: [PlaceReview] = []
    private(set) var checkins: [PlaceCheckin] = []
    private(set) var meetups: [Meetup] = []
    /// The parts under the place that did not load, named, so an empty
    /// section is never a failure in disguise.
    private(set) var failedSections: Set<String> = []

    let placeID: String
    private let places: any PlacesReading
    private let meetupSource: any MeetupsReading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(placeID: String, places: any PlacesReading, meetups: any MeetupsReading) {
        self.placeID = placeID
        self.places = places
        self.meetupSource = meetups
    }

    /// Every photo the web gathers for the place: its own, then the reviews',
    /// then the check-ins', each once.
    var photos: [URL] {
        guard case .loaded(let place) = state else { return [] }
        var seen: Set<URL> = []
        return (place.photos + reviews.flatMap(\.photos) + checkins.compactMap(\.photoURL))
            .filter { seen.insert($0).inserted }
    }

    func load() async {
        do {
            guard let place = try await places.place(id: placeID) else {
                state = .missing
                return
            }
            state = .loaded(place)
        } catch {
            log.error("place read failed: \(String(describing: error), privacy: .public)")
            if case .loaded = state { return }
            state = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to load location details.")))
            return
        }
        failedSections = []
        async let reviews = places.reviews(placeID: placeID, limit: Self.reviewLimit)
        async let checkins = places.checkins(placeID: placeID, limit: Self.checkinLimit)
        async let meetups = meetupSource.atPlace(placeID: placeID, limit: Self.reviewLimit)
        do { self.reviews = try await reviews } catch { failedSections.insert("reviews") }
        do { self.checkins = try await checkins } catch { failedSections.insert("checkins") }
        do { self.meetups = try await meetups } catch { failedSections.insert("meetups") }
        if !failedSections.isEmpty {
            log.error("place sections failed: \(self.failedSections.sorted().joined(separator: ","), privacy: .public)")
        }
    }
}
