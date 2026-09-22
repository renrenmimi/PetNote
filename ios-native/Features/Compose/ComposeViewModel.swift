import Foundation
import Observation
import OSLog

/// Drives the composer: pick, prepare, upload, publish.
///
/// Four things here exist because of specific ways publishing goes wrong, and
/// all four are ported from src/pages/Create.tsx rather than reinvented:
///
///   - **one operation id per submission, reused by every retry.** The server
///     derives the post's document id from it, so a retry after a lost response
///     returns the post the first attempt made. Without it the retry that this
///     screen actively encourages is the duplicate-posting bug.
///   - **each upload is recorded as it lands, not at the end.** A failure on
///     photo three must not throw photos one and two away, and a retry must not
///     make the person send them again.
///   - **nothing ever deletes uploaded media.** Past the handoff the publish
///     may have committed with the response lost, and deleting then leaves a
///     live post pointing at dead URLs — irreversibly. See `AssetReclaim`.
///   - **the stages are named separately.** "Uploading 2/3" while the CPU is
///     re-encoding a photo and nothing is on the wire is not just imprecise; on
///     a slow phone it points at the wrong thing.
@MainActor
@Observable
final class ComposeViewModel {
    // MARK: - Limits (the web client's, deliberately)

    static let maxCharacters = 2000
    static let maxFiles = 9
    static let maxTags = 20
    static let maxTagLength = 40
    /// Client-side hints. The enforceable ceiling is the Cloudinary account
    /// plan — see `UploadSignature.isAdvisory`. These exist so an oversize file
    /// is refused with a clear message instead of after a doomed upload.
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxVideoBytes = 80 * 1024 * 1024
    static let maxVideoSeconds: Double = 60

    // MARK: - Picked media

    /// One file the person chose, held in memory.
    ///
    /// The bytes live here and nowhere else: they are deliberately *not* in the
    /// draft. `sessionStorage` could not hold blobs on the web and this could
    /// hold them on disk, but writing a person's photo library into
    /// `UserDefaults` to survive a relaunch is a much worse trade than asking
    /// them to pick again — and anything that mattered is already on the CDN.
    struct PickedItem: Identifiable, Equatable, Sendable {
        let id: String
        /// Identity of the underlying file, for the duplicate check. The web
        /// client uses name+size+lastModified; the photo picker gives a stable
        /// local identifier, which is better.
        let sourceID: String
        let kind: MediaItem.Kind
        let data: Data
        let filename: String
        let mimeType: String
        /// Seconds, for a video. Nil for an image.
        let duration: Double?
    }

    /// Where a submission got to, so the feedback names the stage it is in.
    enum Phase: Equatable, Sendable {
        case idle
        case preparing(index: Int, total: Int)
        case uploading(index: Int, total: Int)
        case publishing
        case failed(stage: Stage)
        case published(postID: String, deduplicated: Bool)

        enum Stage: Sendable { case upload, publish }
    }

    // MARK: - State

    private(set) var items: [PickedItem] = []
    var caption: String = "" {
        didSet {
            if caption.count > Self.maxCharacters {
                caption = String(caption.prefix(Self.maxCharacters))
            }
        }
    }
    private(set) var tags: [String] = []
    var tagInput: String = ""
    var selectedPetID: String?
    private(set) var pets: [Pet] = []
    /// Nil until the pet list has been asked for, so "add a pet first" does not
    /// flash at people who do have pets.
    private(set) var petsLoaded = false

    private(set) var phase: Phase = .idle
    private(set) var uploadedAssets: [UploadedAsset] = []
    private(set) var operationID: String?

    /// A restorable draft found at launch. The banner shows while this is set.
    private(set) var restorableDraft: ComposeDraft?

    /// Why the last attempt failed, in words for the person.
    var failureMessage: String?
    /// Something true that is not a failure — "that earlier post did go
    /// through", "9 files maximum".
    var notice: String?

    /// Stays true from a successful publish until this model is discarded, so
    /// the window between success and the screen closing cannot accept a second
    /// submit. The web client needed the same lock for the same 600 ms.
    private(set) var hasPublished = false
    private var isSubmitting = false

