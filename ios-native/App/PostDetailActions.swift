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

    @State private var actions: PostActionsViewModel?

    var body: some View {
        Group {
            if let actions {
                PostActionsMenu(model: actions, onEdit: onEdit)
            } else {
                // Nothing to act on yet. Not a disabled button: a control that
                // is on screen and does nothing is a dead button, and this one
                // would be every time the post was slow to load.
                Color.clear.frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                    .accessibilityHidden(true)
            }
        }
        .task(id: postID) { await load() }
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
            onDeleted: onDeleted
        )
    }
}
