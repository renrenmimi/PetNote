import FirebaseFirestore
import Foundation
import Testing

@testable import PetNote

/// In-app notifications: what a stored document becomes, where tapping one
/// goes (the web client's routing), and marking read with a way back.
@MainActor
struct NotificationsTests {
    final class FakeSource: NotificationsReading, @unchecked Sendable {
        var pages: [[AppNotification]] = [[]]
        var readError: Error?
        var markError: Error?
        var markAllError: Error?
        var unread = 0
        private(set) var marked: [String] = []
        private(set) var markedAll = 0
        private(set) var pageCalls: [String?] = []

        func page(uid: String, after last: String?, limit: Int) async throws -> [AppNotification] {
            pageCalls.append(last)
            if let readError { throw readError }
            let index = last == nil ? 0 : min(pageCalls.filter { $0 != nil }.count, pages.count - 1)
            return pages[index]
        }
        func hasUnread(uid: String) async throws -> Bool { unread > 0 }
        func unreadCount(uid: String) async throws -> Int { unread }
        func markRead(id: String) async throws {
            marked.append(id)
            if let markError { throw markError }
        }
        func markAllRead() async throws {
            markedAll += 1
            if let markAllError { throw markAllError }
        }
    }

    private static func item(_ id: String, kind: AppNotification.Kind = .like, read: Bool = false,
                             postID: String? = "p1", petID: String? = nil,
                             from: String = "Alice", message: String = "liked your post") -> AppNotification {
        AppNotification(
            id: id, kind: kind, fromUserID: "u-alice", fromUserName: from, fromUserAvatarURL: nil,
            message: message, postID: postID, petID: petID, postImageURL: nil, warningDetails: nil,
            read: read, createdAt: nil
        )
    }

    // MARK: - Decoding

    @Test func aStoredDocumentBecomesANotification() {
        let decoded = AppNotification.decode(id: "n1", [
            "type": "pet_follow", "fromUserId": "u-bob", "fromUserName": "Bob",
            "message": "started following Max", "petId": "pet-1", "read": false,
            "createdAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        #expect(decoded.kind == .petFollow)
        #expect(decoded.petID == "pet-1")
        #expect(decoded.read == false)
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func anUnknownTypeIsKeptNotDropped() {
        let decoded = AppNotification.decode(id: "n2", ["type": "something_new", "message": "hi"])
        #expect(decoded.kind == .unknown)
        #expect(decoded.message == "hi")
    }

    /// The server stores a video post's first media URL as its "image", and
    /// the web then shows a broken picture. Here it becomes the poster.
    @Test func aVideoPostsImageIsItsPoster() {
        let decoded = AppNotification.decode(id: "n3", [
            "type": "like",
            "postImage": "https://res.cloudinary.com/demo/video/upload/v1/petnote/users/u/clip.mp4",
        ])
        let url = decoded.postImageURL?.absoluteString ?? ""
        #expect(url.hasSuffix(".jpg"), "\(url)")
        #expect(url.contains("so_0"), "\(url)")
    }

    // MARK: - What is shown, and where it goes

    /// "Alice Alice liked Max's post" on the web: the server's message for a
    /// pet's post already starts with the name.
    @Test func theSendersNameIsNotSaidTwice() {
        #expect(Self.item("a", message: "liked your post").line == "Alice liked your post")
        #expect(Self.item("b", message: "Alice liked Max's post").line == "Alice liked Max's post")
        #expect(Self.item("c", from: "", message: "You are now the primary owner of Max.").line
            == "You are now the primary owner of Max.")
    }

    @Test func tappingGoesWhereTheWebGoes() {
        #expect(Self.item("like").destination == .postDetail(postID: "p1"))
        #expect(Self.item("comment", kind: .comment).destination == .postDetail(postID: "p1"))
        #expect(Self.item("follow", kind: .petFollow, postID: nil, petID: "pet-1").destination == .pet(petID: "pet-1"))
        #expect(Self.item("legacy", kind: .follow, postID: nil, petID: nil).destination == .user(userID: "u-alice"))
        #expect(Self.item("primary", kind: .petPrimaryTransferred, postID: nil, petID: "pet-2").destination == .pet(petID: "pet-2"))
        #expect(Self.item("meetup", kind: .meetupJoin, postID: nil).destination == nil, "no meetup id to open")
        #expect(Self.item("warning", kind: .warning).destination == nil)
    }

    // MARK: - The list

    @Test func openingAnUnreadOneMarksItReadAndARefusalPutsItBack() async {
        let source = FakeSource()
        source.pages = [[Self.item("n1"), Self.item("n2", read: true)]]
        source.unread = 1
        let model = NotificationsModel(uid: "me", source: source)
        await model.load()
        #expect(model.unreadCount == 1)

        await model.open(model.items[0])
        #expect(source.marked == ["n1"])
        #expect(model.items[0].read)
        #expect(model.unreadCount == 0)

        await model.open(model.items[1])
        #expect(source.marked == ["n1"], "an already-read one was written again")

        let refused = FakeSource()
        refused.pages = [[Self.item("n3")]]
        refused.unread = 1
        refused.markError = NSError(domain: "test", code: 7)
        let other = NotificationsModel(uid: "me", source: refused)
        await other.load()
        await other.open(other.items[0])
        #expect(!other.items[0].read, "a refused write left it looking read")
        #expect(other.unreadCount == 1)
    }

    @Test func markAllReadIsImmediateAndARefusalReloadsTheTruth() async {
        let source = FakeSource()
        source.pages = [[Self.item("n1"), Self.item("n2")]]
        source.unread = 2
        let model = NotificationsModel(uid: "me", source: source)
        await model.load()
        await model.markAllRead()
        #expect(source.markedAll == 1)
        let allRead = model.items.allSatisfy { $0.read }
        #expect(allRead)
        #expect(model.unreadCount == 0)

        source.markAllError = NSError(domain: "test", code: 14)
        source.pages = [[Self.item("n4")]]
        source.unread = 1
        await model.markAllRead()   // nothing unread on screen: no call
        #expect(source.markedAll == 1)
    }

    @Test func aFailedFirstReadSaysSoRatherThanLookingEmpty() async {
        let source = FakeSource()
        source.readError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let model = NotificationsModel(uid: "me", source: source)
        await model.load()
        #expect(model.state == .failed("Couldn't load notifications."))
    }

    @Test func aFullPageMeansThereMayBeMore() async {
        let source = FakeSource()
        let full = (0..<NotificationsModel.pageSize).map { Self.item("n\($0)") }
        source.pages = [full, [Self.item("tail")]]
        let model = NotificationsModel(uid: "me", source: source)
        await model.load()
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.items.count == NotificationsModel.pageSize + 1)
        #expect(!model.hasMore)
        #expect(source.pageCalls.last == "n\(NotificationsModel.pageSize - 1)", "the next page did not start after the last one shown")
    }
}
