import ImageIO
import SwiftUI
import UIKit

/// Filtered previews of picked photos: rendered off the main actor, from a
/// downscaled copy, and kept per photo and filter.
///
/// **One small copy per photo, shared.** The grid tile and all ten strip
/// swatches draw from the same decode, at the tile's size — the same 120pt
/// basis and the same quantisation step `ComposeThumbnail` always used — so
/// opening the strip decodes nothing new, and ten swatches asking at once for
/// the same photo start one decode between them, not ten.
///
/// **One render per picture, shared the same way.** The tile and the strip's
/// swatch for the chosen filter ask for the same key at the same moment;
/// whichever asks second waits for the first one's render rather than making
/// its own.
///
/// **Previews are the upload, smaller.** They go through the same
/// `PhotoFilterRenderer` as `UploadPreparation`, and `blur(0.5px)` is scaled
/// by the decode's size against the original's (see
/// `PhotoFilter.pixelsPerCSSPixel`), so what a swatch shows is what the feed
/// will show.
///
/// `NSCache` for the same reason `ImageLoader` uses it: it gives memory back
/// under pressure without an eviction policy of our own. Keys carry the item
/// id, which is a fresh UUID per pick, so nothing here can go stale — and a
/// removed photo's entries are dropped by `forget(itemID:)` rather than left
/// for the cache to find.
actor ComposeFilterPreviews {
    private let cache = NSCache<NSString, UIImage>()
    /// Decodes and renders in flight, by key, so concurrent callers for one
    /// picture share one.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Every key made for each photo, so a removed one's can be dropped.
    private var keysByItem: [String: Set<String>] = [:]
    /// Photos taken out of the composer. Work for one that finishes after it
    /// went is not kept, and nothing new is started for it.
    private var removed: Set<String> = []

    init() {
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// The pixel size every preview is drawn from.
    nonisolated static func pixelSize(displayScale: CGFloat) -> CGFloat {
        ImageLoader.quantizedPixels(120 * displayScale)
    }

    /// The photo with `filter` applied, at about `maxPixelSize` on its long
    /// edge. Nil when it cannot be decoded or rendered, or has been removed.
    func preview(
        of item: ComposeViewModel.PickedItem, filter: PhotoFilter, maxPixelSize: CGFloat
    ) async -> UIImage? {
        let key = Self.key(item.id, maxPixelSize, filter)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let pending = inFlight[key] { return await pending.value }
        guard let base = await base(of: item, maxPixelSize: maxPixelSize) else { return nil }
        guard filter != .normal else { return base }

        // Again, after the wait for the decode: another caller for this same
        // picture may have started its render, or finished it, meanwhile.
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let pending = inFlight[key] { return await pending.value }
        guard !removed.contains(item.id) else { return nil }

        let data = item.data
        let task = start(key, for: item.id) { Self.render(filter, over: base, pickedData: data) }
        return await settle(task, key: key, itemID: item.id)
    }

    /// Drops a removed photo's previews and stops waiting for its work.
    ///
    /// A render or decode already running is not interrupted — they are one
    /// synchronous call each — but one not yet started is skipped, and
    /// neither is kept when it lands.
    func forget(itemID: String) {
        removed.insert(itemID)
        for key in keysByItem[itemID] ?? [] {
            cache.removeObject(forKey: key as NSString)
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        keysByItem[itemID] = nil
    }

    private func base(of item: ComposeViewModel.PickedItem, maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.key(item.id, maxPixelSize, .normal)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let pending = inFlight[key] { return await pending.value }
        guard !removed.contains(item.id) else { return nil }

        let data = item.data
        let task = start(key, for: item.id) { Self.decode(data, maxPixelSize: maxPixelSize) }
        return await settle(task, key: key, itemID: item.id)
    }

    /// Starts `work` and records it as the one in flight for `key`.
    ///
    /// Synchronous, so the record is there before the caller's first
    /// suspension: a caller that arrives while the work runs finds it and
    /// waits, rather than starting its own.
    ///
    /// Detached, as in `ImageLoader`: work started inside an actor method
    /// inherits the actor, and a decode or render running *on* it would queue
    /// every other swatch's cache hit behind it.
    private func start(
        _ key: String, for itemID: String, _ work: @escaping @Sendable () -> UIImage?
    ) -> Task<UIImage?, Never> {
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled else { return nil }
            return work()
        }
        inFlight[key] = task
        keysByItem[itemID, default: []].insert(key)
        return task
    }

    /// Waits for `task` and keeps what it made — unless its photo was removed
    /// meanwhile.
    private func settle(_ task: Task<UIImage?, Never>, key: String, itemID: String) async -> UIImage? {
        let image = await task.value
        inFlight[key] = nil
        guard !removed.contains(itemID) else { return nil }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        return image
    }

    private nonisolated static func key(_ id: String, _ maxPixelSize: CGFloat, _ filter: PhotoFilter) -> String {
        "\(id)|\(Int(maxPixelSize))|\(filter.rawValue)"
    }

    /// Downsampled while decoding, so a 48-megapixel original never exists in
    /// memory at full size — the technique `ComposeThumbnail` used before it
    /// came through here.
    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// The small copy through `filter`, with the blur scaled against the
    /// photo as picked — the same rule the upload uses.
    private nonisolated static func render(_ filter: PhotoFilter, over base: UIImage, pickedData: Data) -> UIImage? {
        guard let cgImage = base.cgImage else { return nil }
        let originalLongSide = UploadPreparation.pixelSize(of: pickedData).map { max($0.width, $0.height) }
        guard let filtered = PhotoFilterRenderer.shared.render(
            filter, cgImage, originalLongSide: originalLongSide, for: .preview
        ) else { return nil }
        return UIImage(cgImage: filtered)
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}

/// The row of ten filters under the selected photo — the web client's
/// `ImageFilter` component: a swatch of the photo through each filter, its
/// label, and the chosen one outlined.
struct ComposeFilterStrip: View {
    let item: ComposeViewModel.PickedItem
    let selected: PhotoFilter
    let previews: ComposeFilterPreviews
    let onSelect: (PhotoFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Spacing.m) {
                ForEach(PhotoFilter.allCases) { filter in
                    Button {
                        onSelect(filter)
                    } label: {
                        VStack(spacing: Spacing.xs) {
                            ComposeFilterSwatch(item: item, filter: filter, previews: previews)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.control)
                                        .strokeBorder(
                                            filter == selected ? Palette.brandPrimary : Palette.separator,
                                            lineWidth: filter == selected ? 2 : 1
                                        )
                                }
                            Text(filter.label)
                                .font(Typography.caption)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(filter == selected ? Palette.brandPrimary : Palette.primaryText)
                    .accessibilityLabel(Text(filter.label))
                    .accessibilityAddTraits(filter == selected ? [.isSelected] : [])
                    .accessibilityIdentifier("compose.filter.\(filter.rawValue)")
                }
            }
            .padding(.vertical, Spacing.xs)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.filters")
    }
}

/// One filter's swatch. Its own view so each one loads, and re-loads, on its
/// own: choosing a different photo re-renders ten of these, and each shows
/// the moment its own render lands.
struct ComposeFilterSwatch: View {
    let item: ComposeViewModel.PickedItem
    let filter: PhotoFilter
    let previews: ComposeFilterPreviews

    /// The web client's `h-16 w-16`.
    static let side: CGFloat = 64

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Palette.secondaryBackground)
            .frame(width: Self.side, height: Self.side)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: Radius.control))
            .accessibilityHidden(true)
            .task(id: "\(item.id)|\(filter.rawValue)") { await loadPreview() }
    }

    private func loadPreview() async {
        let pixels = ComposeFilterPreviews.pixelSize(displayScale: displayScale)
        let loaded = await previews.preview(of: item, filter: filter, maxPixelSize: pixels)
        // A task whose id has moved on still finishes its await. Writing then
        // would put the previous photo or filter over the current one.
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
