import Foundation
import OSLog

/// An unfinished post.
///
/// A port of `PostDraft` in src/pages/Create.tsx, including the two fields that
/// are there for correctness rather than convenience:
///
///   - **`operationID`** is kept in the draft so a retry *after a relaunch*
///     reuses it and the server recognises the operation instead of publishing
///     a second post. An operation id that only lived in memory would make the
///     idempotency guarantee stop at the app being killed, which is exactly
///     when it is most needed.
///   - **`uploadedAssets`** are the asset *records*, not the files. Once an
///     upload succeeds the bytes are on the CDN, so resuming does not re-send
///     them. Files that were picked but never uploaded cannot be in here, and
///     the banner says so rather than promising more than the storage can keep.
///
/// `handedOff` is deliberately absent. The web client kept it, then stopped
/// writing it and then stopped reading it: the write that set it happens
/// immediately before publishing and can fail while publishing goes ahead, so a
/// persisted `false` can be stale in the one direction that matters. Nothing
/// here may act on such a value, so there is nowhere to put one.
struct ComposeDraft: Codable, Equatable, Sendable {
    var text: String
    var tags: [String]
    var petID: String?
    var savedAt: Date
    var operationID: String?
    var uploadedAssets: [UploadedAsset]

    init(
        text: String = "", tags: [String] = [], petID: String? = nil,
        savedAt: Date = Date(), operationID: String? = nil,
        uploadedAssets: [UploadedAsset] = []
    ) {
        self.text = text
        self.tags = tags
        self.petID = petID
        self.savedAt = savedAt
        self.operationID = operationID
        self.uploadedAssets = uploadedAssets
    }

    /// Whether there is anything worth keeping. Mirrors the web client's
    /// condition: text, tags, a chosen pet, or media already uploaded.
    var isWorthKeeping: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tags.isEmpty || petID != nil || !uploadedAssets.isEmpty
    }
}

protocol ComposeDraftStoring: Sendable {
    /// The stored draft for this account, or nil when there is none or it has
    /// expired. An expired draft is removed as a side effect.
    func load(uid: String) -> ComposeDraft?
    func save(_ draft: ComposeDraft, uid: String)
    func clear(uid: String)
}

/// Drafts in `UserDefaults`, one per account.
///
/// **Per account, and that is a fix rather than a detail.** The web client's
/// first key was a single global string, so two people sharing a browser saw
/// each other's unfinished post. The same mistake is available here — one
/// device, two accounts — and the same remedy applies.
///
/// **It outlives the process, unlike the web client's `sessionStorage`.** That
/// is a deliberate difference, not an oversight: the draft's own purpose is
/// that "a reload can pick the work back up", and on a phone the equivalent of
/// a reload is the system killing a backgrounded app — after which
/// `sessionStorage` would be gone and the operation id with it. The 24-hour
/// expiry is what keeps that from becoming "a post you forgot about surfacing
/// next week", and it is the same 24 hours the web client uses.
///
/// `@unchecked Sendable` because `UserDefaults` is not marked `Sendable` and is
/// nonetheless documented as thread-safe. The unchecked part is that claim and
/// nothing else: every stored property here is a `let`, and the type has no
/// mutable state of its own.
final class UserDefaultsComposeDraftStore: ComposeDraftStoring, @unchecked Sendable {
    static let lifetime: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "compose")

    init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    static func key(uid: String) -> String { "petnote_post_draft:\(uid)" }

    func load(uid: String) -> ComposeDraft? {
        guard let data = defaults.data(forKey: Self.key(uid: uid)) else { return nil }
        guard let draft = try? JSONDecoder().decode(ComposeDraft.self, from: data) else {
            // Unreadable, which a shape change from an older build can cause.
            // Dropped rather than left to fail every launch.
            defaults.removeObject(forKey: Self.key(uid: uid))
            return nil
        }
        if now().timeIntervalSince(draft.savedAt) > Self.lifetime {
            // The draft goes; its uploads stay on the CDN. See `AssetReclaim`
            // for why nothing is deleted here.
            _ = AssetReclaim.decide(assets: draft.uploadedAssets)
            defaults.removeObject(forKey: Self.key(uid: uid))
            return nil
        }
        return draft
    }

    func save(_ draft: ComposeDraft, uid: String) {
        guard draft.isWorthKeeping else { clear(uid: uid); return }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Self.key(uid: uid))
    }

    func clear(uid: String) {
        defaults.removeObject(forKey: Self.key(uid: uid))
    }
}
