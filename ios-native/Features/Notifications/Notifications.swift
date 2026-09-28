import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Observation
import OSLog

// In-app notifications — the web client's /notifications page and the dot on
// its bell (`src/pages/Notifications.tsx`, `src/services/notifications.ts`).
// The server writes them (functions/src/notifications.ts); the client reads,
// marks read, and opens what they point at. No push: neither the web nor the
// server has any.

struct AppNotification: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case like, comment, reply
        case petFollow = "pet_follow"
        /// Legacy, written by older clients.
        case follow
        case meetupJoin = "meetup_join"
        case meetupCancelled = "meetup_cancelled"
        case petPrimaryTransferred = "pet_primary_transferred"
        case warning
        case unknown
    }

    let id: String
    let kind: Kind
    let fromUserID: String
    let fromUserName: String
    let fromUserAvatarURL: URL?
    /// Written by the server, in English, and shown as sent.
    let message: String
    let postID: String?
    let petID: String?
    let postImageURL: URL?
    let warningDetails: String?
    let read: Bool
    let createdAt: Date?

    /// Where tapping it goes: the web client's routing
    /// (`Notifications.tsx:115-138`). Nil stays on the list — which is where
    /// meetup notifications go, having no meetup id to open.
    var destination: Route? {
        switch kind {
        case .petFollow, .follow, .petPrimaryTransferred:
            if let petID { return .pet(petID: petID) }
            return fromUserID.isEmpty ? nil : .user(userID: fromUserID)
        case .warning:
            return nil
        default:
            return postID.map { .postDetail(postID: $0) }
        }
    }

    /// The line to show. The web prints the sender's name and then the
    /// message, and for a like or comment on a pet's post the server's message
    /// already begins with the name — "Alice Alice liked Max's post". Here the
    /// name is added only when the message does not start with it.
    var line: String {
        guard !fromUserName.isEmpty, !message.hasPrefix(fromUserName) else { return message }
        return "\(fromUserName) \(message)"
    }

    static func decode(id: String, _ data: [String: Any]) -> AppNotification {
        func text(_ key: String) -> String? {
            (data[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var imageURL = text("postImage").flatMap(URL.init(string:))
        // A video post's "image" is the video itself; show its poster.
        if let url = imageURL, ["mp4", "mov", "webm", "m4v"].contains(url.pathExtension.lowercased()) {
            imageURL = CloudinaryURL.videoPoster(url, size: .thumbnail)
        }
        return AppNotification(
            id: id,
            kind: Kind(rawValue: text("type") ?? "") ?? .unknown,
            fromUserID: text("fromUserId") ?? "",
            fromUserName: text("fromUserName") ?? "",
            fromUserAvatarURL: text("fromUserAvatar").flatMap(URL.init(string:)),
            message: text("message") ?? "",
            postID: text("postId"),
            petID: text("petId"),
            postImageURL: imageURL,
            warningDetails: text("warningDetails"),
            read: data["read"] as? Bool ?? false,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue()
        )
    }
}

protocol NotificationsReading: Sendable {
    /// Newest first, `limit` at a time; `after` is the last one already shown.
    func page(uid: String, after last: String?, limit: Int) async throws -> [AppNotification]
    func hasUnread(uid: String) async throws -> Bool
    func unreadCount(uid: String) async throws -> Int
    /// One notification, by a direct write the rules allow (only `read`).
    func markRead(id: String) async throws
    /// `markAllNotificationsAsReadCallable`.
    func markAllRead() async throws
}

actor FirestoreNotificationsSource: NotificationsReading {
    private let db: Firestore
    private var cursors: [String: DocumentSnapshot] = [:]

    init(db: Firestore = .firestore()) { self.db = db }

    private func base(_ uid: String) -> Query {
        db.collection("notifications").whereField("userId", isEqualTo: uid)
    }

    func page(uid: String, after last: String?, limit: Int) async throws -> [AppNotification] {
        var query = base(uid).order(by: "createdAt", descending: true).limit(to: limit)
        if let last, let cursor = cursors[last] { query = query.start(afterDocument: cursor) }
        let snapshot = try await query.getDocuments()
        if last == nil { cursors.removeAll() }
        for document in snapshot.documents { cursors[document.documentID] = document }
        return snapshot.documents.map { AppNotification.decode(id: $0.documentID, $0.data()) }
    }

    func hasUnread(uid: String) async throws -> Bool {
        try await !base(uid).whereField("read", isEqualTo: false).limit(to: 1).getDocuments().isEmpty
    }

    func unreadCount(uid: String) async throws -> Int {
        let aggregate = try await base(uid).whereField("read", isEqualTo: false).count.getAggregation(source: .server)
        return aggregate.count.intValue
    }

    func markRead(id: String) async throws {
        try await db.collection("notifications").document(id).updateData(["read": true])
    }

    func markAllRead() async throws {
        try await CallableClient.callIgnoringResult(Callables.markAllNotificationsAsRead)
    }
}

@MainActor
@Observable
final class NotificationsModel {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The web client's page size.
    static let pageSize = 50

    private(set) var items: [AppNotification] = []
    private(set) var state: State = .loading
    private(set) var hasMore = false
    private(set) var unreadCount = 0
    private(set) var isLoadingMore = false

    let uid: String
    private let source: any NotificationsReading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "notifications")

    init(uid: String, source: any NotificationsReading) {
        self.uid = uid
        self.source = source
    }

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            let first = try await source.page(uid: uid, after: nil, limit: Self.pageSize)
            items = first
            hasMore = first.count == Self.pageSize
            state = .loaded
            await refreshCount()
        } catch {
            log.error("notifications read failed: \(String(describing: error), privacy: .public)")
            // What is on screen stays; an empty screen says why it is empty.
            if items.isEmpty { state = .failed(String(localized: "Couldn't load notifications.")) }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let last = items.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await source.page(uid: uid, after: last, limit: Self.pageSize)
            let known = Set(items.map(\.id))
            items += next.filter { !known.contains($0.id) }
            hasMore = next.count == Self.pageSize
        } catch {
            log.error("notifications page failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks it read first, as the web does, and only if it was unread. A
    /// refused write puts it back; opening it goes ahead either way.
    func open(_ item: AppNotification) async {
        guard !item.read, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item.markedRead(true)
        unreadCount = max(0, unreadCount - 1)
        do {
            try await source.markRead(id: item.id)
        } catch {
            log.error("mark read failed: \(String(describing: error), privacy: .public)")
            if let again = items.firstIndex(where: { $0.id == item.id }) { items[again] = item }
            unreadCount += 1
        }
    }

    /// All read, at once on screen; the web does not report a failure either,
    /// so a refused call only means the next load shows the truth.
    func markAllRead() async {
        guard items.contains(where: { !$0.read }) || unreadCount > 0 else { return }
        items = items.map { $0.markedRead(true) }
        unreadCount = 0
        do {
            try await source.markAllRead()
        } catch {
            log.error("mark all read failed: \(String(describing: error), privacy: .public)")
            await load()
        }
    }

    private func refreshCount() async {
        if let count = try? await source.unreadCount(uid: uid) { unreadCount = count }
    }
}

extension AppNotification {
    func markedRead(_ value: Bool) -> AppNotification {
        AppNotification(
            id: id, kind: kind, fromUserID: fromUserID, fromUserName: fromUserName,
            fromUserAvatarURL: fromUserAvatarURL, message: message, postID: postID, petID: petID,
            postImageURL: postImageURL, warningDetails: warningDetails, read: value, createdAt: createdAt
        )
    }
}
