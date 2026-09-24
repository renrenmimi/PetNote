import SwiftUI

// Hosts for the screens whose views take their model as `@Bindable`.
//
// **Why these exist.** `PetProfileView`, `PetEditorView`, `ComposeView` and
// `EditPostView` receive a model rather than owning one. Built directly inside a
// `navigationDestination` or `.sheet` closure, a fresh model would be made every
// time the shell's body is re-evaluated — which happens on any state change up
// there — and the screen would lose what it had loaded and fetch it again.
// `PostDetailView` avoids this by holding its model in `@State`; these hosts do
// the same for the four views that do not, so the model is created once per
// appearance and survives re-renders.
//
// None of the four had ever been constructed anywhere before this file — not in
// the app, not in a preview. They compiled; they had never been drawn.

struct PetProfileHost: View {
    @State private var model: PetProfileViewModel
    private let onEdit: (String) -> Void
    private let onDeleted: () -> Void
    private let onOpenPost: (String) -> Void
    private let socialRow: ((Pet, PetOwnership?) -> AnyView)?
    /// Bumped by the shell after the pet is edited, so the page re-reads the
    /// server's version rather than trusting what was typed.
    private let reloadToken: Int

    init(
        petID: String,
        repository: any PetRepository,
        viewerID: String,
        reloadToken: Int,
        onEdit: @escaping (String) -> Void,
        onDeleted: @escaping () -> Void,
        onOpenPost: @escaping (String) -> Void,
        socialRow: ((Pet, PetOwnership?) -> AnyView)? = nil
    ) {
        _model = State(initialValue: PetProfileViewModel(
            petID: petID, repository: repository, viewerID: viewerID
        ))
        self.reloadToken = reloadToken
        self.onEdit = onEdit
        self.onDeleted = onDeleted
        self.onOpenPost = onOpenPost
        self.socialRow = socialRow
    }

    var body: some View {
        PetProfileView(
            model: model, onEdit: onEdit, onDeleted: onDeleted, onOpenPost: onOpenPost,
            socialRow: socialRow
        )
        .onChange(of: reloadToken) { Task { await model.load() } }
    }
}

struct PetEditorHost: View {
    @State private var model: PetEditorViewModel
    private let onSaved: (String) -> Void
    private let onCancel: () -> Void

    init(
        mode: PetEditorViewModel.Mode,
        repository: any PetRepository,
        uploader: any MediaUploading,
        viewerID: String,
        onSaved: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: PetEditorViewModel(
            mode: mode, repository: repository, uploader: uploader, viewerID: viewerID
        ))
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            PetEditorView(model: model, onSaved: onSaved, onCancel: onCancel)
        }
    }
}

struct ComposeHost: View {
    @State private var model: ComposeViewModel
    private let onClose: () -> Void

    init(
        user: UserSession,
        repositories: Repositories,
        onPublished: @escaping @MainActor (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        _model = State(initialValue: ComposeViewModel(
            uid: user.uid,
            isEmailVerified: user.isEmailVerified,
            uploader: repositories.media,
            writes: repositories.postWrites,
            pets: repositories.petChoices,
            onPublished: onPublished
        ))
        self.onClose = onClose
    }

    var body: some View {
        ComposeView(model: model, onClose: onClose)
    }
}

struct EditPostHost: View {
    @State private var model: EditPostViewModel
    private let onClose: () -> Void

    init(
        postID: String,
        uid: String,
        repositories: Repositories,
        onSaved: @escaping @MainActor () -> Void,
        onClose: @escaping () -> Void
    ) {
        _model = State(initialValue: EditPostViewModel(
            postID: postID,
            uid: uid,
            feed: repositories.feed,
            writes: repositories.postWrites,
            pets: repositories.petChoices,
            onSaved: onSaved
        ))
        self.onClose = onClose
    }

    var body: some View {
        EditPostView(model: model, onClose: onClose)
    }
}
