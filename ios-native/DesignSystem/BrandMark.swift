import SwiftUI

/// The PetNote paw: the web client's `PawIcon` (`src/components/PawIcon.tsx`),
/// from the same drawing as `public/paw-icon.svg`, which is carried over byte
/// for byte as the asset `BrandMark`.
///
/// Its own colours, always — brown pads and the one pink toe. It is not a
/// symbol and is never tinted: `template-rendering-intent` is `original` in
/// the asset and `.renderingMode(.original)` here, so neither the app's tint
/// nor a button style can recolour it. The SF Symbol `pawprint` this replaced
/// was a different drawing in the brand purple, which is a new logo rather
/// than the app's.
///
/// Sizes are the web client's, where there is one: 28 in the navigation bar
/// (`Navbar.tsx`), 64 on the splash (`SplashScreen.tsx`), 36 on the empty
/// feed (`Feed.tsx`).
struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        Image("BrandMark")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The feed bar's lockup, as the web client's navbar has it (`Navbar.tsx`):
/// the paw at 28 and the name beside it, semibold, at the leading edge.
///
/// It stands in for the bar's title, which the feed keeps as the bar's
/// identity and does not draw (FeedView's principal item takes its place):
/// a system title is centred on iOS 26, and a centred name with a paw off to
/// one side is not the lockup. So the name is ours, and it says for itself
/// that it is the heading the title was.
///
/// At the accessibility sizes the name is not drawn — only the paw, which
/// is a fixed 28 — and a long press shows the name large, as a system bar
/// title does instead of growing. Drawn at AX5 it took its own width
/// (`fixedSize`, needed so the default size is not squeezed to an ellipsis)
/// and pushed the account button out of the bar: 09-25's full regression,
/// `testTheAccountMenuIsUsableAtAX5`. VoiceOver reads the name either way.
struct FeedBrandLockup: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Spacing.s) {
            BrandMark(size: 28)
            if !typeSize.isAccessibilitySize {
                Text("PetNote")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
            }
        }
        // Its own width: a bar item is offered what is left after the others,
        // and on 09-25 that squeezed the name to an ellipsis beside the paw.
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("PetNote"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityShowsLargeContentViewer {
            Label { Text("PetNote") } icon: { Image("BrandMark").renderingMode(.original) }
        }
    }
}
