import FirebaseFirestore
import FirebaseFunctions
import Foundation

// Meetups — the web client's Meetups page and meetup detail
// (`src/pages/Meetups.tsx`, `src/pages/MeetupDetail.tsx`,
// `src/services/meetups.ts`), and the server's rules for joining
// (`functions/src/meetups.ts`).
//
// Joining, cancelling and settling a finished meetup go through the server;
// leaving is the one direct write the rules allow — a participant deleting
// their own entry. Creating and editing a meetup need an address lookup the
// test project does not have (docs/places-meetups-plan.md), so they are not
// here.

enum MeetupStatus: String, Sendable {
    case upcoming, completed, cancelled

    var label: String {
        switch self {
        case .upcoming: String(localized: "Upcoming")
        case .completed: String(localized: "Completed")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

struct MeetupPlace: Equatable, Sendable {
    let name: String
    let address: String
    let city: String
    let state: String
    let latitude: Double
    let longitude: Double

    static func decode(_ data: [String: Any]?) -> MeetupPlace {
        let data = data ?? [:]
        return MeetupPlace(
            name: data["name"] as? String ?? "",
            address: data["address"] as? String ?? "",
            city: data["city"] as? String ?? "",
            state: data["state"] as? String ?? "",
            latitude: (data["lat"] as? NSNumber)?.doubleValue ?? 0,
            longitude: (data["lng"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    var cityLine: String {
        [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var directionsURL: URL? {
        guard latitude != 0 || longitude != 0 else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: name.isEmpty ? address : name),
        ]
        return components?.url
    }
}

struct MeetupRequirements: Equatable, Sendable {
    /// The server's `petType`: any, dog, cat, any_dog, any_cat, other.
    let petType: String
    let dogSize: String
    let maxPets: Int
    let mustHavePosts: Bool
    let mustHavePetProfile: Bool
    let minFollowers: Int
    let notes: String

    static func decode(_ data: [String: Any]?) -> MeetupRequirements {
        let data = data ?? [:]
        return MeetupRequirements(
            petType: data["petType"] as? String ?? "any",
            dogSize: data["dogSize"] as? String ?? "any",
            maxPets: (data["maxPets"] as? NSNumber)?.intValue ?? 0,
            mustHavePosts: data["mustHavePosts"] as? Bool ?? false,
            mustHavePetProfile: data["mustHavePetProfile"] as? Bool ?? false,
            minFollowers: (data["minFollowers"] as? NSNumber)?.intValue ?? 0,
            notes: data["additionalNotes"] as? String ?? ""
        )
    }

    /// What the server will check, in the words it refuses with. Shown before
    /// joining so a refusal is not the first anyone hears of a rule.
    var lines: [String] {
        var lines: [String] = []
        switch petType {
        case "dog", "any_dog": lines.append(String(localized: "Dogs only."))
        case "cat", "any_cat": lines.append(String(localized: "Cats only."))
        case "other": lines.append(String(localized: "Other pets only."))
        default: break
        }
        if maxPets > 0 { lines.append(String(localized: "Up to \(maxPets) pets.")) }
        if mustHavePosts { lines.append(String(localized: "Must have posted at least once.")) }
        if mustHavePetProfile { lines.append(String(localized: "Must have a pet profile.")) }
        if minFollowers > 0 { lines.append(String(localized: "Requires at least \(minFollowers) followed pets.")) }
        return lines
    }
}

struct Meetup: Identifiable, Equatable, Sendable {
    let id: String
    let organizerID: String
    let organizerName: String
    let organizerAvatarURL: URL?
    let title: String
    let description: String
    let coverImageURL: URL?
    let date: Date?
    let durationMinutes: Int
    /// For a participants-only meetup this is the blanked public copy; the
    /// real address is in `meetups/{id}/private/address`.
    let place: MeetupPlace
    let locationID: String?
    let isAddressPrivate: Bool
    let requirements: MeetupRequirements
    let status: MeetupStatus
    let participantCount: Int
    /// Set by the server when the meetup is completed: reviews that name the
    /// meetup are accepted from then on, and only from those who were there.
    let isRatingOpen: Bool

    var endsAt: Date? {
        date.map { $0.addingTimeInterval(TimeInterval(max(durationMinutes, 0) * 60)) }
    }

    /// Over, as far as the clock can tell, but not yet marked so: the server
    /// settles it when asked (`checkMeetupStatusCallable`), as the web does
    /// on opening one.
    func hasEndedUnsettled(now: Date) -> Bool {
        guard status == .upcoming, let endsAt else { return false }
        return now >= endsAt
    }

    var isFull: Bool {
        requirements.maxPets > 0 && participantCount >= requirements.maxPets
    }

    /// The web filters by the meetup's pet type, not the pets who joined.
    func isFor(_ filter: MeetupFilter) -> Bool {
        switch filter {
        case .dogs: ["dog", "any_dog"].contains(requirements.petType)
        case .cats: ["cat", "any_cat"].contains(requirements.petType)
        case .otherPets: requirements.petType == "other"
        default: true
        }
    }

    static func decode(id: String, _ data: [String: Any]) -> Meetup {
        func text(_ key: String) -> String { (data[key] as? String) ?? "" }
        return Meetup(
            id: id,
            organizerID: text("organizerId"),
            organizerName: text("organizerName").isEmpty ? String(localized: "PetNote User") : text("organizerName"),
            organizerAvatarURL: URL(string: text("organizerAvatar")),
            title: text("title"),
            description: text("description"),
            coverImageURL: URL(string: text("coverImage")),
            date: (data["date"] as? Timestamp)?.dateValue(),
            durationMinutes: (data["duration"] as? NSNumber)?.intValue ?? 60,
            place: MeetupPlace.decode(data["location"] as? [String: Any]),
            locationID: (data["locationId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            // Missing means private: the web's default, and the safe one.
            isAddressPrivate: (data["locationVisibility"] as? String) != "everyone",
            requirements: MeetupRequirements.decode(data["requirements"] as? [String: Any]),
            status: MeetupStatus(rawValue: text("status")) ?? .upcoming,
            participantCount: (data["participantCount"] as? NSNumber)?.intValue ?? 0,
            isRatingOpen: data["isRatingOpen"] as? Bool ?? false
        )
    }
}

struct MeetupParticipant: Identifiable, Equatable, Sendable {
    /// The participant's uid: their entry is `participants/{uid}`.
    let id: String
    let userName: String
    let userAvatarURL: URL?
    let petID: String
    let petName: String
    let petAvatarURL: URL?

    static func decode(id: String, _ data: [String: Any]) -> MeetupParticipant {
        MeetupParticipant(
            id: (data["userId"] as? String) ?? id,
            userName: (data["userName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "PetNote User"),
            userAvatarURL: (data["userAvatar"] as? String).flatMap(URL.init(string:)),
            petID: data["petId"] as? String ?? "",
            petName: data["petName"] as? String ?? "",
            petAvatarURL: (data["petAvatar"] as? String).flatMap(URL.init(string:))
        )
    }
}

/// The web's filters, less "Nearby": with no saved location the web shows
/// every upcoming meetup under that name, and this app has no location yet,
/// so the tab says what it is.
enum MeetupFilter: String, CaseIterable, Sendable {
    case upcoming, thisWeek, mine, dogs, cats, otherPets

    var label: String {
        switch self {
        case .upcoming: String(localized: "Upcoming")
        case .thisWeek: String(localized: "This Week")
        case .mine: String(localized: "My Meetups")
        case .dogs: String(localized: "Dogs")
        case .cats: String(localized: "Cats")
        case .otherPets: String(localized: "Other", comment: "Meetups for pets other than dogs and cats")
        }
    }

    /// The web's empty states.
    var emptyTitle: String {
        switch self {
        case .mine: String(localized: "No meetups of yours yet")
        case .thisWeek: String(localized: "No meetups this week")
        default: String(localized: "No upcoming meetups")
        }
    }
}

/// What joining came to. The server answers a rule it enforces with
/// `success: false` and its reason, rather than an error.
enum MeetupJoinOutcome: Equatable, Sendable {
    case joined
    case refused(String)
}

protocol MeetupsReading: Sendable {
    func upcoming(limit: Int) async throws -> [Meetup]
    func thisWeek(from now: Date, limit: Int) async throws -> [Meetup]
    /// Organised or joined, soonest first — the web's `getMyMeetups`.
    func mine(uid: String) async throws -> [Meetup]
    func atPlace(placeID: String, limit: Int) async throws -> [Meetup]
    func meetup(id: String) async throws -> Meetup?
    func participants(meetupID: String) async throws -> [MeetupParticipant]
    /// Nil when there is none or the rules refuse — only the organiser and
    /// participants may read it.
    func privateAddress(meetupID: String) async -> MeetupPlace?
    func join(meetupID: String, petID: String?) async throws -> MeetupJoinOutcome
    func leave(meetupID: String, uid: String) async throws
    func cancel(meetupID: String) async throws
    func settle(meetupID: String) async throws
}

actor FirestoreMeetupsSource: MeetupsReading {
    private let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    private var meetups: CollectionReference { db.collection("meetups") }

    func upcoming(limit: Int) async throws -> [Meetup] {
        let snapshot = try await meetups
            .whereField("status", isEqualTo: MeetupStatus.upcoming.rawValue)
            .order(by: "date")
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.map { Meetup.decode(id: $0.documentID, $0.data()) }
    }

    func thisWeek(from now: Date, limit: Int) async throws -> [Meetup] {
        let end = now.addingTimeInterval(7 * 24 * 60 * 60)
        let snapshot = try await meetups
            .whereField("status", isEqualTo: MeetupStatus.upcoming.rawValue)
            .whereField("date", isGreaterThanOrEqualTo: Timestamp(date: now))
            .whereField("date", isLessThanOrEqualTo: Timestamp(date: end))
            .order(by: "date")
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.map { Meetup.decode(id: $0.documentID, $0.data()) }
    }

    func mine(uid: String) async throws -> [Meetup] {
        let organised = try await meetups
            .whereField("organizerId", isEqualTo: uid)
            .order(by: "date")
            .getDocuments()
            .documents.map { Meetup.decode(id: $0.documentID, $0.data()) }
        let joined = try await db.collectionGroup("participants")
            .whereField("userId", isEqualTo: uid)
            .getDocuments()
            .documents.compactMap { document -> String? in
                (document.data()["meetupId"] as? String) ?? document.reference.parent.parent?.documentID
            }
        let known = Set(organised.map(\.id))
        let others = Array(Set(joined).subtracting(known))
        var more: [Meetup] = []
        // `in` takes a bounded list: ten at a time, as the web asks.
        for start in stride(from: 0, to: others.count, by: 10) {
            let chunk = Array(others[start..<min(start + 10, others.count)])
            let snapshot = try await meetups.whereField(FieldPath.documentID(), in: chunk).getDocuments()
            more += snapshot.documents.map { Meetup.decode(id: $0.documentID, $0.data()) }
        }
        return (organised + more).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func atPlace(placeID: String, limit: Int) async throws -> [Meetup] {
        let snapshot = try await meetups
            .whereField("locationId", isEqualTo: placeID)
            .order(by: "date", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.map { Meetup.decode(id: $0.documentID, $0.data()) }
    }

    func meetup(id: String) async throws -> Meetup? {
        let snapshot = try await meetups.document(id).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return Meetup.decode(id: snapshot.documentID, data)
    }

    func participants(meetupID: String) async throws -> [MeetupParticipant] {
        let snapshot = try await meetups.document(meetupID).collection("participants")
            .order(by: "joinedAt")
            .getDocuments()
        return snapshot.documents.map { MeetupParticipant.decode(id: $0.documentID, $0.data()) }
    }

    func privateAddress(meetupID: String) async -> MeetupPlace? {
        guard let snapshot = try? await meetups.document(meetupID).collection("private").document("address").getDocument(),
              snapshot.exists else { return nil }
        return MeetupPlace.decode(snapshot.data())
    }

    func join(meetupID: String, petID: String?) async throws -> MeetupJoinOutcome {
        var payload: [String: Any] = ["meetupId": meetupID]
        if let petID { payload["petId"] = petID }
        let answer = try await CallableClient.call(Callables.joinMeetup, payload)
        if answer["success"] as? Bool == true { return .joined }
        return .refused(answer["error"] as? String ?? String(localized: "Couldn't join this meetup."))
    }

    func leave(meetupID: String, uid: String) async throws {
        // Only the entry: the count comes down in `onParticipantDeleted`,
        // as on the web, so it cannot be taken off twice.
        try await meetups.document(meetupID).collection("participants").document(uid).delete()
    }

    func cancel(meetupID: String) async throws {
        try await CallableClient.callIgnoringResult(Callables.cancelMeetupCallable, ["meetupId": meetupID])
    }

    func settle(meetupID: String) async throws {
        try await CallableClient.callIgnoringResult(Callables.checkMeetupStatus, ["meetupId": meetupID])
    }
}
