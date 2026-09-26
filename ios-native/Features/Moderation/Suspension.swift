import FirebaseFirestore
import SwiftUI

// The web client's `SuspendedBanner`: a line across the top of every screen
// while the signed-in account is banned. It changes nothing the account can
// do — the server refuses a banned account's writes either way — it says why.

/// Whether an account is suspended, from where the web client reads it:
/// `users/{uid}/admin/state`, `banned == true`. The owner may read that
/// document (`firestore.rules`, `match /admin/state`).
protocol SuspensionReading: Sendable {
    func isSuspended(uid: String) async throws -> Bool
}

actor FirestoreSuspensionSource: SuspensionReading {
    private let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    func isSuspended(uid: String) async throws -> Bool {
        let snapshot = try await db.collection("users").document(uid)
            .collection("admin").document("state").getDocument()
        return Suspension.isSuspended(snapshot.data())
    }
}

enum Suspension {
    /// Only an explicit `true`. A missing document or field is the normal
    /// state of every account that was never banned — the rules' own
    /// `isNotBanned()` reads it the same way.
    static func isSuspended(_ adminState: [String: Any]?) -> Bool {
        (adminState?["banned"] as? Bool) == true
    }
}

/// In the layout, not over it: the web's banner was moved from `fixed` to
/// `sticky` because a fixed one covered every page's top bar. Here it sits
/// under each screen's own top bar (`suspendedBanner(_:)`). Hung on the tab
/// view instead, it was drawn over the navigation bar — the same defect,
/// found by `SuspensionUITests` measuring the two frames.
///
/// The words are drawn in the page's own background colour, not white. White
/// on the dark-mode danger red is 3.4:1; background on danger is the pair
/// `PaletteContrastTests.statusColoursMeet45` already holds to 4.5 in both
/// appearances — contrast does not care which of the two is in front.
struct SuspendedBanner: View {
    var body: some View {
        Text("Your account has been suspended.")
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Palette.background)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.s)
            .background(Palette.danger, ignoresSafeAreaEdges: [])
            .accessibilityIdentifier("suspended.banner")
    }
}

extension View {
    /// The banner under this screen's top bar. Applied to the root of each
    /// tab and to every pushed screen, so no screen of either stack is
    /// without it.
    func suspendedBanner(_ shown: Bool) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if shown { SuspendedBanner() }
        }
    }
}
