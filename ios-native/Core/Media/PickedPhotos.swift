import Foundation
import Observation
import PhotosUI
import SwiftUI

/// Photos picked from the library to go with something being written — a
/// place, a review — and sent before it, as the web sends them.
///
/// Each one's preview is made once, as it is picked. Once one is up its
/// address is kept, so another try after the server refused sends only what
/// has not gone. Like the composer's, nothing here deletes an upload: one sent
/// before a later one failed is left behind.
@MainActor
@Observable
final class PickedPhotos {
    struct Photo: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let filename: String
        let thumbnail: UIImage?
        fileprivate(set) var uploaded: URL?
    }

    /// The server's limit for what they go with.
    let limit: Int
    private(set) var items: [Photo] = []
    /// While what they go with is being sent: nothing is added or taken out.
    var isLocked = false

    init(limit: Int) {
        self.limit = limit
    }

    var left: Int { limit - items.count }

    func add(data: Data, filename: String) {
        guard left > 0, !isLocked else { return }
        let side = PickedPhotosRows.thumbnailSide
        let thumbnail = PickedPreview.image(from: data, covering: CGSize(width: side, height: side))
        items.append(Photo(data: data, filename: filename, thumbnail: thumbnail))
    }

    func remove(_ id: Photo.ID) {
        guard !isLocked else { return }
        items.removeAll { $0.id == id }
    }

    /// Their addresses, in the order picked: one already up as it was, each
    /// of the rest prepared as the composer prepares a photo, off the main
    /// actor, and sent. One that fails stops the rest.
    func upload(with uploader: any MediaUploading) async throws -> [URL] {
        var urls: [URL] = []
        for photo in items {
            if let uploaded = photo.uploaded {
                urls.append(uploaded)
                continue
            }
            let data = photo.data, filename = photo.filename
            let prepared = try await Task.detached(priority: .userInitiated) {
                try UploadPreparation.prepareImage(data, filename: filename)
            }.value
            let asset = try await uploader.upload(UploadItem(
                data: prepared.data, filename: prepared.filename, mimeType: prepared.mimeType, resourceType: .image
            ))
            if let index = items.firstIndex(where: { $0.id == photo.id }) { items[index].uploaded = asset.url }
            urls.append(asset.url)
        }
        return urls
    }
}

/// The rows of a form's Photos section: what has been picked, each with the
/// way to take it out again, then the button to pick more while there is
/// room. The section's words are the form's.
struct PickedPhotosRows: View {
    static let thumbnailSide: CGFloat = 88

    let photos: PickedPhotos
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        if !photos.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(Array(photos.items.enumerated()), id: \.element.id) { index, photo in
                        PickedPhotoThumb(photo: photo, number: index + 1) { photos.remove(photo.id) }
                            .accessibilityIdentifier("photos.photo.\(index)")
                    }
                }
            }
        }
        if photos.left > 0 {
            PhotosPicker(
                selection: $selection, maxSelectionCount: photos.left,
                matching: .images, photoLibrary: .shared()
            ) {
                HStack(spacing: Spacing.s) {
                    // Decoration: the words say it.
                    Image(systemName: "photo.on.rectangle").accessibilityHidden(true)
                    Text(photos.items.isEmpty ? String(localized: "Add photos") : String(localized: "Add more photos"))
                }
                .frame(minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
            }
            .disabled(photos.isLocked)
            .accessibilityIdentifier("photos.add")
            .onChange(of: selection) { _, items in
                Task { await load(items) }
            }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            photos.add(data: data, filename: "photo.jpg")
        }
        selection = []
    }
}

/// One picked photo, with the way to take it out again.
private struct PickedPhotoThumb: View {
    let photo: PickedPhotos.Photo
    let number: Int
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = photo.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Palette.secondaryBackground
                }
            }
            .frame(width: PickedPhotosRows.thumbnailSide, height: PickedPhotosRows.thumbnailSide)
            .clipShape(.rect(cornerRadius: Radius.control))
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Photo \(number)"))
            Button(action: onRemove) {
                // Over a photo, so on the scrim, as the full-size image's
                // close button is.
                Image(systemName: "xmark")
                    .font(Typography.caption.weight(.bold))
                    .foregroundStyle(Palette.textOnBrand)
                    .padding(Spacing.xs)
                    .controlScrim()
                    .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Remove photo \(number)"))
        }
    }
}
