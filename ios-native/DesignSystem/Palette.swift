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
    /// What a card sits on: the web feed's slate-50 page under white cards.
    /// Grouped, so the pair keeps its contrast in dark mode too, where
    /// `secondaryBackground` and `cardBackground` are the same grey.
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    /// A card's soft shadow (`PostCard.tsx`'s shadow-[0_18px_40px_-28px]).
    static let cardShadow = Color.black.opacity(0.08)
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

    // MARK: Icons
    /// A control's icon at rest: the feed's bar buttons and a post's actions
    /// use this one grey, as the web client used one slate for its bars and
    /// posts (`Navbar.tsx`, `PostActions.tsx`). The tab bar's resting items
    /// are the system's colour on iOS 26, which does not take one from us.
    /// Selected or active is `brandPrimary`, except a like.
    static let iconInactive = secondaryText
    /// A post someone has liked: the web client's filled heart in red-500
    /// (`PostActions.tsx`), which is Tailwind 4's #FB2C36. An icon colour,
    /// not a text colour — 3.9:1 on white clears the 3:1 a graphic needs and
    /// not the 4.5:1 text does — so the count beside the heart stays grey.
    static let likeActive = Color("LikeActive", bundle: .main)

    // MARK: Brand accent
    /// The web client's `from-purple-500 to-pink-500` (Tailwind 4: #AD46FF,
    /// #F6339A): the sign-in screens' background (`AuthShell.tsx`), the
    /// Create button in the bottom bar (`BottomNav.tsx`) and the splash's
    /// wordmark (`SplashScreen.tsx`). Lighter than `brandGradient`, which is
    /// the 600s because white *text* sits on it; nothing on these two needs
    /// that, and the web drew them in the 500s.
    static let brandAccentStart = Color("BrandAccentStart", bundle: .main)
    static let brandAccentEnd = Color("BrandAccentEnd", bundle: .main)

    /// Left to right, for the Create circle and the wordmark (`to-r`).
    static var brandAccentGradient: LinearGradient {
        LinearGradient(colors: [brandAccentStart, brandAccentEnd], startPoint: .leading, endPoint: .trailing)
    }

    /// Corner to corner, for the sign-in screens' background (`to-br`).
    static var authBackground: LinearGradient {
        LinearGradient(colors: [brandAccentStart, brandAccentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The sign-in card's shadow (`shadow-2xl`).
    static let panelShadow = Color.black.opacity(0.25)

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

    /// What goes behind controls that sit on top of media.
    ///
    /// A `.regularMaterial` is the obvious choice and is right most of the
    /// time, but it is translucent by definition, so it is the wrong thing
    /// when Reduce Transparency is on — which is exactly the setting that asks
    /// for it not to be. This is the opaque substitute, and it belongs here
    /// rather than in each view so that the two stay in step.
    ///
    /// Opaque black at full strength: anything over arbitrary photographic
    /// content has no known background to compute a ratio against, so the only
    /// safe assumption is the worst one.
    static let opaqueScrim = Color.black
}
