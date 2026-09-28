import FirebaseFirestore
import Foundation

// Places — the web client's Places page and location detail
// (`src/pages/Places.tsx`, `src/pages/LocationDetail.tsx`,
// `src/services/locations.ts`, `src/services/checkins.ts`).
//
// The rules let no client write a place, a review or a check-in directly;
// each goes through the server. Reviews without photos are here; adding a
// place needs an address lookup and check-ins need a photo upload, which the
// test project does not have yet (docs/places-meetups-plan.md).

enum PlaceCategory: String, CaseIterable, Sendable {
    case dogPark = "dog_park"
    case hikingTrail = "hiking_trail"
    case beach
    case communityPark = "community_park"
    case cafe
    case greenSpace = "green_space"
    case petStore = "pet_store"
    case vet
    case other

    /// The badge on a place — the web's `categoryLabels`.
    var label: String {
        switch self {
        case .dogPark: String(localized: "Dog Park")
        case .hikingTrail: String(localized: "Hiking Trail")
        case .beach: String(localized: "Beach")
        case .communityPark: String(localized: "Community Park")
        case .cafe: String(localized: "Café")
        case .greenSpace: String(localized: "Green Space")
        case .petStore: String(localized: "Pet Store")
        case .vet: String(localized: "Vet")
        case .other: String(localized: "Other", comment: "Place category")
        }
    }

    /// The filter chip — the web's `categoryFilters`. "Other" has none there:
    /// choosing it showed every place, so it is not offered.
    var filterLabel: String {
        switch self {
        case .dogPark: String(localized: "Dog Parks")
        case .hikingTrail: String(localized: "Hiking Trails")
        case .beach: String(localized: "Beaches")
        case .communityPark: String(localized: "Parks")
        case .cafe: String(localized: "Cafés")
        case .greenSpace: String(localized: "Green Spaces")
        case .petStore: String(localized: "Pet Stores")
        case .vet: String(localized: "Vets")
        case .other: String(localized: "Other", comment: "Place category")
        }
    }

    var emoji: String {
        switch self {
        case .dogPark: "🐕"
        case .hikingTrail: "🥾"
        case .beach: "🏖️"
        case .communityPark: "🌳"
        case .cafe: "☕"
        case .greenSpace: "🌿"
        case .petStore: "🏪"
        case .vet: "🏥"
        case .other: "📍"
        }
    }

    static var filters: [PlaceCategory] { allCases.filter { $0 != .other } }
}

/// The web's sorts less "Nearby (recent)", which without a saved location is
/// "Newest" under another name — and this app has no location yet.
enum PlaceSort: String, CaseIterable, Sendable {
    case newest
    case topRated
    case mostReviewed

    var label: String {
        switch self {
        case .newest: String(localized: "Newest")
        case .topRated: String(localized: "Top Rated")
        case .mostReviewed: String(localized: "Most Reviewed")
        }
    }
}

