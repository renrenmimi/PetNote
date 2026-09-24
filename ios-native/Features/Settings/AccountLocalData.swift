import Foundation

/// What a deleted account leaves on this phone, removed when the server says
/// the account is gone.
///
/// Found by the legal review: the draft is kept per account for a day, but
/// its expiry is only checked when that same account opens the composer
/// again — which a deleted account never does — so its text, tags and the
/// addresses of its uploads stayed until the app itself was removed. The
/// image caches go too: they hold that account's pictures among others. So
/// does the list of spotlight posts the account opened, which has no expiry
/// at all.
enum AccountLocalData {
    static func forget(
        uid: String,
        drafts: any ComposeDraftStoring = UserDefaultsComposeDraftStore(),
        images: ImageLoader = .shared,
        seenSpotlights: any SpotlightSeenStoring = UserDefaultsSpotlightSeenStore()
    ) async {
        drafts.clear(uid: uid)
        seenSpotlights.clear(uid: uid)
        await images.clearAllCaches()
    }
}
