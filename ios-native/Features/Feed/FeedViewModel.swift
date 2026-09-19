import Foundation
import Observation
import OSLog

/// Drives the feed list.
///
/// Four things here exist because of specific ways this goes wrong:
///   - **a generation counter**, so a pull-to-refresh discards a page request
///     that was already in flight rather than splicing its stale rows in after
///     the fresh ones;
///   - **an intent token per post**, so a like rollback cannot undo a state a
///     later tap already set;
///   - **`.unchanged` rolls the count back**, because the server saying "already
///     liked" means its count already contains that like — keeping the
///     optimistic +1 on top shows one more than exists;
///   - **like status replaces rather than unions**, because a post the batch
///     query does not return is a post that is *not* liked, and discarding that
///     answer leaves a filled heart no refresh can clear.
@MainActor
@Observable
final class FeedViewModel {
    enum LoadState: Equatable {
        case idle
        case loadingFirstPage
        case loaded
        /// Distinct from `.loaded` with an empty list: "nothing here yet" and
        /// "we could not find out" must not look the same (§6.5).
        case failed(FailureKind)
    }

    /// Offline and server-side failure need different words (§6.5).
    enum FailureKind: Equatable {
        case offline
        case server

        var message: String {
            switch self {
            case .offline: "You appear to be offline."
            case .server: "Could not load the feed."
            }
        }
    }

    private(set) var posts: [Post] = []
    private(set) var likedPostIDs: Set<String> = []
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var hasMore = true

    /// Shown at the end of the list with its own retry, not as a modal: losing
    /// a page is not a reason to interrupt reading.
    private(set) var pagingFailure: FailureKind?
    /// A like that could not be applied. Shown inline and cleared by the view.
    var likeFailureMessage: String?

    /// The row the person left from, so returning restores position by identity
    /// rather than by offset. Survives a reload as long as that post is still
    /// in the list.
    private(set) var scrollAnchor: String?

