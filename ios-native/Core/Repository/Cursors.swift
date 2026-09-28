import Foundation

/// An opaque paging token.
///
/// It is deliberately just an identifier. The thing that actually lets a
/// repository resume — a Firestore `DocumentSnapshot`, or a (timestamp, docId)
/// pair — stays inside that repository's actor, which buys two things:
///
///   1. Nothing non-`Sendable` crosses an isolation boundary, so this works
///      under complete strict concurrency without `@unchecked Sendable`.
///   2. **A caller cannot read a timestamp out of it and page by time.** The
///      web client's following feed carries a source comment about exactly this:
///      paging with `where("createdAt","<",t)` silently drops posts that share a
///      timestamp, which is why it pages on the (createdAt, documentId) pair
///      instead. An opaque token makes that mistake unrepresentable here.
struct PageCursor: Sendable, Hashable {
    private let id: UUID

    init() {
        id = UUID()
    }
}

/// One page of results plus the token for the next one.
struct Page<Element: Sendable>: Sendable {
    let items: [Element]
    /// Nil when there is nothing after this page.
    let next: PageCursor?

    /// Mirrors `hasMore = docs.length === limitCount` in src/services/posts.ts:
    /// a full page means "there may be more", not "there is more".
    var hasMore: Bool { next != nil }

    static var empty: Page<Element> { Page(items: [], next: nil) }
}
