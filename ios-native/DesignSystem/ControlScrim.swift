import SwiftUI

/// The backing for a control that sits on top of media.
///
/// Controls over photographs and video have no known background to compute a
/// contrast ratio against — the next post's photo could be any colour at all —
/// so they need something behind them. A `.regularMaterial` pinned to its dark
/// variant is the right default: it names no colour, so it does not fight the
/// palette, and it keeps a white glyph readable over whatever is underneath.
///
/// But a material is translucent by definition, which makes it exactly the
/// wrong thing when Reduce Transparency is on — that setting is a person
/// saying the frosted effect is a problem for them. §6.5 asks for a solid
/// substitute, and this is where it happens.
///
/// It lives here, once, rather than at each call site for a reason that is not
/// tidiness: the two have to stay in step. A second place that reaches for a
/// material and forgets the substitution would satisfy no guard and no test,
/// and would only be found by someone who turns the setting on.
private struct ControlScrim: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            // Opaque, and deliberately the strongest one available: over
            // arbitrary photographic content there is no lighter colour that
            // can be shown to be safe.
            content
                .background(Palette.opaqueScrim, in: .circle)
                .environment(\.colorScheme, .dark)
        } else {
            content
                .background(.regularMaterial, in: .circle)
                .environment(\.colorScheme, .dark)
        }
    }
}

extension View {
    /// Backs a control that floats over media, honouring Reduce Transparency.
    func controlScrim() -> some View {
        modifier(ControlScrim())
    }
}
