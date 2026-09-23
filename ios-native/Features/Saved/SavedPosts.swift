import FirebaseFirestore
import Observation
import OSLog
import SwiftUI

// The posts the signed-in person saved — the web client's profile "Saved"
// tab (`Profile.tsx`, `services/bookmarks.ts`). Saving and unsaving stay on
// the post's menu; this only lists them.

protocol SavedPostsReading: Sendable {
    /// The newest `limit` bookmarks' posts, newest bookmark first. A bookmark
    /// whose post has since been deleted is left out, as on the web.
    func savedPosts(uid: String, limit: Int) async throws -> [Post]
}

actor FirestoreSavedPostsSource: SavedPostsReading {
    private let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    /// `getBookmarkedPosts`, step for step: the bookmarks by `createdAt`, then
    /// the posts by id in batches of ten — the size the web client uses for
    /// Firestore's `in` — then back into bookmark order, because the batches
    /// come back in whatever order the server likes.
    func savedPosts(uid: String, limit: Int) async throws -> [Post] {
        let bookmarks = try await db.collection("users").document(uid).collection("bookmarks")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        let ids = bookmarks.documents.map(\.documentID)
        var posts: [String: Post] = [:]
        for batch in SavedPostsModel.batches(of: ids, size: 10) {
            let snapshot = try await db.collection("posts")
                .whereField(FieldPath.documentID(), in: batch)
                .getDocuments()
            for document in snapshot.documents {
                if let post = PostDecoder.post(id: document.documentID, from: document.data()) {
                    posts[post.id] = post
                }
            }
        }
        return SavedPostsModel.ordered(posts, by: ids)
    }
}

@MainActor
@Observable
final class SavedPostsModel {
    enum State: Equatable {
        case loading
        case loaded([Post])
        case failed(String)
    }

    /// The web client's page size for this tab.
    static let limit = 50

    private(set) var state: State = .loading
    /// A reload that failed while a list was already showing. The list stays;
    /// this says it may be out of date.
    private(set) var refreshFailed = false

    private let uid: String
    private let source: any SavedPostsReading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "saved")

    init(uid: String, source: any SavedPostsReading) {
        self.uid = uid
        self.source = source
    }

    /// Run every time the screen appears, so a post unsaved from its own page
    /// is gone when the person comes back to this list.
    func load() async {
        let hadList: Bool = { if case .loaded = state { return true } else { return false } }()
        if !hadList { state = .loading }
        do {
            state = .loaded(try await source.savedPosts(uid: uid, limit: Self.limit))
            refreshFailed = false
        } catch {
            log.error("saved posts read failed: \(String(describing: error), privacy: .public)")
            if hadList {
                refreshFailed = true
            } else {
                state = .failed(String(localized: "Couldn't load your saved posts."))
            }
        }
    }

    nonisolated static func batches(of ids: [String], size: Int) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    nonisolated static func ordered(_ posts: [String: Post], by ids: [String]) -> [Post] {
        ids.compactMap { posts[$0] }
    }
}

struct SavedPostsView: View {
    @State private var model: SavedPostsModel
    private let onOpenPost: (String) -> Void

    init(uid: String, source: any SavedPostsReading, onOpenPost: @escaping (String) -> Void) {
        _model = State(initialValue: SavedPostsModel(uid: uid, source: source))
        self.onOpenPost = onOpenPost
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("saved.loading")
            case .failed(let message):
                VStack(spacing: Spacing.m) {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                    Button { Task { await model.load() } } label: {
                        Text("Try again")
                            .frame(minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("saved.retry")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let posts) where posts.isEmpty:
                // The web client's empty state, word for word.
                VStack(spacing: Spacing.s) {
                    Image(systemName: "bookmark")
                        .font(Typography.pageTitle)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityHidden(true)
                    Text("No saved posts")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                    Text("Bookmark posts you love to find them later")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Layout.pageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("saved.empty")
            case .loaded(let posts):
                grid(posts)
            }
        }
        .background(Palette.background)
        .navigationTitle("Saved posts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func grid(_ posts: [Post]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if model.refreshFailed {
                    Text("Couldn't refresh. Pull down to try again.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier("saved.refreshFailed")
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 3),
                    spacing: Spacing.xs
                ) {
                    ForEach(posts) { post in
                        Button { onOpenPost(post.id) } label: {
                            PostThumbnail(post: post)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PostThumbnail.label(for: post))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("saved.post.\(post.id)")
                    }
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .refreshable { await model.load() }
    }
}
