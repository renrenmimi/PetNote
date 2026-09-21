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

    /// Which account this model is showing. See `prepare(for:)`.
    private var accountID: String?

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
        /// may not include yet. An optimistic guess with a shelf life; see
        /// `reconcile(_:against:)`.
        var unreflectedDelta: Int
        /// The count from the last server read, which `unreflectedDelta` is
        /// measured against.
        var snapshotCount: Int
        var inFlight: Int
        /// How many server reads have looked at `unreflectedDelta` and been
        /// unable to confirm it. Bounded by `unconfirmedReadLimit`.
        var unconfirmedReads = 0
        /// `writeSequence` as of this post's last answered write. A status read
        /// issued before that number cannot describe the result of the write.
        var lastWriteSequence = 0
    }
    private var likeStates: [String: LikeState] = [:]

    /// What this client has had confirmed about a post's comment count but
    /// which the feed's copy of the post may not include yet.
    ///
    /// The same shape as the like offset, for the same reason: `commentCount`
    /// is maintained by a trigger, and the feed's Post is a snapshot taken
    /// before the comment existed. Measured on a device: comment posted, the
    /// detail screen showed it, the server said 1, and the feed still said
    /// "0 comments" — the server was right and nothing had told the feed.
    private struct CommentState {
        var unreflectedDelta: Int
        var snapshotCount: Int
        var unconfirmedReads = 0
    }
    private var commentStates: [String: CommentState] = [:]
    private var likeTasks: [String: Task<Void, Never>] = [:]

    /// Bumped by every like write that comes back with an answer, so a status
    /// read can be compared against it and discarded when it is older.
    private var writeSequence = 0

    /// How many server reads an unconfirmed optimistic offset survives before
    /// the server's number is taken as it stands. See `reconcile(_:against:)`
    /// for why this cannot be "until it is confirmed".
    private static let unconfirmedReadLimit = 3

    private let pageSize: Int
    private let likeDeadline: Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    init(
        feed: any FeedRepository,
        likes: any LikeRepository,
        /// The account this model starts out bound to.
        ///
        /// Supplying it at construction is what makes the first `prepare(for:)`
        /// a no-op. Without it, the call that binds the model would also reset
        /// it — and it races the feed's own first-page task, so whether that
        /// reset lands before or after the first page arrives is undefined.
        accountID: String? = nil,
        pageSize: Int = 20,
        likeDeadline: Duration = .seconds(12),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.feed = feed
        self.likes = likes
        self.accountID = accountID
        self.pageSize = pageSize
        self.likeDeadline = likeDeadline
        self.sleeper = sleeper
    }

    /// Binds this model to a signed-in account, discarding everything it holds
    /// for a different one.
    ///
    /// Signing *out* replaces the whole session scope, so a fresh model is the
    /// normal case and needs nothing. An account *switch* is not that: the view
    /// that owns this model keeps its `@State` across a change of user, because
    /// the view's identity has not changed — so the previous account's rows,
    /// its filled hearts, and (the one that hides) its unconfirmed like offset
    /// are all still here when the next person's feed draws.
    ///
    /// The offset is the one worth spelling out. Account A likes a post whose
    /// trigger has not run; account B has already liked that same post, so B's
    /// status read also says "liked". Nothing contradicts A's stale offset —
    /// same post, same answer — and B is shown A's +1 on top of a count that
    /// already contains B's own like.
    func prepare(for accountID: String) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID

        // Anything still in flight belongs to the person who left.
        for task in likeTasks.values { task.cancel() }
        likeTasks.removeAll()
        // And anything still on its way back is now from an older list.
        generation += 1

        posts = []
        likedPostIDs = []
        likeStates.removeAll()
        writeSequence = 0
        state = .idle
        isLoadingMore = false
        hasMore = true
        pagingFailure = nil
        likeFailureMessage = nil
        scrollAnchor = nil
        nextCursor = nil
        requestedCursors.removeAll()
        didRequestFirstPage = false
    }

    func loadFirstPageIfNeeded() async {
        guard !didRequestFirstPage else { return }
        didRequestFirstPage = true
        await reload()
    }

    func reload() async {
        generation += 1
        let thisGeneration = generation
        // Sampled before the read goes out, so a write that lands while it is
        // in flight can be recognised as newer than the answer.
        let readSequence = writeSequence

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
            await refreshLikeStatus(
                for: page.items, generation: thisGeneration, readSequence: readSequence
            )
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
        let readSequence = writeSequence
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
            await refreshLikeStatus(
                for: fresh, generation: thisGeneration, readSequence: readSequence
            )
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

    /// The batch query is authoritative for the ids it was asked about: present
    /// means liked, absent means not liked. Both halves are applied.
    ///
    /// Two things it is *not* allowed to be authoritative about:
    ///
    ///   - **anything newer than itself.** A read that sampled the server
    ///     before a write this client has since had answered cannot describe
    ///     the result of that write. Applying it anyway is how a pull-to-refresh
    ///     answered late unliked a post under the finger that had just liked it.
    ///   - **the count, when it did not run.** A failed status read still
    ///     arrives alongside a fresh `likeCount` from the feed query, and the
    ///     optimistic offset has to keep being measured against the newest
    ///     count we have seen. Skipping that left the baseline behind while the
    ///     displayed number moved on, and the offset was then added to a count
    ///     that already contained it.
    private func refreshLikeStatus(
        for newPosts: [Post], generation thisGeneration: Int, readSequence: Int
    ) async {
        guard !newPosts.isEmpty else { return }

        var liked: Set<String>?
        do {
            liked = try await likes.likedPostIDs(among: newPosts.map(\.id))
        } catch {
            // Not fatal: hearts render unset and tapping still works. It does
            // mean a first tap on an already-liked post answers `.unchanged`,
            // which is precisely why that path must not keep an offset.
            log.error("like status failed: \(error.localizedDescription, privacy: .public)")
        }
        guard thisGeneration == generation else { return }

        for post in newPosts {
            // Comment counts first and unconditionally: unlike the like state
            // there is no "did the server say we liked it" to wait for, and a
            // post the client has never touched simply has no offset to
            // reconcile.
            if var comments = commentStates[post.id] {
                reconcileComments(&comments, against: post.commentCount)
                comments.snapshotCount = post.commentCount
                commentStates[post.id] = comments
            }

            let freshCount = post.likeCount

            guard var existing = likeStates[post.id] else {
                // Nothing is known about this post, so there is nothing to
                // reconcile — and only an answer we actually received can seed
                // a belief about it.
                if let liked {
                    let serverSaysLiked = liked.contains(post.id)
                    likeStates[post.id] = LikeState(
                        serverLiked: serverSaysLiked,
                        intendedLiked: serverSaysLiked,
                        unreflectedDelta: 0,
                        snapshotCount: freshCount,
                        inFlight: 0
                    )
                }
                continue
            }

            if existing.lastWriteSequence > readSequence {
                // This read is older than a write we have since had answered.
                // It describes a world that no longer exists; the next read
                // will describe this one.
                continue
            }

            if let liked {
                let serverSaysLiked = liked.contains(post.id)
                if serverSaysLiked != existing.serverLiked {
                    // Someone else changed it — another device, moderation, a
                    // cascade. Whatever this client had outstanding against the
                    // old state no longer describes anything.
                    existing.unreflectedDelta = 0
                    existing.unconfirmedReads = 0
                } else {
                    reconcile(&existing, against: freshCount)
                }
                existing.serverLiked = serverSaysLiked
                // Only adopt the server's answer as the intent when nothing is
                // in flight; a tap that has not been answered still owns it.
                if existing.inFlight == 0 { existing.intendedLiked = serverSaysLiked }
            } else {
                reconcile(&existing, against: freshCount)
            }

            existing.snapshotCount = freshCount
            likeStates[post.id] = existing
        }

        // Ids for rows that are gone would otherwise accumulate for the
        // lifetime of the session.
        let present = Set(posts.map(\.id))
        likeStates = likeStates.filter { present.contains($0.key) }
        likedPostIDs = Set(likeStates.filter(\.value.intendedLiked).map(\.key))
    }

    /// Measures the optimistic offset against the newest count the server has
    /// given us, and gives up on it when it cannot be confirmed.
    ///
    /// **Whether a particular aggregate includes our own write cannot be
    /// decided from what the backend exposes.** `likeCount` is a single
    /// integer with no provenance: "it went up by one" does not say whose like
    /// did that. Two consequences, and they point opposite ways:
    ///
    ///   - a stranger's like landing in the same window is credited to us, and
    ///     our offset comes off one read early — one too few, for one read,
    ///     self-correcting;
    ///   - a stranger's *unlike* cancelling our like leaves the count exactly
    ///     where it was, so "has it caught up?" can never answer yes. Held
    ///     without a limit, that offset is wrong on every reading of that post
    ///     for the rest of the session.
    ///
    /// The second is the one that has to be bounded, and the bound is what this
    /// does: the offset survives `unconfirmedReadLimit` server reads, and after
    /// that the server's number is taken as it stands. A number that is briefly
    /// wrong and then right is recoverable; one that is quietly wrong forever
    /// is not.
    /// The count to show for a post's comments.
    ///
    /// Immediate: the offset is applied the moment the write is confirmed, so
    /// coming back from the detail screen shows the new number without a
    /// refresh and without waiting out a timer.
    func displayCommentCount(for post: Post) -> Int {
        max(0, post.commentCount + (commentStates[post.id]?.unreflectedDelta ?? 0))
    }

    /// A comment this client wrote, or deleted, and had confirmed.
    ///
    /// Confirmed means the server accepted the write — not that the aggregate
    /// has moved. Those are different moments and the gap between them is what
    /// this offset covers.
    func recordCommentChange(postID: String, delta: Int) {
        guard delta != 0 else { return }
        let snapshot = posts.first(where: { $0.id == postID })?.commentCount ?? 0
        var state = commentStates[postID] ?? CommentState(unreflectedDelta: 0, snapshotCount: snapshot)
        state.unreflectedDelta += delta
        state.unconfirmedReads = 0
        commentStates[postID] = state
    }

    /// Same bounded window as likes: an offset the server never confirms is
    /// given up on rather than kept forever.
    private func reconcileComments(_ state: inout CommentState, against freshCount: Int) {
        guard state.unreflectedDelta != 0 else {
            state.unconfirmedReads = 0
            return
        }
        if hasCaughtUp(from: state.snapshotCount, to: freshCount, delta: state.unreflectedDelta) {
            // The trigger has landed. Keeping the offset would count the same
            // comment twice — once in the server's number and once in ours.
            state.unreflectedDelta = 0
            state.unconfirmedReads = 0
            return
        }
        state.unconfirmedReads += 1
        if state.unconfirmedReads >= Self.unconfirmedReadLimit {
            log.debug("dropping a comment offset the aggregate never confirmed")
            state.unreflectedDelta = 0
            state.unconfirmedReads = 0
        }
    }

    private func reconcile(_ state: inout LikeState, against freshCount: Int) {
        guard state.unreflectedDelta != 0 else {
            state.unconfirmedReads = 0
            return
        }
        if hasCaughtUp(from: state.snapshotCount, to: freshCount, delta: state.unreflectedDelta) {
            // The aggregate has moved at least as far as our confirmed writes,
            // so keeping the offset would count them twice.
            state.unreflectedDelta = 0
            state.unconfirmedReads = 0
            return
        }
        state.unconfirmedReads += 1
        if state.unconfirmedReads >= Self.unconfirmedReadLimit {
            log.debug("dropping a like offset the aggregate never confirmed")
            state.unreflectedDelta = 0
            state.unconfirmedReads = 0
        }
    }

    /// Whether the server's count has moved at least as far, and in the same
    /// direction, as the writes this client has had confirmed.
    ///
    /// Not equality: somebody else's like can land in the same window, so the
    /// count may have moved further than ours alone would explain. What must
    /// not happen is treating "has not moved at all" as "has caught up".
    ///
    /// This is a heuristic and cannot be anything else — see
    /// `reconcile(_:against:)` for what it gets wrong and what bounds it.
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

    /// What came back from one like write.
    ///
    /// `timedOut` is not `failed`. A failure means nothing was written and
    /// nothing is owed to the count; a timeout means *we do not know*, and the
    /// difference has to reach the person as different words and reach the
    /// state as "believe the next read", not "assume it did not happen".
    private enum LikeOutcome: Sendable {
        case answered(LikeMutationResult)
        case failed(String)
        case timedOut
    }

    /// Runs one like write under a deadline.
    ///
    /// Not "slow": slow is fine, and the intent stays optimistic while a
    /// request is in flight. This is the request that goes out and nothing
    /// comes back — no result, no error — which wedges the post three ways at
    /// once: later taps queue behind it forever, every refresh declines to
    /// adopt the server's state because a tap still owns the intent, and the
    /// screen keeps an optimistic like nothing will ever confirm.
    ///
    /// The work runs in its own unstructured task and is *abandoned*, not
    /// awaited, when the deadline passes. A structured child would have to be
    /// awaited at scope exit, and Firestore's async calls do not promise to
    /// return early on cancellation — so waiting for it is exactly the wait
    /// this is here to end. The point is that the screen stops waiting, not
    /// that the network does.
    private func answer(
        for operation: @escaping @Sendable () async throws -> LikeMutationResult
    ) async -> LikeOutcome {
        let (outcomes, send) = AsyncStream<LikeOutcome>.makeStream()
        let work = Task {
            do { send.yield(.answered(try await operation())) }
            catch { send.yield(.failed(error.localizedDescription)) }
        }
        let timer = Task { [sleeper, likeDeadline] in
            try? await sleeper(likeDeadline)
            send.yield(.timedOut)
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        // Buffered, so whichever finishes first cannot be missed.
        var outcome = outcomes.makeAsyncIterator()
        return await outcome.next() ?? .timedOut
    }

    private func applyLike(postID: String, shouldLike: Bool) async {
        defer {
            if var state = likeStates[postID] {
                state.inFlight = max(0, state.inFlight - 1)
                likeStates[postID] = state
            }
        }

        let likes = self.likes
        let outcome = await answer {
            if shouldLike {
                return try await likes.like(postID: postID)
            } else {
                return try await likes.unlike(postID: postID)
            }
        }
        guard var state = likeStates[postID] else { return }

        switch outcome {
        case .answered(let result):
            // The server has told us something about this post that is newer
            // than any read already in flight.
            writeSequence += 1
            state.lastWriteSequence = writeSequence

            switch result {
            case .changed:
                // **Recorded unconditionally.** The server's count really did
                // move, whether or not a later tap has since superseded this
                // request. Discarding it because the intent moved on is how a
                // like-then-unlike pair lost its +1 and kept its -1, leaving
                // the screen one below the truth for the rest of the session.
                state.unreflectedDelta += shouldLike ? 1 : -1
                state.unconfirmedReads = 0
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

        case .failed(let description):
            log.error("like write failed: \(description, privacy: .public)")
            // Nothing was written, so nothing is owed to the count. The intent
            // goes back to what the server holds — but only if this is the last
            // request outstanding, because a later tap owns the intent.
            rollBackIntent(&state, postID: postID)
            likeFailureMessage = "Could not update the like. Try again."

        case .timedOut:
            log.error("like request for \(postID, privacy: .public) was never answered")
            // No offset is recorded and `lastWriteSequence` is not moved: we do
            // not know whether the write landed, so the next server read is
            // allowed to be the authority on both the heart and the count.
            rollBackIntent(&state, postID: postID)
            likeFailureMessage = "Could not confirm that. Pull down to refresh."
        }
    }

    private func rollBackIntent(_ state: inout LikeState, postID: String) {
        guard state.inFlight <= 1 else { return }
        state.intendedLiked = state.serverLiked
        likeStates[postID] = state
        likedPostIDs = Set(likeStates.filter(\.value.intendedLiked).map(\.key))
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
