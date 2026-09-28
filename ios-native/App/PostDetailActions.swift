import SwiftUI

/// Puts `PostActionsMenu` on the detail screen's bar.
///
/// Attached from the shell as a toolbar item rather than built into
/// `PostDetailView`, so a screen whose scrolling, keyboard and comment
/// behaviour has been verified on a device does not have to be reopened to add
/// a menu to its bar.
///
/// The post is read here rather than handed in: the detail screen is reachable
/// from a link and from the pet page as well as from the feed, and only one of
/// those three has the `Post` in hand.
struct PostDetailActions: View {
    let postID: String
    let user: UserSession
    let repositories: Repositories
    let onEdit: (String) -> Void
    let onDeleted: @MainActor (String) -> Void
    /// The author was blocked. The shell refilters the feed and leaves this
    /// screen, which is now showing somebody the person asked not to see.
    let onBlocked: @MainActor (String) -> Void

    @State private var actions: PostActionsViewModel?
    /// The session's saved posts, so this menu's Save and the post's own save
    /// button are one state.
    @Environment(PostBookmarks.self) private var bookmarks: PostBookmarks?
    @State private var isReporting = false
    @State private var blockFailure: String?

    var body: some View {
        Group {
            if let actions {
                PostActionsMenu(
                    model: actions,
                    onEdit: onEdit,
                    onReport: { isReporting = true },
                    onBlock: { Task { await block(actions.post.authorID) } }
                )
            } else {
                // Nothing to act on yet. Not a disabled button: a control that
                // is on screen and does nothing is a dead button, and this one
                // would be every time the post was slow to load.
                Color.clear.frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                    .accessibilityHidden(true)
            }
        }
        .task(id: postID) { await load() }
        .sheet(isPresented: $isReporting) {
            ReportPostSheet(postID: postID, reporter: repositories.reports) {
                isReporting = false
            }
        }
        .alert(
            "Couldn't block",
            isPresented: Binding(get: { blockFailure != nil }, set: { if !$0 { blockFailure = nil } })
        ) {
            Button("OK", role: .cancel) { blockFailure = nil }
        } message: {
            Text(blockFailure ?? "")
        }
    }

    private func block(_ authorID: String) async {
        do {
            try await Blocking.block(
                authorID, viewerID: user.uid, social: repositories.social, pets: repositories.pets
            )
            onBlocked(authorID)
        } catch {
            // Said, not swallowed: a block that did not happen must not look
            // like one that did.
            blockFailure = "The block didn't go through. Try again."
        }
    }

    private func load() async {
        guard actions == nil,
              let post = try? await repositories.feed.post(id: postID)
        else { return }
        actions = PostActionsViewModel(
            post: post,
            uid: user.uid,
            writes: repositories.postWrites,
            pins: repositories.pins,
            bookmarks: bookmarks,
            onDeleted: onDeleted
        )
    }
}
