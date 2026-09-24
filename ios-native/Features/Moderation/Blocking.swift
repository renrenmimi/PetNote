import Foundation
import OSLog

/// Blocking somebody, the way the web client's `blockUser` does it.
///
/// Two parts. The block itself — `users/{viewer}/blockedUsers/{user}` — is
/// the part that must succeed, and the only one this throws for. Then, best
/// effort: no longer following the pets that were *theirs alone*. Following a
/// pet somebody else also owns is not following the blocked person, and
/// ownership moves between equal co-owners, so the test is the family, not
/// `ownerId` (the web client's comment says the same).
enum Blocking {
    private static let log = Logger(subsystem: "dev.local.petnote.native", category: "moderation")

    /// How many followed pets are looked at. The web client pages through all
    /// of them; this reads one page of this size, which covers any account
    /// that follows fewer — and the feed filters the person's posts either
    /// way, which is where their content actually comes from.
    static let followedPetsExamined = 500

    /// Returns the pets that were unfollowed.
    @discardableResult
    static func block(
        _ userID: String,
        viewerID: String,
        social: any SocialRepository,
        pets: any PetRepository
    ) async throws -> [String] {
        try await social.block(userID: userID, viewerID: viewerID)

        var unfollowed: [String] = []
        let followed: [FollowedPet]
        do {
            followed = try await social.followedPets(viewerID: viewerID, limit: followedPetsExamined)
        } catch {
            log.error("after a block, the followed pets could not be read: \(String(describing: error), privacy: .public)")
            return unfollowed
        }
        for pet in followed {
            guard let family = try? await pets.family(petID: pet.id),
                  !family.isEmpty,
                  family.allSatisfy({ $0.id == userID })
            else { continue }
            do {
                try await social.unfollow(petID: pet.id)
                unfollowed.append(pet.id)
            } catch {
                log.error("after a block, unfollowing \(pet.id.prefix(6), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return unfollowed
    }
}

/// The feed, less the posts of people the viewer has blocked — the web
/// client's `localPosts.filter(post => !blockedUserIds.includes(post.authorId))`.
///
/// A layer under `FeedViewModel` rather than a change inside it: the model's
/// paging, generations and like reconciliation were verified on a device, and
/// this does not touch them. What it guarantees the model instead is that a
/// page is never empty while there is more after it — a page emptied by the
/// filter is followed by the next one here — because an empty page with more
/// behind it would leave the list with no row whose appearance asks for more.
///
/// A blocked list that cannot be read filters nothing, as on the web.
actor BlockFilteringFeed: FeedRepository {
    private let base: any FeedRepository
    private let social: any SocialRepository
    private var viewerID: String
    private var blocked: Set<String>?
    /// The read of the list that is out now, if one is. A second caller while
    /// it is out waits for it rather than asking again: on a cold start the
    /// feed's first page and the spotlight row both ask at once, and that was
    /// two reads of the same list. Nil when the read failed — which fills no
    /// cache, so the next caller asks again.
    private var inFlight: (number: Int, read: Task<Set<String>?, Never>)?
    private var readsStarted = 0
    /// Bumped whenever the cached list stops being the right one: a block, an
    /// unblock, another account. A read begun under an older value still
    /// answers the callers who were waiting for it, but may not fill the cache
    /// — it could be the list from before the block, or somebody else's.
    private var generation = 0
    /// Callers waiting on the read that is out, the one that started it
    /// included. Nothing depends on it; it is how a test can tell "the second
    /// caller shared the read" from "the second caller came after it was
    /// over", which otherwise look the same from outside.
    private(set) var callersWaitingOnRead = 0
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "moderation")

    /// Pages read past emptied ones before giving the model what there is.
    static let maxPagesPerRequest = 5

    init(base: any FeedRepository, social: any SocialRepository, viewerID: String) {
        self.base = base
        self.social = social
        self.viewerID = viewerID
    }

    /// A different account signed in on the same shell.
    func switchAccount(to viewerID: String) {
        self.viewerID = viewerID
        forgetTheList()
    }

    /// After a block or an unblock, so the next read filters by the new list.
    func invalidate() {
        forgetTheList()
    }

    /// The cache, and the read that would have filled it: a caller after
    /// this point starts a read of its own rather than joining one that began
    /// before the change.
    private func forgetTheList() {
        blocked = nil
        inFlight = nil
        generation += 1
    }

    /// Not private: the feed's spotlight row filters by the same list, from
    /// this same cache, so a block leaves both at once (`BlockedAuthorsProviding`).
    func blockedIDs() async -> Set<String> {
        if let blocked { return blocked }
        let generation = self.generation
        let current: (number: Int, read: Task<Set<String>?, Never>)
        if let inFlight {
            current = inFlight
        } else {
            readsStarted += 1
            let social = self.social
            let viewerID = self.viewerID
            let log = self.log
            current = (readsStarted, Task { () async -> Set<String>? in
                do {
                    return try await social.blockedUserIDs(viewerID: viewerID)
                } catch {
                    log.error("blocked users read failed; filtering nothing: \(String(describing: error), privacy: .public)")
                    return nil
                }
            })
            inFlight = current
        }
        callersWaitingOnRead += 1
        let answer = await current.read.value
        callersWaitingOnRead -= 1
        if inFlight?.number == current.number { inFlight = nil }
        if let answer, generation == self.generation { blocked = answer }
        return answer ?? []
    }

    func posts(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        let blocked = await blockedIDs()
        guard !blocked.isEmpty else { return try await base.posts(after: cursor, limit: limit) }
        var cursor = cursor
        var page = Page<Post>.empty
        for _ in 0..<Self.maxPagesPerRequest {
            page = try await base.posts(after: cursor, limit: limit)
            let kept = page.items.filter { !blocked.contains($0.authorID) }
            if !kept.isEmpty || !page.hasMore {
                return Page(items: kept, next: page.next)
            }
            cursor = page.next
        }
        // Five pages in a row of nothing but blocked people. The cursor is
        // handed back so this is not mistaken for the end of the feed, but an
        // empty page gives the list no row to ask for more from: past this
        // point a person sees what was already loaded, and pulling to refresh
        // starts again from the top. Not a case any real block list reaches.
        return Page(items: [], next: page.next)
    }

    /// A post opened directly — a link, a notification — is shown whoever
    /// wrote it, as the web detail page does.
    func post(id: String) async throws -> Post? {
        try await base.post(id: id)
    }
}
