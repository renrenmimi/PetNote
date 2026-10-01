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
           [FunctionsErrorCode.permissionDenied, .failedPrecondition, .notFound, .invalidArgument, .alreadyExists]
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

    /// Names for the places from Apple Maps on the list, asked for as each
    /// page arrives.
    let lookups: PlaceLookups
    private let source: any PlacesReading
    private var loadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(source: any PlacesReading, lookups: PlaceLookups = PlaceLookups()) {
        self.source = source
        self.lookups = lookups
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
                found = try await searchResults(for: search)
                hasMore = false
            }
            // A newer choice has been made while this one was reading.
            guard category == self.category, sort == self.sort, search == searchText else { return }
            items = found
            state = .loaded
            await lookups.lookUp(found)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("places read failed: \(String(describing: error), privacy: .public)")
            if items.isEmpty { state = .failed(GatheringWords.message(for: error, fallback: GatheringWords.listFailure)) }
        }
    }

    /// The places from Apple Maps that Apple finds for `text` and that are
    /// ours, in Apple's order, then the places from the web whose names
    /// start with it, the web's search. An Apple Maps place stores no name
    /// for the web's search to find. When Apple cannot be asked, the web's
    /// matches are still shown.
    private func searchResults(for text: String) async throws -> [Place] {
        async let named = source.search(prefix: text)
        let ids: [String]
        do {
            ids = try await lookups.search(text)
        } catch {
            log.error("Apple Maps search failed: \(String(describing: error), privacy: .public)")
            ids = []
        }
        let ours = ids.isEmpty ? [] : try await source.places(applePlaceIDs: ids)
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let fromApple = ours.sorted { (rank[$0.applePlaceID ?? ""] ?? .max) < (rank[$1.applePlaceID ?? ""] ?? .max) }
        var seen: Set<String> = []
        return (fromApple + (try await named)).filter { seen.insert($0.id).inserted }
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
        // Apple is asked once the page is in, so the page after it need not
        // wait for Apple to answer about this one.
        guard let next = await nextPage(after: last) else { return }
        await lookups.lookUp(next)
    }

    /// The page after `last`, added to the list; nil when it could not be read.
    private func nextPage(after last: String) async -> [Place]? {
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await source.places(category: category, sort: sort, after: last, limit: Self.pageSize)
            let known = Set(items.map(\.id))
            items += next.filter { !known.contains($0.id) }
            hasMore = next.count == Self.pageSize
            return next
        } catch {
            log.error("places page failed: \(String(describing: error), privacy: .public)")
            hasMore = false
            return nil
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

    /// Whether the viewer has reviewed this place. Nil until known — the
    /// button to write one waits rather than guessing.
    private(set) var hasReviewed: Bool?
    /// Whether the viewer has checked in here today, the server's day. Nil
    /// until known, as for a review.
    private(set) var hasCheckedInToday: Bool?

    let placeID: String
    let viewerID: String
    let reviewer: any PlaceReviewing
    private let checker: any PlaceCheckingIn
    private let now: @Sendable () -> Date
    /// Where the place is, for one from Apple Maps.
    let lookups: PlaceLookups
    private let places: any PlacesReading
    private let meetupSource: any MeetupsReading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        placeID: String, viewerID: String, places: any PlacesReading,
        reviewer: any PlaceReviewing, checker: any PlaceCheckingIn, meetups: any MeetupsReading,
        lookups: PlaceLookups = PlaceLookups(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.placeID = placeID
        self.viewerID = viewerID
        self.places = places
        self.reviewer = reviewer
        self.checker = checker
        self.meetupSource = meetups
        self.lookups = lookups
        self.now = now
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
        let place: Place
        do {
            guard let found = try await places.place(id: placeID) else {
                state = .missing
                return
            }
            place = found
            state = .loaded(found)
        } catch {
            log.error("place read failed: \(String(describing: error), privacy: .public)")
            if case .loaded = state { return }
            state = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to load location details.")))
            return
        }
        // Apple is asked about the place while its reviews, check-ins and
        // meetups are read: none of them waits for Apple's answer.
        let lookups = lookups
        async let lookedUp: Void = lookups.lookUp([place])
        failedSections = []
        async let reviews = places.reviews(placeID: placeID, limit: Self.reviewLimit)
        async let checkins = places.checkins(placeID: placeID, limit: Self.checkinLimit)
        async let meetups = meetupSource.atPlace(placeID: placeID, limit: Self.reviewLimit)
        do { self.reviews = try await reviews } catch { failedSections.insert("reviews") }
        do { self.checkins = try await checkins } catch { failedSections.insert("checkins") }
        do { self.meetups = try await meetups } catch { failedSections.insert("meetups") }
        // And about where those meetups are, while the review button waits
        // only for the server.
        let meetupPlaces = self.meetups.map(\.place)
        async let meetupsLookedUp: Void = lookups.lookUp(meetupPlaces: meetupPlaces)
        async let reviewed = try? reviewer.hasReviewed(placeID: placeID, uid: viewerID, meetupID: nil)
        async let checkedIn = try? checker.hasCheckedIn(placeID: placeID, uid: viewerID, on: now())
        hasReviewed = await reviewed
        hasCheckedInToday = await checkedIn
        if !failedSections.isEmpty {
            log.error("place sections failed: \(self.failedSections.sorted().joined(separator: ","), privacy: .public)")
        }
        await lookedUp
        await meetupsLookedUp
    }
}
