import UIKit

/// A photo picked from the library, made small enough to show while it waits
/// to be uploaded, and not smaller than the space it is shown in.
///
/// `preparingThumbnail(of:)` fits a photo inside the size it is given and
/// keeps its shape, so asking for the size of the space leaves the short side
/// short of it: a 4:3 photo asked for 200 by 200 comes back 200 by 150, and a
/// square cut from that is soft on a phone. This asks for enough to cover the
/// space instead, at the phones' three pixels a point.
enum PickedPreview {
    static let pixelsPerPoint: CGFloat = 3

    static func image(from data: Data, covering points: CGSize) -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(
            points.width * pixelsPerPoint / image.size.width,
            points.height * pixelsPerPoint / image.size.height
        )
        // Never larger than the photo is.
        guard scale < 1 else { return image }
        return image.preparingThumbnail(of: CGSize(
            width: (image.size.width * scale).rounded(.up), height: (image.size.height * scale).rounded(.up)
        ))
    }
}