    let uid: String
    /// Read by the view to show the "verify your email" state, and by
    /// `canShare`. `createPostCallable` refuses an unverified caller outright,
    /// so this is the client saying the same thing earlier and in words.
    let isEmailVerified: Bool
    private let uploader: any MediaUploading
    private let writes: any PostWriteRepository
    private let petSource: any PetChoiceProviding
    private let drafts: any ComposeDraftStoring
    private let onPublished: (@MainActor (String) -> Void)?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "compose")

    /// An in-flight "did that earlier attempt publish?" lookup.
    ///
    /// Informational only, and never load-bearing: see `PublishStatus`.
    private(set) var pendingStatusLookup: Task<Void, Never>?

    /// The selection this attempt's uploads line up with. Uploaded assets are
    /// matched to picked files **by position**, so any change to the selection
    /// invalidates them.
    private var attemptSelectionSignature: String = ""

    init(
        uid: String,
        isEmailVerified: Bool,
        uploader: any MediaUploading,
        writes: any PostWriteRepository,
        pets petSource: any PetChoiceProviding,
        drafts: any ComposeDraftStoring = UserDefaultsComposeDraftStore(),
        onPublished: (@MainActor (String) -> Void)? = nil
    ) {
        self.uid = uid
        self.isEmailVerified = isEmailVerified
        self.uploader = uploader
        self.writes = writes
        self.petSource = petSource
        self.drafts = drafts
        self.onPublished = onPublished
    }

    // MARK: - Start

    func start() async {
        restorableDraft = drafts.load(uid: uid)
        await loadPets()
    }

    func loadPets() async {
        defer { petsLoaded = true }
        do {
            pets = try await petSource.pets(ownedBy: uid)
            // One pet is not a choice; preselect it rather than making the
            // person tap the only option.
            if pets.count == 1, selectedPetID == nil { selectedPetID = pets[0].id }
        } catch {
            log.error("could not load pets: \(error.localizedDescription, privacy: .public)")
            pets = []
        }
    }

    // MARK: - Drafts

    func restoreDraft() {
        guard let draft = restorableDraft else { return }
        caption = draft.text
        tags = draft.tags
        selectedPetID = draft.petID
        // The attempt's identity and its media come back together. Resuming
        // publishes the same post rather than a second one, and does not
        // re-send bytes that are already on the CDN.
        operationID = draft.operationID.flatMap { OperationID.isValid($0) ? $0 : nil }
        uploadedAssets = draft.uploadedAssets
        attemptSelectionSignature = selectionSignature
        restorableDraft = nil
    }

    func discardDraft() {
        // Clears the draft locally, as it should. It does **not** delete the
        // uploaded photos: "I don't want this draft" is not evidence that no
        // post references them.
        _ = AssetReclaim.decide(assets: restorableDraft?.uploadedAssets ?? uploadedAssets)
        drafts.clear(uid: uid)
        restorableDraft = nil
        operationID = nil
        uploadedAssets = []
    }

    /// Writes the current state down. Called after each upload lands and again
    /// immediately before publishing, so a process death at any point resumes
    /// with the same operation id and the same media.
    func persistDraft() {
        guard !hasPublished else { return }
        drafts.save(
            ComposeDraft(
                text: caption, tags: tags, petID: selectedPetID, savedAt: Date(),
                operationID: operationID, uploadedAssets: uploadedAssets
            ),
            uid: uid
        )
    }

    // MARK: - Selection

    var selectionSignature: String { items.map(\.id).joined(separator: "|") }

    var remainingSlots: Int { max(0, Self.maxFiles - items.count) }

    /// Adds picked files, refusing the ones that cannot be posted.
    ///
    /// Returns nothing and reports through `notice`: every refusal here has a
    /// reason the person needs to read, and a thrown error would collapse nine
    /// separate reasons into one.
    func add(_ incoming: [PickedItem]) {
        guard !incoming.isEmpty else { return }
        if incoming.count > remainingSlots {
            notice = "Maximum \(Self.maxFiles) files allowed"
        }
        var accepted: [PickedItem] = []
        var known = Set(items.map(\.sourceID))
        var duplicates = 0

        for candidate in incoming.prefix(remainingSlots) {
            guard !known.contains(candidate.sourceID) else { duplicates += 1; continue }
            if let refusal = Self.refusal(for: candidate) { notice = refusal; continue }
            known.insert(candidate.sourceID)
            accepted.append(candidate)
        }
        if duplicates > 0 { notice = "Duplicate file skipped" }
        guard !accepted.isEmpty else { return }
        items += accepted
        selectionChanged()
    }

    func remove(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        selectionChanged()
    }

    /// Why this file cannot be posted, if it cannot.
    static func refusal(for item: PickedItem) -> String? {
        switch item.kind {
        case .image:
            // Checked on the *picked* bytes. Preparation shrinks most photos
            // well under this, so the message is about the original the person
            // recognises rather than about a re-encode they never saw.
            guard item.data.count <= UploadPreparation.Options.default.maxInputBytes else {
                return "That photo is too large to process."
            }
            return nil
        case .video:
            if item.data.count > maxVideoBytes {
                return "File too large. Images: max 10MB, Videos: max 80MB"
            }
            if let duration = item.duration, duration > maxVideoSeconds {
                return "Video must be under 60 seconds"
            }
            return nil
        }
    }

    /// The selection moved, so this attempt's uploads no longer line up with it.
    ///
    /// They are released — kept on the CDN, dropped from this attempt — and a
    /// fresh operation is started. Publishing a post whose media is a mix of
    /// two different selections is the alternative.
    private func selectionChanged() {
        let signature = selectionSignature
        defer { attemptSelectionSignature = signature }
        guard attemptSelectionSignature != signature, !uploadedAssets.isEmpty else { return }

        let staleOperationID = operationID
        _ = AssetReclaim.decide(assets: uploadedAssets)
        uploadedAssets = []
        operationID = nil
        phase = .idle

        guard let staleOperationID else { return }
        // Nothing is deleted either way. The lookup only lets us say something
        // true about what happened — and a `false` answer means "not visible
        // yet", not "never published", so only the `true` branch speaks.
        //
        // The handle is kept so the screen can drop it on the way out, and so a
        // test can wait for the answer rather than for a duration.
        pendingStatusLookup?.cancel()
        pendingStatusLookup = Task { [writes] in
            guard let status = try? await writes.publishStatus(operationID: staleOperationID),
                  case .published = status, !Task.isCancelled else { return }
            self.notice = "Your earlier post did go through — those photos are still in use."
        }
    }

    // MARK: - Tags

    /// Mirrors the server's `validateIncomingTags` (functions/src/posts.ts:79),
    /// which is what `createPostCallable` and `updatePostCallable` actually
    /// run — not `normalizeTags`, which is the aggregation trigger's lenient
    /// reader. Lowercase, strip a leading `#`, dedupe, cap the total, and
    /// **leave out any tag the callable would refuse**: over the length limit,
    /// or unusable as a `hashtags/{tag}` document id. Sending one gets the
    /// whole post refused with `invalid-argument`, and every retry with it.
    static func normalized(_ input: String, addingTo existing: [String]) -> [String] {
        var result = existing
        for tag in tagPieces(input) {
            guard result.count < maxTags else { break }
            guard !tag.isEmpty, refusal(forTag: tag) == nil else { continue }
            guard !result.contains(tag) else { continue }
            result.append(tag)
        }
        return result
    }

    /// The server's own words for the first tag in `input` it would refuse,
    /// or nil. `normalized` leaves such a tag out; this is how the person is
    /// told why, which the server's comment asks for — "a person who typed
    /// `dogs/cats` should be told, not have it disappear".
    static func tagRefusal(in input: String) -> String? {
        tagPieces(input).lazy.filter { !$0.isEmpty }.compactMap(refusal(forTag:)).first
    }

    /// `normalizeTagText`: trimmed, lowercased, one leading `#` removed.
    private static func tagPieces(_ input: String) -> [String] {
        input.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { piece in
            var tag = piece.trimmingCharacters(in: .whitespaces).lowercased()
            if tag.hasPrefix("#") { tag.removeFirst() }
            return tag
        }
    }

    /// `TAG_FORBIDDEN_CHARACTERS` in functions/src/posts.ts.
    private static let forbiddenTagCharacters: Set<Character> = [".", "*", "~", "/", "[", "]"]

    /// Why the callable would refuse this (already normalised) tag, in its
    /// own words, or nil.
    ///
    /// Length in **UTF-16 units**, because the server's `tag.length` is
    /// JavaScript's: 21 emoji are 21 Characters and 42 units, and the server
    /// refuses them.
    private static func refusal(forTag tag: String) -> String? {
        if tag.utf16.count > maxTagLength {
            return "Tags must be \(maxTagLength) characters or fewer."
        }
        // `/^__.*__$/` is Firestore's reserved id shape; the server rejects
        // it with the same sentence as the forbidden characters.
        let reserved = tag.count >= 4 && tag.hasPrefix("__") && tag.hasSuffix("__")
        if reserved || tag.contains(where: forbiddenTagCharacters.contains) {
            return "Tags cannot contain . * ~ / [ ] characters."
        }
        return nil
    }

    func commitTagInput() {
        let refusal = Self.tagRefusal(in: tagInput)
        let next = Self.normalized(tagInput, addingTo: tags)
        tagInput = ""
        if let refusal { notice = refusal }
        guard next != tags else { return }
        tags = next
        persistDraft()
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        persistDraft()
    }

    // MARK: - Publish

    /// Whether Share can do anything. Separate from the disabled state so the
    /// view and the tests ask the same question.
    var canShare: Bool {
        guard !hasPublished, !isSubmitting else { return false }
        guard isEmailVerified else { return false }
        guard selectedPetID != nil else { return false }
        // Either newly picked files, or media a previous attempt already got
        // onto the CDN. The second case is what lets a relaunched app finish a
        // post without making the person find the photos again — the web
        // client restores the assets and then refuses to publish them, which
        // is a gap rather than a decision.
        return !items.isEmpty || !uploadedAssets.isEmpty
    }

    func share() async {
        guard canShare, let petID = selectedPetID else { return }
        isSubmitting = true
        failureMessage = nil
        defer { isSubmitting = false }

        // One id for this submission, reused by every retry of it.
        let operationID = self.operationID ?? OperationID.new()
        self.operationID = operationID

        // True once the media has been handed to the publish call. From that
        // moment a failure is ambiguous — the write may have committed and the
        // response been lost — so nothing may be deleted, and the message has
        // to say that pressing Share again is safe.
        var handedOff = false
        do {
            let pending = Array(items.dropFirst(uploadedAssets.count))
            for (offset, item) in pending.enumerated() {
                let position = uploadedAssets.count + offset + 1
                phase = .preparing(index: position, total: items.count)
                let payload = try await prepared(item)
                phase = .uploading(index: position, total: items.count)
                let asset = try await uploader.upload(payload)
                // Recorded as it lands: a failure on the next one must not
                // throw this one away.
                uploadedAssets.append(asset)
                persistDraft()
            }

            phase = .publishing
            handedOff = true
            // Written before the call, so a relaunch resumes the same
            // operation with the same media. Deliberately no "we are
            // publishing" flag: that write can fail while publishing goes
            // ahead, and a stale copy of it is what made the web client delete
            // a live post's photos.
            persistDraft()

            let outcome = try await writes.publish(
                PublishRequest(
                    operationID: operationID,
                    text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                    tags: tags,
                    petID: petID,
                    media: uploadedAssets
                )
            )

            hasPublished = true
            drafts.clear(uid: uid)
            self.operationID = nil
            uploadedAssets = []
            items = []
            phase = .published(postID: outcome.postID, deduplicated: outcome.deduplicated)
            notice = outcome.deduplicated ? "That post was already published." : "Posted."
            // The feed's loaded pages cannot contain what was just made, so
            // whoever owns the list is told to go and get it. Without this the
            // person lands on a feed missing their own post and pull-to-refresh
            // is the only way to see it.
            onPublished?(outcome.postID)
        } catch {
            // Only the stage changes what can be said. Nothing is deleted on
            // either path: uploaded assets stay so the retry resumes from them,
            // and past the handoff they may already be referenced by a
            // committed post.
            phase = .failed(stage: handedOff ? .publish : .upload)
            failureMessage = Self.message(for: error, handedOff: handedOff)
            persistDraft()
            log.error("publish attempt failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Gets one picked file into the bytes that go on the wire.
    private func prepared(_ item: PickedItem) async throws -> UploadItem {
        switch item.kind {
        case .video:
            // Video is uploaded as picked. Re-encoding it on the phone costs
            // minutes and Cloudinary transcodes for delivery anyway.
            return UploadItem(
                data: item.data, filename: item.filename, mimeType: item.mimeType,
                resourceType: .video
            )
        case .image:
            let source = item
            // Off the main actor: this is a full decode and re-encode, and on
            // a large photo it is the slowest thing the composer does. Running
            // it here would stop the progress label it is supposed to be
            // driving from ever being drawn.
            let prepared = try await Task.detached(priority: .userInitiated) {
                try UploadPreparation.prepareImage(source.data, filename: source.filename)
            }.value
            if prepared.data.count > Self.maxImageBytes {
                throw UploadError.tooLarge(
                    limitBytes: Self.maxImageBytes, actualBytes: prepared.data.count
                )
            }
            return UploadItem(
                data: prepared.data, filename: prepared.filename,
                mimeType: prepared.mimeType, resourceType: .image
            )
        }
    }

    /// What to tell the person, and whether to invite them to press Share again.
    static func message(for error: Error, handedOff: Bool) -> String {
        let detail: String
        switch error {
        case let upload as UploadError:
            detail = describe(upload)
        case let write as PostWriteError:
            detail = describe(write)
        case let preparation as UploadPreparation.PreparationError:
            detail = describe(preparation)
        default:
            detail = "Something went wrong."
        }
        guard handedOff else { return detail }
        // Past the handoff the outcome is unknown, and the operation id is what
        // makes saying this honest rather than hopeful.
        return "\(detail) Press Share again — it won't post twice."
    }

    static func describe(_ error: UploadError) -> String {
        switch error {
        case .notSignedIn: "Please sign in again."
        case .banned: "Your account has been suspended."
        case .rateLimited: "Too many uploads just now. Wait a moment."
        case .signatureUnavailable: "Uploads are unavailable in this build."
        case .tooLarge(let limit, _):
            "That file is over the \(limit / (1024 * 1024))MB limit."
        case .timedOut: "The upload timed out. Check your connection."
        case .offline: "You appear to be offline."
        case .rejected: "That file was not accepted."
        case .malformedResponse: "The upload finished but could not be confirmed."
        case .transport: "The upload could not be completed."
        }
    }

    static func describe(_ error: PostWriteError) -> String {
        switch error {
        case .notSignedIn: "Please sign in again."
        case .emailNotVerified: "Verify your email before posting."
        case .banned: "Your account has been suspended."
        case .petNotAccessible: "You do not have access to that pet."
        case .postNotFound: "That post no longer exists."
        case .notTheAuthor: "You can only change your own posts."
        case .rateLimited: "Too many posts just now. Wait a moment."
        case .rejected(let words): words
        case .outcomeUnknown: "We could not tell whether that went through."
        case .transport(CallableTransport.unavailable):
            "This build cannot reach the server."
        case .transport: "The request could not be completed."
        }
    }

    static func describe(_ error: UploadPreparation.PreparationError) -> String {
        switch error {
        case .tooLargeToProcess(_, let limit):
            "That photo is over the \(limit / (1024 * 1024))MB limit."
        case .undecodable: "That photo could not be read."
        case .unencodable: "That photo could not be prepared for upload."
        }
    }

    /// What the Share button says while working.
    var phaseLabel: String {
        switch phase {
        case .preparing(let index, let total): "Preparing \(index)/\(total)…"
        case .uploading(let index, let total): "Uploading \(index)/\(total)…"
        case .publishing: "Publishing…"
        case .failed: "Retry"
        case .published: "Posted"
        case .idle: "Share"
        }
    }

    var isWorking: Bool {
        switch phase {
        case .preparing, .uploading, .publishing: true
        case .idle, .failed, .published: false
        }
    }
}
