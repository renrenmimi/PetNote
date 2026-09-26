import SafariServices
import SwiftUI

/// The Terms of Service and the Privacy Policy.
///
/// Shown from the published web pages, the one place both texts live, so the
/// app and the web cannot disagree about what was agreed to. That is the
/// owner's decision about *where* the text is shown; it is not a claim that
/// the web text already describes the iPhone app — see
/// docs/legal-pages-ios-review.md for where it does not.
///
/// In an in-app Safari view, not a web view: the pages send
/// `frame-ancestors 'none'`, and the reader's way back is Safari's own Done
/// (the pages' "←" has no history to go back to in a fresh view).
enum LegalDocument: String, Identifiable, CaseIterable {
    case terms
    case privacy

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .terms: URL(string: "https://petnote.vercel.app/terms")!
        case .privacy: URL(string: "https://petnote.vercel.app/privacy")!
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .terms: "Terms of Service"
        case .privacy: "Privacy Policy"
        }
    }
}

/// Opens a legal page in-app, and gives the screen back on Done.
struct LegalPageSheet: UIViewControllerRepresentable {
    let document: LegalDocument

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: document.url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// The two links, side by side, for the foot of the sign-in and sign-up
/// screens.
struct LegalLinks: View {
    @State private var open: LegalDocument?

    var body: some View {
        HStack(spacing: Spacing.m) {
            ForEach(LegalDocument.allCases) { document in
                Button { open = document } label: {
                    Text(document.title)
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.brandPrimary)
                .accessibilityIdentifier("legal.\(document.rawValue)")
            }
        }
        .sheet(item: $open) { document in
            LegalPageSheet(document: document)
                .ignoresSafeArea()
        }
    }
}
