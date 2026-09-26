import Foundation
import Observation
import OSLog

/// Which posts the signed-in person has saved, for the save button on every
/// post (the web client's `PostActions.tsx` has one on each card) and for the
/// detail screen's menu, so the two never disagree about the same post.
///
/// One per session scope, owned by `SignedInView` and replaced on an account
/// switch: whose saves these are is the one thing it must never get wrong.
///
/// **Reads are batched by the screen, not by the card.** A list calls
/// `load(_:)` with the ids of a page when the page arrives; ids already known
/// are not read again, so a page costs one query per 30 posts
/// (`bookmarkedPostIDs(among:)`) rather than a read per card.
///
/// **A write is optimistic and answered, not timed.** The button shows the new
/// state at once, a second tap on the same post waits for the first to be
/// answered, and a failure puts the old state back and says so. "Already in
/// that state" is success; "that post is gone" is not.
@MainActor
@Observable
final class PostBookmarks {
    private(set) var saved: Set<String> = []
    /// Posts with a save or unsave out. Their button is disabled until it is
    /// answered, which is what makes a double tap one write.
    private(set) var pending: Set<String> = []
    /// Read by whoever shows it; cleared by them.
    var failureMessage: String?

    private var known: Set<String> = []
    /// Bumped by every save or unsave of a post. A read applies its answer
    /// only to posts whose count has not moved since the read left: an answer
    /// from before a write — still out, or already answered — is older than
    /// what the person asked for. The block list had the same race
    /// (`BlockFilteringFeed`); this is the same guard.
    private var writeCount: [String: Int] = [:]
    private let writes: any PostWriteRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "postmanage")

    init(writes: any PostWriteRepository) {
        self.writes = writes
    }

    func isSaved(_ postID: String) -> Bool { saved.contains(postID) }
    func isPending(_ postID: String) -> Bool { pending.contains(postID) }

    /// Reads the saved state of whichever of these posts it does not know yet.
    ///
    /// A post written to since the read left is left alone: its state is
    /// what the person asked for, and a read from before must not put the old
    /// one back. A failed read leaves the posts unknown, so the
    /// next page's read asks again; their buttons show "not saved" meanwhile,
    /// and saving from there is still right — a save of a saved post answers
    /// "unchanged".
    func load(_ postIDs: [String]) async {
        let unknown = Array(Set(postIDs).subtracting(known))
        guard !unknown.isEmpty else { return }
        known.formUnion(unknown)
        let countsWhenAsked = unknown.map { writeCount[$0, default: 0] }
        do {
            let answer = try await writes.bookmarkedPostIDs(among: unknown)
            for (id, count) in zip(unknown, countsWhenAsked) where writeCount[id, default: 0] == count {
                if answer.contains(id) { saved.insert(id) } else { saved.remove(id) }
            }
        } catch {
            for (id, count) in zip(unknown, countsWhenAsked) where writeCount[id, default: 0] == count {
                known.remove(id)
            }
            log.error("bookmark status read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Saves or unsaves one post. Returns whether it is saved afterwards.
    @discardableResult
    func toggle(_ postID: String) async -> Bool {
        guard !pending.contains(postID) else { return saved.contains(postID) }
        let wanted = !saved.contains(postID)
        pending.insert(postID)
        known.insert(postID)
        writeCount[postID, default: 0] += 1
        defer { pending.remove(postID) }
        set(postID, wanted)
        do {
            let result = wanted
                ? try await writes.bookmark(postID: postID)
                : try await writes.unbookmark(postID: postID)
            switch result {
            case .changed, .unchanged:
                break
            case .postNotFound:
                set(postID, false)
                failureMessage = String(localized: "That post no longer exists.")
            }
        } catch {
            set(postID, !wanted)
            failureMessage = describe(error)
        }
        return saved.contains(postID)
    }

    private func set(_ postID: String, _ isSaved: Bool) {
        if isSaved { saved.insert(postID) } else { saved.remove(postID) }
    }

    /// The menu's own wording (`PostActionsViewModel`), so a failed save
    /// reads the same from the row as from the menu.
    private func describe(_ error: Error) -> String {
        if let write = error as? PostWriteError { return ComposeViewModel.describe(write) }
        log.error("bookmark write failed: \(String(describing: error), privacy: .public)")
        return String(localized: "That did not go through.")
    }
}
