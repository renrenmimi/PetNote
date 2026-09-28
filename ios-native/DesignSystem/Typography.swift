import SwiftUI

/// Four semantic levels, everything else derived from them.
///
/// Only `Font.TextStyle` is used — never a fixed point size — so Dynamic Type
/// moves the whole interface. The web client needed a whole utility
/// (src/utils/dynamicType.ts) to work around Tailwind's rem scale being pinned
/// to a 16px root, which made iOS's text-size setting do nothing. Native gets
/// this right by default, which is a reason to not reintroduce the problem by
/// hardcoding sizes.
enum Typography {
    /// Screen title. One per screen.
    static let pageTitle = Font.largeTitle
    /// Section heading inside a screen.
    static let sectionTitle = Font.headline
    /// Body copy: post text, comments.
    static let body = Font.body
    /// Supporting detail: timestamps, counts, hints.
    static let caption = Font.footnote
}

extension View {
    /// Clamps a piece of UI that genuinely cannot grow without breaking — a
    /// fixed-height control, say. Used sparingly: the default is to let text
    /// grow and let the layout reflow.
    func clampedDynamicType(max: DynamicTypeSize = .accessibility3) -> some View {
        dynamicTypeSize(...max)
    }
}
