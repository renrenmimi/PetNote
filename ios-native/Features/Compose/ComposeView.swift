import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// The composer.
///
/// Laid out to put the two things that can go wrong where they can be seen: the
/// stage label sits on the Share button itself, and a failed attempt turns that
/// button into "Retry" rather than offering a separate control — because
/// pressing it again is the *correct* recovery and anything that looks like a
/// second, different action invites publishing twice.
struct ComposeView: View {
    @Bindable var model: ComposeViewModel
    var onClose: () -> Void

    @State private var selection: [PhotosPickerItem] = []
    @State private var isLoadingSelection = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if model.restorableDraft != nil { draftBanner }
                    if let notice = model.notice { banner(notice, tone: Palette.secondaryText) }
                    if let failure = model.failureMessage { banner(failure, tone: Palette.danger) }

                    if !model.isEmailVerified {
                        verifyEmailNotice
                    } else if model.petsLoaded && model.pets.isEmpty {
                        noPetsNotice
                    } else {
                        mediaSection
                        captionSection
                        petSection
                        tagSection
                    }
                }
                .padding(Layout.pageInset)
            }
            .background(Palette.background)
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onClose)
                        .accessibilityIdentifier("compose.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) { shareButton }
            }
            .task { await model.start() }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                isLoadingSelection = true
                Task {
                    let picked = await ComposeMediaPicker.load(items)
                    model.add(picked)
                    model.persistDraft()
                    selection = []
                    isLoadingSelection = false
                }
            }
        }
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            Task { await model.share() }
        } label: {
            HStack(spacing: Spacing.xs) {
                if model.isWorking { ProgressView() }
                Text(model.phaseLabel)
            }
            .font(Typography.sectionTitle)
        }
        .disabled(!model.canShare || model.isWorking || isLoadingSelection)
        .accessibilityIdentifier("compose.share")
    }

    // MARK: - Sections

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 3),
                      spacing: Spacing.s) {
                ForEach(model.items) { item in
                    ComposeThumbnail(item: item) { model.remove(id: item.id); model.persistDraft() }
                }
                ForEach(model.uploadedAssets, id: \.publicID) { asset in
                    // Media a previous attempt already got onto the CDN. Shown
                    // because it is part of what pressing Share will publish —
                    // leaving it invisible is how somebody discards a draft
                    // believing there is nothing in it.
                    RemoteImage(
                        url: asset.thumbnailURL ?? asset.url,
                        aspectRatio: 1,
                        cornerRadius: Radius.control,
                        size: .thumbnail
                    )
                    .accessibilityLabel("Already uploaded")
                }
                if model.remainingSlots > 0 {
                    PhotosPicker(
                        selection: $selection,
                        maxSelectionCount: model.remainingSlots,
                        matching: .any(of: [.images, .videos])
                    ) {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .strokeBorder(Palette.separator, lineWidth: 1)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { Image(systemName: "plus").foregroundStyle(Palette.secondaryText) }
                    }
                    .accessibilityIdentifier("compose.addMedia")
                    .accessibilityLabel("Add photo or video")
                }
            }
            Text("\(model.items.count + model.uploadedAssets.count)/\(ComposeViewModel.maxFiles) files")
                .font(Typography.caption)
                .foregroundStyle(Palette.tertiaryText)
        }
    }

    private var captionSection: some View {
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
                .accessibilityIdentifier("compose.caption")
                .onChange(of: model.caption) { _, _ in model.persistDraft() }
        }
    }

    private var petSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Which pet is this about?").font(Typography.sectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.m) {
                    ForEach(model.pets) { pet in
                        Button {
                            model.selectedPetID = pet.id
                            model.persistDraft()
                        } label: {
                            VStack(spacing: Spacing.xs) {
                                RemoteImage(
                                    url: pet.avatarURL, aspectRatio: 1,
                                    cornerRadius: Layout.minTouchTarget, size: .avatar
                                )
                                .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                                .overlay {
                                    Circle().strokeBorder(
                                        model.selectedPetID == pet.id ? Palette.brandPrimary : Palette.separator,
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
                        .accessibilityIdentifier("compose.pet.\(pet.id)")
                        .accessibilityAddTraits(model.selectedPetID == pet.id ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Tags").font(Typography.sectionTitle)
            TextField("Add tags (e.g. cat, cute)", text: $model.tagInput)
                .font(Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(Spacing.s)
                .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.control))
                // Return commits. Space does **not**, unlike the web client,
                // where space also pages through an IME's candidate list and
                // committing on it turned half-typed Chinese into a tag. On iOS
                // the keyboard owns that interaction entirely and the app never
                // sees the keystroke, so the hazard is absent and the shortcut
                // would only cost multi-word intent.
                .onSubmit { model.commitTagInput() }
                .accessibilityIdentifier("compose.tagInput")
            if !model.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(model.tags, id: \.self) { tag in
                            Button {
                                model.removeTag(tag)
                            } label: {
                                Label("#\(tag)", systemImage: "xmark")
                                    .labelStyle(.titleAndIcon)
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

    // MARK: - Notices

    private var draftBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // Names what is actually in the draft. Photos are only in it if a
            // previous attempt uploaded them; ones that were merely picked are
            // not, and promising "your draft" without that qualification is a
            // promise the storage cannot keep.
            Text(draftBannerText).font(Typography.body)
            HStack(spacing: Spacing.m) {
                Button("Restore") { model.restoreDraft() }
                    .accessibilityIdentifier("compose.draft.restore")
                Button("Discard") { model.discardDraft() }
                    .accessibilityIdentifier("compose.draft.discard")
            }
            .font(Typography.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.card))
    }

    private var draftBannerText: String {
        let count = model.restorableDraft?.uploadedAssets.count ?? 0
        if count > 0 {
            return count == 1
                ? String(localized: "Unsaved draft, with 1 file already uploaded")
                : String(localized: "Unsaved draft, with \(count) files already uploaded")
        }
        return String(localized: "You have an unsaved draft (text, tags and pet — photos need picking again)")
    }

    private func banner(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verifyEmailNotice: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Please verify your email before posting").font(Typography.sectionTitle)
            Text("Check your inbox for a verification link from PetNote.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(Spacing.m)
        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.card))
    }

    private var noPetsNotice: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("You need to add a pet before posting").font(Typography.sectionTitle)
            Text("Add your pet profile first, then come back here.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(Spacing.m)
        .background(Palette.secondaryBackground, in: .rect(cornerRadius: Radius.card))
    }
}

/// A picked file's preview.
///
/// Decoded through ImageIO at thumbnail size rather than `UIImage(data:)`,
/// which would hold a full-resolution bitmap per tile — nine of those is how a
/// composer gets killed for memory on an older phone. Same technique and the
/// same quantisation step as `ImageLoader`, so a 110pt tile and a 120pt tile
/// ask for the same pixels.
struct ComposeThumbnail: View {
    let item: ComposeViewModel.PickedItem
    let onRemove: () -> Void

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Palette.secondaryBackground)
                        .overlay {
                            Image(systemName: item.kind == .video ? "film" : "photo")
                                .foregroundStyle(Palette.tertiaryText)
                        }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.control))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .padding(Spacing.xs)
                    .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.primaryText)
            .accessibilityLabel("Remove file")
        }
        .task(id: item.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard item.kind == .image else { return }
        let pixels = ImageLoader.quantizedPixels(120 * displayScale)
        let data = item.data
        image = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
