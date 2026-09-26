import CoreGraphics

/// 4pt grid. Six steps only — a seventh would be a decision someone has to
/// justify, which is the point of naming them.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Two radii plus a capsule, per the engineering spec's §5.2.
enum Radius {
    static let card: CGFloat = 16
    static let control: CGFloat = 12
    /// The sign-in card (`AuthShell.tsx`'s rounded-3xl).
    static let panel: CGFloat = 24
}

enum Layout {
    /// Horizontal page inset, applied at page level rather than per component.
    static let pageInset: CGFloat = 16
    /// Minimum hit target. Undersized controls get `.contentShape` to reach it
    /// without growing visually.
    static let minTouchTarget: CGFloat = 44
}
