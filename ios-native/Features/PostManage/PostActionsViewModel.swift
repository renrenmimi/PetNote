import FirebaseFirestore
import Foundation
import Observation
import OSLog

/// Which post a person has pinned to their profile.
///
/// **TEMPORARY.** `users/{uid}.pinnedPostId` belongs to the line that owns
/// `FirestoreUserRepository`; this reads the one field the post menu needs so
/// the pin control can say "Pin" or "Unpin" truthfully instead of guessing.
protocol PinnedPostReading: Sendable {
    func pinnedPostID(for uid: String) async throws -> String?
}

actor FirestorePinnedPostSource: PinnedPostReading {
    private let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    func pinnedPostID(for uid: String) async throws -> String? {
        let snapshot = try await db.collection("users").document(uid).getDocument()
        let value = snapshot.data()?["pinnedPostId"] as? String
        return (value?.isEmpty ?? true) ? nil : value
    }
}

/// The owner's controls on a post: edit, delete, pin, and — for anybody — save.
///
/// The four are together because they share one question ("is this mine?") and
/// one hazard: each of them changes something the feed is already showing, so
/// each reports back rather than leaving the list to find out on its own.
@MainActor
@Observable
final class PostActionsViewModel {
    /// Bookmarks are the client-direct-write exception. Three states for the
    /// same reason likes have three: a silent no-op is indistinguishable from
    /// success, and "already saved" is not "that post is gone".
    private(set) var isBookmarked = false
    private(set) var isPinned = false
    private(set) var isDeleted = false
    private(set) var isWorking = false
    /// Read by the view. Cleared by the view.
    var failureMessage: String?
    var notice: String?

    let post: Post
    private let uid: String
    private let writes: any PostWriteRepository
    private let pins: any PinnedPostReading
    private let onDeleted: (@MainActor (String) -> Void)?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "postmanage")

    init(
        post: Post,
        uid: String,
        writes: any PostWriteRepository,
        pins: any PinnedPostReading = FirestorePinnedPostSource(),
        onDeleted: (@MainActor (String) -> Void)? = nil
    ) {
        self.post = post
        self.uid = uid
        self.writes = writes
        self.pins = pins
        self.onDeleted = onDeleted
    }

    /// Edit, delete and pin are the author's. Saving is everybody's.
    var isOwnPost: Bool { post.authorID == uid }

    func refresh() async {
        isBookmarked = (try? await writes.isBookmarked(postID: post.id)) ?? false
        guard isOwnPost else { return }
        isPinned = (try? await pins.pinnedPostID(for: uid)) == post.id
    }

    // MARK: - Bookmark

    func toggleBookmark() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let wanted = !isBookmarked
        // Optimistic, and rolled back by the answer rather than by a timer.
        isBookmarked = wanted
        do {
            let result = wanted
                ? try await writes.bookmark(postID: post.id)
                : try await writes.unbookmark(postID: post.id)
            switch result {
            case .changed:
                break
            case .unchanged:
                // The server was already in the state we asked for. The
                // optimistic value is right; nothing to undo.
                break
            case .postNotFound:
                isBookmarked = false
                failureMessage = "That post no longer exists."
            }
        } catch {
            isBookmarked = !wanted
            failureMessage = describe(error)
        }
    }

    // MARK: - Pin

    func togglePin() async {
        guard isOwnPost, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let wanted = !isPinned
        do {
            // Idempotent on the server — it is a set on the user document — so
            // there is no uncertain outcome to handle and no reason not to
            // retry.
            try await writes.setPinned(postID: wanted ? post.id : nil)
            isPinned = wanted
            notice = wanted ? "Pinned to your profile." : "Unpinned."
        } catch {
            failureMessage = describe(error)
        }
    }

    // MARK: - Delete

    func delete() async {
        guard isOwnPost, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await writes.delete(postID: post.id)
            isDeleted = true
            // The list is told rather than left to discover a row that now
            // points at nothing.
            onDeleted?(post.id)
        } catch PostWriteError.postNotFound {
            // Already gone. That is the outcome that was asked for, so it is
            // reported as success — the callable itself returns success for a
            // post that does not exist, for the same reason.
            isDeleted = true
            onDeleted?(post.id)
        } catch {
            failureMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let write = error as? PostWriteError { return ComposeViewModel.describe(write) }
        log.error("post action failed: \(String(describing: error), privacy: .public)")
        return "That did not go through."
    }
}
