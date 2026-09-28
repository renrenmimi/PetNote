import SwiftUI
import Testing
import UIKit

@testable import PetNote

/// Contrast as an assertion, not as something to measure from a screenshot in
/// stage 6. Ratios are WCAG 2.1: 4.5:1 for body text, 3:1 for large text and
/// icons (engineering spec §5.3).
@MainActor
struct PaletteContrastTests {
    private func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// Composites over a background first: several system label colours are
    /// translucent, and contrast against a colour you can see through is
    /// meaningless without knowing what is behind it.
    private func components(_ color: UIColor, over background: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        color.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        background.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return (fr * fa + br * (1 - fa), fg * fa + bg * (1 - fa), fb * fa + bb * (1 - fa))
    }

    private func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ foreground: Color, on background: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        let bg = resolve(background, style)
        let fg = resolve(foreground, style)
        let lf = luminance(components(fg, over: bg))
        let lb = luminance(components(bg, over: bg))
        let hi = max(lf, lb), lo = min(lf, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    private let styles: [(UIUserInterfaceStyle, String)] = [(.light, "light"), (.dark, "dark")]

    @Test func bodyTextMeets45OnEverySurface() {
        for (style, name) in styles {
            for (surface, surfaceName) in [
                (Palette.background, "background"),
                (Palette.secondaryBackground, "secondaryBackground"),
                (Palette.cardBackground, "cardBackground"),
            ] {
                let ratio = contrast(Palette.primaryText, on: surface, style)
                #expect(ratio >= 4.5, "primaryText on \(surfaceName) in \(name): \(ratio)")
            }
        }
    }

    @Test func secondaryTextMeets45OnEverySurface() {
        for (style, name) in styles {
            for (surface, surfaceName) in [
                (Palette.background, "background"),
                (Palette.secondaryBackground, "secondaryBackground"),
                (Palette.cardBackground, "cardBackground"),
            ] {
                let ratio = contrast(Palette.secondaryText, on: surface, style)
                #expect(ratio >= 4.5, "secondaryText on \(surfaceName) in \(name): \(ratio)")
            }
        }
    }

    /// Non-essential only, so 3:1. Anything a person must be able to read uses
    /// secondaryText or better.
    @Test func tertiaryTextMeets3() {
        for (style, name) in styles {
            let ratio = contrast(Palette.tertiaryText, on: Palette.background, style)
            #expect(ratio >= 3.0, "tertiaryText on background in \(name): \(ratio)")
        }
    }

    /// brandPrimary is used for text and icons, so it carries the text threshold.
    @Test func brandPrimaryMeets45AsText() {
        for (style, name) in styles {
            let ratio = contrast(Palette.brandPrimary, on: Palette.background, style)
            #expect(ratio >= 4.5, "brandPrimary on background in \(name): \(ratio)")
        }
    }

    /// Both ends of the gradient, because a label sits across the whole sweep.
    ///
    /// This is the check that made us move off the web client's colours: white
    /// on its purple-500 → pink-500 is 4.12:1 and 3.58:1, both under 4.5. The
    /// 600-step versions used here are 5.53:1 and 4.54:1.
    @Test func whiteTextOnTheBrandGradientMeets45AtBothEnds() {
        for (style, name) in styles {
            for (end, endName) in [
                (Palette.brandGradientStart, "gradient start"),
                (Palette.brandGradientEnd, "gradient end"),
            ] {
                let ratio = contrast(Palette.textOnBrand, on: end, style)
                #expect(ratio >= 4.5, "white on \(endName) in \(name): \(ratio)")
            }
        }
    }

    /// 4.5, not 3: a status colour almost always has words beside it in the
    /// same colour, and splitting the two would be a distinction the code
    /// cannot enforce.
    @Test func statusColoursMeet45() {
        for (style, name) in styles {
            for (colour, colourName) in [
                (Palette.danger, "danger"),
                (Palette.success, "success"),
                (Palette.warning, "warning"),
            ] {
                let ratio = contrast(colour, on: Palette.background, style)
                #expect(ratio >= 4.5, "\(colourName) on background in \(name): \(ratio)")
            }
        }
    }
}
