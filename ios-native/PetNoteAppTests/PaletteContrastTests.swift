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

// MARK: - What is drawn, not what is defined

/// The gap the token tests leave open.
///
/// Every test above measures a *token* against a *surface*. That is not what a
/// person reads: a view can take a compliant token and render it at 60% opacity,
/// and the ratio on screen is then whatever the composite works out to. The
/// token tests stay green throughout, because nothing they look at changed.
///
/// So these tests measure the composites the app actually draws, found by
/// reading the views rather than by assuming they draw tokens at full strength.
/// `grep -rn '\.opacity(' App Core Features` is how the list was built; if a new
/// one appears it belongs here.
@MainActor
struct RenderedContrastTests {
    private func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func rgb(_ color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// `foreground` drawn at `opacity` over `background`, as a view modifier
    /// would compose it — the modifier multiplies into the alpha, it does not
    /// replace it.
    private func contrast(
        _ foreground: Color,
        on background: Color,
        opacity: CGFloat,
        _ style: UIUserInterfaceStyle
    ) -> CGFloat {
        let fg = rgb(resolve(foreground, style))
        let bg = rgb(resolve(background, style))
        let alpha = fg.a * opacity
        let composited = (
            r: fg.r * alpha + bg.r * (1 - alpha),
            g: fg.g * alpha + bg.g * (1 - alpha),
            b: fg.b * alpha + bg.b * (1 - alpha)
        )
        let lf = luminance(composited)
        let lb = luminance((bg.r, bg.g, bg.b))
        return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
    }

    private let styles: [(UIUserInterfaceStyle, String)] = [(.light, "light"), (.dark, "dark")]

    /// `PostDetailView.CommentRow` draws the whole row at `.opacity(0.6)` while
    /// a comment is in flight — which is the state 5C.4 puts every new comment
    /// into, on purpose, for as long as the round trip takes.
    ///
    /// Two labels inside that row carry the contrast requirement: the author
    /// name (`secondaryText`, body threshold 4.5:1) and "Sending…"
    /// (`tertiaryText`, 3:1). Neither is decorative — the second one is the only
    /// thing telling the person the comment has not been posted yet.
    @Test func pendingCommentRowStaysReadable() {
        for (style, name) in styles {
            let author = contrast(Palette.secondaryText, on: Palette.background, opacity: 1, style)
            #expect(author >= 4.5, "pending comment author name in \(name): \(author)")

            let sending = contrast(Palette.tertiaryText, on: Palette.background, opacity: 1, style)
            #expect(sending >= 3.0, "pending comment \"Sending…\" in \(name): \(sending)")

            let body = contrast(Palette.primaryText, on: Palette.background, opacity: 1, style)
            #expect(body >= 4.5, "pending comment text in \(name): \(body)")
        }
    }

    /// The thresholds above only mean anything while the row is actually drawn
    /// at full strength.
    ///
    /// This test was written against a row that dimmed itself to 0.6, and at
    /// that strength the author name measured 2.57:1 in light and the
    /// "Sending…" label 2.13:1. The view no longer does that. But a test that
    /// checks tokens in isolation cannot see an `.opacity()` reappearing on
    /// the row — that is precisely how the original defect went unnoticed —
    /// so the absence is asserted against the source, not assumed.
    @Test func thePendingRowDoesNotDimItself() throws {
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Features/PostDetail/PostDetailView.swift")
        let text = try String(contentsOf: view, encoding: .utf8)

        let offenders = text.components(separatedBy: .newlines).enumerated().filter { _, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { return false }
            return line.contains(".opacity(")
        }.map { "line \($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        #expect(
            offenders.isEmpty,
            """
            An opacity is back in the comment detail view. Whatever it dims, \
            the ratios asserted above stop describing what is on screen:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Full strength, for the same three, so a failure above can be read as
    /// "the opacity did it" rather than "the token was always wrong".
    @Test func theSameLabelsAtFullStrengthAreFine() {
        for (style, name) in styles {
            #expect(contrast(Palette.secondaryText, on: Palette.background, opacity: 1, style) >= 4.5,
                    "secondaryText at full strength in \(name)")
            #expect(contrast(Palette.tertiaryText, on: Palette.background, opacity: 1, style) >= 3.0,
                    "tertiaryText at full strength in \(name)")
        }
    }

    /// The brand gradient is a sweep, and a label sits across all of it. The
    /// token test checks the two ends; this checks the middle, because "both
    /// ends pass" only implies "the middle passes" if the ratio is monotonic
    /// along the sweep, which is an assumption and not a fact.
    @Test func whiteOnTheBrandGradientMeets45AllTheWayAcross() {
        for (style, name) in styles {
            let start = rgb(resolve(Palette.brandGradientStart, style))
            let end = rgb(resolve(Palette.brandGradientEnd, style))
            for step in 0...20 {
                let t = CGFloat(step) / 20
                let mix = UIColor(
                    red: start.r + (end.r - start.r) * t,
                    green: start.g + (end.g - start.g) * t,
                    blue: start.b + (end.b - start.b) * t,
                    alpha: 1
                )
                let ratio = contrast(Palette.textOnBrand, on: Color(uiColor: mix), opacity: 1, style)
                #expect(ratio >= 4.5, "white on gradient t=\(t) in \(name): \(ratio)")
            }
        }
    }

    /// Not an assertion — a record. Disabled controls are outside WCAG 1.4.3,
    /// and `Palette.disabled` is low contrast on purpose. It is written down
    /// because the palette says disabled "is never the only signal", and on the
    /// sign-in button it currently is: the label still reads "Sign in" and only
    /// the background changes.
    @Test func recordTheDisabledSubmitButtonRatio() {
        for (style, name) in styles {
            let ratio = contrast(Palette.textOnBrand, on: Palette.disabled, opacity: 1, style)
            print("MEASURED disabled submit button, white on Palette.disabled, \(name): \(ratio)")
        }
    }
}