struct Place: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let city: String
    let state: String
    let latitude: Double
    let longitude: Double
    let category: PlaceCategory
    let description: String
    let features: [String]
    let photos: [URL]
    let averageRating: Double
    let totalRatings: Int
    let totalCheckins: Int
    let verifiedByCheckins: Bool

    /// "4.5 (2 reviews)", or nil with no reviews — the web's line.
    var ratingLine: String? {
        guard totalRatings > 0 else { return nil }
        let average = averageRating.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(average) (\(totalRatings) reviews)")
    }

    /// Apple Maps, where the web opened Google Maps. No coordinates, no link.
    var directionsURL: URL? {
        guard latitude != 0 || longitude != 0 else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components?.url
    }

    static func decode(id: String, _ data: [String: Any]) -> Place {
        func text(_ key: String) -> String { (data[key] as? String) ?? "" }
        func number(_ key: String) -> Double { (data[key] as? NSNumber)?.doubleValue ?? 0 }
        func strings(_ key: String) -> [String] { (data[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        return Place(
            id: id,
            name: text("name"),
            address: text("address"),
            city: text("city"),
            state: text("state"),
            latitude: number("lat"),
            longitude: number("lng"),
            category: PlaceCategory(rawValue: text("category")) ?? .other,
            description: text("description"),
            features: strings("features"),
            photos: strings("photos").compactMap(URL.init(string:)),
            averageRating: number("averageRating"),
            totalRatings: Int(number("totalRatings")),
            totalCheckins: Int(number("totalCheckins")),
            verifiedByCheckins: data["verifiedByCheckins"] as? Bool ?? false
        )
    }

    /// The web's feature names, as words. An unknown one is shown as stored
    /// rather than dropped.
    static func featureLabel(_ key: String) -> String {
        switch key {
        case "off_leash": String(localized: "Off-leash")
        case "fenced": String(localized: "Fenced")
        case "water_access": String(localized: "Water access")
        case "waste_bags": String(localized: "Waste bags")
        case "parking": String(localized: "Parking")
        case "restrooms": String(localized: "Restrooms")
        case "seating": String(localized: "Seating")
        case "shade": String(localized: "Shade")
        case "lighting": String(localized: "Lighting")
        case "beach_access": String(localized: "Beach access")
        case "trails": String(localized: "Trails")
        case "food_nearby": String(localized: "Food nearby")
        default: key.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct PlaceReview: Identifiable, Equatable, Sendable {
    let id: String
    let userID: String
    let userName: String
    let userAvatarURL: URL?
    let rating: Int
    let comment: String
    let photos: [URL]
    let tags: [String]
    let createdAt: Date?

    static func decode(id: String, _ data: [String: Any]) -> PlaceReview {
        PlaceReview(
            id: id,
            userID: data["userId"] as? String ?? "",
            userName: (data["userName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "PetNote User"),
            userAvatarURL: (data["userAvatar"] as? String).flatMap(URL.init(string:)),
            rating: (data["rating"] as? NSNumber)?.intValue ?? 0,
            comment: data["comment"] as? String ?? "",
            photos: ((data["photos"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(URL.init(string:)) },
            tags: ((data["tags"] as? [Any]) ?? []).compactMap { $0 as? String },
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue()
        )
    }
}

struct PlaceCheckin: Identifiable, Equatable, Sendable {
    let id: String
    let userName: String
    let userAvatarURL: URL?
    let photoURL: URL?
    let caption: String
    let petName: String?
    let createdAt: Date?

    static func decode(id: String, _ data: [String: Any]) -> PlaceCheckin {
        PlaceCheckin(
            id: id,
            userName: (data["userName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "PetNote User"),
            userAvatarURL: (data["userAvatar"] as? String).flatMap(URL.init(string:)),
            photoURL: (data["photoUrl"] as? String).flatMap(URL.init(string:)),
            caption: data["caption"] as? String ?? "",
            petName: (data["petName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue()
        )
    }
}

/// A review as the person writes it — the web's rating sheet
/// (`LocationRatingModal.tsx`) without photos, which need the test
/// Cloudinary account.
struct PlaceReviewDraft: Equatable, Sendable {
    /// The web's tag choices, word for word; stored as written.
    static let tagOptions = [
        "🌳 Spacious", "🐕 Off-leash area", "💧 Water access", "🅿️ Easy parking",
        "🚽 Restrooms nearby", "🪑 Seating available", "🌙 Well-lit", "🐕‍🦺 Dog-friendly",
        "🐱 Cat-friendly", "☕ Café nearby", "🏖️ Beach access", "🏃 Trails available",
    ]
    /// The web's limit, in the web's units: UTF-16, which is what
    /// JavaScript's `length` and the server's check count. An emoji is two.
    static let maxComment = 300

    /// A tag as shown. The stored words stay the web's — other people's
    /// reviews carry them — and one this list does not know is shown as is.
    static func tagLabel(_ tag: String) -> String {
        switch tag {
        case "🌳 Spacious": String(localized: "🌳 Spacious")
        case "🐕 Off-leash area": String(localized: "🐕 Off-leash area")
        case "💧 Water access": String(localized: "💧 Water access")
        case "🅿️ Easy parking": String(localized: "🅿️ Easy parking")
        case "🚽 Restrooms nearby": String(localized: "🚽 Restrooms nearby")
        case "🪑 Seating available": String(localized: "🪑 Seating available")
        case "🌙 Well-lit": String(localized: "🌙 Well-lit")
        case "🐕‍🦺 Dog-friendly": String(localized: "🐕‍🦺 Dog-friendly")
        case "🐱 Cat-friendly": String(localized: "🐱 Cat-friendly")
        case "☕ Café nearby": String(localized: "☕ Café nearby")
        case "🏖️ Beach access": String(localized: "🏖️ Beach access")
        case "🏃 Trails available": String(localized: "🏃 Trails available")
        default: tag
        }
    }

    let placeID: String
    /// Set when the review is of a meetup that took place there.
    let meetupID: String?
    var rating = 0
    /// 0 means "not given"; the server then takes the overall rating.
    var space = 0
    var safety = 0
    var cleanliness = 0
    var tags: [String] = []
    var comment = ""

    var commentLength: Int { comment.utf16.count }

    var canSubmit: Bool { (1...5).contains(rating) && commentLength <= Self.maxComment }

    /// What `submitReviewCallable` takes. Subscores go only when given: the
    /// server refuses a 0 and fills a missing one in with the rating.
    var payload: [String: Any] {
        var payload: [String: Any] = [
            "locationId": placeID,
            "rating": rating,
            "comment": comment.trimmingCharacters(in: .whitespacesAndNewlines),
            "tags": tags,
            "photos": [String](),
        ]
        var friendly: [String: Any] = [:]
        if space > 0 { friendly["space"] = space }
        if safety > 0 { friendly["safety"] = safety }
        if cleanliness > 0 { friendly["cleanliness"] = cleanliness }
        if !friendly.isEmpty { payload["petFriendly"] = friendly }
        if let meetupID { payload["meetupId"] = meetupID }
        return payload
    }

    /// The server's own document id for this review, so "already reviewed"
    /// is one read rather than a query.
    static func reviewID(uid: String, meetupID: String?) -> String {
        meetupID.map { "\(uid)_\($0)" } ?? uid
    }
}

protocol PlaceReviewing: Sendable {
    func submitReview(_ draft: PlaceReviewDraft) async throws
    /// Whether this person has already reviewed the place (or the meetup).
    func hasReviewed(placeID: String, uid: String, meetupID: String?) async throws -> Bool
}

protocol PlacesReading: Sendable {
    /// `limit` at a time; `after` is the last place already shown.
    func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place]
    /// Names starting with `prefix` — the web's search, which is a prefix
    /// match and case-sensitive.
    func search(prefix: String) async throws -> [Place]
    func place(id: String) async throws -> Place?
    func reviews(placeID: String, limit: Int) async throws -> [PlaceReview]
    func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin]
}

actor FirestorePlacesSource: PlacesReading, PlaceReviewing {
    private let db: Firestore
    private var cursors: [String: DocumentSnapshot] = [:]

    init(db: Firestore = .firestore()) { self.db = db }

    func places(category: PlaceCategory?, sort: PlaceSort, after last: String?, limit: Int) async throws -> [Place] {
        var query: Query = db.collection("locations")
        if let category, category != .other {
            query = query.whereField("category", isEqualTo: category.rawValue)
        }
        switch sort {
        case .topRated:
            query = query.order(by: "averageRating", descending: true).order(by: "totalRatings", descending: true)
        case .mostReviewed:
            query = query.order(by: "totalRatings", descending: true)
        case .newest:
            query = query.order(by: "createdAt", descending: true)
        }
        query = query.limit(to: limit)
        if let last, let cursor = cursors[last] { query = query.start(afterDocument: cursor) }
        let snapshot = try await query.getDocuments()
        if last == nil { cursors.removeAll() }
        for document in snapshot.documents { cursors[document.documentID] = document }
        return snapshot.documents.map { Place.decode(id: $0.documentID, $0.data()) }
    }

    func search(prefix: String) async throws -> [Place] {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let snapshot = try await db.collection("locations")
            .whereField("name", isGreaterThanOrEqualTo: needle)
            .whereField("name", isLessThanOrEqualTo: needle + "\u{f8ff}")
            .order(by: "name")
            .limit(to: 20)
            .getDocuments()
        return snapshot.documents.map { Place.decode(id: $0.documentID, $0.data()) }
    }

    func place(id: String) async throws -> Place? {
        let snapshot = try await db.collection("locations").document(id).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return Place.decode(id: snapshot.documentID, data)
    }

    func reviews(placeID: String, limit: Int) async throws -> [PlaceReview] {
        let snapshot = try await db.collection("locations").document(placeID).collection("reviews")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.map { PlaceReview.decode(id: $0.documentID, $0.data()) }
    }

    func submitReview(_ draft: PlaceReviewDraft) async throws {
        try await CallableClient.callIgnoringResult(Callables.submitReview, draft.payload)
    }

    func hasReviewed(placeID: String, uid: String, meetupID: String?) async throws -> Bool {
        try await db.collection("locations").document(placeID).collection("reviews")
            .document(PlaceReviewDraft.reviewID(uid: uid, meetupID: meetupID))
            .getDocument().exists
    }

    func checkins(placeID: String, limit: Int) async throws -> [PlaceCheckin] {
        let snapshot = try await db.collection("locations").document(placeID).collection("checkins")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.map { PlaceCheckin.decode(id: $0.documentID, $0.data()) }
    }
}
