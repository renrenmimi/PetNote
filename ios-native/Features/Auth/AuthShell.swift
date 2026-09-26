import SwiftUI

/// The frame for the three signed-out screens, as the web client's
/// `AuthShell.tsx` draws it: the brand gradient behind everything, and one
/// white card — the paw and the name, small, then the screen's own title and
/// form. Sign-in, sign-up and the password reset share it, as they do on the
/// web, so moving between them does not read as moving between products.
///
/// What stays native, as the owner asked:
///
/// - **Safe areas.** The gradient runs under the status bar, the home
///   indicator and the keyboard; the card never does. It sits in a scroll
///   view inside the safe area, centred when it fits and scrolling when it
///   does not.
/// - **The keyboard.** The scroll view is inside the keyboard's safe area, so
///   it shrinks when the keyboard rises and the focused field is kept in view
///   by the system — no delay and no measurement of our own, which is what
///   failed on the web when the Chinese candidate bar arrived late.
/// - **Dynamic Type.** Every text is a text style and the card only has a
///   maximum width, so the largest sizes grow the card downwards and scroll.
struct AuthShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                card
                    .padding(.horizontal, Layout.pageInset)
                    .padding(.vertical, Spacing.xl)
                    // Centred when it fits, as the web's `margin: auto` is.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background {
            // Under the keyboard too: the strip beneath it continues the
            // screen instead of interrupting it (the web set its keyboard
            // backdrop to the gradient's far end for the same reason).
            Palette.authBackground
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            // The brand once, small (`AuthShell.tsx`: paw 24 and the name).
            HStack(spacing: Spacing.s) {
                BrandMark(size: 24)
                Text("PetNote")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
            }
            .accessibilityElement(children: .combine)
            content
        }
        .padding(Spacing.xl)
        // The web's max-w-md: a card, not a page, on the widest screens.
        .frame(maxWidth: 448, alignment: .leading)
        .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.panel))
        .shadow(color: Palette.panelShadow, radius: 24, y: 12)
    }
}
