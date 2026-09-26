import SwiftUI
import UIKit

/// The web client's Create button in the bottom bar (`BottomNav.tsx`): a
/// circle in the brand gradient, left to right, with a white plus — the one
/// place the bar uses colour, because it is the primary action.
///
/// A tab bar draws its items as templates, in one colour, which is how this
/// came out as a black square on 09-25. So the circle is drawn once into an
/// image marked `.alwaysOriginal`, which the bar shows as it is. The gradient
/// and the white are the palette's; nothing here names a colour of its own.
///
/// 30pt rather than the web's 36px: an iPhone tab bar lays its items out in
/// a fixed row, and 30 is what fits above the label without crowding it.
@MainActor
enum CreateTabIcon {
    static let image: UIImage = {
        let side: CGFloat = 30
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        // The web's purple-500 to pink-500 (`Palette.brandAccentGradient`).
        let start = UIColor(named: "BrandAccentStart") ?? .systemPurple
        let end = UIColor(named: "BrandAccentEnd") ?? .systemPink
        let white = UIColor(Palette.textOnBrand)
        let drawn = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let cg = context.cgContext
            cg.addEllipse(in: rect)
            cg.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [start.cgColor, end.cgColor] as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: side / 2),
                    end: CGPoint(x: side, y: side / 2),
                    options: []
                )
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: side / 2, weight: .bold)
            if let plus = UIImage(systemName: "plus", withConfiguration: configuration)?
                .withTintColor(white, renderingMode: .alwaysOriginal) {
                let size = plus.size
                plus.draw(in: CGRect(
                    x: (side - size.width) / 2,
                    y: (side - size.height) / 2,
                    width: size.width,
                    height: size.height
                ))
            }
        }
        return drawn.withRenderingMode(.alwaysOriginal)
    }()
}
