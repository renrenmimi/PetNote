import SwiftUI

/// Editing a post. The media is shown and said to be fixed, rather than being
/// left out — a person who came here to change a photo needs an answer, not an
/// absence.
struct EditPostView: View {
    @Bindable var model: EditPostViewModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .notFound:
                    message("That post no longer exists.")
                case .failed(let words):
                    VStack(spacing: Spacing.m) {
                        Text(words).font(Typography.body).foregroundStyle(Palette.secondaryText)
                        Button("Try again") { Task { await model.load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    editor
                }
            }
            .background(Palette.background)
            .navigationTitle("Edit Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onClose).accessibilityIdentifier("editPost.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isSaving ? "Saving…" : "Save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("editPost.save")
                }
            }
            .task { await model.load() }
            .onChange(of: model.didSave) { _, saved in if saved { onClose() } }
        }
    }

    private func message(_ words: LocalizedStringKey) -> some View {
        Text(words)
            .font(Typography.body)
            .foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !model.canEdit {
                    Text("You can only edit your own posts.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                }
                if let failure = model.failureMessage {
                    Text(failure).font(Typography.caption).foregroundStyle(Palette.danger)
                }
                if let first = model.post?.media.first {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        RemoteImage(
                            url: first.thumbnailURL ?? first.url,
                            aspectRatio: MediaView.defaultRatio,
                            cornerRadius: Radius.card,
                            size: .medium
                        )
                        Text("Media cannot be changed after posting")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack {
                        Text("Caption").font(Typography.sectionTitle)
                        Spacer()
                        Text("\(model.caption.count)/\(ComposeViewModel.maxCharacters)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                    TextEditor(text: $model.caption)
                        .frame(minHeight: 96)
                        .font(Typography.body)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.s)
                        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.control))
                        .accessibilityIdentifier("editPost.caption")
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Tag a pet").font(Typography.sectionTitle)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.m) {
                            ForEach(model.pets) { pet in
                                Button { model.selectedPetID = pet.id } label: {
                                    VStack(spacing: Spacing.xs) {
                                        RemoteImage(
                                            url: pet.avatarURL, aspectRatio: 1,
                                            cornerRadius: Layout.minTouchTarget, size: .avatar
                                        )
                                        .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                                        .overlay {
                                            Circle().strokeBorder(
                                                model.selectedPetID == pet.id
                                                    ? Palette.brandPrimary : Palette.separator,
                                                lineWidth: model.selectedPetID == pet.id ? 2 : 1
                                            )
                                        }
                                        Text(pet.name).font(Typography.caption).lineLimit(1)
                                    }
                                    .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.primaryText)
                                .accessibilityIdentifier("editPost.pet.\(pet.id)")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Tags").font(Typography.sectionTitle)
                    TextField("Add tags (e.g. cat, cute)", text: $model.tagInput)
                        .font(Typography.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(Spacing.s)
                        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.control))
                        .onSubmit { model.commitTagInput() }
                        .accessibilityIdentifier("editPost.tagInput")
                    if !model.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.s) {
                                ForEach(model.tags, id: \.self) { tag in
                                    Button { model.removeTag(tag) } label: {
                                        Label("#\(tag)", systemImage: "xmark")
                                            .font(Typography.caption)
                                            .padding(.horizontal, Spacing.m)
                                            .frame(minHeight: Layout.minTouchTarget)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Palette.brandPrimary)
                                    .accessibilityLabel("Remove tag \(tag)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(Layout.pageInset)
        }
    }
}

/// The owner's menu on a post, plus the save control everybody gets.
///
/// A menu rather than a row of icons: delete needs a confirmation and pin needs
/// a label that says which way it goes, and neither survives being squeezed
/// into a glyph.
struct PostActionsMenu: View {
    @Bindable var model: PostActionsViewModel
    var onEdit: (String) -> Void
    /// Somebody else's post only, as on the web. Nil hides it.
    var onReport: (() -> Void)?
    /// Blocking the post's author. Somebody else's post only; nil hides it.
    var onBlock: (() -> Void)?

    @State private var isConfirmingDelete = false
    @State private var isConfirmingBlock = false

    var body: some View {
        Menu {
            Button {
                Task { await model.toggleBookmark() }
            } label: {
                Label(
                    model.isBookmarked ? "Remove from saved" : "Save",
                    systemImage: model.isBookmarked ? "bookmark.fill" : "bookmark"
                )
            }
            .accessibilityIdentifier("post.actions.bookmark")
            if model.isOwnPost {
                Button { onEdit(model.post.id) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .accessibilityIdentifier("post.actions.edit")
                Button {
                    Task { await model.togglePin() }
                } label: {
                    Label(
                        model.isPinned ? "Unpin from profile" : "Pin to profile",
                        systemImage: model.isPinned ? "pin.slash" : "pin"
                    )
                }
                .accessibilityIdentifier("post.actions.pin")
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("post.actions.delete")
            } else {
                if let onReport {
                    Button(role: .destructive, action: onReport) {
                        Label("Report", systemImage: "flag")
                    }
                    .accessibilityIdentifier("post.actions.report")
                }
                if onBlock != nil {
                    Button(role: .destructive) { isConfirmingBlock = true } label: {
                        Label("Block \(model.post.authorName)", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("post.actions.block")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
        }
        // One action at a time: a second tap while a delete is in flight would
        // otherwise be a second delete of a post that may already be gone.
        .disabled(model.isWorking)
        .accessibilityIdentifier("post.actions")
        .accessibilityLabel("Post actions")
        .task { await model.refresh() }
        .confirmationDialog(
            "Delete this post?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Says what is lost, because the cascade takes the comments and
            // likes with it and nothing brings them back.
            Text("The post, its comments and its likes are removed. This cannot be undone.")
        }
        .confirmationDialog(
            "Block @\(model.post.authorName)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { onBlock?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The web client's words, which say what a block does and does not
            // do: posts are public, so no block can hide them from anyone.
            Text("""
                They won't be able to comment on your posts or join your meetups, \
                and you won't see their posts. Your posts stay public, so they can \
                still be viewed by anyone.
                """)
        }
        // The model says "that did not go through" rather than pretending a
        // delete or pin happened. Until this alert, nothing on screen read it,
        // so a failed delete looked exactly like a tap that did nothing.
        .alert(
            "Couldn't complete that",
            isPresented: Binding(
                get: { model.failureMessage != nil },
                set: { if !$0 { model.failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.failureMessage = nil }
        } message: {
            Text(model.failureMessage ?? "")
        }
        .onChange(of: model.notice) { _, notice in
            guard let notice else { return }
            // Pinning has no other visible result on this screen; VoiceOver
            // users are told, and the menu's label already reads the new way
            // round for everyone else.
            AccessibilityNotification.Announcement(notice).post()
            model.notice = nil
        }
    }
}
