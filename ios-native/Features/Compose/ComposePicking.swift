import AVFoundation
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns what the photo picker hands back into something the composer can post.
///
/// `PHPickerViewController` — which is what `PhotosPicker` is — needs no photo
/// library permission and never shows the whole library to the process. That is
/// the native answer to a file input, and it is a better one: the app sees only
/// the items the person chose.
///
/// Images arrive as `Data` and go straight to `UploadPreparation`, which reads
/// HEIC natively. Videos are copied to a file first so their duration can be
/// read and so the bytes can be memory-mapped rather than held resident — an
/// 80 MB video as a `Data` in RAM is most of a small phone's budget for one
/// post.
enum ComposeMediaPicker {
    /// A video, fetched as a file rather than as bytes.
    struct PickedMovie: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { movie in
                SentTransferredFile(movie.url)
            } importing: { received in
                // The received file is deleted when this closure returns, so
                // it has to be copied somewhere we own.
                let suffix = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("petnote-\(UUID().uuidString).\(suffix)")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: received.file, to: copy)
                return PickedMovie(url: copy)
            }
        }
    }

    static func load(_ selection: [PhotosPickerItem]) async -> [ComposeViewModel.PickedItem] {
        var picked: [ComposeViewModel.PickedItem] = []
        for item in selection {
            if let loaded = await load(item) { picked.append(loaded) }
        }
        return picked
    }

    static func load(_ item: PhotosPickerItem) async -> ComposeViewModel.PickedItem? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        // The picker's own identifier, when it has one: a stable identity for
        // the underlying asset, which is what the duplicate check wants. The
        // web client synthesises one from name+size+lastModified because a
        // browser gives it nothing better.
        let sourceID = item.itemIdentifier ?? UUID().uuidString

        if isVideo {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return nil }
            // Mapped, not read: the bytes stay on disk until the upload walks
            // them.
            guard let data = try? Data(contentsOf: movie.url, options: .mappedIfSafe) else { return nil }
            let duration = await self.duration(of: movie.url)
            return ComposeViewModel.PickedItem(
                id: UUID().uuidString,
                sourceID: sourceID,
                kind: .video,
                data: data,
                filename: movie.url.lastPathComponent,
                mimeType: mimeType(forExtension: movie.url.pathExtension) ?? "video/quicktime",
                duration: duration
            )
        }

        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = UploadPreparation.imageType(of: data)
        return ComposeViewModel.PickedItem(
            id: UUID().uuidString,
            sourceID: sourceID,
            kind: .image,
            data: data,
            filename: "photo.\(fileExtension(for: type))",
            mimeType: type.map(UploadPreparation.mimeType(for:)) ?? "image/jpeg",
            duration: nil
        )
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }

    static func fileExtension(for utType: String?) -> String {
        guard let utType, let type = UTType(utType) else { return "jpg" }
        return type.preferredFilenameExtension ?? "jpg"
    }

    static func mimeType(forExtension pathExtension: String) -> String? {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType
    }
}
