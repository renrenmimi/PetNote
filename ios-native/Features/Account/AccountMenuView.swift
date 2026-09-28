import SwiftUI

/// The account entry, and the menu behind it.
///
/// Sign-out used to live in the navigation bar as a bare "Sign out" button.
/// Two things were wrong with that and only one of them was the measurement:
///
///   1. **The bar lays its items out, not us.** The touch region of a
///      `ToolbarItem`'s SwiftUI `Button` is the bar's content box, and adding
///      `.frame(minHeight:)`, padding or a `.contentShape` at the call site
///      moved none of it (`SignedInView` and `HitRegionBoundaryUITests` both
///      record the attempts). The height landed in [43.438, 44.062) — an
///      interval straddling the requirement that no tap can close, because
///      certifying it would mean aiming inside a 0.063pt window. A control
///      whose size we cannot state is a control in the wrong place.
///   2. **The bar is one tap from ending the session.** Nothing separates
///      brushing the top-right corner from signing out.
///
/// Moving it here fixes both with the same move: the entry opens a menu, the
/// menu is laid out by us, and ending the session is a second, deliberate tap
/// on a row whose hit region is ours to set and ours to measure.
///
/// **Deliberately not a settings screen.** An account entry and a sign-out
/// row, and nothing else — no avatar editing, no notification switches, no
/// about page. The one non-interactive line is the signed-in address, which is
/// not a feature but the answer to "whose session am I about to end".
struct AccountMenuButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            // Opening only. The session is ended from inside the menu, by a
            // separate tap on a separate control — see AccountMenuView.
            isPresented = true
        } label: {
            Image(systemName: "person.crop.circle")
        }
        // On the Button, not on a container around it. `root.signedIn` on a
        // container once overwrote the identifier of every element beneath it,
        // and `detail.post` and `feed.error` did the same thing afterwards.
        .accessibilityIdentifier("account.menu")
        // Without this, VoiceOver announces the symbol's own name. The label
        // says what the control is; the hint says what happens, which is the
        // part that tells someone this is not the sign-out button any more.
        .accessibilityLabel("Account")
        .accessibilityHint("Opens the account menu")
    }
}

/// The menu itself: who is signed in, and the one action a session has.
struct AccountMenuView: View {
    let email: String
    let onSignOut: () -> Void
    /// Leaving without doing anything.
    ///
    /// Until this existed the sheet held exactly one control and it ended the
    /// session. A SwiftUI sheet does not dismiss when the dimmed area behind
    /// it is tapped — `closeAccountMenu` in the UI tests records measuring
    /// that — so the only way out was a drag, advertised by nothing but the
    /// grabber. Someone who opened this by brushing the corner of the bar had
    /// a choice between a gesture they may not know and the one button on
    /// screen, which signs them out.
    let onClose: () -> Void

    /// The sheet's resting height: enough for the header and one row at the
    /// default type size. Not a design token — it is a fact about this sheet's
    /// contents rather than a value other screens should share, and
    /// `DesignSystem/` is not ours to add to.
    static let preferredHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            signOutRow
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.background)
        // No .accessibilityIdentifier and no .accessibilityAction on this
        // stack. An `.accessibilityAction` on a container in this project
        // turned a child button's reported rectangle into 603x874 at x=-100 —
        // every tap then landed somewhere other than where the control was
        // drawn, and the tests still found an element to "tap".
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Account")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("account.title")
                Text(email)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("account.email")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            closeButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.pageInset)
        .padding(.top, Spacing.xl)
        // A step more than the header would need on looks alone. Measured:
        // the row's hit region reaches about 14.7pt above the rectangle it is
        // drawn in, which at `Spacing.l` left only 0.8pt of clear space
        // between the bottom of the address and the top of a region that ends
        // the session. Padding is the right place to absorb that; the line
        // above it is not.
        .padding(.bottom, Spacing.xl)
    }

    /// The way out, in the corner a sheet's way out is looked for.
    ///
    /// At the top rather than as a second row under sign-out, and that is the
    /// whole point of where it is: a menu that opened by accident should have
    /// the harmless control under the thumb that is coming down, not the one
    /// that ends the session. Height and shape on the label, as everywhere
    /// else here — on the Button they move where it sits and leave the hit
    /// region behind.
    private var closeButton: some View {
        Button(action: onClose) {
            Text("Close")
                .font(Typography.body)
                .foregroundStyle(Palette.brandPrimary)
                // `.lineLimit(1)` with `.fixedSize()`: at the accessibility
                // type sizes a wrapping "Close" would squeeze the address next
                // to it into a column two characters wide.
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("account.close")
        .accessibilityHint("Closes the account menu without signing out")
    }

    private var signOutRow: some View {
        Button(action: onSignOut) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    // The row already says "Sign out"; announcing the glyph as
                    // well reads the same control twice.
                    .accessibilityHidden(true)
                Text("Sign out")
                    .font(Typography.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, Layout.pageInset)
            // Height and shape on the LABEL, never on the Button. On the
            // Button, `.frame(minHeight:)` moves where the control sits and
            // leaves the hit region where it was — that is exactly how a 20pt
            // sign-out control shipped once already.
            //
            // One grid step above the 44pt minimum, on purpose. At exactly 44
            // the pass/fail verdict turns on rounding at the last device
            // pixel, which is the ambiguity that made the navigation-bar
            // button unmeasurable; a row with headroom gives a measurement
            // that says something.
            .frame(
                maxWidth: .infinity,
                minHeight: Layout.minTouchTarget + Spacing.m,
                alignment: .leading
            )
            .contentShape(.rect)
        }
        .accessibilityIdentifier("session.signOut")
    }
}
