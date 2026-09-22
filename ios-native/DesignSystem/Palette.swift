import SwiftUI

/// Every colour the app is allowed to use, named by what it means.
///
/// Two sources, on purpose:
///
///   - **Neutrals delegate to the system's semantic colours** rather than
///     copying their values into the asset catalog. The system ones already
///     track light/dark, Increase Contrast, and Reduce Transparency, and they
///     follow the platform when it changes. A copied hex would silently drift
///     from the OS and would ignore those accessibility settings.
///   - **Brand colours live in `Palette.xcassets`**, because they are ours and
///     the system has no opinion about them.
///
/// Either way nothing outside this file names a colour, and no view writes a
/// hex — `DesignSystemGuardTests` fails the build's test run if one appears.
enum Palette {
    // MARK: Surfaces
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    /// Cards sit on the page rather than float: §5.2 says separate them with
    /// background colour, not shadow.
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)

    // MARK: Text
    static let primaryText = Color(uiColor: .label)
    /// Measured, not inherited: the system's `secondaryLabel` is 3.44:1 on a
    /// white page, under the 4.5:1 body-text threshold. Dark mode's system
    /// value does clear it, so only the light value is replaced. Same reasoning
    /// for `tertiaryText`, which carries the 3:1 non-essential threshold and
    /// must never be the only way something is communicated.
    static let secondaryText = Color("SecondaryText", bundle: .main)
    static let tertiaryText = Color("TertiaryText", bundle: .main)
    static let textOnBrand = Color.white

    // MARK: Brand
    /// Used for text and icons, so it is contrast-checked against the page
    /// background in both modes (`PaletteContrastTests`).
    static let brandPrimary = Color("BrandPrimary", bundle: .main)
    static let brandGradientStart = Color("BrandGradientStart", bundle: .main)
    static let brandGradientEnd = Color("BrandGradientEnd", bundle: .main)

    /// The brand mark, kept for identity — never as a large background area.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandGradientStart, brandGradientEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: Status
    /// Also measured. On a white page the system greens and oranges are 2.22:1
    /// and 2.31:1 — below even the 3:1 icon threshold, let alone 4.5:1 for the
    /// text that usually sits next to them. Dark mode keeps the system values,
    /// which measure 8.42:1 and 7.62:1.
    static let danger = Color("StatusDanger", bundle: .main)
    static let success = Color("StatusSuccess", bundle: .main)
    static let warning = Color("StatusWarning", bundle: .main)
    /// Disabled state is deliberately low contrast — it means "not available",
    /// and it is never the only signal.
    static let disabled = Color(uiColor: .quaternaryLabel)
}
