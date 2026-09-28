import CoreTransferable
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

// Sharing a post — the web client's share menu (`src/components/ShareMenu.tsx`)
// and its share card (`src/components/ShareCard.tsx`).

/// What a shared post says and where it points.
enum PostShareContent {
    /// The site a shared link opens in the production app. One place,
    /// because it is a decision rather than a detail: the web builds the link
    /// from whatever address it was loaded from — the live site is
    /// `petnote.vercel.app`, and its post page opens without signing in —
    /// while inside the old iPhone app that address is `capacitor://localhost`,
    /// a link nobody else can open. `petnote.app`, which the link handling
    /// accepts, has no DNS at all.
    static let site = URL(string: "https://petnote.vercel.app")!

    /// Where links point in this build. The site reads the production
    /// project, so a post from a test project would be a link that opens and
    /// finds nothing. Test builds link with the app's own scheme instead,
    /// which opens the post in a test build of the app and nowhere else.
    static var linksToTheSite: Bool { AppEnvironment.current.backend == .production }

    /// The one place a link is made, for a post or a place.
    static func link(path kind: String, id: String, toSite: Bool = linksToTheSite) -> URL {
        if toSite { return site.appending(path: kind).appending(component: id) }
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = kind
        // The id is one encoded component either way: a `/` in it cannot
        // make the link point anywhere else.
        let oneComponent = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + (id.addingPercentEncoding(withAllowedCharacters: oneComponent) ?? id)
        return components.url ?? site
    }

    /// The web's `SHARE_TITLE`, word for word.
    static var title: String { String(localized: "Check out this cute pet on PetNote!") }

    /// The id as one path component, encoded: a `/` in it cannot make the
    /// link point anywhere but a post.
    static func link(to postID: String, toSite: Bool = linksToTheSite) -> URL {
        link(path: "post", id: postID, toSite: toSite)
    }

    /// The first 100 characters of the post, as the web sends.
    static func text(of post: Post) -> String {
        String(post.text.prefix(100))
    }
}

/// A post as a picture: the photo, who posted it, the start of the text, a
/// few tags and the PetNote line. Made when the person picks where it goes,
/// not before, so opening the menu costs nothing.
struct PostShareCard: Transferable {
    let post: Post

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in
            try await card.pngData()
        }
        // Not the web's "petnote-share.png": a lowercase `petnote-` string in
        // the Release binary is what the package audit reads as a test
        // switch, and the audit's rule is simpler kept true than excused.
        .suggestedFileName("PetNote.png")
    }

    /// The web's canvas size, in points.
    static let size = CGSize(width: 400, height: 560)

    /// The first picture: the photo, or a video's poster. The web handed a
    /// video's own URL to an image loader and drew the grey box every time.
    var pictureURL: URL? {
        guard let first = post.media.first else { return nil }
        switch first.kind {
        case .image: return CloudinaryURL.optimized(first.url, size: .medium)
        case .video: return first.thumbnailURL ?? CloudinaryURL.videoPoster(first.url, size: .medium)
        }
    }

    func pngData() async throws -> Data {
        var picture: UIImage?
        if let url = pictureURL {
            // A picture that will not load leaves the grey box, as on the web;
            // the rest of the card is still worth sending.
            picture = try? await ImageLoader.shared.image(for: url, maxPixelSize: Self.size.width * 2)
        }
        return try await Self.render(post: post, picture: picture)
    }

    enum RenderError: Error { case noImage }

    @MainActor
    static func render(post: Post, picture: UIImage?) throws -> Data {
        let renderer = ImageRenderer(content: PostShareCardView(post: post, picture: picture))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(size)
        guard let data = renderer.uiImage?.pngData() else { throw RenderError.noImage }
        return data
    }
}