    private let feed: any FeedRepository
    private let likes: any LikeRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "feed")

    private var nextCursor: PageCursor?
    private var requestedCursors: Set<PageCursor> = []
    private var didRequestFirstPage = false

    /// Incremented by every reload. A page response carrying an older
    /// generation is dropped — it describes a list that no longer exists.
    private var generation = 0

    /// Per post: what the server last told us, and what the person has asked
    /// for since. The displayed count is derived from the two rather than being
    /// nudged up and down.
    ///
    /// Incremental offsets plus rollbacks drift: when one tap's failure is
    /// skipped because a later tap superseded it, its +1 is never taken back
    /// off, and the screen disagrees with the server until a reload. Deriving
    /// the number instead makes every intermediate state self-correcting — the
    /// same shape the web client's useLike uses (baseCount + pending).
    /// Per post, the three separate facts that were previously squeezed into
    /// one counter — and each of which failed differently for it.
    ///
    ///   - **what the server holds** (`serverLiked`): the like document's
    ///     existence, which the batch query reports and a successful write
    ///     changes. Authoritative and immediate.
    ///   - **what the person asked for** (`intendedLiked`): drives the heart.
    ///   - **what the server's *count* has not caught up with**
    ///     (`unreflectedDelta`): `likeCount` is maintained by a trigger that
    ///     runs after the write, so a write can be confirmed while the
    ///     aggregate still holds the old number.
    ///
    /// `inFlight` counts unsettled requests. It goes down as well as up, which
    /// the old `intent` never did — so "has a tap ever happened" was being read
    /// as "is a tap still happening", and every later refresh was ignored.
    private struct LikeState {
        var serverLiked: Bool
        var intendedLiked: Bool
        /// Net change this client has had confirmed but which `snapshotCount`
        /// may not include yet.
        var unreflectedDelta: Int
        /// The count from the last server read, which `unreflectedDelta` is
        /// measured against.
        var snapshotCount: Int
        var inFlight: Int
    }
    private var likeStates: [String: LikeState] = [:]
    private var likeTasks: [String: Task<Void, Never>] = [:]

    private let pageSize: Int

    init(feed: any FeedRepository, likes: any LikeRepository, pageSize: Int = 20) {
        self.feed = feed
        self.likes = likes
        self.pageSize = pageSize
    }

    func loadFirstPageIfNeeded() async {
        guard !didRequestFirstPage else { return }
        didRequestFirstPage = true
        await reload()
    }

    func reload() async {
        generation += 1
        let thisGeneration = generation

        state = .loadingFirstPage
        requestedCursors.removeAll()
        nextCursor = nil
        pagingFailure = nil
        isLoadingMore = false

        do {
            let page = try await feed.posts(after: nil, limit: pageSize)
            guard thisGeneration == generation else { return }
            posts = page.items
            nextCursor = page.next
            hasMore = page.hasMore
            state = .loaded
            await refreshLikeStatus(for: page.items, generation: thisGeneration)
        } catch {
            guard thisGeneration == generation else { return }
            log.error("feed first page failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(Self.kind(of: error))
        }
    }

    func loadMoreIfNeeded(currentItem: Post?) async {
        guard state == .loaded, hasMore, !isLoadingMore, pagingFailure == nil,
              let cursor = nextCursor else { return }
        if let currentItem {
            let threshold = max(0, posts.count - 5)
            guard let index = posts.firstIndex(where: { $0.id == currentItem.id }),
                  index >= threshold else { return }
        }
        // 5A.3: a flung list fires this repeatedly; each cursor is spent once.
        guard !requestedCursors.contains(cursor) else { return }
        requestedCursors.insert(cursor)

        let thisGeneration = generation
        isLoadingMore = true
        defer { if thisGeneration == generation { isLoadingMore = false } }

        do {
            let page = try await feed.posts(after: cursor, limit: pageSize)
            // Dropped rather than appended: this page was read from a list that
            // has since been replaced, and splicing it in would leave gaps that
            // can never be paged over.
            guard thisGeneration == generation else {
                log.debug("discarding a page from generation \(thisGeneration)")
                return
            }
            let known = Set(posts.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) }
            posts.append(contentsOf: fresh)
            nextCursor = page.next
            hasMore = page.hasMore
            await refreshLikeStatus(for: fresh, generation: thisGeneration)
        } catch {
            guard thisGeneration == generation else { return }
            log.error("feed page failed: \(error.localizedDescription, privacy: .public)")
            // What is already on screen stays; the failure appears at the end
            // of the list with a retry.
            pagingFailure = Self.kind(of: error)
            requestedCursors.remove(cursor)
        }
    }

    func retryPaging() async {
        pagingFailure = nil
        await loadMoreIfNeeded(currentItem: nil)
    }

    /// The batch query is the authority for the ids it was asked about: present
    /// means liked, absent means not liked. Both halves are applied.
    /// The batch query is authoritative for the ids it was asked about:
    /// present means liked, absent means not liked. Both halves are applied.
    private func refreshLikeStatus(for newPosts: [Post], generation thisGeneration: Int) async {
        guard !newPosts.isEmpty else { return }
        let asked = Set(newPosts.map(\.id))
        let counts = Dictionary(newPosts.map { ($0.id, $0.likeCount) }, uniquingKeysWith: { a, _ in a })
        do {
            let liked = try await likes.likedPostIDs(among: Array(asked))
            guard thisGeneration == generation else { return }
            for id in asked {
                let serverSaysLiked = liked.contains(id)
                let freshCount = counts[id] ?? 0

                guard var existing = likeStates[id] else {
                    likeStates[id] = LikeState(
                        serverLiked: serverSaysLiked,
                        intendedLiked: serverSaysLiked,
                        unreflectedDelta: 0,
                        snapshotCount: freshCount,
                        inFlight: 0
                    )
                    continue
                }

                if serverSaysLiked != existing.serverLiked {
                    // Someone else changed it — another device, moderation, a
                    // cascade. Whatever this client had outstanding against the
                    // old state no longer describes anything.
                    existing.unreflectedDelta = 0
                } else if hasCaughtUp(
                    from: existing.snapshotCount, to: freshCount, delta: existing.unreflectedDelta
                ) {
                    // The aggregate has moved at least as far as our confirmed
                    // writes, so keeping the delta would count them twice.
                    existing.unreflectedDelta = 0
                }
                // Otherwise the trigger has not run yet and the delta is still
                // the only thing making the count right.

                existing.serverLiked = serverSaysLiked
                existing.snapshotCount = freshCount
                // Only adopt the server's answer as the intent when nothing is
                // in flight; a tap that has not been answered still owns it.
                if existing.inFlight == 0 { existing.intendedLiked = serverSaysLiked }
                likeStates[id] = existing
            }
            // Ids for rows that are gone would otherwise accumulate for the
            // lifetime of the session.
            let present = Set(posts.map(\.id))
            likeStates = likeStates.filter { present.contains($0.key) }
            likedPostIDs = Set(likeStates.filter(\.value.intendedLiked).map(\.key))
        } catch {
            // Not fatal: hearts render unset and tapping still works. It does
            // mean a first tap on an already-liked post answers `.unchanged`,
            // which is precisely why that path must not keep an offset.
            log.error("like status failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether the server's count has moved at least as far, and in the same
    /// direction, as the writes this client has had confirmed.
    ///
    /// Not equality: somebody else's like can land in the same window, so the
    /// count may have moved further than ours alone would explain. What must
    /// not happen is treating "has not moved at all" as "has caught up".
    private func hasCaughtUp(from old: Int, to fresh: Int, delta: Int) -> Bool {
        guard delta != 0 else { return true }
        let moved = fresh - old
        guard moved.signum() == delta.signum() else { return false }
        return abs(moved) >= abs(delta)
    }

    func rememberScrollAnchor(_ postID: String) { scrollAnchor = postID }
    func clearScrollAnchor() { scrollAnchor = nil }

    func isLiked(_ post: Post) -> Bool {
        likeStates[post.id]?.intendedLiked ?? false
    }

    /// The number to draw.
    ///
    ///   server's count
    ///   + what our confirmed writes have added that the count has not caught
    ///     up with yet
    ///   + one for a tap that has not been answered
    func displayLikeCount(for post: Post) -> Int {
        guard let state = likeStates[post.id] else { return post.likeCount }
        let pending = state.intendedLiked == state.serverLiked
            ? 0
            : (state.intendedLiked ? 1 : -1)
        return max(0, post.likeCount + state.unreflectedDelta + pending)
    }

    func toggleLike(_ post: Post) {
        let postID = post.id
        var state = likeStates[postID] ?? LikeState(
            serverLiked: false, intendedLiked: false,
            unreflectedDelta: 0, snapshotCount: post.likeCount, inFlight: 0
        )
        let shouldLike = !state.intendedLiked
        state.intendedLiked = shouldLike
        state.inFlight += 1
        likeStates[postID] = state
        likedPostIDs = Set(likeStates.filter(\.value.intendedLiked).map(\.key))

        let previous = likeTasks[postID]
        likeTasks[postID] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.applyLike(postID: postID, shouldLike: shouldLike)
        }
    }

    private func applyLike(postID: String, shouldLike: Bool) async {
        defer {
            if var state = likeStates[postID] {
                state.inFlight = max(0, state.inFlight - 1)
                likeStates[postID] = state
            }
        }

        do {
            let result = shouldLike
                ? try await likes.like(postID: postID)
                : try await likes.unlike(postID: postID)
            guard var state = likeStates[postID] else { return }

            switch result {
            case .changed:
                // **Recorded unconditionally.** The server's count really did
                // move, whether or not a later tap has since superseded this
                // request. Discarding it because the intent moved on is how a
                // like-then-unlike pair lost its +1 and kept its -1, leaving
                // the screen one below the truth for the rest of the session.
                state.unreflectedDelta += shouldLike ? 1 : -1
                state.serverLiked = shouldLike
                likeStates[postID] = state
            case .unchanged:
                // The server was already in this state: nothing moved, and the
                // count already accounts for it. Only the belief is corrected.
                state.serverLiked = shouldLike
                likeStates[postID] = state
            case .postNotFound:
                posts.removeAll { $0.id == postID }
                likeStates[postID] = nil
                likedPostIDs.remove(postID)
                likeFailureMessage = "That post no longer exists."
            }
        } catch {
            guard var state = likeStates[postID] else { return }
            // Nothing was written, so nothing is owed to the count. The intent
            // goes back to what the server holds — but only if this is the last
            // request outstanding, because a later tap owns the intent.
            if state.inFlight <= 1 {
                state.intendedLiked = state.serverLiked
                likeStates[postID] = state
                likedPostIDs = Set(likeStates.filter(\.value.intendedLiked).map(\.key))
            }
            likeFailureMessage = "Could not update the like. Try again."
        }
    }

    private static func kind(of error: Error) -> FailureKind {
        let nsError = error as NSError
        // Firestore reports a dead network as code 14 (unavailable); URLSession
        // uses its own domain.
        if nsError.domain == NSURLErrorDomain || nsError.code == 14 { return .offline }
        return .server
    }

    /// Waits for every in-flight like mutation. Test-facing.
    func waitForPendingLikes() async {
        for task in likeTasks.values { await task.value }
    }
}
