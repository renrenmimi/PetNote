import SwiftUI

/// "For You" and "Following" over the feed: the web client's tab strip
/// (src/pages/Feed.tsx:452-492). Two equal halves, the chosen one in the body
/// colour and the other in the secondary one, a hairline under both, and a
/// bar under the chosen half that slides across to the other.
///
/// The bar is the brand purple, not the gradient: the old iPhone app
/// (`feature/ios-polish-round2`) made it a solid accent because "the brand
/// gradient is worth one thing per screen — the primary action".
///
/// Two differences from the web, both deliberate:
///   - **44pt tall where the web's is about 30.** Here the halves are the
///     controls, and a control is `Layout.minTouchTarget`.
///   - **The list's first row, so it scrolls away with the list.** The web's
///     strip is sticky. Pinned under this bar it would sit over the top 44pt
///     of whichever list is showing, for good: every card would pass under it
///     on its way to the bar, and a control there is on screen and cannot be
///     touched. Scrolled away, it is waiting where the list starts.
struct FeedTabStrip: View {
    @Binding var selection: FeedTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            half(.forYou, title: "For You")
            half(.following, title: "Following")
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) { indicator }
        .padding(.horizontal, Layout.pageInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.tabs")
    }

    private func half(_ tab: FeedTab, title: LocalizedStringKey) -> some View {
        Button {
            selection = tab
        } label: {
            Text(title)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(selection == tab ? Palette.primaryText : Palette.secondaryText)
                .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Which one is showing is said, not only drawn.
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier("feed.tab.\(tab.rawValue)")
    }

    private var indicator: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Palette.brandPrimary)
                .frame(width: geometry.size.width / 2, height: 2)
                .offset(x: selection == .forYou ? 0 : geometry.size.width / 2)
        }
        .frame(height: 2)
        // The web's 300ms slide; none at all with Reduce Motion on.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: selection)
        .accessibilityHidden(true)
    }
}