/// The card itself. A picture, not a screen: it is drawn light whatever the
/// phone is set to, and at the default text size, so it looks the same to
/// whoever receives it and the text always fits.
struct PostShareCardView: View {
    let post: Post
    let picture: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                } else {
                    Palette.secondaryBackground
                }
            }
            .frame(width: PostShareCard.size.width, height: PostShareCard.size.width)
            .clipped()

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(post.authorName.isEmpty ? String(localized: "PetNote User") : post.authorName)
                    .font(Typography.body.weight(.bold))
                    .foregroundStyle(Palette.primaryText)
                if !post.text.isEmpty {
                    Text(PostShareContent.text(of: post))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(3)
                }
                if !post.tags.isEmpty {
                    Text(post.tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.brandPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("🐾 Shared from PetNote")
                    .font(Typography.caption.weight(.bold))
                    .foregroundStyle(Palette.brandPrimary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            LinearGradient(
                colors: [Palette.brandGradientStart, Palette.brandGradientEnd],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
        }
        .frame(width: PostShareCard.size.width, height: PostShareCard.size.height)
        .background(Palette.background)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
    }
}

/// The share button on a post: copy the link, share it, or share the card.
/// iOS's own sheet does the sending, so there is no list of apps to keep here.
///
/// A plain button that opens the system's action sheet — the web's share menu
/// is a bottom action sheet too (`ShareMenu.tsx`) — whose choices hand over to
/// iOS's share sheet. It was a `Menu`, and a `Menu` is a UIKit control: a slow
/// drag that began on it did not move the list around it. Measured on
/// 2026-09-26, the same 200pt drag moved the feed 0pt from the share button
/// and 190pt from the like button beside it — and since the button moved next
/// to the comments, it is where a thumb scrolling the feed comes down.
struct PostShareMenu: View {
    let post: Post
    @State private var copied = false
    @State private var choosing = false
    @State private var sharing: ShareSheetRequest?

    var body: some View {
        Button { choosing = true } label: {
            // The system's share symbol rather than the web's paper plane:
            // this opens iOS's own share sheet, and that is the symbol iOS
            // uses for it. Same size and grey as the rest of the row.
            Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                .imageScale(.large)
                .foregroundStyle(copied ? Palette.success : Palette.iconInactive)
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("post.share")
        .accessibilityLabel("Share")
        .accessibilityValue(copied ? String(localized: "Link copied!") : "")
        .confirmationDialog("Share", isPresented: $choosing, titleVisibility: .automatic) {
            Button("Copy Link") {
                UIPasteboard.general.url = PostShareContent.link(to: post.id)
                copied = true
                AccessibilityNotification.Announcement(String(localized: "Link copied!")).post()
            }
            Button("Share to…") { sharing = .link(post) }
            Button("Share as Image") { sharing = .card(post) }
        } message: {
            if !PostShareContent.linksToTheSite {
                // Said where the link is made, not left to be discovered.
                Text("Test build: links open this app, not the website")
            }
        }
        .background(ShareSheetPresenter(request: $sharing))
        // The tick goes back to the share arrow after a moment.
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// What iOS's share sheet is asked to send for a post.
enum ShareSheetRequest: Equatable {
    /// The link, with the web's title as the subject and the start of the
    /// post as the message — what `shareLink` hands `navigator.share`.
    case link(Post)
    /// The post as a picture (`PostShareCard`), made now rather than when the
    /// menu opened, so opening the menu costs nothing.
    case card(Post)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.link(a), .link(b)), let (.card(a), .card(b)): a.id == b.id
        default: false
        }
    }

    @MainActor
    func activityItems() async -> [Any]? {
        switch self {
        case .link(let post):
            let link = ShareItemSource(item: PostShareContent.link(to: post.id), title: PostShareContent.title)
            let message = PostShareContent.text(of: post)
            return message.isEmpty ? [link] : [message, link]
        case .card(let post):
            // A card that cannot be drawn is not offered as an empty sheet.
            guard let data = try? await PostShareCard(post: post).pngData(),
                  let picture = UIImage(data: data) else { return nil }
            return [ShareItemSource(item: picture, title: PostShareContent.title)]
        }
    }
}

/// One thing to share, with the title the sheet shows above it and mail uses
/// as the subject.
final class ShareItemSource: NSObject, UIActivityItemSource {
    private let item: Any
    private let title: String

    init(item: Any, title: String) {
        self.item = item
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { item }

    func activityViewController(
        _ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? { item }

    func activityViewController(
        _ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String { title }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let url = item as? URL {
            metadata.originalURL = url
            metadata.url = url
        } else if let picture = item as? UIImage {
            metadata.imageProvider = NSItemProvider(object: picture)
        }
        return metadata
    }
}

/// Presents iOS's share sheet for a request, from a view controller behind the
/// share button.
///
/// Needed because a `ShareLink` can only be tapped, and the choice of what to
/// share is made in the action sheet. The share sheet waits for the action
/// sheet to finish going away rather than for a fixed time: presenting while
/// it is still leaving is refused by UIKit without an error.
struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var request: ShareSheetRequest?

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var isPreparing = false
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let request, !coordinator.isPreparing, host.presentedViewController == nil else { return }
        coordinator.isPreparing = true
        let binding = $request
        Task { @MainActor in
            defer { coordinator.isPreparing = false }
            guard let items = await request.activityItems() else {
                binding.wrappedValue = nil
                return
            }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, _, _, _ in binding.wrappedValue = nil }
            sheet.popoverPresentationController?.sourceView = host.view
            let present = { host.present(sheet, animated: true) }
            if let leaving = host.view.window?.rootViewController?.presentedViewController,
               leaving.isBeingDismissed, let transition = leaving.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in present() }
            } else {
                present()
            }
        }
    }
}
