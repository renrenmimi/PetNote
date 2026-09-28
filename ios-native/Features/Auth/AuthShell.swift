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
///   failed on the web when the Chinese candidate bar arrived late. The card
///   is centred in the height the screen has *without* the keyboard
///   (`RestingHeight`), so the keyboard coming up, or its suggestion bar
///   changing, does not move a card that was already in view.
/// - **Dynamic Type.** Every text is a text style and the card only has a
///   maximum width, so the largest sizes grow the card downwards and scroll.
struct AuthShell<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var resting = RestingHeight()

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                card
                    .padding(.horizontal, Layout.pageInset)
                    .padding(.vertical, Spacing.xl)
                    // Centred when it fits, as the web's `margin: auto` is —
                    // in the height without the keyboard. Centred in the
                    // height *with* it, the whole card jumped 112pt when the
                    // email field took focus (measured on the iPhone 17
                    // simulator, 2026-09-26), and on the phone it jumped a
                    // second or two later, when the suggestion bar arrived:
                    // the device suite's tap on the password field landed
                    // where the field had just been, in ten of twelve tests.
                    .frame(maxWidth: .infinity, minHeight: resting.height(for: proxy.size))
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: proxy.size, initial: true) { _, size in resting.observe(size) }
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

/// The height the auth screens have with the keyboard down, per width.
///
/// The keyboard only ever takes height away and never changes the width, so
/// at one width the tallest height seen is the resting one. A new width — a
/// rotation, a resized window — starts again from what it is given.
struct RestingHeight: Equatable {
    private(set) var width: CGFloat = 0
    private(set) var height: CGFloat = 0

    mutating func observe(_ size: CGSize) {
        if size.width != width {
            width = size.width
            height = size.height
        } else {
            height = max(height, size.height)
        }
    }

    /// What to centre in: never less than the space there is.
    func height(for size: CGSize) -> CGFloat {
        size.width == width ? max(size.height, height) : size.height
    }
}
