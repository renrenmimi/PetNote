import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// Sharing a post — the web client's share menu (`src/components/ShareMenu.tsx`)
// and its share card (`src/components/ShareCard.tsx`).

/// What a shared post says and where it points.
enum PostShareContent {
    /// The site a shared link opens. One place, because it is a decision
    /// rather than a detail: the web builds the link from whatever address it
    /// was loaded from, which inside the old iPhone app is
    /// `capacitor://localhost` — a link nobody else can open. This is the live
    /// site, the same one the terms and privacy pages come from, and its post
    /// page opens without signing in. `petnote.app`, which the link handling
    /// accepts, does not answer today.
    ///
    /// The site reads the production project, so a post shared from a test
    /// build is one it will not find.
    static let site = URL(string: "https://petnote.vercel.app")!

    /// The web's `SHARE_TITLE`, word for word.
    static var title: String { String(localized: "Check out this cute pet on PetNote!") }

    /// The id as one path component, encoded: a `/` in it cannot make the
    /// link point anywhere but a post.
    static func link(to postID: String) -> URL {
        site.appending(path: "post").appending(component: postID)
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
        .suggestedFileName("petnote-share.png")
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
struct PostShareMenu: View {
    let post: Post
    @State private var copied = false

    var body: some View {
        Menu {
            Button {
                UIPasteboard.general.url = PostShareContent.link(to: post.id)
                copied = true
                AccessibilityNotification.Announcement(String(localized: "Link copied!")).post()
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            ShareLink(
                item: PostShareContent.link(to: post.id),
                subject: Text(PostShareContent.title),
                message: Text(PostShareContent.text(of: post))
            ) {
                Label("Share to…", systemImage: "square.and.arrow.up")
            }
            ShareLink(
                item: PostShareCard(post: post),
                preview: SharePreview(PostShareContent.title)
            ) {
                Label("Share as Image", systemImage: "photo")
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                .foregroundStyle(copied ? Palette.success : Palette.secondaryText)
                .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("post.share")
        .accessibilityLabel("Share")
        .accessibilityValue(copied ? String(localized: "Link copied!") : "")
        // The tick goes back to the share arrow after a moment.
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
