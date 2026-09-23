import Foundation
import Testing
import UIKit

@testable import PetNote

/// Sharing a post: the link, what goes with it, and the card.
@MainActor
struct SharingTests {
    private static func post(
        _ id: String = "p1", text: String = "TEST CONTENT a walk in the park",
        media: [MediaItem] = [], tags: [String] = []
    ) -> Post {
        Post(
            id: id, authorID: "a", authorName: "Alice", authorAvatarURL: nil,
            text: text, media: media, petID: nil, petName: nil,
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: 0, tags: tags
        )
    }

    /// A link somebody else can open: the live site's post page. The web
    /// built it from wherever the page was loaded, which in the old iPhone app
    /// was `capacitor://localhost`.
    @Test func theLinkIsTheLiveSitesPostPage() {
        #expect(PostShareContent.link(to: "abc123").absoluteString == "https://petnote.vercel.app/post/abc123")
    }

    /// Ids are the server's, but a link is built from one, so it is encoded
    /// rather than trusted to be path-safe.
    @Test func anIdCannotChangeWhereTheLinkGoes() {
        let link = PostShareContent.link(to: "a/../../settings")
        #expect(link.host() == "petnote.vercel.app")
        #expect(link.path(percentEncoded: true).hasPrefix("/post/"))
        #expect(!link.path(percentEncoded: true).dropFirst("/post/".count).contains("/"), "\(link)")
    }

    @Test func theTextIsTheFirstHundredCharacters() {
        let long = String(repeating: "喵", count: 150)
        #expect(PostShareContent.text(of: Self.post(text: long)).count == 100)
        #expect(PostShareContent.text(of: Self.post(text: "short")) == "short")
    }

    // MARK: - The card

    @Test func theCardsPictureIsThePhotoOrAVideosPoster() throws {
        let photo = try #require(URL(string: "https://res.cloudinary.com/demo/image/upload/v1/petnote/users/u/a.jpg"))
        let photoCard = PostShareCard(post: Self.post(media: [MediaItem(url: photo, kind: .image, thumbnailURL: nil)]))
        #expect(photoCard.pictureURL?.absoluteString.contains("w_800") == true)

        let clip = try #require(URL(string: "https://res.cloudinary.com/demo/video/upload/v1/petnote/users/u/clip.mp4"))
        let videoCard = PostShareCard(post: Self.post(media: [MediaItem(url: clip, kind: .video, thumbnailURL: nil)]))
        let poster = videoCard.pictureURL?.absoluteString ?? ""
        #expect(poster.hasSuffix(".jpg") && poster.contains("so_0"), "a video was handed over as a picture: \(poster)")

        #expect(PostShareCard(post: Self.post()).pictureURL == nil)
    }

    /// The web's 400 × 560, drawn at twice that. With no picture it still
    /// makes a card, as the web does with its grey box.
    @Test func theCardIsTheWebsSize() throws {
        let data = try PostShareCard.render(post: Self.post(tags: ["walk", "park"]), picture: nil)
        let image = try #require(UIImage(data: data))
        #expect(image.size.width * image.scale == 800)
        #expect(image.size.height * image.scale == 1120)
    }

    /// A long post, in Chinese, with no spaces to break at — the case that
    /// ran off the web's canvas — makes a card the same size.
    @Test func aLongPostStillMakesTheSameCard() throws {
        let long = String(repeating: "今天带它去公园散步了", count: 40)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let data = try PostShareCard.render(post: Self.post(text: long, tags: ["a", "b", "c", "d"]), picture: picture)
        let image = try #require(UIImage(data: data))
        #expect(image.size.width * image.scale == 800)
        #expect(image.size.height * image.scale == 1120)
    }
}
