import CoreGraphics
import Testing

@testable import PetNote

/// The sign-in card is centred in the height without the keyboard, so the
/// keyboard rising does not move it. See `AuthShell`.
struct RestingHeightTests {
    @Test func theKeyboardRisingDoesNotChangeTheHeightToCentreIn() {
        var resting = RestingHeight()
        resting.observe(CGSize(width: 402, height: 815))
        // The keyboard, then its suggestion bar.
        resting.observe(CGSize(width: 402, height: 480))
        resting.observe(CGSize(width: 402, height: 436))
        #expect(resting.height(for: CGSize(width: 402, height: 436)) == 815)
    }

    @Test func itIsNeverLessThanTheSpaceThereIs() {
        var resting = RestingHeight()
        resting.observe(CGSize(width: 402, height: 600))
        #expect(resting.height(for: CGSize(width: 402, height: 700)) == 700)
    }

    /// A rotation or a resized window is a new screen, not a keyboard.
    @Test func aNewWidthStartsAgain() {
        var resting = RestingHeight()
        resting.observe(CGSize(width: 402, height: 815))
        resting.observe(CGSize(width: 874, height: 361))
        #expect(resting.height(for: CGSize(width: 874, height: 361)) == 361)
        // Before the new width is observed, the space itself is used.
        #expect(RestingHeight().height(for: CGSize(width: 320, height: 500)) == 500)
    }
}
